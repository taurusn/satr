import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// Paper for paged exports.
enum PaperSize: String, CaseIterable, Sendable, Identifiable {
    case a4, a3, letter
    var id: String { rawValue }
    /// Portrait size in points.
    var portrait: CGSize {
        switch self {
        case .a4: CGSize(width: 595.28, height: 841.89)
        case .a3: CGSize(width: 841.89, height: 1190.55)
        case .letter: CGSize(width: 612, height: 792)
        }
    }
    var label: String {
        switch self {
        case .a4: "A4"
        case .a3: "A3"
        case .letter: String(localized: "Letter")
        }
    }
}

/// Board PDF (PRD-2 EXP-5): the whole board as one vector page sized to its content, or each section on paper
/// with card body never under 9 pt; always Paper; noted boxes numbered and the notes after as numbered sources.
/// Drawn by Linen from the renderer's display list, never by WebKit: Thmanyah as outlines with an invisible
/// searchable layer (`OutlineText`), so the file carries no Thmanyah font data and its Arabic can be searched.
enum BoardPDF {
    enum Shape: Sendable, Equatable {
        case whole
        case sections(PaperSize)
    }

    struct Output: Sendable {
        var pages: Int
        var bytes: Int
        var seconds: Double
        var glyphs: Int
        var forms: Int
        var hiddenWords: Int
        /// Sections whose body had to split across pages, by title.
        var splitSections: [String]
    }

    enum Failure: Error, CustomStringConvertible {
        case cannotCreate(URL), empty
        var description: String {
            switch self {
            case let .cannotCreate(u): String(localized: "Linen could not write \(u.lastPathComponent)")
            case .empty: String(localized: "This board has nothing to export")
            }
        }
    }

    /// CSS pixels to points: a board pixel prints at its true size.
    static let pointsPerPixel: CGFloat = 0.75
    /// The largest page side viewers are asked to support (PDF 1.7; WebKit splits at it too).
    static let maxSide: CGFloat = 14_400
    /// Card body is 15 px; 9 pt is the floor (EXP-5), so a section never prints smaller than 0.6 pt per pixel.
    static let minScale: CGFloat = 9.0 / 15.0
    static let margin: CGFloat = 36

