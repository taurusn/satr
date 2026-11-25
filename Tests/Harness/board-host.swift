// Linen's board host (Lane B): hosts Renderer/page.html the way the app does and drives the board view.
//
//   board-host shot <file.canvas> <out.png> [--width 1176] [--height 760] [--night] [--rail] [--list] [--ar]
//                   [--view fit|first|open|<node id>] [--zoom 0.5] [--onscreen] [--hold 600]
//   board-host bench <file.canvas> [--runs 20] [--width 1176] [--height 760] [--onscreen] [--rail]
//                   first paint (20 fresh loads at the opening view) and the B(a) gesture set, frame stats
//   board-host checks <file.canvas>...  structural checks at 12 zoom steps and two widths, console errors
//   board-host update <old.canvas> <new.canvas> [--onscreen]   load, rewrite, report the view hold and marks
//
// Build: swiftc -swift-version 5 -O -o build/board-host Tests/Harness/board-host.swift -framework AppKit -framework WebKit
import AppKit
import Darwin
import UniformTypeIdentifiers
import WebKit
import PDFKit

let args = Array(CommandLine.arguments.dropFirst())
// --renderer <dir> runs another copy of the renderer (the witness measures today's renderer against the branch's).
let rendererDir: URL = {
    if let i = CommandLine.arguments.firstIndex(of: "--renderer"), i + 1 < CommandLine.arguments.count { return URL(fileURLWithPath: CommandLine.arguments[i + 1]) }
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Renderer")
}()

func flag(_ name: String) -> Bool { args.contains(name) }
func value(_ name: String, _ fallback: Double) -> Double {
    if let i = args.firstIndex(of: name), i + 1 < args.count, let v = Double(args[i + 1]) { return v }
    return fallback
}
func string(_ name: String) -> String? {
    if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
    return nil
}

final class AppScheme: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let rel = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        let file = rendererDir.appendingPathComponent(rel).standardizedFileURL
        guard file.path.hasPrefix(rendererDir.standardizedFileURL.path), let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)"])!)
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

final class LocalScheme: NSObject, WKURLSchemeHandler {
    var base = URL(fileURLWithPath: "/")
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let rel = comps.path.removingPercentEncoding.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 } ?? ""
        let file = base.appendingPathComponent(rel)
        guard let data = try? Data(contentsOf: file) else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime])!)
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

@MainActor
final class Host: NSObject, WKScriptMessageHandler {
    let web: WKWebView
    let window: NSWindow
    let local = LocalScheme()
    var messages: [[String: Any]] = []
    var consoleErrors: [String] = []
    var waiters: [(String, CheckedContinuation<[String: Any], Never>)] = []

