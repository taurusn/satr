// Export from the real renderer's display list (Renderer/board.js `displayList`), not a synthetic one: loads a board
// fixture into Linen's renderer offscreen, asks for its display list, and writes the whole-board PDF, the Sections
// PDF, a PNG of the view, and checks text, search, fonts and structure.
//
//   swiftc -O -swift-version 6 -parse-as-library -o build/real docs/spikes/export/real.swift Linen/Export/DisplayList.swift \
//     Linen/Export/OutlineText.swift Linen/Export/BoardPDF.swift Linen/Export/PDFCompact.swift Linen/Export/BoardPNG.swift \
//     -framework AppKit -framework PDFKit -framework WebKit
//   ./build/real Tests/Fixtures/boards/big-500.canvas build/export-out
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
    func make() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(AppScheme(), forURLScheme: "linen-app")
        config.userContentController.add(self, name: "linen")
        window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1176, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1176, height: 800), configuration: config)
        window.contentView = web
        window.orderBack(nil)
    }
    nonisolated func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let d = m.body as? [String: Any], let t = d["type"] as? String else { return }
            if t == "error" { print("page error: \(d["message"] ?? "")") }
            seen.append(t)
            for (i, w) in waits.enumerated().reversed() where w.0 == t { waits.remove(at: i); w.1.resume() }
        }
    }
    func wait(_ t: String) async {
        if seen.contains(t) { return }
        await withCheckedContinuation { waits.append((t, $0)) }
    }
    func send(_ msg: [String: Any]) async -> Any? { try? await web.callAsyncJavaScript("return await window.linen.receive(msg)", arguments: ["msg": msg], contentWorld: .page) }
}

func strip(_ s: String) -> String {
    let marks = CharacterSet(charactersIn: "\u{064B}\u{064C}\u{064D}\u{064E}\u{064F}\u{0650}\u{0651}\u{0652}\u{0670}\u{200F}\u{200E}\u{061C}")
    return String(String.UnicodeScalarView(s.unicodeScalars.filter { !marks.contains($0) })).components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
}

func run(_ args: [String]) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: args[0]); p.arguments = Array(args.dropFirst())
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    try? p.run(); p.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
}

@main
struct Real {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in await go(); exit(0) }
        app.run()
    }

    @MainActor static func go() async {
        let board = URL(fileURLWithPath: CommandLine.arguments[1])
        let out = URL(fileURLWithPath: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "build/export-out")
        let text = (try? String(contentsOf: board, encoding: .utf8)) ?? ""
        let sidecar = try? String(contentsOf: URL(fileURLWithPath: board.path + ".notes.json"), encoding: .utf8)
        let p = Page(); p.make()
        p.web.load(URLRequest(url: URL(string: "linen-app://renderer/page.html")!))
        await p.wait("ready")
        _ = await p.send(["type": "settings", "theme": "paper", "face": "sans", "uiDir": "ltr", "lang": "en", "contrast": false, "foldArabic": true])
        var load: [String: Any] = ["type": "load", "kind": "board", "docId": "b", "name": board.lastPathComponent, "path": board.path, "text": text, "version": 1]
        if let sidecar { load["sidecar"] = sidecar }
        _ = await p.send(load)
        await p.wait("rendered")
        let t0 = Date()
        guard let raw = await p.send(["type": "command", "name": "displayList"]) else { print("no display list"); return }
        let dlTime = Date().timeIntervalSince(t0)
        let name = board.deletingPathExtension().lastPathComponent
        if let json = try? JSONSerialization.data(withJSONObject: raw) { try? json.write(to: out.appendingPathComponent("real-\(name)-displaylist.json")) }
        guard let list = try? DisplayList.parse(raw) else { print("display list did not parse"); return }
        let lines: [DisplayList.Line] = list.items.compactMap { if case let .text(l) = $0 { return l }; return nil }
        print("REAL display list from \(board.lastPathComponent): \(list.items.count) items, \(lines.count) text runs, \(list.sections.count) sections, \(list.notes.count) notes, \(Int(list.size.width)) x \(Int(list.size.height)) px, built in \(String(format: "%.2f", dlTime)) s")
        for (shape, label) in [(BoardPDF.Shape.whole, "whole"), (.sections(.a4), "sections")] {
            let url = out.appendingPathComponent("real-\(name)-\(label).pdf")
            guard let o = try? BoardPDF.write(list, shape: shape, to: url), let doc = PDFDocument(url: url) else { print("\(label): failed"); continue }
            let all = strip((0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined(separator: "\n"))
            var found = 0, missing: [String] = []
            for l in lines {
                if all.contains(strip(l.text)) { found += 1 } else if missing.count < 4 { missing.append(l.text) }
            }
            let fonts = run(["/opt/homebrew/bin/pdffonts", url.path])
            let info = run(["/opt/homebrew/bin/pdfinfo", url.path])
            print("\(label): \(o.pages) pages, \(o.bytes / 1024) KB, \(String(format: "%.2f", o.seconds)) s; text runs read back \(found)/\(lines.count)" + (missing.isEmpty ? "" : " missing e.g. " + missing.map { "«\($0)»" }.joined(separator: " ")) +
                  "; Thmanyah in file: \(fonts.lowercased().contains("thmanyah")); pdfinfo errors: \(info.contains("Error"))")
            if let pg = doc.page(at: 0) {
                let b = pg.bounds(for: .mediaBox)
                let t = pg.thumbnail(of: NSSize(width: 1600, height: 1600 * b.height / b.width), for: .mediaBox)
                if let tiff = t.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: out.appendingPathComponent("real-\(name)-\(label)-p1.png"))
                }
            }
        }
        let firstSection = list.sections.first?.rect ?? CGRect(origin: .zero, size: list.size)
        let view = CGRect(x: firstSection.minX - 20, y: firstSection.minY - 70, width: 1176, height: 760)
        if let o = try? BoardPNG.write(list, region: .rect(view), scale: 2, to: out.appendingPathComponent("real-\(name)-view.png")) {
            print("PNG view 2x: \(o.width) x \(o.height) px, \(o.bytes / 1024) KB, \(String(format: "%.2f", o.seconds)) s")
        }
    }
}