    static func write(_ list: DisplayList, shape: Shape, sourcesPaper: PaperSize = .a4, title: String? = nil, to url: URL) throws -> Output {
        let started = Date()
        guard !list.items.isEmpty else { throw Failure.empty }
        let docTitle = title ?? list.title
        var info: [CFString: Any] = [kCGPDFContextCreator: "Linen"]
        if !docTitle.isEmpty { info[kCGPDFContextTitle] = docTitle }
        var first = CGRect(origin: .zero, size: sourcesPaper.portrait)
        guard let ctx = CGContext(url as CFURL, mediaBox: &first, info as CFDictionary) else { throw Failure.cannotCreate(url) }
        let text = OutlineText(context: ctx)
        let painter = BoardPainter(list: list, text: text, ctx: ctx)
        var pages = 0
        var outline: [[CFString: Any]] = []
        var split: [String] = []

        switch shape {
        case .whole:
            let content = list.size
            var scale = pointsPerPixel
            let longest = max(content.width, content.height) * scale + 2 * margin
            if longest > maxSide { scale = (maxSide - 2 * margin) / max(content.width, content.height) }
            var box = CGRect(x: 0, y: 0, width: content.width * scale + 2 * margin, height: content.height * scale + 2 * margin)
            ctx.beginPage(mediaBox: &box)
            paper(ctx, box)
            ctx.saveGState()
            ctx.translateBy(x: margin, y: box.height - margin)
            ctx.scaleBy(x: scale, y: -scale)
            painter.paint(visible: CGRect(origin: .zero, size: content))
            ctx.restoreGState()
            ctx.endPage()
            pages += 1
            outline.append([kCGPDFOutlineTitle: docTitle.isEmpty ? String(localized: "Board") : docTitle, kCGPDFOutlineDestination: pages])

        case let .sections(paperSize):
            // Top-level sections, each on its own pages (nested ones print inside them), then whatever lies
            // outside every section, so no box is left out.
            var sections = list.sections.filter { $0.depth == 0 }
            let outside = painter.nodeBoxes.filter { b in !sections.contains { $0.rect.insetBy(dx: -1, dy: -1).contains(b) } }
            if sections.isEmpty {
                sections = [DisplayList.Section(id: "", title: docTitle, rect: CGRect(origin: .zero, size: list.size))]
            } else if let first = outside.first {
                let r = outside.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -24, dy: -24)
                sections.append(DisplayList.Section(id: "", title: String(localized: "Outside sections"), rect: r))
            }
            for section in sections {
                // Section names sit above their sections, so the page takes in the band above the box.
                let r = section.rect.insetBy(dx: -16, dy: 0).union(CGRect(x: section.rect.minX, y: section.rect.minY - 44, width: 1, height: 1))
                let top: CGFloat = 54, bottom: CGFloat = 40
                // Body never under 9 pt: the floor comes from the smallest box text in this section (a table in a
                // card may be 13.5 px, not 15). Chrome under 12 px (pills, eyebrows) is not body.
                let body = list.items.compactMap { item -> CGFloat? in
                    if case let .text(l) = item, l.role == nil, l.size >= 12, section.rect.contains(CGPoint(x: l.rect.midX, y: l.rect.midY)) { return l.size }
                    return nil
                }.min() ?? 15
                // The orientation that needs fewer pages at that floor; on a tie, the section's own shape.
                func layout(_ landscape: Bool) -> (paper: CGSize, area: CGSize, scale: CGFloat, tiles: [CGRect]) {
                    let paperBox = landscape ? CGSize(width: paperSize.portrait.height, height: paperSize.portrait.width) : paperSize.portrait
                    let area = CGSize(width: paperBox.width - 2 * margin, height: paperBox.height - top - bottom)
                    let fit = min(area.width / r.width, area.height / r.height, 1)
                    let scale = max(fit, 9 / body)
                    let tiles = scale > fit ? cuts(for: r, scale: scale, area: area, nodes: painter.nodeBoxes) : [r]
                    return (paperBox, area, scale, tiles)
                }
                let byShape = layout(r.width > r.height), other = layout(!(r.width > r.height))
                let chosen = other.tiles.count < byShape.tiles.count ? other : byShape
                let (paperBox, area, scale, tiles) = (chosen.paper, chosen.area, chosen.scale, chosen.tiles)
                if tiles.count > 1 { split.append(section.title) }
                for (i, tile) in tiles.enumerated() {
                    var box = CGRect(origin: .zero, size: paperBox)
                    ctx.beginPage(mediaBox: &box)
                    paper(ctx, box)
                    pages += 1
                    header(text, ctx, box: box, left: docTitle, right: tiles.count > 1 ? "\(section.title) · \(i + 1)/\(tiles.count)" : section.title, rtl: list.rtl)
                    footer(text, ctx, box: box, page: pages)
                    ctx.saveGState()
                    let drawn = CGSize(width: tile.width * scale, height: tile.height * scale)
                    let ox = margin + (area.width - drawn.width) / 2
                    ctx.translateBy(x: ox, y: box.height - top)
                    ctx.scaleBy(x: scale, y: -scale)
                    ctx.translateBy(x: -tile.minX, y: -tile.minY)
                    ctx.clip(to: tile)
                    painter.paint(visible: tile)
                    ctx.restoreGState()
                    ctx.endPage()
                }
                let title = section.title.isEmpty ? String(localized: "Section") : section.title
                outline.append([kCGPDFOutlineTitle: title, kCGPDFOutlineDestination: pages - tiles.count + 1])
            }
        }

