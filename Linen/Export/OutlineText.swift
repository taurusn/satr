import CoreGraphics
import CoreText
import Foundation

/// Text for Linen's PDFs (PRD-2 EXP-5, EXP-8): each glyph is drawn as its outline, so the page looks like Thmanyah
/// while no Thmanyah font data enters the file, and the same words are written underneath as invisible text in
/// faces whose text maps cleanly (Geeza Pro for Arabic, Helvetica for the rest), so search, selection and copy
/// work. Quartz writes Thmanyah's own glyph-to-text map wrong for Arabic (0 of 8 words found), which is why the
/// visible layer carries no text at all.
///
/// Each distinct glyph outline is drawn once into a `CGLayer`, which Quartz writes as one vector form and then
/// reuses for every copy of that glyph (spike X(a): 57,600 glyphs took 2.6 MB as forms and 8.7 MB as paths).
///
/// Coordinates: the context's current transform must have y growing downwards (the display list's orientation);
/// `baseline` points are in those coordinates.
final class OutlineText {
    let ctx: CGContext
    /// PNG export draws glyphs with their fonts (a bitmap carries no font) and writes no invisible layer.
    let raster: Bool
    private var forms: [String: (layer: CGLayer, origin: CGPoint)] = [:]
    private var referenceFonts: [String: CTFont] = [:]
    private var faceFonts: [String: CTFont] = [:]
    private(set) var glyphsDrawn = 0
    private(set) var hiddenWords = 0
    var formCount: Int { forms.count }

    /// Outlines are made at this size and scaled down, so the form's coordinates keep their precision.
    private static let reference: CGFloat = 100

    init(context: CGContext, raster: Bool = false) {
        ctx = context
        self.raster = raster
    }

    // MARK: Fonts

    func font(_ face: Face, size: CGFloat) -> CTFont {
        let key = "\(face.rawValue)@\(size)"
        if let f = faceFonts[key] { return f }
        let f = CTFontCreateWithName(face.postScriptName as CFString, size, nil)
        faceFonts[key] = f
        return f
    }

    /// The CSS line box model WebKit uses: the content area (ascent plus descent, rounded) sits in the middle of
    /// the line box, and the baseline is its ascent below the content area's top.
    func baseline(top: CGFloat, height: CGFloat, font f: CTFont) -> CGFloat {
        let asc = CTFontGetAscent(f).rounded(), desc = CTFontGetDescent(f).rounded()
        return top + (height - (asc + desc)) / 2 + asc
    }

    // MARK: Lines

    /// A typeset line of `text` in one face, with the paragraph direction set so mixed lines order as WebKit's do.
    func typeset(_ text: String, face: Face, size: CGFloat, rtl: Bool, tracking: CGFloat = 0) -> CTLine {
        CTLineCreateWithAttributedString(attributed(text, face: face, size: size, rtl: rtl, tracking: tracking))
    }

    /// The same for any font (notes: code faces, fallbacks).
    func typeset(_ text: String, font f: CTFont, rtl: Bool, tracking: CGFloat = 0) -> CTLine {
        CTLineCreateWithAttributedString(attributed(text, font: f, rtl: rtl, tracking: tracking))
    }

    func attributed(_ text: String, face: Face, size: CGFloat, rtl: Bool, tracking: CGFloat = 0) -> NSAttributedString {
        attributed(text, font: font(face, size: size), rtl: rtl, tracking: tracking)
    }

