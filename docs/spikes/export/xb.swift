// Spike X(b): a long Arabic and English note exported to a paginated PDF by Linen/Export/NotePDF.swift: WebKit
// draws everything but the text, Linen draws each line from the DOM's line boxes as Thmanyah outlines with the
// invisible searchable layer. Checks the EXP-8 gate: lines aligned within 0.5 pt of where WebKit draws them (both
// rasterised at 4x and compared line by line against a reference export in which WebKit draws its own text, same
// page breaks), the word checks of X(a), and no Thmanyah font data.
//
//   swiftc -O -swift-version 6 -parse-as-library -o build/xb docs/spikes/export/xb.swift Linen/Export/*.swift \
//     -framework AppKit -framework PDFKit -framework WebKit
//   ./build/xb build/export-out
import AppKit
import PDFKit
import UniformTypeIdentifiers
import WebKit

let renderer = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Renderer")

final class AppScheme: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let rel = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        let file = renderer.appendingPathComponent(rel).standardizedFileURL
        guard file.path.hasPrefix(renderer.standardizedFileURL.path), let data = try? Data(contentsOf: file) else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime])!)
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

@MainActor
final class Page: NSObject, WKScriptMessageHandler {
    var window: NSWindow!
    var web: WKWebView!
    var seen: [String] = []
    var waits: [(String, CheckedContinuation<Void, Never>)] = []
    func make(paper: PaperSize) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(AppScheme(), forURLScheme: "linen-app")
        config.userContentController.add(self, name: "linen")
        (window, web) = NotePDF.makeHost(configuration: config, paper: paper)
    }
    nonisolated func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        let body = m.body
        MainActor.assumeIsolated {
            guard let d = body as? [String: Any], let t = d["type"] as? String else { return }
            if t == "error" { print("page error: \(d["message"] ?? "")") }
            if ProcessInfo.processInfo.environment["XB_TRACE"] != nil { print("  msg \(t)") }
            seen.append(t)
            for (i, w) in waits.enumerated().reversed() where w.0 == t { waits.remove(at: i); w.1.resume() }
        }
    }
    func wait(_ t: String) async {
        if seen.contains(t) { return }
        await withCheckedContinuation { waits.append((t, $0)) }
    }
    func send(_ msg: [String: Any]) async { _ = try? await web.callAsyncJavaScript("return await window.linen.receive(msg)", arguments: ["msg": msg], contentWorld: .page) }
    func open(note: String) async {
        web.load(URLRequest(url: URL(string: "linen-app://renderer/page.html")!))
        await wait("ready")
        print("  page ready")
        await send(["type": "settings", "theme": "paper", "face": "sans", "uiDir": "ltr", "lang": "en", "contrast": false, "foldArabic": true])
        await send(["type": "load", "docId": "x", "name": "note.md", "path": "/tmp/note.md", "text": note, "plain": false, "version": 1, "meta": [:]])
        await wait("rendered")
        print("  note rendered")
    }
}

