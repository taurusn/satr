import AppKit
import CoreText
import Foundation
import WebKit

/// Note and page PDF with Arabic you can search (PRD-2 EXP-8, spike X(b)). WebKit lays the note out at the paper's
/// width and draws everything but the text; Linen paginates between lines and blocks, takes one vector slice of
/// WebKit's drawing per page, and draws every line of text over it from the DOM's own line boxes as Thmanyah
/// outlines with the invisible searchable layer (`OutlineText`). This replaces Linen 1's print path, whose PDFs
/// embedded Thmanyah and read back 0 of 8 Arabic test words.
///
/// The web view is a dedicated offscreen one (`makeHost`) showing the note in Linen's renderer, or a sealed page
/// (PAGE-9, EXP-7); the export changes its DOM (it hides the text it redraws), so it is discarded afterwards. Text
/// in a face Linen cannot outline (a page's own web font) stays WebKit's: drawn and searchable as that font allows.
@MainActor
enum NotePDF {
    struct Options: Sendable {
        var paper: PaperSize = .a4
        var title: String = ""
        /// Paper behind the page instead of white (the Print sheet's "Paper background").
        var paperBackground = false
        /// Spike X(b)'s comparison: WebKit draws the text itself (Thmanyah embedded) with the same page breaks.
        var reference = false
        /// EXP-7's one long page instead of paper pages, scaled to fit 14,400 pt when taller.
        var longPage = false
        /// Ask Linen's renderer to finish lazy blocks (code, math, diagrams) first. Off for sealed pages: their
        /// page world is the page's own code.
        var prepareRenderer = true
    }

    struct Output: Sendable {
        var pages: Int
        var bytes: Int
        var seconds: Double
        var segments: Int
        /// Segments drawn word by word because Core Text's line did not match WebKit's within 1.5 percent.
        var wordFallbacks: Int
        var glyphs: Int
        /// Each drawn line's box in page points (origin at the bottom left), for checks.
        var lineBoxes: [LineBox]
    }

    struct LineBox: Sendable {
        var page: Int
        var rect: CGRect
        var text: String
        /// The words' boxes as WebKit laid them out, in the same page points.
        var words: [(text: String, rect: CGRect)]
    }

    enum Failure: Error, CustomStringConvertible {
        case layout(String), cannotCreate(URL)
        var description: String {
            switch self {
            case let .layout(why): String(localized: "Linen could not lay out this note for PDF: \(why)")
            case let .cannotCreate(u): String(localized: "Linen could not write \(u.lastPathComponent)")
            }
        }
    }

    /// Page geometry in points. CSS pixels print at 0.75 pt, so the web view is `contentWidth` pixels wide.
    static let margins = (top: CGFloat(58), bottom: CGFloat(50), side: CGFloat(52))
    static let pointsPerPixel: CGFloat = 0.75

    static func contentWidth(_ paper: PaperSize) -> CGFloat {
        ((paper.portrait.width - 2 * margins.side) / pointsPerPixel).rounded(.down)
    }