        if !list.notes.isEmpty {
            let first = pages + 1
            pages += Sources.write(list.notes, ctx: ctx, text: text, paper: sourcesPaper, firstPage: pages + 1, rtl: list.rtl)
            outline.append([kCGPDFOutlineTitle: String(localized: "Sources"), kCGPDFOutlineDestination: first])
        }
        CGPDFContextSetOutline(ctx, [kCGPDFOutlineChildren: outline] as CFDictionary)
        ctx.closePDF()
        compactInPlace(url, pages: pages)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return Output(pages: pages, bytes: bytes, seconds: Date().timeIntervalSince(started), glyphs: text.glyphsDrawn,
                      forms: text.formCount, hiddenWords: text.hiddenWords, splitSections: split)
    }

    /// Shrinks the file Quartz wrote (`PDFCompact`) and keeps the result only if it reads back the same: every page
    /// there, each with its box, its contents and its resources.
    static func compactInPlace(_ url: URL, pages: Int) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int), size <= PDFCompact.maxBytes,
              let data = try? Data(contentsOf: url), let small = PDFCompact.compact(data), small.count < data.count,
              let before = CGPDFDocument(url as CFURL), let provider = CGDataProvider(data: small as CFData),
              let after = CGPDFDocument(provider), after.numberOfPages == pages, before.numberOfPages == pages else { return }
        for i in 1...max(1, pages) {
            guard let a = after.page(at: i), let b = before.page(at: i), a.getBoxRect(.mediaBox) == b.getBoxRect(.mediaBox),
                  let dict = a.dictionary else { return }
            var contents: CGPDFObjectRef?, resources: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetObject(dict, "Contents", &contents), contents != nil,
                  CGPDFDictionaryGetDictionary(dict, "Resources", &resources), resources != nil else { return }
        }
        try? small.write(to: url, options: .atomic)
    }

    static func paper(_ ctx: CGContext, _ box: CGRect) {
        ctx.setFillColor(RGBA.paper.cg)
        ctx.fill(box)
    }

    /// Running heads in Sans 8.5 pt: the board on the leading side, the section on the trailing side.
    static func header(_ text: OutlineText, _ ctx: CGContext, box: CGRect, left: String, right: String, rtl: Bool) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: box.height)
        ctx.scaleBy(x: 1, y: -1)
        let quiet = RGBA(r: 0x1F / 255, g: 0x33 / 255, b: 0x28 / 255, a: 0.7)
        for (s, leading) in [(left, true), (right, false)] where !s.isEmpty {
            let r = OutlineText.isRTL(s)
            let line = text.typeset(s, face: .sans, size: 8.5, rtl: r)
            let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let atLeft = leading != rtl
            text.draw(line, text: s, x: atLeft ? margin : box.width - margin - w, baseline: 28, color: quiet)
        }
        ctx.setFillColor(RGBA.rule.cg)
        ctx.fill(CGRect(x: margin, y: 36, width: box.width - 2 * margin, height: 0.5))
        ctx.restoreGState()
    }

    static func footer(_ text: OutlineText, _ ctx: CGContext, box: CGRect, page: Int) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: box.height)
        ctx.scaleBy(x: 1, y: -1)
        let s = "\(page)"
        let line = text.typeset(s, face: .sans, size: 8.5, rtl: false)
        let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        text.draw(line, text: s, x: (box.width - w) / 2, baseline: box.height - 20, color: RGBA(r: 0x1F / 255, g: 0x33 / 255, b: 0x28 / 255, a: 0.7))
        ctx.restoreGState()
    }

    /// Splits a section that does not fit one page at `scale` into page tiles, cutting between rows (and, if it is
    /// too wide, between columns) of cards wherever a cut can avoid going through one.
    static func cuts(for r: CGRect, scale: CGFloat, area: CGSize, nodes: [CGRect]) -> [CGRect] {
        let pageW = area.width / scale, pageH = area.height / scale
        func lines(from a: CGFloat, to b: CGFloat, step: CGFloat, spans: [(CGFloat, CGFloat)]) -> [CGFloat] {
            var out = [a]
            var at = a
            while b - at > step {
                // The lowest cut between rows of cards, however short the page; only when there is none (a card
                // taller than the page, or a masonry of columns with no clean rows), the cut in the page's lower half
                // that goes through the fewest cards.
                let short = spans.filter { $0.1 - $0.0 <= step }
                func crossings(_ y: CGFloat) -> Int { short.reduce(0) { $0 + ($1.0 < y - 0.5 && $1.1 > y + 0.5 ? 1 : 0) } }
                var candidates: [CGFloat] = [at + step]
                for s in short where s.0 - 2 > at && s.0 - 2 < at + step { candidates.append(s.0 - 2) }
                candidates.sort(by: >)
                var cut = candidates.first { $0 > at + 1 && crossings($0) == 0 }
                if cut == nil {
                    cut = candidates.filter { $0 >= at + step * 0.5 }.min { crossings($0) < crossings($1) || crossings($0) == crossings($1) && $0 > $1 }
                }
                let y = cut ?? at + step
                out.append(y)
                at = y
            }
            out.append(b)
            return out
        }
        let inside = nodes.filter { $0.intersects(r) }
        let ys = lines(from: r.minY, to: r.maxY, step: pageH, spans: inside.map { ($0.minY, $0.maxY) }.sorted { $0.0 > $1.0 })
        let xs = lines(from: r.minX, to: r.maxX, step: pageW, spans: inside.map { ($0.minX, $0.maxX) }.sorted { $0.0 > $1.0 })
        var tiles: [CGRect] = []
        for j in 0..<(ys.count - 1) {
            for i in 0..<(xs.count - 1) {
                tiles.append(CGRect(x: xs[i], y: ys[j], width: xs[i + 1] - xs[i], height: ys[j + 1] - ys[j]))
            }
        }
        return tiles
    }
}