func note() -> String {
    var s = "---\ntitle: Linen export test\n---\n# Linen export test\n\n"
    let en = "Linen keeps your place while an agent rewrites the file, and marks what changed since you last looked. The service answers on staging but the ledger write fails under load; retry is not idempotent yet."
    let ar = "يقرأ لينن ما يكتبه الوكلاء على الماك والآيفون، ويحفظ مكانك حين يعيد الوكيل كتابة الملف. تمت مزامنة ١٢ ملفا في ٣ ثوان، لا سحابة ولا حساب."
    let mixed = "افتح ملف board.canvas في Linen ثم اضغط Present لعرض الأقسام، أو صدّر المخطط إلى PDF."
    for i in 1...18 {
        s += i % 3 == 0 ? "## القسم \(i): الجاهزية\n\n" : "## Section \(i): readiness\n\n"
        s += "\(en) **Bold words** and *slanted words* sit beside `inline code`.\n\n"
        s += "\(ar) **كلمات عريضة** و`board.canvas`.\n\n"
        s += "\(mixed)\n\n"
        if i % 2 == 0 { s += "- First item of a list, with enough words to wrap onto a second line in the column.\n- البند الثاني في القائمة، بكلمات كافية لتلتف إلى سطر ثان.\n- Third\n\n" }
        if i % 3 == 1 { s += "1. Numbered one\n2. Numbered two, a little longer than the first\n3. الثالث\n\n" }
        if i % 4 == 2 { s += "```swift\n// a comment: تعليق بالعربية\nlet board = try Board(contentsOf: url) // Gateway\nprint(board.nodes.count)\n```\n\n" }
        if i % 5 == 3 { s += "| Area | الحالة | Notes |\n|---|---|---|\n| Gateway | يعمل | seen working end to end |\n| Ledger | جزئي | fails under load |\n| مزامنة | Broken | الكتابة تفشل |\n\n" }
        if i % 6 == 4 { s += "> \(en)\n\n> [!note] Callout title\n> \(ar)\n\n" }
        if i % 7 == 5 { s += "A sentence with a footnote.[^n\(i)]\n\n[^n\(i)]: The footnote text, with Arabic: الوكلاء.\n\n" }
    }
    return s
}

let testWords = ["Linen", "readiness", "idempotent", "board.canvas", "Present", "لينن", "الوكلاء", "سحابة", "مزامنة", "الماك", "حساب", "الجاهزية", "تعليق", "Gateway"]

func strip(_ s: String) -> String {
    let marks = CharacterSet(charactersIn: "\u{064B}\u{064C}\u{064D}\u{064E}\u{064F}\u{0650}\u{0651}\u{0652}\u{0670}\u{200F}\u{200E}\u{061C}")
    return String(String.UnicodeScalarView(s.unicodeScalars.filter { !marks.contains($0) })).components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
}

/// A page rasterised at `scale` pixels per point: grey levels, row 0 at the top.
struct Raster {
    var w: Int, h: Int, scale: CGFloat, px: [UInt8]
    init(_ page: CGPDFPage, scale: CGFloat) {
        let box = page.getBoxRect(.mediaBox)
        self.scale = scale
        w = Int(box.width * scale); h = Int(box.height * scale)
        px = [UInt8](repeating: 255, count: w * h)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.drawPDFPage(page)
    }
    /// Ink bounding box (in page points, origin bottom left) inside `r`, or nil.
    func ink(in r: CGRect, threshold: UInt8 = 150) -> CGRect? {
        let x0 = max(0, Int(r.minX * scale)), x1 = min(w - 1, Int(r.maxX * scale))
        // CGContext bitmap rows: row 0 is the top of the image when drawn this way
        let y0 = max(0, Int((CGFloat(h) / scale - r.maxY) * scale)), y1 = min(h - 1, Int((CGFloat(h) / scale - r.minY) * scale))
        guard x1 > x0, y1 > y0 else { return nil }
        var lx = Int.max, hx = Int.min, ly = Int.max, hy = Int.min
        for y in y0...y1 { let row = y * w; for x in x0...x1 where px[row + x] < threshold { lx = min(lx, x); hx = max(hx, x); ly = min(ly, y); hy = max(hy, y) } }
        guard lx <= hx else { return nil }
        let H = CGFloat(h) / scale
        return CGRect(x: CGFloat(lx) / scale, y: H - CGFloat(hy + 1) / scale, width: CGFloat(hx - lx + 1) / scale, height: CGFloat(hy - ly + 1) / scale)
    }
}

func run(_ args: [String]) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: args[0]); p.arguments = Array(args.dropFirst())
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    try? p.run(); p.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
}