    /// An offscreen window and web view at the paper's content width, from a configuration that already carries
    /// the renderer's schemes (as `DocumentWindow.build` makes them).
    static func makeHost(configuration: WKWebViewConfiguration, paper: PaperSize) -> (NSWindow, WKWebView) {
        let w = contentWidth(paper)
        let window = NSWindow(contentRect: NSRect(x: -32000, y: -32000, width: w, height: 1200), styleMask: [.borderless], backing: .buffered, defer: false)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: w, height: 1200), configuration: configuration)
        web.mediaType = "print"
        window.contentView = web
        window.orderBack(nil)
        return (window, web)
    }

    /// A dedicated offscreen renderer holding one note at the paper's width, for `write`. The configuration must carry
    /// the renderer's schemes (as `DocumentWindow.build` sets them) and no "linen" message handler: the host adds its
    /// own to learn when the page is ready and rendered.
    @MainActor
    final class Host: NSObject, WKScriptMessageHandler {
        let window: NSWindow
        let web: WKWebView
        private var seen: Set<String> = []
        private var waiting: [(String, CheckedContinuation<Bool, Never>)] = []

        init(configuration: WKWebViewConfiguration, paper: PaperSize) {
            let proxy = WeakHandler()
            configuration.userContentController.add(proxy, name: "linen")
            (window, web) = NotePDF.makeHost(configuration: configuration, paper: paper)
            super.init()
            proxy.target = self
        }

        /// Loads the renderer, sends `settings` and `load` (the same messages a tab sends), and waits for "rendered".
        func open(renderer: URL = URL(string: "linen-app://renderer/page.html")!, settings: [String: Any], load: [String: Any], timeout: Double = 20) async -> Bool {
            web.load(URLRequest(url: renderer))
            guard await wait("ready", timeout: timeout) else { return false }
            var s = settings
            s["type"] = "settings"
            s["theme"] = "paper"
            _ = try? await web.callAsyncJavaScript("return await window.linen.receive(msg)", arguments: ["msg": s], contentWorld: .page)
            var l = load
            l["type"] = "load"
            _ = try? await web.callAsyncJavaScript("return await window.linen.receive(msg)", arguments: ["msg": l], contentWorld: .page)
            return await wait("rendered", timeout: timeout)
        }

        func close() {
            web.configuration.userContentController.removeScriptMessageHandler(forName: "linen")
            window.orderOut(nil)
            window.contentView = nil
        }

        nonisolated func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            MainActor.assumeIsolated {
                guard let d = m.body as? [String: Any], let t = d["type"] as? String else { return }
                seen.insert(t)
                for (i, w) in waiting.enumerated().reversed() where w.0 == t {
                    waiting.remove(at: i)
                    w.1.resume(returning: true)
                }
            }
        }

        private func wait(_ type: String, timeout: Double) async -> Bool {
            if seen.contains(type) { return true }
            return await withCheckedContinuation { cont in
                waiting.append((type, cont))
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                    MainActor.assumeIsolated {
                        if let i = self.waiting.firstIndex(where: { $0.0 == type }) { self.waiting.remove(at: i).1.resume(returning: false) }
                    }
                }
            }
        }
    }

    /// The content controller keeps its handlers strongly; this breaks the cycle with `Host`.
    private final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var target: Host?
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { target?.userContentController(c, didReceive: m) }
    }

    // MARK: Writing

    /// Web views with an export under way: one at a time each, since an export changes the page's DOM.
    private static var busy: Set<ObjectIdentifier> = []
    /// The most pages one export writes, and how long it may take.
    static let maxPages = 2000, deadline: TimeInterval = 180

    static func write(from web: WKWebView, options: Options, to url: URL) async throws -> Output {
        let key = ObjectIdentifier(web)
        guard !busy.contains(key) else { throw Failure.layout("an export of this page is already running") }
        busy.insert(key)
        defer { busy.remove(key) }
        let started = Date()
        web.mediaType = "print"
        let world = WKContentWorld.world(name: "linen-export")
        if options.prepareRenderer { await prepareRenderer(web) }
        let raw: Any?
        do {
            raw = try await web.callAsyncJavaScript(collector, arguments: ["css": exportCSS], contentWorld: world)
        } catch {
            throw Failure.layout(error.localizedDescription)
        }
        guard let layout = raw as? [String: Any], let height = DisplayList.num(layout["height"]), let width = DisplayList.num(layout["width"]),
              height > 0, width > 0, height.isFinite, width.isFinite else {
            throw Failure.layout("no layout")
        }
        let fonts = (layout["fonts"] as? [[String: Any]] ?? []).map(FontInfo.init)
        let segments = (layout["segs"] as? [[String: Any]] ?? []).compactMap(Segment.init)
        let spans = (layout["spans"] as? [[Any]] ?? []).compactMap { a -> (CGFloat, CGFloat)? in
            guard a.count == 2, let t = DisplayList.num(a[0]), let b = DisplayList.num(a[1]), b > t else { return nil }
            return (t, b)
        }
        let heads = (layout["heads"] as? [[String: Any]] ?? []).compactMap(Heading.init)
        let resolved = fonts.map { $0.resolve() }
        // Hide only what Linen will redraw.
        let redraw = options.reference ? [] : resolved.indices.filter { resolved[$0].known }
        do {
            _ = try await web.callAsyncJavaScript(hider, arguments: ["fonts": redraw], contentWorld: world)
        } catch {
            throw Failure.layout(error.localizedDescription)
        }
        let redrawn = Set(redraw)

        let paper = options.paper.portrait
        let breaks: [CGFloat]
        // Content wider than the paper's column (a wide diagram in a page) is scaled to fit it, never cut.
        var scale = min(pointsPerPixel, (paper.width - 2 * margins.side) / width)
        var pageSize = paper
        if options.longPage {
            // Slices of 12,000 px (under WebKit's 14,400 pt split) stacked on one page.
            var b: [CGFloat] = [0]
            while height - b.last! > 12_000 { b.append(b.last! + 12_000) }
            b.append(height.rounded(.up))
            breaks = b
            scale = pointsPerPixel
            let side = BoardPDF.maxSide
            if height * scale + margins.top + margins.bottom > side { scale = (side - margins.top - margins.bottom) / height }
            if width * scale + 2 * margins.side > side { scale = min(scale, (side - 2 * margins.side) / width) }
            pageSize = CGSize(width: width * scale + 2 * margins.side, height: height * scale + margins.top + margins.bottom)
        } else {
            let pageHeightPx = (paper.height - margins.top - margins.bottom) / scale
            guard height / pageHeightPx < Double(maxPages) else { throw Failure.layout("more than \(maxPages) pages") }
            breaks = paginate(height: height, pageHeight: pageHeightPx, spans: spans + segments.map { ($0.rect.minY, $0.rect.maxY) }, heads: heads)
        }
        guard breaks.count - 1 <= maxPages else { throw Failure.layout("more than \(maxPages) pages") }

        var info: [CFString: Any] = [kCGPDFContextCreator: "Linen"]
        if !options.title.isEmpty { info[kCGPDFContextTitle] = options.title }
        var media = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(url as CFURL, mediaBox: &media, info as CFDictionary) else { throw Failure.cannotCreate(url) }
        let text = OutlineText(context: ctx)
        var fallbacks = 0
        var outline: [[CFString: Any]] = []
        var boxes: [LineBox] = []
        var pages = 0

        for (index, slice) in zip(breaks.indices, zip(breaks, breaks.dropFirst())) {
            let (y0, y1) = slice
            if Date().timeIntervalSince(started) > deadline { throw Failure.layout("it took longer than \(Int(deadline)) s") }
            let config = WKPDFConfiguration()
            config.rect = CGRect(x: 0, y: y0, width: width, height: y1 - y0)
            let data = try await web.pdf(configuration: config)
            guard let provider = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(provider), let slicePage = doc.page(at: 1) else {
                throw Failure.layout("WebKit drew no page \(index + 1)")
            }
            // On paper each slice is a page; on one long page the slices stack, `top` points down from its top.
            let page = options.longPage ? 0 : index
            let top = options.longPage ? y0 * scale : 0
            if !options.longPage || index == 0 {
                var box = media
                ctx.beginPage(mediaBox: &box)
                ctx.setFillColor(options.paperBackground ? RGBA.paper.cg : CGColor(gray: 1, alpha: 1))
                ctx.fill(box)
                pages += 1
            }
            // WebKit's drawing of the slice, text hidden.
            ctx.saveGState()
            let h = (y1 - y0) * scale
            ctx.translateBy(x: margins.side, y: pageSize.height - margins.top - top - h)
            ctx.scaleBy(x: scale, y: scale)
            ctx.clip(to: CGRect(x: 0, y: 0, width: width, height: y1 - y0))
            ctx.drawPDFPage(slicePage)
            ctx.restoreGState()
            // Linen's drawing of the text on it, in the DOM's coordinates.
            ctx.saveGState()
            ctx.translateBy(x: margins.side, y: pageSize.height - margins.top - top)
            ctx.scaleBy(x: scale, y: -scale)
            ctx.translateBy(x: 0, y: -y0)
            for s in segments where s.rect.midY >= y0 && s.rect.midY < y1 && redrawn.contains(s.font) || options.reference && s.rect.midY >= y0 && s.rect.midY < y1 {
                guard s.font < resolved.count else { continue }
                if !options.reference, !draw(s, font: (resolved[s.font].font, resolved[s.font].oblique), info: fonts[s.font], text: text) { fallbacks += 1 }
                func toPage(_ r: CGRect) -> CGRect {
                    CGRect(x: margins.side + r.minX * scale, y: pageSize.height - margins.top - top - (r.maxY - y0) * scale,
                           width: r.width * scale, height: r.height * scale)
                }
                let ns = s.text as NSString
                boxes.append(LineBox(page: page, rect: toPage(s.rect), text: s.text,
                                     words: s.words.filter { $0.range.location + $0.range.length <= ns.length }.map { (ns.substring(with: $0.range), toPage($0.rect)) }))
            }
            ctx.restoreGState()
            let last = index == breaks.count - 2
            if !options.longPage || last {
                running(text, ctx, box: media, title: options.title, page: page + 1, first: page == 0 || options.longPage)
                ctx.endPage()
            }
            for hd in heads where hd.top >= y0 && hd.top < y1 && hd.level <= 3 {
                outline.append([kCGPDFOutlineTitle: hd.text, kCGPDFOutlineDestination: page + 1, "level" as CFString: hd.level])
            }
        }
        CGPDFContextSetOutline(ctx, [kCGPDFOutlineChildren: nest(outline)] as CFDictionary)
        ctx.closePDF()
        BoardPDF.compactInPlace(url, pages: pages)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return Output(pages: pages, bytes: bytes, seconds: Date().timeIntervalSince(started), segments: segments.count,
                      wordFallbacks: fallbacks, glyphs: text.glyphsDrawn, lineBoxes: boxes)
    }

    /// Linen's renderer fills lazy code, math and diagrams for print (`prepareForPrint`, in the page world, where
    /// `window.linen` lives); the export waits at most 10 s for it.
    static func prepareRenderer(_ web: WKWebView) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var finished = false
            func finish() { if !finished { finished = true; done.resume() } }
            web.callAsyncJavaScript("return await window.linen.receive({ type: 'command', name: 'prepareForPrint' })", arguments: [:], in: nil, in: .page) { _ in
                MainActor.assumeIsolated { finish() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { MainActor.assumeIsolated { finish() } }
        }
    }

    /// Draws one segment as one Core Text line laid on WebKit's box; when the two disagree (a tab, a bidi run that
    /// WebKit interleaved with a neighbouring element), word by word on each word's own box. Returns false then.
    private static func draw(_ s: Segment, font: (CTFont, Bool), info: FontInfo, text: OutlineText) -> Bool {
        let (f, oblique) = font
        let asc = info.ascent ?? CTFontGetAscent(f).rounded()
        let line = text.typeset(s.text, font: f, rtl: s.rtl, tracking: info.letterSpacing)
        let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let tolerance = max(1.5, 0.015 * s.rect.width)
        // A line that falls back to a second font (Arabic inside code) is placed word by word: the fallback face
        // Core Text picks need not have WebKit's widths, so one scale for the line misplaces its middle.
        let fonts = Set((CTLineGetGlyphRuns(line) as! [CTRun]).map { CTFontCopyPostScriptName((CTRunGetAttributes($0) as NSDictionary)[kCTFontAttributeName as String] as! CTFont) as String })
        if w > 0, fonts.count <= 1 || s.words.count <= 1, abs(w - s.rect.width) <= tolerance || s.words.count <= 1 {
            let sx = s.rect.width > 0 && abs(w - s.rect.width) > 0.3 ? min(1.15, max(0.87, s.rect.width / w)) : 1
            let x = s.rtl ? s.rect.maxX - w * sx : s.rect.minX
            text.draw(line, text: s.text, x: x, baseline: s.rect.minY + asc, xScale: sx, color: s.color, rtl: s.rtl, oblique: oblique)
            return true
        }
        let ns = s.text as NSString
        var extents: [(NSRange, CGFloat, CGFloat)] = []
        for wd in s.words {
            guard wd.range.location + wd.range.length <= ns.length else { continue }
            let piece = ns.substring(with: wd.range)
            let wl = text.typeset(piece, font: f, rtl: s.rtl, tracking: info.letterSpacing)
            let ww = CGFloat(CTLineGetTypographicBounds(wl, nil, nil, nil))
            let sx = wd.rect.width > 0 && ww > 0 && abs(ww - wd.rect.width) > 0.3 ? min(1.2, max(0.8, wd.rect.width / ww)) : 1
            text.outlines(wl, x: wd.rect.minX, baseline: wd.rect.minY + asc, xScale: sx, color: s.color, oblique: oblique)
            // the word's own sub-words (a token like "a:b" is one word here) keep their places in the whole line
            for (r, lo, hi) in text.wordExtents(wl, text: piece, x: wd.rect.minX, xScale: sx) {
                extents.append((NSRange(location: wd.range.location + r.location, length: r.length), lo, hi))
            }
        }
        // One invisible layer for the whole line, so PDFKit reads it in order (see OutlineText.hidden).
        text.hidden(text: s.text, words: extents, baseline: s.rect.minY + asc, size: CTFontGetSize(f), rtl: s.rtl)
        return false
    }

    /// The running title (from the second page) and the page number, drawn as outlines like the text.
    private static func running(_ text: OutlineText, _ ctx: CGContext, box: CGRect, title: String, page: Int, first: Bool) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: box.height)
        ctx.scaleBy(x: 1, y: -1)
        let quiet = RGBA(r: 0x1F / 255, g: 0x33 / 255, b: 0x28 / 255, a: 0.75)
        if !first, !title.isEmpty {
            let rtl = OutlineText.isRTL(title)
            let t = rtl ? title : title.uppercased()
            let line = text.typeset(t, face: .sans500, size: 7.5, rtl: rtl, tracking: rtl ? 0 : 1)
            let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            text.draw(line, text: t, x: rtl ? box.width - margins.side - w : margins.side, baseline: 32, color: quiet, rtl: rtl)
        }
        let n = "\(page)"
        let nl = text.typeset(n, face: .sans, size: 8.5, rtl: false)
        let nw = CGFloat(CTLineGetTypographicBounds(nl, nil, nil, nil))
        text.draw(nl, text: n, x: (box.width - nw) / 2, baseline: box.height - 24, color: quiet, rtl: false)
        ctx.restoreGState()
    }

    /// Page breaks in CSS pixels: never through a line of text, a code block, a table row or a figure shorter than
    /// a page, and never right under a heading (it moves to the next page with what follows it).
    static func paginate(height: CGFloat, pageHeight: CGFloat, spans: [(CGFloat, CGFloat)], heads: [Heading]) -> [CGFloat] {
        let sorted = spans.filter { $0.1 - $0.0 < pageHeight * 0.95 }.sorted { $0.0 < $1.0 }
        var breaks: [CGFloat] = [0]
        var y0: CGFloat = 0
        while height - y0 > pageHeight {
            var y = y0 + pageHeight
            var moved = true, rounds = 0
            while moved, rounds < 400 {
                moved = false
                rounds += 1
                // the topmost thing that straddles the cut pulls it up to its own top
                // (whatever the page's length: a figure shorter than a page moves whole to the next one)
                if let s = sorted.first(where: { $0.0 < y - 0.5 && $0.1 > y + 0.5 }), s.0 > y0 + 1 {
                    y = s.0 - 0.5
                    moved = true
                }
                if let h = heads.last(where: { $0.top > y0 + pageHeight * 0.25 && $0.top < y && $0.bottom > y - 40 }) {
                    y = h.top - 0.5
                    moved = true
                }
            }
            // Whole pixels: WebKit snaps each slice's text to its own pixel grid, so a break on a half pixel would
            // move every line on the page by half a pixel against the DOM.
            y = max(y0 + 1, min(y, y0 + pageHeight)).rounded(.down)
            if y <= y0 { y = (y0 + pageHeight).rounded(.down) }
            breaks.append(y)
            y0 = y
        }
        breaks.append(height.rounded(.up))
        return breaks
    }

    /// Flat headings (with their level) into the nested outline Quartz wants: each heading under the nearest one
    /// above it with a smaller level.
    static func nest(_ flat: [[CFString: Any]]) -> [[CFString: Any]] {
        final class Node { var item: [CFString: Any]; var level: Int; var kids: [Node] = []
            init(_ i: [CFString: Any], _ l: Int) { item = i; level = l } }
        let root = Node([:], 0)
        var stack: [Node] = [root]
        for item in flat {
            let level = max(1, item["level" as CFString] as? Int ?? 1)
            var clean = item
            clean.removeValue(forKey: "level" as CFString)
            let n = Node(clean, level)
            while stack.count > 1, stack.last!.level >= level { stack.removeLast() }
            stack.last!.kids.append(n)
            stack.append(n)
        }
        func build(_ n: Node) -> [CFString: Any] {
            var d = n.item
            if !n.kids.isEmpty { d[kCGPDFOutlineChildren] = n.kids.map(build) }
            return d
        }
        return root.kids.map(build)
    }

    // MARK: What the page reports

    struct FontInfo {
        var family: String
        var weight: Int
        var italic: Bool
        var size: CGFloat
        var letterSpacing: CGFloat
        /// The baseline's distance below a text box's top, measured in the page.
        var ascent: CGFloat?
        /// The first family is a web font the page loaded (not one of Linen's).
        var web: Bool

        init(_ d: [String: Any]) {
            family = d["family"] as? String ?? ""
            weight = DisplayList.int(d["weight"], in: 1...1000) ?? 400
            italic = (d["italic"] as? Bool) ?? false
            size = DisplayList.num(d["size"]) ?? 16
            letterSpacing = DisplayList.num(d["ls"]) ?? 0
            web = (d["web"] as? Bool) ?? false
            let limit = size * 2
            ascent = DisplayList.num(d["asc"]).flatMap { $0 > 0 && $0 < limit ? $0 : nil }
        }

        /// The face WebKit used, by the same family list: Linen's faces are Thmanyah, `mono` the system's. `known` is
        /// false when the first family is one Linen cannot find on this Mac (a page's own web font): WebKit keeps that text.
        func resolve() -> (font: CTFont, oblique: Bool, known: Bool) {
            let names = family.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            if web, let first = names.first, !first.lowercased().hasPrefix("linen ") {
                return (CTFontCreateWithName("Helvetica" as CFString, size, nil), false, false)
            }
            for n in names {
                switch n.lowercased() {
                case "linen sans":
                    let ps = weight >= 600 ? "thmanyahsans-Bold" : weight >= 500 ? "thmanyahsans-Medium" : "thmanyahsans-Regular"
                    return (CTFontCreateWithName(ps as CFString, size, nil), italic, true)
                case "linen serif display":
                    return (CTFontCreateWithName("thmanyahserifdisplay-Light" as CFString, size, nil), italic, true)
                case "linen serif text":
                    return (CTFontCreateWithName((weight >= 500 ? "thmanyahseriftext-Medium" : "thmanyahseriftext-Regular") as CFString, size, nil), italic, true)
                case "sf mono", "ui-monospace", "monospace":
                    // The system's monospaced face, with its own fallback (WebKit set Arabic in code in SF Arabic)
                    // and its real italic.
                    let w: NSFont.Weight = weight >= 700 ? .bold : weight >= 600 ? .semibold : weight >= 500 ? .medium : weight < 350 ? .light : .regular
                    let base = NSFont.monospacedSystemFont(ofSize: size, weight: w) as CTFont
                    if italic, let it = CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitItalic, .traitItalic) { return (it, false, true) }
                    return (base, italic, true)
                case "-apple-system", "system-ui", "sans-serif":
                    return (NSFont.systemFont(ofSize: size, weight: weight >= 600 ? .semibold : weight >= 500 ? .medium : .regular) as CTFont, italic, true)
                default:
                    let f = CTFontCreateWithName(n as CFString, size, nil)
                    if (CTFontCopyFamilyName(f) as String).caseInsensitiveCompare(n) == .orderedSame {
                        // an installed face; a family WebKit got from the page itself is not, and stays WebKit's
                        if italic, let it = CTFontCreateCopyWithSymbolicTraits(f, size, nil, .traitItalic, .traitItalic) { return (it, false, true) }
                        return (f, italic, true)
                    }
                }
            }
            return (CTFontCreateWithName("thmanyahsans-Regular" as CFString, size, nil), italic, false)
        }
    }

    struct Segment {
        var text: String
        var font: Int
        var color: RGBA
        var rtl: Bool
        var rect: CGRect
        var words: [(range: NSRange, rect: CGRect)]

        init?(_ d: [String: Any]) {
            guard let t = d["t"] as? String, !t.isEmpty, let f = DisplayList.int(d["f"], in: 0...100_000), let x = DisplayList.num(d["x"]), let y = DisplayList.num(d["y"]),
                  let w = DisplayList.num(d["w"]), let h = DisplayList.num(d["h"]) else { return nil }
            text = t
            font = f
            color = RGBA.parse(d["c"]) ?? .ink2
            rtl = (d["d"] as? Bool) ?? false
            rect = CGRect(x: x, y: y, width: w, height: h)
            words = (d["w8"] as? [[Any]] ?? []).compactMap { a in
                guard a.count == 6, let s = DisplayList.int(a[0], in: 0...Int(Int32.max)), let e = DisplayList.int(a[1], in: 0...Int(Int32.max)),
                      let x = DisplayList.num(a[2]), let y = DisplayList.num(a[3]), let w = DisplayList.num(a[4]), let h = DisplayList.num(a[5]), e > s else { return nil }
                return (NSRange(location: s, length: e - s), CGRect(x: x, y: y, width: w, height: h))
            }
        }
    }

    struct Heading {
        var level: Int
        var text: String
        var top: CGFloat
        var bottom: CGFloat
        init?(_ d: [String: Any]) {
            guard let l = DisplayList.int(d["level"], in: 1...6), let t = DisplayList.num(d["top"]), let b = DisplayList.num(d["bottom"]) else { return nil }
            level = l
            text = d["text"] as? String ?? ""
            top = t
            bottom = b
        }
    }

    // MARK: The page side

    /// Export look on top of the renderer's print rules: no chrome, no column limit, and generated text (list
    /// markers, separators) in faces that map cleanly, since WebKit still draws those itself.
    static let exportCSS = """
    html.linen-export, html.linen-export body { background: transparent !important; }
    html.linen-export body { padding: 0 !important; margin: 0 !important; }
    html.linen-export #pane { padding: 0 !important; margin: 0 !important; }
    html.linen-export #outline, html.linen-export #progress, html.linen-export #footer, html.linen-export #findbar,
    html.linen-export #match-rail, html.linen-export #props, html.linen-export .notice, html.linen-export #banner { display: none !important; }
    html.linen-export #note-header, html.linen-export #doc > .blk, html.linen-export #doc > .blk.wide { max-width: none !important; }
    html.linen-export li::marker, html.linen-export *::before, html.linen-export *::after { font-family: Helvetica, "Geeza Pro", sans-serif !important; }
    html.linen-export .lx-hide { visibility: hidden !important; }
    html.linen-export .blk.chg::before, html.linen-export .gap { display: none !important; }
    """

    /// Hides the text nodes whose face Linen redraws (after measuring: hiding never moves anything).
    static let hider = """
    const st = window.__linenExport; if (!st) return 0;
    const keep = new Set(fonts); let n = 0;
    st.nodes.forEach((t, i) => {
      if (!keep.has(st.nodeFont[i])) return;
      const p = t.parentElement; if (!p) return;
      if (p instanceof SVGElement) { p.style.visibility = 'hidden'; n++; return; }
      const s = document.createElement('span'); s.className = 'lx-hide'; t.parentNode.insertBefore(s, t); s.appendChild(t); n++;
    });
    return n;
    """

    /// Runs in its own content world: measures every text node Linen may redraw and reports lines, unbreakable spans
    /// and headings in document pixels.
    static let collector = """
    const html = document.documentElement;
    let st = document.getElementById('linen-export-style');
    if (!st) { st = document.createElement('style'); st.id = 'linen-export-style'; st.textContent = css; document.head.appendChild(st); }
    html.classList.add('linen-export');
    // Waits are bounded: a page's image or font that never settles must not hold the export.
    const within = (p, ms) => Promise.race([p, new Promise(r => setTimeout(r, ms))]);
    await within(Promise.all([...document.images].slice(0, 2000).map(i => i.decode ? i.decode().catch(() => {}) : null)), 3000);
    if (document.fonts) await within(document.fonts.ready, 3000);
    await new Promise(r => setTimeout(r, 60)); // offscreen windows barely run animation frames
    const sx = window.scrollX, sy = window.scrollY;
    // Visibility comes from layout, not the hidden attribute: print rules show NOTE-3's sources (Renderer/blocks.css),
    // and text with no box on the page is skipped below.
    const skip = '.katex, #outline, #progress, #footer, #findbar, #match-rail, #props, #status, .vh, script, style, noscript, .notice, #banner, button, input, textarea, select';
    const nodes = [];
    const tw = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, { acceptNode(n) {
      const p = n.parentElement; if (!p || p.closest(skip)) return NodeFilter.FILTER_REJECT;
      return NodeFilter.FILTER_ACCEPT; } });
    // White space stays WebKit's: wrapping it changed the layout (spike X(b)), and it draws nothing.
    while (nodes.length < 200000 && tw.nextNode()) if (/\\S/.test(tw.currentNode.nodeValue)) nodes.push(tw.currentNode);
    let budget = 2000000; // layout queries, so a page cannot make the export endless
    const fonts = [], fontIndex = new Map(), segs = [], nodeFont = [];
    const range = document.createRange();
    const U = (rs) => { let l = Infinity, t = Infinity, r = -Infinity, b = -Infinity; for (const x of rs) { if (!(x.width > 0)) continue; l = Math.min(l, x.left); t = Math.min(t, x.top); r = Math.max(r, x.right); b = Math.max(b, x.bottom); } return l === Infinity ? null : { l: l + sx, t: t + sy, r: r + sx, b: b + sy }; };
    for (const n of nodes) {
      const p = n.parentElement;
      const cs = getComputedStyle(p);
      if (cs.visibility !== 'visible' || cs.display === 'none' || Number(cs.opacity) === 0) { nodeFont.push(-1); continue; }
      const key = [cs.fontFamily, cs.fontWeight, cs.fontStyle, cs.fontSize, cs.letterSpacing].join('|');
      let fi = fontIndex.get(key);
      if (fi === undefined) {
        fi = fonts.length; fontIndex.set(key, fi);
        const first = cs.fontFamily.split(',')[0].trim().replace(/^["']|["']$/g, '');
        const web = document.fonts ? [...document.fonts].some(f => f.family.replace(/^["']|["']$/g, '') === first && f.status === 'loaded') : false;
        fonts.push({ family: cs.fontFamily, weight: Number(cs.fontWeight) || 400, italic: cs.fontStyle !== 'normal', size: parseFloat(cs.fontSize), ls: cs.letterSpacing === 'normal' ? 0 : (parseFloat(cs.letterSpacing) || 0), web });
      }
      nodeFont.push(fi);
      const upper = cs.textTransform === 'uppercase';
      const pre = /^pre/.test(cs.whiteSpace) || cs.whiteSpace === 'break-spaces';
      const rtl = cs.direction === 'rtl';
      const color = cs.webkitTextFillColor && cs.webkitTextFillColor !== cs.color && !/rgba\\(0, 0, 0, 0\\)/.test(cs.webkitTextFillColor) ? cs.webkitTextFillColor : cs.color;
      const t = n.nodeValue;
      const words = [];
      const re = /\\S+/g; let m;
      while ((m = re.exec(t)) && budget > 0) {
        budget--;
        range.setStart(n, m.index); range.setEnd(n, m.index + m[0].length);
        const rs = [...range.getClientRects()].filter(x => x.width > 0);
        if (!rs.length) continue;
        const one = rs.every(x => Math.abs(x.top - rs[0].top) < 2);
        if (one) { words.push({ s: m.index, e: m.index + m[0].length, r: U(rs) }); continue; }
        // a token broken across lines: split it where the line changes (by character up to 2,000; beyond that
        // proportionally to each line's width, which only very long unbroken strings reach)
        if (m[0].length > 2000) {
          const total = rs.reduce((a, x) => a + x.width, 0) || 1; let at = m.index;
          rs.forEach((x, k) => { const len = k === rs.length - 1 ? m.index + m[0].length - at : Math.round(m[0].length * x.width / total);
            words.push({ s: at, e: at + len, r: U([x]) }); at += len; });
          continue;
        }
        budget -= m[0].length;
        let start = m.index, top = null;
        for (let i = m.index; i < m.index + m[0].length; i++) {
          range.setStart(n, i); range.setEnd(n, i + 1);
          const r = [...range.getClientRects()].find(x => x.width > 0);
          if (!r) continue;
          if (top === null) top = r.top;
          else if (Math.abs(r.top - top) > 2) { range.setStart(n, start); range.setEnd(n, i); words.push({ s: start, e: i, r: U(range.getClientRects()) }); start = i; top = r.top; }
        }
        range.setStart(n, start); range.setEnd(n, m.index + m[0].length); words.push({ s: start, e: m.index + m[0].length, r: U(range.getClientRects()) });
      }
      // words on the same line make one segment
      let cur = null;
      const flush = () => {
        if (!cur) return;
        let text, w8 = [];
        if (pre) {
          text = t.slice(cur.ws[0].s, cur.ws[cur.ws.length - 1].e);
          for (const w of cur.ws) w8.push([w.s - cur.ws[0].s, w.e - cur.ws[0].s, w.r.l, w.r.t, w.r.r - w.r.l, w.r.b - w.r.t]);
        } else {
          text = '';
          for (const w of cur.ws) { if (text) text += ' '; const s = text.length; text += t.slice(w.s, w.e); w8.push([s, text.length, w.r.l, w.r.t, w.r.r - w.r.l, w.r.b - w.r.t]); }
        }
        if (upper) text = text.toUpperCase();
        if (segs.length < 400000) segs.push({ t: text, f: fi, c: color, d: rtl, x: cur.r.l, y: cur.r.t, w: cur.r.r - cur.r.l, h: cur.r.b - cur.r.t, w8 });
        cur = null;
      };
      for (const w of words) {
        if (!w.r) continue;
        if (cur && Math.abs(w.r.t - cur.r.t) < 1.5 && Math.abs(w.r.b - cur.r.b) < 1.5) {
          cur.ws.push(w); cur.r = { l: Math.min(cur.r.l, w.r.l), t: Math.min(cur.r.t, w.r.t), r: Math.max(cur.r.r, w.r.r), b: Math.max(cur.r.b, w.r.b) };
        } else { flush(); cur = { ws: [w], r: { ...w.r } }; }
      }
      flush();
    }
    // Where WebKit puts the baseline below a text box's top, per font: a zero-size inline-block sits on it.
    const probes = document.createElement('div');
    probes.style.cssText = 'position:absolute;left:0;top:0;visibility:hidden;white-space:nowrap;line-height:normal';
    document.body.appendChild(probes);
    for (const f of fonts) {
      const d = document.createElement('div');
      d.style.fontFamily = f.family; d.style.fontWeight = String(f.weight); d.style.fontStyle = f.italic ? 'italic' : 'normal'; d.style.fontSize = f.size + 'px';
      const tn = document.createTextNode('Hxg'); const mk = document.createElement('span');
      mk.style.cssText = 'display:inline-block;width:0;height:0;vertical-align:baseline';
      d.appendChild(tn); d.appendChild(mk); probes.appendChild(d);
      range.setStart(tn, 0); range.setEnd(tn, 3);
      f.asc = mk.getBoundingClientRect().top - range.getBoundingClientRect().top;
    }
    probes.remove();
    // the hider runs next, once Linen knows which faces it can redraw
    window.__linenExport = { nodes, nodeFont };
    const spans = [];
    document.querySelectorAll('pre.code, .table-wrap tr, .mermaid-src, .math.display, img, .callout, blockquote, figure, hr, svg').forEach(el => {
      const r = el.getBoundingClientRect(); if (r.height > 0) spans.push([r.top + sy, r.bottom + sy]); });
    const heads = [...document.querySelectorAll('#note-title, #doc h1, #doc h2, #doc h3, #doc h4, h1, h2, h3')].filter((h, i, all) => all.indexOf(h) === i && h.getClientRects().length).map(h => {
      const r = h.getBoundingClientRect(); return { level: h.id === 'note-title' ? 1 : Number(h.tagName[1]), text: h.textContent.trim(), top: r.top + sy, bottom: r.bottom + sy }; });
    return { fonts, segs, spans, heads, height: Math.ceil(Math.max(document.documentElement.scrollHeight, document.body.scrollHeight)),
             width: Math.ceil(Math.max(document.documentElement.clientWidth, document.documentElement.scrollWidth, document.body.scrollWidth)) };
    """
}