    init(width: Double, height: Double, onscreen: Bool) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(AppScheme(), forURLScheme: "linen-app")
        config.setURLSchemeHandler(local, forURLScheme: "linen-local")
        let origin = onscreen ? NSPoint(x: 40, y: 80) : NSPoint(x: -30000, y: -30000)
        window = NSWindow(contentRect: NSRect(origin: origin, size: NSSize(width: width, height: height)), styleMask: onscreen ? [.titled] : [.borderless], backing: .buffered, defer: false)
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: config)
        super.init()
        config.userContentController.add(self, name: "linen")
        config.userContentController.add(self, name: "console")
        config.userContentController.addUserScript(WKUserScript(source: """
          window.addEventListener('error', e => webkit.messageHandlers.console.postMessage('error: ' + e.message + ' @' + (e.filename||'') + ':' + (e.lineno||'')));
          window.addEventListener('securitypolicyviolation', e => webkit.messageHandlers.console.postMessage('csp: ' + e.violatedDirective + ' ' + e.blockedURI));
          const ce = console.error; console.error = (...a) => { webkit.messageHandlers.console.postMessage('console: ' + a.map(String).join(' ').slice(0, 300)); ce(...a); };
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        window.contentView = web
        if onscreen {
            window.title = "Linen board host"
            window.level = .floating
            window.orderFrontRegardless()
        } else {
            window.orderBack(nil)
        }
    }

    nonisolated func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        let name = m.name
        let body = m.body
        MainActor.assumeIsolated {
            if name == "console" { consoleErrors.append("\(body)"); return }
            guard let msg = body as? [String: Any], let type = msg["type"] as? String else { return }
            messages.append(msg)
            if type == "error" { consoleErrors.append("page error: \(msg["during"] ?? "?"): \(msg["message"] ?? "?")") }
            if type == "imageInfo", let reqs = msg["requests"] as? [String] {
                var map: [String: Any] = [:]
                for r in reqs where r.hasPrefix("path:") { map[r] = ["status": "ok", "url": "linen-local://asset/" + (String(r.dropFirst(5)).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")] }
                Task { _ = try? await self.send(["type": "imageInfo", "map": map]) }
            }
            if let i = waiters.firstIndex(where: { $0.0 == type }) { messages.removeLast(); waiters.remove(at: i).1.resume(returning: msg) }
        }
    }

    func wait(for type: String, timeout: Double = 20) async -> [String: Any] {
        if let i = messages.firstIndex(where: { $0["type"] as? String == type }) { return messages.remove(at: i) }
        return await withCheckedContinuation { cont in
            waiters.append((type, cont))
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                MainActor.assumeIsolated {
                    if let i = self.waiters.firstIndex(where: { $0.0 == type }) { self.waiters.remove(at: i).1.resume(returning: ["type": "timeout"]) }
                }
            }
        }
    }

    func open() async {
        web.load(URLRequest(url: URL(string: "linen-app://renderer/page.html")!))
        _ = await wait(for: "ready")
    }

    @discardableResult
    func send(_ msg: [String: Any]) async throws -> Any? {
        try await web.callAsyncJavaScript("return await window.linen.receive(msg)", arguments: ["msg": msg], contentWorld: .page)
    }
    func command(_ name: String, _ extra: [String: Any] = [:]) async -> Any? {
        var m = extra
        m["type"] = "command"
        m["name"] = name
        do { return try await send(m) } catch { print("command \(name) failed: \(error)"); return nil }
    }
    func js(_ code: String) async -> Any? { try? await web.callAsyncJavaScript(code, arguments: [:], contentWorld: .page) }

    func settings(night: Bool, ar: Bool) async {
        _ = try? await send(["type": "settings", "theme": night ? "night" : "paper", "face": "sans", "uiDir": ar ? "rtl" : "ltr", "lang": ar ? "ar" : "en", "contrast": false])
    }

    /// Loads a board; returns the milliseconds to the page's firstPaint and its own measure.
    func loadBoard(_ file: URL, docId: String, place: [String: Any]? = nil, baseline: [String]? = nil, extra: [String: Any] = [:]) async throws -> (Double, Double) {
        let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        let side = URL(fileURLWithPath: file.path + ".notes.json")
        let sidecar: Any = (try? String(contentsOf: side, encoding: .utf8)) ?? NSNull()
        local.base = file.deletingLastPathComponent()
        messages.removeAll { ["rendered", "firstPaint"].contains($0["type"] as? String ?? "") }
        var msg: [String: Any] = ["type": "load", "kind": "board", "docId": docId, "name": file.lastPathComponent, "path": file.path,
                                  "refPath": file.lastPathComponent, "text": text, "sidecar": sidecar, "version": 1, "meta": [:]]
        if let place { msg["place"] = place }
        if let baseline { msg["baseline"] = baseline; msg["baselineDate"] = "14 October" }
        for (k, v) in extra { msg[k] = v }
        let t0 = CFAbsoluteTimeGetCurrent()
        Task { _ = try? await self.send(msg) }
        let fp = await wait(for: "firstPaint", timeout: 20)
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        return (ms, (fp["paintMs"] as? NSNumber)?.doubleValue ?? -1)
    }

    func snapshot(to path: String) async {
        try? await Task.sleep(for: .milliseconds(250))
        let img = try? await web.takeSnapshot(configuration: WKSnapshotConfiguration())
        if let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}

func stats(_ xs: [Double]) -> String {
    guard !xs.isEmpty else { return "no frames" }
    let s = xs.sorted()
    func q(_ p: Double) -> Double { s[min(s.count - 1, Int(p * Double(s.count)))] }
    let dropped = Double(xs.filter { $0 > 25 }.count) / Double(xs.count) * 100
    return String(format: "p50 %.1f  p95 %.1f  p99 %.1f  dropped %.1f%%  longest %.0f ms  (%d frames)", q(0.5), q(0.95), q(0.99), dropped, s.last!, xs.count)
}

@MainActor
func run() async {
    guard let cmd = args.first else { print("usage: board-host shot|bench|checks|update ..."); exit(2) }
    let width = value("--width", 1176), height = value("--height", 760)
    let onscreen = flag("--onscreen")
    let host = Host(width: width, height: height, onscreen: onscreen)
    await host.open()
    await host.settings(night: flag("--night"), ar: flag("--ar"))
    _ = await host.command("outline", ["show": flag("--rail"), "overlay": false])
    switch cmd {
    case "shot":
        guard args.count >= 3 else { print("shot <file> <out.png>"); exit(2) }
        let file = URL(fileURLWithPath: args[1])
        let view = string("--view") ?? "open"
        var place: [String: Any]? = nil
        if let z = string("--zoom"), let s = Double(z), let cx = string("--cx").flatMap(Double.init), let cy = string("--cy").flatMap(Double.init) {
            place = ["kind": "board", "cx": cx, "cy": cy, "zoom": s, "node": NSNull(), "mode": "canvas"]
        }
        let base = string("--baseline").map { (try? String(contentsOfFile: $0, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? [] }
        if let h = string("--heads") { _ = await host.js("window.__linenHeads = \"\(h)\"; return true") }
        let (ms, paint) = try! await host.loadBoard(file, docId: "shot", place: place, baseline: base)
        if view == "fit" { _ = await host.command("fit") }
        else if view == "first" { }
        else if view != "open" { _ = await host.command("goNode", ["id": view, "select": true]) }
        if let z = string("--zoom"), let s = Double(z), place == nil { _ = await host.command("zoomTo", ["s": s]) }
        if flag("--list") { _ = await host.command("toggleList") }
        if let w = string("--legend") { _ = await host.command("legend", ["word": w]); _ = await host.command("findNext") }
        if let q = string("--find") { let n = await host.command("findText", ["q": q]); print("find \(q): \(n ?? "?") hits"); _ = await host.command("findNext") }
        if let n = string("--note") { _ = await host.command("goNode", ["id": n, "select": true]); try? await Task.sleep(for: .milliseconds(500)); print("note open: \(await host.command("openNote", ["id": n]) ?? "?")") }
        if flag("--copyref") { print("reference:\n\(((await host.command("copyReference", ["refPath": "boards/" + file.lastPathComponent])) as? [String: Any])?["text"] ?? "none")") }
        if flag("--display") { print("display list: \(await host.command("displayListSummary") ?? "?")") }
        try? await Task.sleep(for: .milliseconds(Int(value("--hold", 700))))
        if let probe = string("--probe") { print("probe: \(await host.js(probe) ?? "nil")") }
        await host.snapshot(to: args[2])
        let v = await host.command("view") as? [String: Any] ?? [:]
        print(String(format: "first paint %.0f ms (page %.0f ms); view s=%.3f level=%@ mounted=%@", ms, paint, (v["s"] as? Double) ?? -1, (v["level"] as? String) ?? "?", "\(v["mounted"] ?? "?")"))
        for e in host.consoleErrors.prefix(10) { print("console: \(e)") }
    case "bench":
        let file = URL(fileURLWithPath: args[1])
        let runs = Int(value("--runs", 20))
        var paints: [Double] = [], pagePaints: [Double] = []
        for i in 0..<runs {
            let (ms, paint) = try! await host.loadBoard(file, docId: "b\(i)")
            paints.append(ms)
            pagePaints.append(paint)
            try? await Task.sleep(for: .milliseconds(150))
        }
        let v = await host.command("view") as? [String: Any] ?? [:]
        print("board \(file.lastPathComponent): opening view s=\(v["s"] ?? "?") level=\(v["level"] ?? "?") mounted=\(v["mounted"] ?? "?") window \(Int(width))x\(Int(height)) \(onscreen ? "on screen" : "offscreen")")
        print("first paint (host, \(runs) loads): \(stats(paints).replacingOccurrences(of: "dropped", with: "over-25"))")
        print("first paint (page's own):          \(stats(pagePaints).replacingOccurrences(of: "dropped", with: "over-25"))")
        var byName: [String: [Double]] = [:], settle: [String: [Double]] = [:], order: [String] = []
        let gestureRuns = Int(value("--gesture-runs", 3))
        for _ in 0..<gestureRuns {
            var exp: [String: Any] = [:]
            for k in (string("--exp") ?? "").split(separator: ",") { exp[String(k)] = true }
            guard let out = await host.command("bench", ["frames": 180, "exp": exp]) as? [String: Any], let rs = out["runs"] as? [[String: Any]] else { print("bench failed"); break }
            for r in rs {
                let name = r["name"] as? String ?? "?"
                if byName[name] == nil { order.append(name) }
                let fr = (r["frames"] as? [Double]) ?? []
                byName[name, default: []] += fr
                if flag("--js") { print(String(format: "  %@: frame() js %.2f ms, dom %@, over %@, under %@", name, (r["jsMs"] as? Double) ?? -1, "\(r["dom"] ?? "?")", "\(r["over"] ?? "?")", "\(r["under"] ?? "?")")) }
                if flag("--slow") { print("  \(name): slow frames at \(fr.enumerated().filter { $0.element > 25 }.map { "\($0.offset):\(Int($0.element))" })") }
                settle[name, default: []].append((r["settleMs"] as? Double) ?? -1)
            }
        }
        for name in order {
            let st = settle[name] ?? []
            print(String(format: "%-24@ %@  settle max %.0f ms", name as NSString, stats(byName[name] ?? []), st.max() ?? -1))
        }
        for e in host.consoleErrors.prefix(10) { print("console: \(e)") }
    case "checks":
        var failed = 0
        for path in args.dropFirst() where !path.hasPrefix("--") && path.hasSuffix(".canvas") {
            let file = URL(fileURLWithPath: path)
            for w in [1176.0, 390.0] {
                host.window.setContentSize(NSSize(width: w, height: w > 500 ? 760 : 790))
                host.web.frame = NSRect(x: 0, y: 0, width: w, height: w > 500 ? 760 : 790)
                host.consoleErrors.removeAll()
                _ = try! await host.loadBoard(file, docId: "c\(Int(w))")
                _ = await host.command("fit")
                try? await Task.sleep(for: .milliseconds(450))
                var smalls: [String] = [], missing: [String] = []
                for s in [0.05, 0.1, 0.2, 0.29, 0.31, 0.45, 0.6, 0.72, 0.74, 1.0, 1.5, 2.5] {
                    _ = await host.command("zoomTo", ["s": s])
                    for _ in 0..<40 { if ((await host.command("view") as? [String: Any])?["queue"] as? Int ?? 0) == 0 { break }; try? await Task.sleep(for: .milliseconds(30)) }
                    guard let r = await host.command("structural") as? [String: Any] else { continue }
                    for x in (r["small"] as? [String]) ?? [] { smalls.append("s=\(s): \(x)") }
                    for x in (r["missingText"] as? [String]) ?? [] { missing.append("s=\(s): \(x)") }
                    for x in (r["hiddenChips"] as? [String]) ?? [] { missing.append("s=\(s): chip under a card \(x)") }
                    for x in (r["chipsOverCards"] as? [String]) ?? [] { missing.append("s=\(s): chip over a card \(x)") }
                    for x in (r["smallNames"] as? [String]) ?? [] { missing.append("s=\(s): section name under 15 px \(x)") }
                    for x in (r["blankText"] as? [String]) ?? [] { missing.append("s=\(s): text node drawn as a blank box \(x)") }
                    if let n = r["labelsUnderConnectors"] as? Int, n > 0 { missing.append("s=\(s): \(n) section names under the connectors") }
                    if let n = r["labelsWithoutBand"] as? Int, n > 0 { missing.append("s=\(s): \(n) section names without a ground band") }
                }
                for rail in [false, true] {
                    _ = await host.command("outline", ["show": rail, "overlay": false])
                    if let f = await host.command("fitClear") as? [String: Any], let hits = f["hits"] as? [String], !hits.isEmpty { missing.append("fit with rail \(rail): board under \(hits.joined(separator: ", "))") }
                }
                let ok = smalls.isEmpty && missing.isEmpty && host.consoleErrors.isEmpty
                if !ok { failed += 1 }
                print("\(ok ? "PASS" : "FAIL")  \(file.lastPathComponent) @\(Int(w))  small text \(smalls.count), missing text \(missing.count), console \(host.consoleErrors.count)")
                for x in smalls.prefix(4) { print("      small: \(x)") }
                for x in missing.prefix(4) { print("      missing: \(x)") }
                for x in host.consoleErrors.prefix(4) { print("      console: \(x)") }
            }
        }
        exit(failed == 0 ? 0 : 1)
    case "measurecheck":
        // Measuring for `linen layout` in a page with no board loaded must equal measuring with the board loaded.
        var failed = 0
        for path in args.dropFirst() where path.hasSuffix(".canvas") {
            let file = URL(fileURLWithPath: path)
            let text = String(decoding: try! Data(contentsOf: file), as: UTF8.self)
            let side: Any = (try? String(contentsOf: URL(fileURLWithPath: file.path + ".notes.json"), encoding: .utf8)) ?? NSNull()
            let fresh = Host(width: width, height: height, onscreen: false)
            await fresh.open()
            let a = await fresh.command("measureNodes", ["text": text, "sidecar": side]) as? [String] ?? []
            _ = try! await host.loadBoard(file, docId: "m")
            let b = await host.command("measureNodes", ["text": text, "sidecar": side]) as? [String] ?? []
            let diff = zip(a, b).filter { $0 != $1 }
            let ok = a.count == b.count && diff.isEmpty
            if !ok { failed += 1 }
            print("\(ok ? "PASS" : "FAIL")  measure \(file.lastPathComponent): \(a.count) cards, \(diff.count) differ\(diff.prefix(3).map { " \($0.0) vs \($0.1)" }.joined())")
        }
        exit(failed == 0 ? 0 : 1)
    case "arrange":
        // ENG-8 to ENG-14, ENG-21 in the page, with synthetic pointer events: arrange <file> (Tests/Harness/board-arrange-checks.js)
        let file = URL(fileURLWithPath: args[1])
        _ = try! await host.loadBoard(file, docId: "arr", place: ["kind": "board", "cx": 520, "cy": 170, "zoom": 1.0, "node": NSNull(), "mode": "canvas"], extra: ["canArrange": true])
        try? await Task.sleep(for: .milliseconds(500))
        let code = try! String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("board-arrange-checks.js"), encoding: .utf8)
        let text = String(decoding: try! Data(contentsOf: file), as: UTF8.self)
        var res: Any? = nil
        do { res = try await host.web.callAsyncJavaScript(code, arguments: ["text": text], contentWorld: .page) } catch { print("error: \(error)") }
        var failed = 0
        for r in (res as? [[String: Any]]) ?? [] {
            let pass = r["pass"] as? Bool ?? false
            if !pass { failed += 1 }
            print("\(pass ? "PASS" : "FAIL")  \(r["name"] ?? "")  [\(r["detail"] ?? "")]")
        }
        if res == nil { print("suite did not run"); failed += 1 }
        for e in host.consoleErrors.prefix(6) { print("console: \(e)") }
        exit(failed == 0 ? 0 : 1)
    case "notecheck":
        // BRD-19, BLK-8 in the page: notecheck <board.canvas> (Tests/Harness/note-embed-checks.js), then the PDF
        let board = String(decoding: try! Data(contentsOf: URL(fileURLWithPath: args[1])), as: UTF8.self)
        let code = try! String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("note-embed-checks.js"), encoding: .utf8)
        var res: Any? = nil
        do { res = try await host.web.callAsyncJavaScript(code, arguments: ["board": board], contentWorld: .page) } catch { print("error: \(error)") }
        var failed = 0
        for r in (res as? [[String: Any]]) ?? [] {
            let pass = r["pass"] as? Bool ?? false
            if !pass { failed += 1 }
            print("\(pass ? "PASS" : "FAIL")  \(r["name"] ?? "")  [\(r["detail"] ?? "")]")
        }
        if res == nil { print("suite did not run"); failed += 1 }
        let opened = host.messages.contains { $0["type"] as? String == "openWiki" && ($0["target"] as? String) == "map.canvas" && ($0["newTab"] as? Bool) == true }
        if !opened { failed += 1 }
        print("\(opened ? "PASS" : "FAIL")  the Open board button opens the board in its own tab  [openWiki map.canvas, new tab]")
        try? await Task.sleep(for: .milliseconds(300))
        let pdf = try? await host.web.pdf(configuration: WKPDFConfiguration())
        let text = pdf.flatMap { PDFDocument(data: $0)?.string } ?? ""
        let printed = text.contains("Request form") && text.contains("Nightly import")
        if !printed { failed += 1 }
        print("\(printed ? "PASS" : "FAIL")  the note prints with the board drawn in it (PDF text has its boxes)  [\(pdf?.count ?? 0) bytes]")
        for e in host.consoleErrors.prefix(6) { print("console: \(e)") }
        exit(failed == 0 ? 0 : 1)
    case "routes":
        // routes <file>: the page's own routes (points, sides, how, label), as JSON
        _ = try! await host.loadBoard(URL(fileURLWithPath: args[1]), docId: "routes")
        let r = try? await host.web.callAsyncJavaScript("const S = window.LinenBoard._state; const o = {}; if (S.routes) for (const [id, r] of S.routes) o[id] = { pts: r.pts, how: r.how, fromSide: r.fromSide, toSide: r.toSide, label: r.label }; return JSON.stringify(o);", arguments: [:], contentWorld: .page)
        print((r as? String) ?? "{}")
        exit(0)
    case "benchdrag":
        // ENG-16: drag frames. benchdrag <file> --ids a,b [--steps 60] [--zoom s] [--cx x --cy y]: each box dragged
        // 400 x 120 board px in `steps` frames through the page's own drag code (routing, cards, lines, guides), timed.
        let file = URL(fileURLWithPath: args[1])
        var place: [String: Any]? = nil
        if let z = string("--zoom"), let s = Double(z), let cx = string("--cx").flatMap(Double.init), let cy = string("--cy").flatMap(Double.init) {
            place = ["kind": "board", "cx": cx, "cy": cy, "zoom": s, "node": NSNull(), "mode": "canvas"]
        }
        _ = try! await host.loadBoard(file, docId: "drag", place: place)
        try? await Task.sleep(for: .milliseconds(400))
        for id in (string("--ids") ?? "").split(separator: ",") {
            let r = await host.command("benchDrag", ["id": String(id), "steps": Int(value("--steps", 60)), "noSnap": flag("--nosnap")]) as? [String: Any]
            print(String(format: "drag %@: %@ lines, frame work p50 %.1f ms, p95 %.1f ms, max %.1f ms", String(id), "\(r?["lines"] ?? "?")", (r?["p50"] as? Double) ?? -1, (r?["p95"] as? Double) ?? -1, (r?["max"] as? Double) ?? -1))
        }
        for e in host.consoleErrors.prefix(6) { print("console: \(e)") }
        exit(0)
    case "probe":
        let code = try! String(contentsOfFile: args[1], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        print(((try? await host.web.callAsyncJavaScript("return await \(code)", arguments: [:], contentWorld: .page)) ?? "nil") ?? "nil")
        exit(0)
    case "m7":
        // The Codex M7 findings, one check each (Tests/Harness/board-m7-checks.js).
        let code = try! String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("board-m7-checks.js"), encoding: .utf8)
        let body = code.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "^//.*$", with: "", options: .regularExpression)
        let trimmed = body.hasSuffix(";") ? String(body.dropLast()) : body
        let res = try? await host.web.callAsyncJavaScript("return await \(trimmed)", arguments: [:], contentWorld: .page)
        var failed = 0
        for r in (res as? [[String: Any]]) ?? [] {
            let pass = r["pass"] as? Bool ?? false
            if !pass { failed += 1 }
            print("\(pass ? "PASS" : "FAIL")  #\(r["id"] ?? "?") \(r["name"] ?? "")  [\(r["detail"] ?? "")]")
        }
        if res == nil { print("suite did not run") ; failed += 1 }
        for e in host.consoleErrors.prefix(6) { print("console: \(e)") }
        exit(failed == 0 ? 0 : 1)
    case "update":
        let a = URL(fileURLWithPath: args[1]), b = URL(fileURLWithPath: args[2])
        _ = try! await host.loadBoard(a, docId: "u")
        let base = await host.wait(for: "baseline", timeout: 3)
        _ = await host.command("goNode", ["id": string("--at") ?? "", "select": false])
        try? await Task.sleep(for: .milliseconds(500))
        let before = await host.js("const S = window.LinenBoard._state; const c = [...S.mounted.keys()][0]; return JSON.stringify(S.view)") as? String ?? ""
        let text = String(decoding: try! Data(contentsOf: b), as: UTF8.self)
        let side: Any = (try? String(contentsOf: URL(fileURLWithPath: b.path + ".notes.json"), encoding: .utf8)) ?? NSNull()
        _ = try? await host.send(["type": "update", "kind": "board", "text": text, "sidecar": side, "version": 2])
        try? await Task.sleep(for: .milliseconds(500))
        let after = await host.js("return JSON.stringify(window.LinenBoard._state.view)") as? String ?? ""
        let v = await host.command("view") as? [String: Any] ?? [:]
        print("baseline \((base["hashes"] as? [String])?.count ?? -1) entries; view before \(before) after \(after); changed \(v["changed"] ?? "?") rewritten \(v["rewritten"] ?? "?")")
        if let out = string("--out") { await host.snapshot(to: out) }
        for e in host.consoleErrors.prefix(10) { print("console: \(e)") }
    case "witness":
        await witness(host, URL(fileURLWithPath: args[1]), width: width, height: height)
    default:
        print("unknown command \(cmd)")
        exit(2)
    }
    exit(0)
}

// ---------- the line witness (PRD-2 17.6) ----------
// For each view: the normal render; lines only (boxes, names, chips, ground pattern and chrome hidden); a mask of every
// placed box painted from the model's own positions (not from the renderer's drawing code); a mask of section names and
// titles. A line pixel inside a mask shrunk by 3 px is a hidden line pixel. Prints one line per view and a total.
struct Bitmap {
    let w: Int, h: Int, bpr: Int, spp: Int
    let data: [UInt8]
    init?(_ path: String) {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)), let rep = NSBitmapImageRep(data: d) else { return nil }
        // Redraw into a known 8-bit RGBA layout.
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: rep.pixelsWide * 4, bitsPerPixel: 32) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        rep.draw(in: NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
        NSGraphicsContext.restoreGraphicsState()
        w = out.pixelsWide; h = out.pixelsHigh; bpr = out.bytesPerRow; spp = 4
        data = Array(UnsafeBufferPointer(start: out.bitmapData!, count: bpr * h))
    }
    func px(_ x: Int, _ y: Int) -> (Int, Int, Int) { let o = y * bpr + x * spp; return (Int(data[o]), Int(data[o + 1]), Int(data[o + 2])) }
}

/// A mask shrunk by r px: a pixel stays only when every pixel in its (2r+1) square is in the mask (an integral image).
func erode(_ m: [Bool], _ w: Int, _ h: Int, _ r: Int) -> [Bool] {
    var I = [Int](repeating: 0, count: (w + 1) * (h + 1))
    for y in 0..<h { var row = 0; for x in 0..<w { if m[y * w + x] { row += 1 }; I[(y + 1) * (w + 1) + x + 1] = I[y * (w + 1) + x + 1] + row } }
    var out = [Bool](repeating: false, count: w * h)
    let full = (2 * r + 1) * (2 * r + 1)
    for y in r..<max(r, h - r) { for x in r..<max(r, w - r) where m[y * w + x] {
        let x0 = x - r, y0 = y - r, x1 = x + r + 1, y1 = y + r + 1
        let s = I[y1 * (w + 1) + x1] - I[y0 * (w + 1) + x1] - I[y1 * (w + 1) + x0] + I[y0 * (w + 1) + x0]
        out[y * w + x] = s == full
    } }
    return out
}

@MainActor
func witness(_ host: Host, _ fileIn: URL, width: Double, height: Double) async {
    // --route elbow|curved|straight measures a board as if its owner set the board's line style (Hatim's restyle action).
    var file = fileIn
    if let rt = string("--route"), let d = try? Data(contentsOf: fileIn), var obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
        var ln = obj["linen"] as? [String: Any] ?? [:]
        ln["route"] = rt
        obj["linen"] = ln
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("witness-\(rt)-" + fileIn.lastPathComponent)
        if let out = try? JSONSerialization.data(withJSONObject: obj) { try? out.write(to: tmp); file = tmp }
    }
    let outDir = string("--out") ?? NSTemporaryDirectory()
    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    let tag = string("--tag") ?? file.deletingPathExtension().lastPathComponent
    // A busy machine can time a load out (the page has no board yet and the plan comes back empty): load once more.
    var (_, paint) = try! await host.loadBoard(file, docId: "witness")
    if paint < 0 { print("first load timed out; loading again"); (_, paint) = try! await host.loadBoard(file, docId: "witness2") }
    try? await Task.sleep(for: .milliseconds(600))
    // The views: Fit, each top-level section fitted, then tiles over the whole board (gutters included) at zoom 0.4 and
    // at reading zoom 0.8, skipping tiles with no connector end in or near them (round 10, finding 9).
    let plan = await host.js("""
      const S = window.LinenBoard._state, b = S.board, out = [{ name: 'fit', fit: true }];
      for (const id of b.order) {
        const n = b.byId.get(id);
        if (!n || n.kind !== 'section' || n.depth > 0 || !n.placed) continue;
        out.push({ name: id, node: id });
      }
      let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
      for (const n of b.nodes) if (n.placed) { x0 = Math.min(x0, n.x); y0 = Math.min(y0, n.y); x1 = Math.max(x1, n.x + n.w); y1 = Math.max(y1, n.y + n.h); }
      const spans = [];
      for (const e of b.edges) {
        const a = b.byId.get(e.from), c = b.byId.get(e.to);
        if (!a || !c || !a.placed || !c.placed || e.missing) continue;
        spans.push([Math.min(a.x, c.x) - 60, Math.min(a.y, c.y) - 60, Math.max(a.x + a.w, c.x + c.w) + 60, Math.max(a.y + a.h, c.y + c.h) + 60]);
      }
      for (const read of [0.4, 0.8]) {
        const vw = S.W / read, vh = S.H / read;
        if ((x1 - x0) * read <= S.W && (y1 - y0) * read <= S.H) continue;
        let k = 0;
        for (let y = y0 - 60; y < y1; y += vh * 0.9) for (let x = x0 - 20; x < x1; x += vw * 0.9) {
          if (!spans.some((r) => r[0] < x + vw && r[2] > x && r[1] < y + vh && r[3] > y)) continue;
          out.push({ name: 'z' + read + '@' + (++k), view: { s: read, tx: -x * read, ty: -y * read } });
        }
      }
      return JSON.stringify(out);
    """) as? String ?? "[]"
    // The geometry of every line, once (witness-geo.js: lines through boxes, overlaps, near misses, shared ends, chips).
    let geoJS = (try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("witness-geo.js"), encoding: .utf8)) ?? ""
    let inj = await host.js("try {\n" + geoJS + "\n} catch (e) { return 'geo script: ' + e.message; }\nreturn 'ok'") as? String ?? "geo script: no answer"
    if inj != "ok" { print(inj) }
    let geo = await host.js("try { return window.__witGeo ? window.__witGeo() : 'none'; } catch (e) { return 'geo: ' + e.message; }") as? String ?? "?"
    print("GEO \(tag): \(geo)")
    let views = (try? JSONSerialization.jsonObject(with: Data(plan.utf8))) as? [[String: Any]] ?? []
    let maxViews = Int(value("--max-views", 40))
    let hideChrome = ".b-zpanel,.b-chip,.b-line,.b-toast,.b-hlabel,.b-notecard,.b-rail,.b-readlist2,.b-find{visibility:hidden!important}"
    func style(_ css: String) async {
        _ = await host.js("let s = document.getElementById('wit'); if (!s) { s = document.createElement('style'); s.id = 'wit'; document.head.appendChild(s); } s.textContent = \(String(reflecting: css)); return 1")
    }
    func redraw(_ exp: String) async {
        _ = await host.js("const S = window.LinenBoard._state; S.exp = \(exp); const v = S.view; await window.linen.receive({type: 'command', name: 'setView', s: v.s, tx: v.tx, ty: v.ty}); return 1")
        try? await Task.sleep(for: .milliseconds(Int(value("--settle", 350))))
    }
    var totalHidden = 0, totalName = 0, totalLine = 0, totalChip = 0, totalNameAreas = 0, totalChipOnChip = 0
    var lines: [String] = []
    for (vi, v) in views.prefix(maxViews).enumerated() {
        let name = v["name"] as? String ?? "v\(vi)"
        await style(""); await redraw("{}")
        if v["fit"] as? Bool == true { _ = await host.command("fit") }
        else if let n = v["node"] as? String { _ = await host.command("goNode", ["id": n, "select": false]) }
        else if let vv = v["view"] as? [String: Any] { _ = await host.command("setView", ["s": vv["s"] ?? 1, "tx": vv["tx"] ?? 0, "ty": vv["ty"] ?? 0]) }
        try? await Task.sleep(for: .milliseconds(700))
        let safe = name.replacingOccurrences(of: "/", with: "_")
        let base = "\(outDir)/\(tag)-\(String(format: "%02d", vi))-\(safe)"
        await style(hideChrome); await redraw("{}")
        await host.snapshot(to: base + "-view.png")
        // lines only
        await style(hideChrome + ".b-over,.b-under,.b-weave{visibility:hidden!important}")
        await redraw("{noNodes: true}")
        await host.snapshot(to: base + "-lines.png")
        // boxes: painted from the model's positions over everything
        await style(hideChrome + ".b-over,.b-under,.b-weave,.b-shapes{visibility:hidden!important}")
        await redraw("{noNodes: true, noEdges: true}")
        _ = await host.js("""
          const S = window.LinenBoard._state, b = S.board, v = S.view;
          let c = document.getElementById('witmask'); if (c) c.remove();
          c = document.createElement('canvas'); c.id = 'witmask';
          const host = document.querySelector('.b-canvas'), r = host.getBoundingClientRect(), dpr = devicePixelRatio || 1;
          c.width = r.width * dpr; c.height = r.height * dpr;
          c.style.cssText = 'position:absolute;left:0;top:0;width:' + r.width + 'px;height:' + r.height + 'px;z-index:99;pointer-events:none';
          const g = c.getContext('2d'); g.setTransform(dpr, 0, 0, dpr, 0, 0); g.fillStyle = '#ff00ff';
          for (const n of b.nodes) { if (!n.placed || n.kind === 'section') continue; g.fillRect(n.x * v.s + v.tx, n.y * v.s + v.ty, n.w * v.s, n.h * v.s); }
          host.appendChild(c); return 1;
        """)
        await host.snapshot(to: base + "-boxes.png")
        _ = await host.js("const c = document.getElementById('witmask'); if (c) c.remove(); return 1")
        // section names and titles
        await style(hideChrome + ".b-over,.b-weave,.b-shapes{visibility:hidden!important} .b-slbl b,.b-slbl .eyebrow,.b-stitle span{background:#ff00ff!important;color:transparent!important;box-shadow:0 0 0 calc(3 * var(--px, 1px)) #ff00ff!important}")
        await redraw("{noNodes: true, noEdges: true}")
        await host.snapshot(to: base + "-names.png")
        await style(""); await redraw("{}")
        // Label chips on screen: on top of each other, and over other lines (screen px, chips shrunk by 2; witness-geo.js).
        let wv = (try? JSONSerialization.jsonObject(with: Data(((await host.js("return window.__witView ? window.__witView() : '{}'") as? String) ?? "{}").utf8))) as? [String: Any] ?? [:]
        let chipHits = (wv["under"] as? NSNumber)?.intValue ?? 0, chipOnChip = (wv["chipOnChip"] as? NSNumber)?.intValue ?? 0
        totalChip += chipHits; totalChipOnChip += chipOnChip
        let vs = await host.command("view") as? [String: Any] ?? [:]
        guard let L = Bitmap(base + "-lines.png"), let B = Bitmap(base + "-boxes.png"), let N = Bitmap(base + "-names.png") else { print("\(name): could not read the renders"); continue }
        let w = L.w, h = L.h, scale = Double(w) / width
        // The ground: the most common colour of the lines-only render (a corner pixel can be a line).
        var hist: [Int: Int] = [:]
        for y in stride(from: 0, to: h, by: 7) { for x in stride(from: 0, to: w, by: 7) { let (r, g, b) = L.px(x, y); hist[(r << 16) | (g << 8) | b, default: 0] += 1 } }
        let gk = hist.max { $0.value < $1.value }?.key ?? 0
        let g0 = (gk >> 16, (gk >> 8) & 255, gk & 255)
        var isLine = [Bool](repeating: false, count: w * h), boxM = [Bool](repeating: false, count: w * h), nameM = [Bool](repeating: false, count: w * h)
        var lineCount = 0
        for y in 0..<h { for x in 0..<w {
            let (r, g, b) = L.px(x, y)
            if abs(r - g0.0) + abs(g - g0.1) + abs(b - g0.2) > 40 { isLine[y * w + x] = true; lineCount += 1 }
            let (r2, g2, b2) = B.px(x, y); if r2 > 200 && g2 < 90 && b2 > 200 { boxM[y * w + x] = true }
            let (r3, g3, b3) = N.px(x, y); if r3 > 200 && g3 < 90 && b3 > 200 { nameM[y * w + x] = true }
        } }
        let rr = max(1, Int((3 * scale).rounded()))
        let bE = erode(boxM, w, h, rr), nE = erode(nameM, w, h, rr)
        var hidden = 0, underName = 0
        var cells: [Int: Int] = [:]
        var nameCells: [Int: Int] = [:]
        let s = (vs["s"] as? Double) ?? 1, tx = (vs["tx"] as? Double) ?? 0, ty = (vs["ty"] as? Double) ?? 0
        for i in 0..<(w * h) where isLine[i] {
            if bE[i] { hidden += 1; let x = Double(i % w) / scale, y = Double(i / w) / scale; cells[Int(((x - tx) / s) / 40) * 100000 + Int(((y - ty) / s) / 40), default: 0] += 1 }
            else if nE[i] { underName += 1; let x = Double(i % w) / scale, y = Double(i / w) / scale; nameCells[Int(((x - tx) / s) / 40) * 100000 + Int(((y - ty) / s) / 40), default: 0] += 1 }
        }
        totalHidden += hidden; totalLine += lineCount
        if s >= 0.3 { totalName += underName } else { totalNameAreas += underName }
        let top = cells.sorted { $0.value > $1.value }.prefix(4).map { "(\(($0.key / 100000) * 40),\(($0.key % 100000) * 40)) \($0.value)" }.joined(separator: "; ")
        let ntop = nameCells.sorted { $0.value > $1.value }.prefix(3).map { "(\(($0.key / 100000) * 40),\(($0.key % 100000) * 40)) \($0.value)" }.joined(separator: "; ")
        let row = String(format: "%@ s=%.2f: line px %d, hidden under boxes %d, under names %d, lines under chips %d, chip on chip %d", name, s, lineCount, hidden, underName, chipHits, chipOnChip) + (top.isEmpty ? "" : "  boxes at board " + top) + (ntop.isEmpty ? "" : "  names at board " + ntop)
        lines.append(row); print(row)
    }
    let stats = await host.js("const s = window.LinenBoard._state.routeStats; return s ? JSON.stringify(s) : 'none'") as? String ?? "?"
    print("TOTAL \(tag): views \(min(views.count, maxViews)) of \(views.count), line px \(totalLine), hidden under boxes \(totalHidden), under names \(totalName) (and \(totalNameAreas) below the map level), lines under other chips \(totalChip), chip on chip \(totalChipOnChip)")
    print("router: \(stats)")
    for e in host.consoleErrors.prefix(10) { print("console: \(e)") }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Task { @MainActor in await run() }
app.run()