@main
struct XB {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in await go(); exit(0) }
        app.run()
    }

    @MainActor static func go() async {
        let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/export-out")
        let md = note()
        try? md.write(to: out.appendingPathComponent("xb-note.md"), atomically: true, encoding: .utf8)
        let ours = out.appendingPathComponent("xb-note.pdf"), ref = out.appendingPathComponent("xb-note-webkit-text.pdf")
        var result: NotePDF.Output?
        for (url, reference) in [(ours, false), (ref, true)] {
            let p = Page(); p.make(paper: .a4)
            await p.open(note: md)
            do {
                let o = try await NotePDF.write(from: p.web, options: .init(paper: .a4, title: "Linen export test", paperBackground: false, reference: reference), to: url)
                print("\(reference ? "REFERENCE (WebKit text)" : "LINEN"): \(o.pages) pages, \(o.bytes / 1024) KB, \(String(format: "%.2f", o.seconds)) s, \(o.segments) line segments, \(o.wordFallbacks) drawn word by word, \(o.glyphs) glyphs")
                if !reference { result = o }
            } catch { print("export failed: \(error)") }
        }
        guard let o = result, let doc = PDFDocument(url: ours), let refDoc = CGPDFDocument(ref as CFURL), let ourDoc = CGPDFDocument(ours as CFURL) else { return }
        // 1. alignment: each line's ink in our PDF against WebKit's own drawing of the same line
        var dxs: [CGFloat] = [], dys: [CGFloat] = []
        var signed: [(CGFloat, CGFloat, CGFloat, String)] = []
        var cx: [CGFloat] = [], cy: [CGFloat] = []
        var worst: [(CGFloat, String)] = []
        var pageRasters: [Int: (Raster, Raster)] = [:]
        for b in o.lineBoxes {
            if pageRasters[b.page] == nil, let a = ourDoc.page(at: b.page + 1), let r = refDoc.page(at: b.page + 1) { pageRasters[b.page] = (Raster(a, scale: 4), Raster(r, scale: 4)) }
            guard let (ra, rr) = pageRasters[b.page] else { continue }
            let probe = b.rect.insetBy(dx: -1.5, dy: -1)
            guard let ia = ra.ink(in: probe), let ir = rr.ink(in: probe) else { continue }
            let dx = max(abs(ia.minX - ir.minX), abs(ia.maxX - ir.maxX)), dy = max(abs(ia.minY - ir.minY), abs(ia.maxY - ir.maxY))
            dxs.append(dx); dys.append(dy)
            signed.append((ia.minY - ir.minY, ia.maxY - ir.maxY, ia.minX - ir.minX, b.text))
            cx.append(abs(ia.midX - ir.midX)); cy.append(abs(ia.midY - ir.midY))
            worst.append((max(dx, dy), "p\(b.page + 1) dx \(String(format: "%.2f", dx)) dy \(String(format: "%.2f", dy)) «\(b.text.prefix(40))»"))
        }
        func pct(_ a: [CGFloat], _ q: Double) -> CGFloat { let s = a.sorted(); return s.isEmpty ? -1 : s[min(s.count - 1, Int(Double(s.count) * q))] }
        let within = zip(dxs, dys).filter { max($0, $1) <= 0.5 }.count
        print("ALIGNMENT vs WebKit's own text, \(dxs.count) lines: horizontal p50 \(String(format: "%.2f", pct(dxs, 0.5))) p95 \(String(format: "%.2f", pct(dxs, 0.95))) max \(String(format: "%.2f", dxs.max() ?? -1)) pt; vertical p50 \(String(format: "%.2f", pct(dys, 0.5))) p95 \(String(format: "%.2f", pct(dys, 0.95))) max \(String(format: "%.2f", dys.max() ?? -1)) pt; \(within)/\(dxs.count) within 0.5 pt")
        let cwithin = zip(cx, cy).filter { max($0, $1) <= 0.5 }.count
        print("ALIGNMENT by ink centre: horizontal p50 \(String(format: "%.2f", pct(cx, 0.5))) p95 \(String(format: "%.2f", pct(cx, 0.95))) max \(String(format: "%.2f", cx.max() ?? -1)); vertical p50 \(String(format: "%.2f", pct(cy, 0.5))) p95 \(String(format: "%.2f", pct(cy, 0.95))) max \(String(format: "%.2f", cy.max() ?? -1)) pt; \(cwithin)/\(cx.count) within 0.5 pt")
        for w in worst.sorted(by: { $0.0 > $1.0 }).prefix(6) { print("   worst: \(w.1)") }
        if ProcessInfo.processInfo.environment["XB_SIGNED"] != nil {
            var hist: [String: Int] = [:]
            for (a, b, _, _) in signed { hist[String(format: "bottom %+.2f top %+.2f", a, b), default: 0] += 1 }
            for (k, v) in hist.sorted(by: { $0.value > $1.value }).prefix(8) { print("   \(v)x \(k)") }
            for (a, b, c, t) in signed.prefix(12) { print(String(format: "   %+.2f %+.2f dx %+.2f ", a, b, c) + "«\(t.prefix(30))»") }
        }
        // 2. text and search
        let all = strip((0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined(separator: "\n"))
        var lines = 0, found = 0, missing: [String] = []
        for b in o.lineBoxes { lines += 1; if all.contains(strip(b.text)) { found += 1 } else if missing.count < 20 { missing.append(b.text) } }
        print("PDFKit text: \(found)/\(lines) lines exact (logical order, diacritics ignored)" + (missing.isEmpty ? "" : "; missing e.g. " + missing.map { "«\($0)»" }.joined(separator: " ")))
        print("findString: " + testWords.map { "\($0) \(doc.findString($0, withOptions: []).count)" }.joined(separator: ", "))
        // 3. selection boxes against the words' boxes as WebKit laid them out
        var sel: [String] = [], worstSel: CGFloat = 0, worstSelY: CGFloat = 0
        for wd in ["readiness", "idempotent", "Present", "لينن", "الوكلاء", "سحابة", "مزامنة", "الماك", "حساب", "Gateway"] {
            guard let s = doc.findString(wd, withOptions: []).first, let page = s.pages.first else { continue }
            let i = doc.index(for: page)
            let b = s.bounds(for: page)
            let candidates = o.lineBoxes.filter { $0.page == i }.flatMap { $0.words }.filter { strip($0.text).contains(wd) }
            guard let w = candidates.min(by: { abs($0.rect.midX - b.midX) + abs($0.rect.midY - b.midY) < abs($1.rect.midX - b.midX) + abs($1.rect.midY - b.midY) }) else { sel.append("\(wd) ?"); continue }
            // the word box may carry punctuation the search word does not: compare the edge the word starts from
            let exact = strip(w.text) == wd
            let d = exact ? max(abs(w.rect.minX - b.minX), abs(w.rect.maxX - b.maxX)) : min(abs(w.rect.minX - b.minX), abs(w.rect.maxX - b.maxX))
            let dy = abs(w.rect.midY - b.midY)
            worstSel = max(worstSel, d); worstSelY = max(worstSelY, dy)
            sel.append("\(wd) x±\(String(format: "%.2f", d)) y±\(String(format: "%.2f", dy))")
        }
        print("selection boxes vs WebKit's word boxes (pt): worst horizontal \(String(format: "%.2f", worstSel)), worst vertical centre \(String(format: "%.2f", worstSelY)); " + sel.joined(separator: ", "))
        // 4. copy a mixed line by its box
        if let b = o.lineBoxes.first(where: { $0.text.contains("board.canvas") && OutlineText.isRTL($0.text) }), let page = doc.page(at: b.page) {
            let got = (page.selection(for: b.rect.insetBy(dx: -1, dy: 1))?.string ?? "").trimmingCharacters(in: .whitespaces)
            print("mixed line copied by its box: \(got == b.text ? "EXACT" : "diff")\n   want «\(b.text)»\n   got  «\(got)»")
        }
        let fonts = run(["/opt/homebrew/bin/pdffonts", ours.path])
        print("pdffonts: \(Set(fonts.split(separator: "\n").dropFirst(2).map { String($0.split(separator: " ").first ?? "") }).sorted().joined(separator: ", ")); Thmanyah present: \(fonts.lowercased().contains("thmanyah"))")
        let refFonts = run(["/opt/homebrew/bin/pdffonts", ref.path])
        print("reference pdffonts (WebKit text): Thmanyah present: \(refFonts.lowercased().contains("thmanyah"))")
        let info = run(["/opt/homebrew/bin/pdfinfo", ours.path])
        print("pdfinfo: " + (info.split(separator: "\n").first { $0.hasPrefix("Pages:") }.map(String.init) ?? "?") + (info.contains("Error") ? " ERRORS" : ", no errors"))
        // 5. the same note as one HTML file (EXP-3)
        let htmlURL = out.appendingPathComponent("xb-note.html")
        let hp = Page(); hp.make(paper: .a4)
        await hp.open(note: md)
        do {
            let h = try await NoteHTML.write(from: hp.web, title: "Linen export test", rendererDirectory: renderer, image: { _ in nil }, to: htmlURL)
            let text = (try? String(contentsOf: htmlURL, encoding: .utf8)) ?? ""
            let outward = ["http://", "https://", "//fonts", "@import", "linen-app:", "linen-local:", "linen-remote:", "file:"].filter { text.contains($0) }
            let urls = (try? NSRegularExpression(pattern: #"url\((?!data:)[^)]*\)"#).numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))) ?? -1
            print("HTML: \(h.bytes / 1024) KB, images \(h.images), missing \(h.missingImages); outward references: \(outward.isEmpty ? "none" : outward.joined(separator: ", ")); non-data url(): \(urls); Thmanyah embedded: \(text.contains("@font-face") && text.lowercased().contains("thmanyah") ? "yes" : "no"); names thmanyah: \(text.contains("thmanyah sans"))")
            // open it as a browser would, and ask the page what it loaded
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let win = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 900, height: 1100), styleMask: [.borderless], backing: .buffered, defer: false)
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 1100), configuration: config)
            win.contentView = view; win.orderBack(nil)
            view.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
            try? await Task.sleep(for: .seconds(2))
            let res = try? await view.callAsyncJavaScript("return performance.getEntriesByType('resource').map(e => e.name).filter(n => !n.startsWith('data:'))", arguments: [:], contentWorld: .page)
            let errs = try? await view.callAsyncJavaScript("return [document.title, document.querySelectorAll('#doc .blk').length, getComputedStyle(document.body).fontFamily, document.documentElement.dataset.theme]", arguments: [:], contentWorld: .page)
            print("HTML in a web view: resources loaded \((res as? [Any])?.count ?? -1) \(res ?? ""); page \(errs ?? "")")
            for theme in ["paper", "night"] {
                if theme == "night" {
                    let before = try? await view.callAsyncJavaScript("return document.documentElement.dataset.theme + ' / ' + document.getElementById('theme').textContent", arguments: [:], contentWorld: .page)
                    _ = try? await view.callAsyncJavaScript("document.getElementById('theme').click()", arguments: [:], contentWorld: .page)
                    try? await Task.sleep(for: .milliseconds(300))
                    let after = try? await view.callAsyncJavaScript("return document.documentElement.dataset.theme", arguments: [:], contentWorld: .page)
                    print("HTML theme switch: before \(before ?? "?") , after click \(after ?? "?") (the script runs under the hashed policy when the button has a label)")
                }
                if let img = try? await view.takeSnapshot(configuration: WKSnapshotConfiguration()), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: out.appendingPathComponent("xb-note-html-\(theme).png")) }
            }
        } catch { print("HTML export failed: \(error)") }
        // 6. a page with its own web font, as one long page (EXP-7): its text stays WebKit's, Linen's is outlined
        let pageDir = out.appendingPathComponent("xb-page")
        try? FileManager.default.createDirectory(at: pageDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: pageDir.appendingPathComponent("face.ttf"))
        try? FileManager.default.copyItem(at: URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Arial.ttf"), to: pageDir.appendingPathComponent("face.ttf"))
        var body = "<h1 style='font:300 34px \"Linen Serif Display\"'>Page export</h1>"
        for i in 0..<120 { body += "<p style='font:15px PageFace'>Web font line \(i) set in the page's own face.</p><p style='font:15px \"Linen Sans\"' dir='rtl'>سطر \(i) بخط لينن: يقرأ لينن ما يكتبه الوكلاء.</p>" }
        let pageHTML = "<!doctype html><meta charset='utf-8'><style>@font-face{font-family:PageFace;src:url(face.ttf)}@font-face{font-family:'Linen Sans';src:local('thmanyahsans-Regular')}@font-face{font-family:'Linen Serif Display';src:local('thmanyahserifdisplay-Light')}body{margin:0}</style>\(body)"
        try? pageHTML.write(to: pageDir.appendingPathComponent("page.html"), atomically: true, encoding: .utf8)
        let pc = WKWebViewConfiguration(); pc.websiteDataStore = .nonPersistent()
        let (pw, pv) = NotePDF.makeHost(configuration: pc, paper: .a4)
        _ = pw
        pv.loadFileURL(pageDir.appendingPathComponent("page.html"), allowingReadAccessTo: pageDir)
        try? await Task.sleep(for: .seconds(2))
        let longURL = out.appendingPathComponent("xb-page-long.pdf")
        do {
            let o = try await NotePDF.write(from: pv, options: .init(paper: .a4, title: "Page export", longPage: true), to: longURL)
            let doc = PDFDocument(url: longURL)
            let size = doc?.page(at: 0)?.bounds(for: .mediaBox).size ?? .zero
            let f = run(["/opt/homebrew/bin/pdffonts", longURL.path])
            let pageText = doc?.string ?? ""
            print("PAGE long: \(o.pages) page \(Int(size.width)) x \(Int(size.height)) pt, \(o.segments) segments, \(o.lineBoxes.count) redrawn; web font kept: \(f.contains("Arial")); Thmanyah: \(f.lowercased().contains("thmanyah")); finds «لينن» \(doc?.findString("لينن", withOptions: []).count ?? 0), «Web font line 119» \(pageText.contains("Web font line 119"))")
        } catch { print("page export failed: \(error)") }
        // 7. the app's way in: NotePDF.Host
        let hc = WKWebViewConfiguration(); hc.websiteDataStore = .nonPersistent()
        hc.setURLSchemeHandler(AppScheme(), forURLScheme: "linen-app")
        let host = NotePDF.Host(configuration: hc, paper: .letter)
        let ok = await host.open(settings: ["face": "sans", "uiDir": "ltr", "lang": "en", "contrast": false, "foldArabic": true],
                                 load: ["docId": "h", "name": "note.md", "path": "/tmp/note.md", "text": md, "plain": false, "version": 1, "meta": [:]])
        if ok, let o = try? await NotePDF.write(from: host.web, options: .init(paper: .letter, title: "Linen export test"), to: out.appendingPathComponent("xb-note-letter.pdf")) {
            print("HOST: rendered, Letter, \(o.pages) pages, \(o.bytes / 1024) KB, \(String(format: "%.2f", o.seconds)) s")
        } else { print("HOST: failed (rendered \(ok))") }
        host.close()
        // previews
        for i in [0, 1] {
            guard let pg = doc.page(at: i) else { continue }
            let t = pg.thumbnail(of: NSSize(width: 1200, height: 1697), for: .mediaBox)
            if let tiff = t.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: out.appendingPathComponent("xb-note-p\(i + 1).png"))
            }
        }
    }
}