    func attributed(_ text: String, font f: CTFont, rtl: Bool, tracking: CGFloat = 0) -> NSAttributedString {
        var dir = rtl ? CTWritingDirection.rightToLeft : CTWritingDirection.leftToRight
        let style = withUnsafeBytes(of: &dir) { buf in
            var settings = [CTParagraphStyleSetting(spec: .baseWritingDirection, valueSize: MemoryLayout<CTWritingDirection>.size, value: buf.baseAddress!)]
            return CTParagraphStyleCreate(&settings, 1)
        }
        var attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): f,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
        ]
        if tracking != 0 { attrs[NSAttributedString.Key(kCTKernAttributeName as String)] = tracking }
        return NSAttributedString(string: text, attributes: attrs)
    }

    /// Draws one display list line: placed on WebKit's line box, aligned to its leading edge (or centred on
    /// `rect.minX`), and stretched to WebKit's measured width when Core Text's differs by more than half a point.
    func draw(_ l: DisplayList.Line) {
        let line = typeset(l.text, face: l.face, size: l.size, rtl: l.rtl, tracking: l.tracking)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let base = l.baseline ?? baseline(top: l.rect.minY, height: l.rect.height, font: font(l.face, size: l.size))
        var sx: CGFloat = 1
        if !l.centered, l.rect.width > 0, width > 0, abs(width - l.rect.width) > 0.5 { sx = min(1.25, max(0.8, l.rect.width / width)) }
        let x = l.centered ? l.rect.minX - width / 2 : l.rtl ? l.rect.maxX - width * sx : l.rect.minX
        draw(line, text: l.text, x: x, baseline: base, xScale: sx, color: l.color, rtl: l.rtl)
    }

    /// The width a display list line takes (for the chip behind a label).
    func width(of l: DisplayList.Line) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(typeset(l.text, face: l.face, size: l.size, rtl: l.rtl, tracking: l.tracking), nil, nil, nil))
    }

    /// Draws a typeset line: its glyphs as outlines, then its words as invisible text over the same boxes.
    func draw(_ line: CTLine, text: String, x: CGFloat, baseline: CGFloat, xScale: CGFloat = 1, color: RGBA, rtl: Bool? = nil, oblique: Bool = false) {
        outlines(line, x: x, baseline: baseline, xScale: xScale, color: color, oblique: oblique)
        if raster { return }
        let ns = text as NSString
        let words = Self.words(ns).compactMap { r -> (NSRange, CGFloat, CGFloat)? in
            guard let v = glyphSpan(line, range: r) else { return nil }
            return (r, x + v.minX * xScale, x + v.maxX * xScale)
        }
        hidden(text: text, words: words, baseline: baseline, size: Self.size(of: line), rtl: rtl ?? Self.isRTL(text))
    }

    /// The glyphs of a typeset line as outlines only (callers that place words one by one write the invisible layer
    /// for the whole line once, with `hidden(text:words:...)`).
    func outlines(_ line: CTLine, x: CGFloat, baseline: CGFloat, xScale: CGFloat = 1, color: RGBA, oblique: Bool = false) {
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            guard let runFont = attrs[kCTFontAttributeName as String].map({ $0 as! CTFont }) else { continue }
            let n = CTRunGetGlyphCount(run)
            if n == 0 { continue }
            var glyphs = [CGGlyph](repeating: 0, count: n)
            var pos = [CGPoint](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: n), &pos)
            let size = CTFontGetSize(runFont)
            if raster {
                ctx.saveGState()
                ctx.translateBy(x: x, y: baseline)
                ctx.scaleBy(x: xScale, y: -1)
                ctx.textMatrix = CGAffineTransform(a: 1, b: 0, c: oblique ? 0.249328 : 0, d: 1, tx: 0, ty: 0)
                ctx.setFillColor(color.cg)
                CTFontDrawGlyphs(runFont, glyphs, pos, n, ctx)
                ctx.restoreGState()
                glyphsDrawn += n
                continue
            }
            for i in 0..<n {
                glyph(glyphs[i], font: runFont, size: size, at: CGPoint(x: x + pos[i].x * xScale, y: baseline - pos[i].y), xScale: xScale, color: color, oblique: oblique)
            }
        }
    }

    /// The visible extent of each word of a typeset line, in the context's coordinates.
    func wordExtents(_ line: CTLine, text: String, x: CGFloat, xScale: CGFloat = 1) -> [(NSRange, CGFloat, CGFloat)] {
        Self.words(text as NSString).compactMap { r in
            glyphSpan(line, range: r).map { (r, x + $0.minX * xScale, x + $0.maxX * xScale) }
        }
    }

    static func size(of line: CTLine) -> CGFloat {
        guard let first = (CTLineGetGlyphRuns(line) as! [CTRun]).first,
              let f = (CTRunGetAttributes(first) as NSDictionary)[kCTFontAttributeName as String] else { return 12 }
        return CTFontGetSize(f as! CTFont)
    }

    private func glyph(_ g: CGGlyph, font f: CTFont, size: CGFloat, at p: CGPoint, xScale: CGFloat, color: RGBA, oblique: Bool) {
        let ps = CTFontCopyPostScriptName(f) as String
        let key = "\(ps)|\(g)|\(color.key)\(oblique ? "|i" : "")"
        var form = forms[key]
        if form == nil {
            let ref = referenceFont(f, ps)
            // Thmanyah has no italic: WebKit slants the upright face by 14 degrees, and so does this.
            var slant = CGAffineTransform(a: 1, b: 0, c: oblique ? 0.249328 : 0, d: 1, tx: 0, ty: 0)
            guard let path = CTFontCreatePathForGlyph(ref, g, &slant) else {
                // No outline: a space (nothing to draw), or a colour emoji, drawn as it is (the one case the visible
                // layer holds a font). Thmanyah never takes this path.
                if CTFontGetSymbolicTraits(f).contains(.traitColorGlyphs) { drawPlain(g, font: f, at: p, color: color) }
                return
            }
            let box = path.boundingBoxOfPath
            if box.isEmpty || box.isNull { return }
            let pad: CGFloat = 1
            guard let layer = CGLayer(ctx, size: CGSize(width: box.width + 2 * pad, height: box.height + 2 * pad), auxiliaryInfo: nil),
                  let lc = layer.context else { return }
            lc.translateBy(x: -box.minX + pad, y: -box.minY + pad)
            lc.setFillColor(color.cg)
            lc.addPath(path)
            lc.fillPath()
            form = (layer, CGPoint(x: box.minX - pad, y: box.minY - pad))
            forms[key] = form
        }
        guard let form else { return }
        let s = size / Self.reference
        ctx.saveGState()
        ctx.translateBy(x: p.x, y: p.y)
        ctx.scaleBy(x: s * xScale, y: -s)
        ctx.draw(form.layer, at: form.origin)
        ctx.restoreGState()
        glyphsDrawn += 1
    }

    private func referenceFont(_ f: CTFont, _ ps: String) -> CTFont {
        if let r = referenceFonts[ps] { return r }
        let r = CTFontCreateCopyWithAttributes(f, Self.reference, nil, nil)
        referenceFonts[ps] = r
        return r
    }

    private func drawPlain(_ g: CGGlyph, font f: CTFont, at p: CGPoint, color: RGBA) {
        ctx.saveGState()
        ctx.translateBy(x: p.x, y: p.y)
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(color.cg)
        var glyph = g, origin = CGPoint.zero
        CTFontDrawGlyphs(f, &glyph, &origin, 1, ctx)
        ctx.restoreGState()
    }

    // MARK: The invisible layer

    /// Writes the line again as invisible text whose words sit exactly over the visible words, so a search hit or
    /// a selection lands on the word the reader sees and a copy reads in logical order with its spaces.
    ///
    /// How (spike X(a), `docs/spikes/export/README.md`): the whole line is typeset once in the searchable faces with
    /// the same paragraph direction; each word's glyphs are then drawn with one `CTFontDrawGlyphs` call, scaled
    /// horizontally to the visible word's width and anchored to its position, and each space at the gap. Drawing
    /// each word as its own `CTLine` made PDFKit read an Arabic line backwards, one word per line; one call per run
    /// without the per-word scale left gaps inside Arabic words that PDFKit read as spaces ("لي نن").
    /// `words` are the line's words (ranges in `text`) with the left and right edges of their visible glyphs.
    func hidden(text: String, words visible: [(NSRange, CGFloat, CGFloat)], baseline: CGFloat, size: CGFloat, rtl: Bool) {
        let ns = text as NSString
        guard !raster, ns.length > 0, !visible.isEmpty else { return }
        let hiddenText = NSMutableAttributedString(attributedString: Self.searchable(text, size: size))
        var dir = rtl ? CTWritingDirection.rightToLeft : CTWritingDirection.leftToRight
        let style = withUnsafeBytes(of: &dir) { buf in
            var settings = [CTParagraphStyleSetting(spec: .baseWritingDirection, valueSize: MemoryLayout<CTWritingDirection>.size, value: buf.baseAddress!)]
            return CTParagraphStyleCreate(&settings, 1)
        }
        hiddenText.addAttribute(NSAttributedString.Key(kCTParagraphStyleAttributeName as String), value: style, range: NSRange(location: 0, length: ns.length))
        let hiddenLine = CTLineCreateWithAttributedString(hiddenText)

        struct Word { var range: NSRange; var vlo, vhi, hlo, hhi: CGFloat }
        var words: [Word] = []
        for (r, lo, hi) in visible {
            guard hi > lo, let h = glyphSpan(hiddenLine, range: r) else { continue }
            words.append(Word(range: r, vlo: lo, vhi: hi, hlo: h.minX, hhi: h.maxX))
        }
        guard !words.isEmpty else { return }
        func word(_ i: CFIndex) -> Int? { words.firstIndex { i >= $0.range.location && i < $0.range.location + $0.range.length } }

        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        ctx.translateBy(x: 0, y: baseline)
        ctx.scaleBy(x: 1, y: -1)
        for run in CTLineGetGlyphRuns(hiddenLine) as! [CTRun] {
            guard let f = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String].map({ $0 as! CTFont }) else { continue }
            let n = CTRunGetGlyphCount(run)
            if n == 0 { continue }
            var g = [CGGlyph](repeating: 0, count: n), p = [CGPoint](repeating: .zero, count: n), idx = [CFIndex](repeating: 0, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &g)
            CTRunGetPositions(run, CFRange(location: 0, length: n), &p)
            CTRunGetStringIndices(run, CFRange(location: 0, length: n), &idx)
            var i = 0
            while i < n {
                let w = word(idx[i])
                var j = i + 1
                while j < n, word(idx[j]) == w { j += 1 }
                var s: CGFloat = 1
                var q: [CGPoint] = []
                if let w {
                    let m = words[w]
                    s = m.hhi > m.hlo ? max(0.3, min(3, (m.vhi - m.vlo) / (m.hhi - m.hlo))) : 1
                    q = (i..<j).map { CGPoint(x: (m.vlo + (p[$0].x - m.hlo) * s) / s, y: 0) }
                } else {
                    // White space: at the start of the gap between the words around it.
                    let before = words.last { $0.range.location + $0.range.length <= idx[i] }
                    let after = words.first { $0.range.location > idx[i] }
                    let a = before.map { rtl ? $0.vlo : $0.vhi } ?? 0
                    let b = after.map { rtl ? $0.vhi : $0.vlo } ?? a
                    q = (i..<j).map { _ in CGPoint(x: min(a, b), y: 0) }
                }
                var gg = Array(g[i..<j])
                ctx.textMatrix = CGAffineTransform(scaleX: s, y: 1)
                CTFontDrawGlyphs(f, &gg, &q, j - i, ctx)
                i = j
            }
        }
        ctx.restoreGState()
        hiddenWords += words.count
    }

    /// The visual extent of the glyphs that came from `range`.
    private func glyphSpan(_ line: CTLine, range: NSRange) -> (minX: CGFloat, maxX: CGFloat, width: CGFloat)? {
        var lo = CGFloat.infinity, hi = -CGFloat.infinity
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let n = CTRunGetGlyphCount(run)
            if n == 0 { continue }
            var idx = [CFIndex](repeating: 0, count: n), pos = [CGPoint](repeating: .zero, count: n), adv = [CGSize](repeating: .zero, count: n)
            CTRunGetStringIndices(run, CFRange(location: 0, length: n), &idx)
            CTRunGetPositions(run, CFRange(location: 0, length: n), &pos)
            CTRunGetAdvances(run, CFRange(location: 0, length: n), &adv)
            for i in 0..<n where idx[i] >= range.location && idx[i] < range.location + range.length {
                lo = min(lo, pos[i].x); hi = max(hi, pos[i].x + adv[i].width)
            }
        }
        return hi > lo ? (lo, hi, hi - lo) : nil
    }

    /// Word ranges (UTF-16) between runs of white space.
    static func words(_ s: NSString) -> [NSRange] {
        var out: [NSRange] = []
        var start = -1
        let ws = CharacterSet.whitespacesAndNewlines
        for i in 0..<s.length {
            let c = s.character(at: i)
            let isSpace = UnicodeScalar(c).map { ws.contains($0) } ?? false
            if isSpace {
                if start >= 0 { out.append(NSRange(location: start, length: i - start)); start = -1 }
            } else if start < 0 { start = i }
        }
        if start >= 0 { out.append(NSRange(location: start, length: s.length - start)) }
        return out
    }

    /// The word in faces whose glyphs map back to text: Geeza Pro for Arabic script, Helvetica for everything else.
    static func searchable(_ word: String, size: CGFloat) -> NSAttributedString {
        let geeza = CTFontCreateWithName("GeezaPro" as CFString, size, nil)
        let helvetica = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let out = NSMutableAttributedString(string: word)
        let ns = word as NSString
        var i = 0
        while i < ns.length {
            let arabic = isArabic(ns.character(at: i))
            var j = i + 1
            while j < ns.length, isArabic(ns.character(at: j)) == arabic { j += 1 }
            out.addAttribute(NSAttributedString.Key(kCTFontAttributeName as String), value: arabic ? geeza : helvetica, range: NSRange(location: i, length: j - i))
            i = j
        }
        return out
    }

    static func isArabic(_ c: unichar) -> Bool {
        (0x0600...0x06FF).contains(c) || (0x0750...0x077F).contains(c) || (0x08A0...0x08FF).contains(c)
            || (0xFB50...0xFDFF).contains(c) || (0xFE70...0xFEFF).contains(c) || c == 0x200C || c == 0x200D
    }

    // MARK: Paragraphs

    /// Lays out a paragraph across `width`, draws each line, and returns the height used. Lines hang from `top`.
    @discardableResult
    func paragraph(_ text: String, face: Face, size: CGFloat, color: RGBA, rtl: Bool, x: CGFloat, top: CGFloat, width: CGFloat,
                   lineHeight: CGFloat, maxLines: Int = .max) -> CGFloat {
        let typesetter = CTTypesetterCreateWithAttributedString(attributed(text, face: face, size: size, rtl: rtl))
        let ns = text as NSString
        var start = 0, y = top, count = 0
        while start < ns.length, count < maxLines {
            let n = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
            if n <= 0 { break }
            let piece = ns.substring(with: NSRange(location: start, length: n)).trimmingCharacters(in: .whitespacesAndNewlines)
            start += n
            if piece.isEmpty { continue }
            let line = typeset(piece, face: face, size: size, rtl: rtl)
            let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let base = baseline(top: y, height: lineHeight, font: font(face, size: size))
            draw(line, text: piece, x: rtl ? x + width - w : x, baseline: base, color: color, rtl: rtl)
            y += lineHeight
            count += 1
        }
        return y - top
    }

    /// How tall `paragraph` would draw, without drawing.
    func measure(_ text: String, face: Face, size: CGFloat, rtl: Bool, width: CGFloat, lineHeight: CGFloat) -> CGFloat {
        let typesetter = CTTypesetterCreateWithAttributedString(attributed(text, face: face, size: size, rtl: rtl))
        let ns = text as NSString
        var start = 0, lines = 0
        while start < ns.length {
            let n = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
            if n <= 0 { break }
            if !ns.substring(with: NSRange(location: start, length: n)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lines += 1 }
            start += n
        }
        return CGFloat(lines) * lineHeight
    }

    /// True when the text holds Arabic script, so a paragraph of it reads right to left.
    static func isRTL(_ s: String) -> Bool {
        for u in s.utf16 {
            if isArabic(u) { return true }
            if let sc = UnicodeScalar(u), CharacterSet.letters.contains(sc) { return false }
        }
        return false
    }
}