/// Paints display list items into a context whose transform has y growing downwards, in board pixels.
final class BoardPainter {
    let list: DisplayList
    let text: OutlineText
    let ctx: CGContext
    private var images: [Int: CGImage] = [:]
    /// Card boxes, for page cuts.
    let nodeBoxes: [CGRect]
    /// Each box by id, to clip its text.
    private let boxes: [String: CGRect]

    init(list: DisplayList, text: OutlineText, ctx: CGContext) {
        self.list = list
        self.text = text
        self.ctx = ctx
        nodeBoxes = list.items.compactMap { if case let .rect(b) = $0, b.node != nil, b.role != "section", b.role != "pill" { return b.rect }; return nil }
        var byID: [String: CGRect] = [:]
        for case let .rect(b) in list.items where b.role == "node" { if let id = b.node { byID[id] = b.rect } }
        boxes = byID
    }

    /// Draws every item that touches `visible`; the rest never enters the file.
    func paint(visible: CGRect) {
        var clips = 0
        for (i, item) in list.items.enumerated() {
            switch item {
            case let .rect(b):
                if b.rect.insetBy(dx: -6, dy: -6).intersects(visible) { rect(b) }
            case let .path(s):
                if s.path.boundingBoxOfPath.insetBy(dx: -s.lineWidth - 4, dy: -s.lineWidth - 4).intersects(visible) { shape(s) }
            case let .text(l):
                let reach = l.centered ? CGRect(x: l.rect.minX - 400, y: l.rect.minY, width: 800, height: max(1, l.rect.height)) : l.rect
                guard reach.insetBy(dx: -2, dy: -2).intersects(visible) else { continue }
                if l.chip { chip(for: l) }
                if let id = l.node, let box = boxes[id] {
                    // what the card hides on screen is not drawn, nor searchable
                    if l.rect.minY >= box.maxY - 1 || l.rect.maxY <= box.minY { continue }
                    if l.rect.maxY > box.maxY || l.rect.minX < box.minX - 1 || l.rect.maxX > box.maxX + 1 {
                        ctx.saveGState()
                        ctx.clip(to: box)
                        text.draw(l)
                        ctx.restoreGState()
                        continue
                    }
                }
                text.draw(l)
            case let .image(p):
                if p.rect.intersects(visible) { image(p, index: i) }
            case let .clip(r):
                ctx.saveGState()
                ctx.clip(to: r)
                clips += 1
            case .unclip:
                if clips > 0 { ctx.restoreGState(); clips -= 1 }
            }
        }
        while clips > 0 { ctx.restoreGState(); clips -= 1 }
        marks(visible: visible)
    }

    /// The paper chip under a connector label (BRD-4).
    private func chip(for l: DisplayList.Line) {
        let w = text.width(of: l)
        let x = l.centered ? l.rect.minX - w / 2 : (l.rtl ? l.rect.maxX - w : l.rect.minX)
        let r = CGRect(x: x - 6, y: l.rect.minY, width: w + 12, height: max(l.rect.height, l.size + 6))
        let path = CGPath(roundedRect: r, cornerWidth: 2, cornerHeight: 2, transform: nil)
        ctx.setFillColor(RGBA.paper.cg)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.setStrokeColor(RGBA.rule.cg)
        ctx.setLineWidth(1)
        ctx.addPath(path)
        ctx.strokePath()
    }

