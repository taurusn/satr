// Spike I(a): one Linen page in a WKWebView, hosted the way the Mac app's DocumentWindow hosts it (linen-app for the
// renderer, linen-local for images beside the document, the `linen` message handler, the error and CSP listener at
// document start). The bridge answers what the page asks of the app (imageInfo, resolveLinks, baseline), as the Mac
// app and Loom's shim do.
import UIKit
import UniformTypeIdentifiers
import WebKit

let resources = Bundle.main.resourceURL!
let rendererRoot = resources.appendingPathComponent("renderer").standardizedFileURL
let fixturesRoot = resources.appendingPathComponent("fixtures")
let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

/// Serves the renderer from the app bundle as linen-app://renderer/ (the Mac app's AppScheme).
final class AppScheme: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, url.host == "renderer" else { task.didFailWithError(URLError(.badURL)); return }
        let rel = url.path.split(separator: "/").map(String.init).filter { $0 != ".." && $0 != "." }
        let file = rel.reduce(rendererRoot) { $0.appendingPathComponent($1) }
        guard file.path.hasPrefix(rendererRoot.path + "/"), let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                        headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)", "Cache-Control": "no-store"])!)
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// Images beside the open document: linen-local://asset/<path relative to the document's folder>.
final class LocalScheme: NSObject, WKURLSchemeHandler {
    var base = fixturesRoot
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let rel = comps.path.removingPercentEncoding.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 } ?? ""
        let file = base.appendingPathComponent(rel)
        guard let data = try? Data(contentsOf: file) else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime])!)
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// Keeps the user content controller from holding the page (the cold first-paint runs build and drop pages).
final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: Page?
    init(_ t: Page) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        let name = m.name, body = m.body
        MainActor.assumeIsolated { target?.received(name, body) }
    }
}

@MainActor
final class Page: NSObject, WKNavigationDelegate {
    let web: WKWebView
    let local = LocalScheme()
    var messages: [[String: Any]] = []
    var consoleErrors: [String] = []
    var consoleWarnings: [String] = []
    var pageErrors: [String] = []
    var terminations: [String] = []
    var docDir = fixturesRoot
    private var waiters: [(String, CheckedContinuation<[String: Any], Never>)] = []
    static var systemConsole = "?"

