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

let args = Array(CommandLine.arguments.dropFirst())
let rendererDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Renderer")

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
    func loadBoard(_ file: URL, docId: String, place: [String: Any]? = nil, baseline: [String]? = nil) async throws -> (Double, Double) {
        let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        let side = URL(fileURLWithPath: file.path + ".notes.json")
        let sidecar: Any = (try? String(contentsOf: side, encoding: .utf8)) ?? NSNull()
        local.base = file.deletingLastPathComponent()
        messages.removeAll { ["rendered", "firstPaint"].contains($0["type"] as? String ?? "") }
        var msg: [String: Any] = ["type": "load", "kind": "board", "docId": docId, "name": file.lastPathComponent, "path": file.path,
                                  "refPath": file.lastPathComponent, "text": text, "sidecar": sidecar, "version": 1, "meta": [:]]
        if let place { msg["place"] = place }
        if let baseline { msg["baseline"] = baseline; msg["baselineDate"] = "14 October" }
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
    default:
        print("unknown command \(cmd)")
        exit(2)
    }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Task { @MainActor in await run() }
app.run()