    private func rect(_ b: DisplayList.Box) {
        let r = b.rect
        let path = b.radius > 0 ? CGPath(roundedRect: r, cornerWidth: min(b.radius, r.width / 2), cornerHeight: min(b.radius, r.height / 2), transform: nil) : CGPath(rect: r, transform: nil)
        if b.shadow {
            // Loom's soft ink shadow as two faint offset shapes: Quartz writes a real shadow as a bitmap.
            for (dy, grow, alpha) in [(CGFloat(1), CGFloat(0), CGFloat(0.07)), (3, 1, 0.04)] {
                ctx.setFillColor(RGBA.ink.cg.copy(alpha: alpha)!)
                ctx.addPath(CGPath(roundedRect: r.insetBy(dx: -grow, dy: -grow).offsetBy(dx: 0, dy: dy), cornerWidth: b.radius + grow, cornerHeight: b.radius + grow, transform: nil))
                ctx.fillPath()
            }
        }
        if let f = b.fill {
            ctx.setFillColor(f.cg)
            ctx.addPath(path)
            ctx.fillPath()
        }
        if let h = b.hatch {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            ctx.setStrokeColor(h.color.cg)
            ctx.setLineWidth(h.lineWidth)
            var x = r.minX - r.height
            while x < r.maxX {
                ctx.move(to: CGPoint(x: x, y: r.maxY))
                ctx.addLine(to: CGPoint(x: x + r.height, y: r.minY))
                x += h.gap
            }
            ctx.strokePath()
            ctx.restoreGState()
        }
        if let s = b.stroke, b.lineWidth > 0 {
            ctx.saveGState()
            ctx.setStrokeColor(s.cg)
            ctx.setLineWidth(b.lineWidth)
            if !b.dash.isEmpty { ctx.setLineDash(phase: 0, lengths: b.dash) }
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    private func shape(_ s: DisplayList.Shape) {
        ctx.saveGState()
        if let f = s.fill {
            ctx.setFillColor(f.cg)
            ctx.addPath(s.path)
            ctx.fillPath()
        }
        if let st = s.stroke, s.lineWidth > 0 {
            ctx.setStrokeColor(st.cg)
            ctx.setLineWidth(s.lineWidth)
            ctx.setLineCap(s.roundCap ? .round : .butt)
            ctx.setLineJoin(.round)
            if !s.dash.isEmpty { ctx.setLineDash(phase: 0, lengths: s.dash) }
            ctx.addPath(s.path)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    /// Pixels per board pixel an image is decoded at: twice its drawn size is crisp in print; PNG sets its scale.
    var imageScale: CGFloat = 2

    private func image(_ p: DisplayList.Picture, index: Int) {
        var img = images[index]
        // Decoded no larger than drawn, so a small file declaring a huge picture costs only what it shows.
        if img == nil, let src = CGImageSourceCreateWithData(p.data as CFData, nil) {
            let side = min(8192, max(1, Int((max(p.rect.width, p.rect.height) * imageScale).rounded(.up))))
            img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: side,
                                                              kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            images[index] = img
        }
        guard let img else { return }
        ctx.saveGState()
        ctx.translateBy(x: p.rect.minX, y: p.rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(origin: .zero, size: p.rect.size))
        ctx.restoreGState()
    }

    /// The numbers on noted boxes (EXP-5, NOTE-3): a small paper chip at the note's anchor.
    private func marks(visible: CGRect) {
        for note in list.notes {
            guard let a = note.anchor else { continue }
            let label = "\(note.number)"
            let line = text.typeset(label, face: .sans500, size: 10, rtl: false)
            let w = max(16, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) + 8)
            let chip = CGRect(x: list.rtl ? a.x + 4 : a.x - w - 4, y: a.y + 4, width: w, height: 16)
            guard chip.intersects(visible) else { continue }
            ctx.setFillColor(RGBA.paper2.cg)
            ctx.addPath(CGPath(roundedRect: chip, cornerWidth: 2, cornerHeight: 2, transform: nil))
            ctx.fillPath()
            ctx.setStrokeColor(RGBA.ink.cg)
            ctx.setLineWidth(0.75)
            ctx.addPath(CGPath(roundedRect: chip, cornerWidth: 2, cornerHeight: 2, transform: nil))
            ctx.strokePath()
            let lw = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            text.draw(line, text: label, x: chip.midX - lw / 2, baseline: text.baseline(top: chip.minY, height: chip.height, font: text.font(.sans500, size: 10)), color: RGBA.ink)
        }
    }
}

/// The numbered sources that follow a board or a page in print (NOTE-3): title, area, body and references, on
/// paper pages with page numbers. Returns how many pages it wrote.
enum Sources {
    static func write(_ notes: [DisplayList.Note], ctx: CGContext, text: OutlineText, paper: PaperSize, firstPage: Int, rtl: Bool) -> Int {
        let box0 = CGRect(origin: .zero, size: paper.portrait)
        let m = BoardPDF.margin + 18
        let width = box0.width - 2 * m
        let bottomLimit = box0.height - 56
        var pages = 0
        var y: CGFloat = 0
        func newPage() {
            if pages > 0 { ctx.restoreGState(); ctx.endPage() }
            var box = box0
            ctx.beginPage(mediaBox: &box)
            BoardPDF.paper(ctx, box)
            BoardPDF.footer(text, ctx, box: box, page: firstPage + pages)
            pages += 1
            ctx.saveGState()
            ctx.translateBy(x: 0, y: box.height)
            ctx.scaleBy(x: 1, y: -1)
            y = 64
        }
        /// Any field, line by line: what does not fit continues on the next page, so nothing is lost (NOTE-3).
        func flow(_ s: String, face: Face, size: CGFloat, color: RGBA, lineHeight: CGFloat) {
            let r = OutlineText.isRTL(s) || (s.isEmpty && rtl)
            var remaining = s
            while !remaining.isEmpty {
                var room = Int((bottomLimit - y) / lineHeight)
                if room < 1 { newPage(); room = Int((bottomLimit - y) / lineHeight) }
                if room < 1 { return }
                let total = Int((text.measure(remaining, face: face, size: size, rtl: r, width: width, lineHeight: lineHeight) / lineHeight).rounded())
                y += text.paragraph(remaining, face: face, size: size, color: color, rtl: r, x: m, top: y, width: width, lineHeight: lineHeight, maxLines: room)
                if total <= room { return }
                let next = rest(of: remaining, afterLines: room, text: text, face: face, size: size, rtl: r, width: width)
                // Core Text could not break it at this width and gave it back whole: stop rather than loop.
                if next == remaining || next.isEmpty { return }
                remaining = next
                newPage()
            }
        }
        newPage()
        let title = String(localized: "Sources")
        let tl = text.typeset(title, face: .serif, size: 24, rtl: rtl)
        let tw = CGFloat(CTLineGetTypographicBounds(tl, nil, nil, nil))
        text.draw(tl, text: title, x: rtl ? m + width - tw : m, baseline: y + 24, color: RGBA.ink, rtl: rtl)
        y += 48
        let quiet = RGBA(r: 0x1F / 255, g: 0x33 / 255, b: 0x28 / 255, a: 0.75)
        for note in notes {
            let heading = note.title.isEmpty ? "\(note.number)" : "\(note.number). \(note.title)"
            // keep a heading with at least two lines of what follows
            if y + 15 + 28 > bottomLimit { newPage() }
            flow(heading, face: .sans500, size: 10.5, color: RGBA.ink, lineHeight: 15)
            if !note.area.isEmpty { flow(note.area.uppercased(), face: .sans500, size: 7.5, color: quiet, lineHeight: 12) }
            for para in plain(note.body).components(separatedBy: "\n") where !para.trimmingCharacters(in: .whitespaces).isEmpty {
                flow(para, face: .sans, size: 9.5, color: RGBA.ink2, lineHeight: 14)
            }
            for ref in note.refs { flow(ref, face: .mono, size: 8, color: RGBA.ink2, lineHeight: 13) }
            y += 12
        }
        ctx.restoreGState()
        ctx.endPage()
        return pages
    }

    /// The text left after `lines` lines of a paragraph laid out at `width`.
    private static func rest(of s: String, afterLines lines: Int, text: OutlineText, face: Face, size: CGFloat, rtl: Bool, width: CGFloat) -> String {
        let ns = s as NSString
        let ts = CTTypesetterCreateWithAttributedString(text.attributed(s, face: face, size: size, rtl: rtl))
        var start = 0
        for _ in 0..<lines {
            let n = CTTypesetterSuggestLineBreak(ts, start, Double(width))
            if n <= 0 { break }
            start += n
        }
        return start >= ns.length ? "" : ns.substring(from: start).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Markdown to plain text for print: emphasis marks dropped, links as "text (address)", code as its text.
    static func plain(_ md: String) -> String {
        var s = md
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\(([^)]+)\)"#, with: "$1 ($2)", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\*\*|__|`"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^\s{0,3}#{1,6}\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^\s*[-*+]\s+"#, with: "• ", options: .regularExpression)
        return s
    }
}