    init(frame: CGRect) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Console messages also go to the system log, read outside the app (simctl log, device log collect).
        if config.preferences.responds(to: NSSelectorFromString("_setLogsPageMessagesToSystemConsoleEnabled:")) {
            config.preferences.setValue(true, forKey: "logsPageMessagesToSystemConsoleEnabled")
            Page.systemConsole = (config.preferences.value(forKey: "logsPageMessagesToSystemConsoleEnabled") as? Bool) == true ? "on" : "set but reads off"
        } else { Page.systemConsole = "not available" }
        config.setURLSchemeHandler(AppScheme(), forURLScheme: "linen-app")
        config.setURLSchemeHandler(local, forURLScheme: "linen-local")
        let recorder = (try? String(contentsOf: Bundle.main.url(forResource: "recorder", withExtension: "js")!, encoding: .utf8)) ?? ""
        // The Mac app's own listener (DocumentWindow.build), then the spike's console capture and frame recorder.
        config.userContentController.addUserScript(WKUserScript(source: """
          window.addEventListener('error', e => { try { webkit.messageHandlers.linen.postMessage({type: 'error', during: 'page', message: e.message + ' @' + (e.filename || '') + ':' + (e.lineno || '')}); } catch (_) {} });
          window.addEventListener('securitypolicyviolation', e => { try { webkit.messageHandlers.linen.postMessage({type: 'error', during: 'csp', message: e.violatedDirective + ' ' + e.blockedURI}); } catch (_) {} });
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.addUserScript(WKUserScript(source: recorder, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        web = WKWebView(frame: frame, configuration: config)
        super.init()
        let h = WeakHandler(self)
        for name in ["linen", "console", "warn"] { config.userContentController.add(h, name: name) }
        web.navigationDelegate = self
        web.isInspectable = true
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.bounces = false
        web.backgroundColor = UIColor(red: 0.98, green: 0.97, blue: 0.94, alpha: 1)
        web.isOpaque = false
    }

    func tearDown() {
        web.configuration.userContentController.removeAllScriptMessageHandlers()
        web.configuration.userContentController.removeAllUserScripts()
        web.stopLoading()
        web.removeFromSuperview()
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            terminations.append(Stamp.now())
            Out.line("WEB CONTENT PROCESS TERMINATED at \(Stamp.now())")
        }
    }

    func received(_ name: String, _ body: Any) {
        if name == "console" { consoleErrors.append("\(body)"); return }
        if name == "warn" { consoleWarnings.append("\(body)"); return }
        guard let msg = body as? [String: Any], let type = msg["type"] as? String else { return }
        switch type {
        case "error":
            pageErrors.append("\(msg["during"] ?? "?"): \(msg["message"] ?? "?")")
        case "imageInfo":
            var map: [String: Any] = [:]
            for r in (msg["requests"] as? [String]) ?? [] {
                if r.hasPrefix("path:") {
                    let rel = String(r.dropFirst(5))
                    let ok = FileManager.default.fileExists(atPath: docDir.appendingPathComponent(rel).path)
                    map[r] = ok ? ["status": "ok", "url": "linen-local://asset/" + (rel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? rel)] : ["status": "missing"]
                } else { map[r] = ["status": "missing"] }
            }
            local.base = docDir
            Task { await self.send(["type": "imageInfo", "map": map]) }
        case "resolveLinks":
            var map: [String: Any] = [:]
            for t in (msg["targets"] as? [String]) ?? [] {
                let ok = FileManager.default.fileExists(atPath: docDir.appendingPathComponent(t + ".md").path)
                map[t] = ok ? ["state": "ok", "hint": t + ".md"] : ["state": "missing", "hint": "No note called \(t)"]
            }
            Task { await self.send(["type": "linkStatus", "map": map]) }
        default:
            break
        }
        if let i = waiters.firstIndex(where: { $0.0 == type }) { waiters.remove(at: i).1.resume(returning: msg); return }
        messages.append(msg)
        if messages.count > 400 { messages.removeFirst(200) }
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

    func open() async -> Bool {
        messages.removeAll()
        web.load(URLRequest(url: URL(string: "linen-app://renderer/page.html")!))
        return (await wait(for: "ready", timeout: 30))["type"] as? String == "ready"
    }

    @discardableResult
    func send(_ msg: [String: Any]) async -> Any? {
        do { return try await web.callAsyncJavaScript("return await window.linen.receive(msg)", arguments: ["msg": msg], contentWorld: .page) } catch {
            pageErrors.append("send \(msg["type"] ?? "?") failed: \(error.localizedDescription)")
            return nil
        }
    }

    func command(_ name: String, _ extra: [String: Any] = [:]) async -> Any? {
        var m = extra
        m["type"] = "command"
        m["name"] = name
        return await send(m)
    }

    func js(_ code: String) async -> Any? {
        do { return try await web.callAsyncJavaScript(code, arguments: [:], contentWorld: .page) } catch { return "JSERR \(error)" }
    }

    func settings(theme: String = "paper", lang: String = "en") async {
        await send(["type": "settings", "theme": theme, "face": "sans", "uiDir": lang == "ar" ? "rtl" : "ltr", "lang": lang, "contrast": false, "foldArabic": true])
    }

    /// A note or plain text file, as DocumentWindow.sendLoad sends it. Returns ms to `rendered`.
    func loadNote(_ file: URL, docId: String) async -> (Double, [String: Any]) {
        let text = String(decoding: (try? Data(contentsOf: file)) ?? Data(), as: UTF8.self)
        let plain = file.pathExtension.lowercased() == "txt"
        let sidecar: Any = plain ? NSNull() : ((try? String(contentsOf: URL(fileURLWithPath: file.path + ".notes.json"), encoding: .utf8)) ?? NSNull())
        docDir = file.deletingLastPathComponent()
        local.base = docDir
        messages.removeAll { ["rendered", "firstPaint"].contains($0["type"] as? String ?? "") }
        let msg: [String: Any] = ["type": "load", "docId": docId, "name": file.lastPathComponent, "path": file.path, "text": text, "plain": plain,
                                  "version": 1, "allowRemote": false, "meta": ["modified": "14:02"], "sidecar": sidecar]
        let t0 = CFAbsoluteTimeGetCurrent()
        Task { await self.send(msg) }
        let r = await wait(for: "rendered", timeout: 20)
        return ((CFAbsoluteTimeGetCurrent() - t0) * 1000, r)
    }

    /// A board, as DocumentWindow.sendLoad sends it. Returns ms to the page's firstPaint and the page's own measure.
    func loadBoard(_ file: URL, text: String? = nil, docId: String, place: [String: Any]? = nil, version: Int = 1) async -> (Double, [String: Any]) {
        let body = text ?? String(decoding: (try? Data(contentsOf: file)) ?? Data(), as: UTF8.self)
        let sidecar: Any = (try? String(contentsOf: URL(fileURLWithPath: file.path + ".notes.json"), encoding: .utf8)) ?? NSNull()
        docDir = file.deletingLastPathComponent()
        local.base = docDir
        messages.removeAll { ["rendered", "firstPaint"].contains($0["type"] as? String ?? "") }
        var msg: [String: Any] = ["type": "load", "kind": "board", "docId": docId, "name": file.lastPathComponent, "path": file.path,
                                  "refPath": file.lastPathComponent, "text": body, "sidecar": sidecar, "version": version, "meta": [:]]
        if let place { msg["place"] = place }
        let t0 = CFAbsoluteTimeGetCurrent()
        Task { await self.send(msg) }
        let fp = await wait(for: "firstPaint", timeout: 30)
        return ((CFAbsoluteTimeGetCurrent() - t0) * 1000, fp)
    }

    func snapshot(to url: URL) async {
        let c = WKSnapshotConfiguration()
        if let img = try? await web.takeSnapshot(configuration: c), let png = img.pngData() { try? png.write(to: url) }
    }

    /// Waits until the board has mounted everything its budget queued (the renderer's own queue).
    func settle(maxMs: Int = 3000) async {
        var waited = 0
        while waited < maxMs {
            let q = ((await command("view")) as? [String: Any])?["queue"] as? Int ?? 0
            if q == 0 { break }
            try? await Task.sleep(for: .milliseconds(30))
            waited += 30
        }
    }
}

enum Stamp {
    static func now() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }
}

/// Progress lines to stdout (devicectl --console, simctl launch --console) and to Documents/results/progress.txt.
enum Out {
    static let dir: URL = {
        let d = documents.appendingPathComponent("results")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    static func line(_ s: String) {
        let l = "[\(Stamp.now())] \(s)\n"
        FileHandle.standardOutput.write(l.data(using: .utf8)!)
        let f = dir.appendingPathComponent("progress.txt")
        if let h = try? FileHandle(forWritingTo: f) { h.seekToEndOfFile(); h.write(l.data(using: .utf8)!); try? h.close() } else { try? l.write(to: f, atomically: true, encoding: .utf8) }
    }
    static func write(_ name: String, _ obj: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { line("could not encode \(name)"); return }
        try? data.write(to: dir.appendingPathComponent(name + ".json"))
        line("wrote results/\(name).json (\(data.count) bytes)")
    }
}
