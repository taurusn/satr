import AppKit
import UniformTypeIdentifiers
import WebKit

/// Where the command finds Linen: its own app bundle (the command lives in `Linen.app/Contents/Helpers/linen`), else the
/// app beside it in a build folder, else the installed app. `LINEN_RENDERER` overrides the renderer for development.
enum Locate {
    static var executable: URL {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buf = [CChar](repeating: 0, count: Int(size) + 1)
        _NSGetExecutablePath(&buf, &size)
        return URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath().standardizedFileURL
    }

    /// The enclosing `Linen.app`, when the command runs from inside one.
    static var appBundle: URL? {
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        if contents.lastPathComponent == "Contents", app.pathExtension == "app" { return app }
        let sibling = executable.deletingLastPathComponent().appendingPathComponent("Linen.app")
        if FileManager.default.fileExists(atPath: sibling.path) { return sibling }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.hatim.linen")
    }

    static var renderer: URL? {
        if let env = ProcessInfo.processInfo.environment["LINEN_RENDERER"], !env.isEmpty { return URL(fileURLWithPath: env) }
        guard let app = appBundle else { return nil }
        let r = app.appendingPathComponent("Contents/Resources/renderer")
        return FileManager.default.fileExists(atPath: r.appendingPathComponent("page.html").path) ? r : nil
    }
}

/// Serves the renderer's own files, read-only, from inside its folder.
final class RendererScheme: NSObject, WKURLSchemeHandler {
    let root: URL
    init(root: URL) { self.root = root.standardizedFileURL }
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let rel = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        let file = root.appendingPathComponent(rel).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime])!)
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// Serves images a document names, only from inside the document's folder, through the vault gate's descriptor walk
/// (SafeOpen, no symlink escape and no race between checking and reading). Each load gets its own folder, named in the
/// URL's host, so a request still in flight from the last document never reads from the next one's folder.
@MainActor
final class FolderScheme: NSObject, WKURLSchemeHandler {
    private var folders: [String: URL] = [:]
    private var order: [String] = []

    /// A host token for a document's folder; the last eight stay valid.
    func token(for folder: URL) -> String {
        let t = UUID().uuidString.lowercased()
        folders[t] = folder
        order.append(t)
        if order.count > 8 { folders.removeValue(forKey: order.removeFirst()) }
        return t
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = comps.host, let root = folders[host] else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
        let rel = comps.path.removingPercentEncoding.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 } ?? ""
        guard let opened = SafeOpen.open(root: root, relative: rel), let data = SafeOpen.read(opened) else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
        let mime = UTType(filenameExtension: (rel as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime, "X-Content-Type-Options": "nosniff"])!)
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// Linen's renderer in an offscreen window, driven by the same messages the app sends (section 9.2: "the command is a
/// small executable inside Linen.app that hosts the renderer in its own offscreen WKWebView").
@MainActor
final class RendererHost: NSObject, WKScriptMessageHandler {
    let web: WKWebView
    let window: NSWindow
    let folder = FolderScheme()
    private(set) var messages: [[String: Any]] = []
    private(set) var consoleErrors: [String] = []
    private var waiters: [(String, CheckedContinuation<[String: Any], Never>)] = []

    init(renderer: URL, width: Double, height: Double) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(RendererScheme(root: renderer), forURLScheme: "linen-app")
        config.setURLSchemeHandler(folder, forURLScheme: "linen-local")
        window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
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
        window.orderBack(nil)
    }

    nonisolated func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        MainActor.assumeIsolated {
            let name = m.name, body = m.body
            if name == "console" { consoleErrors.append("\(body)"); return }
            guard let msg = body as? [String: Any], let type = msg["type"] as? String else { return }
            // A message about an earlier load is about that one, never the current one (it can arrive late).
            if let d = msg["docId"] as? String, d != "cli-\(loads)" { return }
            if type == "imageInfo", let reqs = msg["requests"] as? [String] { answerImages(reqs); return }
            if type == "resolveLinks" { return }
            if let i = waiters.firstIndex(where: { $0.0 == type }) { waiters.remove(at: i).1.resume(returning: msg); return }
            messages.append(msg)
        }
    }

    private var folderToken = ""
    private var folderRoot = URL(fileURLWithPath: "/nonexistent")

    /// Images inside the document's folder load; anything else shows as missing, as an unknown image would in the app.
    private func answerImages(_ reqs: [String]) {
        var map: [String: Any] = [:]
        for r in reqs {
            if r.hasPrefix("path:") {
                let rel = String(r.dropFirst(5))
                if let o = SafeOpen.open(root: folderRoot, relative: rel) {
                    close(o.fd)
                    map[r] = ["status": "ok", "url": "linen-local://\(folderToken)/" + (rel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")]
                    continue
                }
            }
            map[r] = ["status": "missing"]
        }
        Task { _ = try? await self.send(["type": "imageInfo", "map": map]) }
    }

    /// Forgets the last call's renderer errors, so each answer reports only its own.
    func clearErrors() { consoleErrors.removeAll() }

    func wait(for type: String, timeout: Double) async -> [String: Any] {
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
        web.load(URLRequest(url: URL(string: "linen-app://renderer/page.html")!))
        return (await wait(for: "ready", timeout: 15))["type"] as? String == "ready"
    }

    @discardableResult
    func send(_ msg: [String: Any]) async throws -> Any? {
        try await web.callAsyncJavaScript("return await window.linen.receive(msg)", arguments: ["msg": msg], contentWorld: .page)
    }

    func js(_ code: String, _ args: [String: Any] = [:]) async throws -> Any? {
        try await web.callAsyncJavaScript(code, arguments: args, contentWorld: .page)
    }

    func command(_ name: String, _ extra: [String: Any] = [:]) async -> Any? {
        var msg = extra
        msg["type"] = "command"
        msg["name"] = name
        return try? await send(msg)
    }

    private var loads = 0

    /// Loads a note or a board as the app does and waits for it to render. Each load is a new document to the page
    /// (its own id and version), as when the app opens a file, so a warm page never mistakes it for the last one.
    func load(_ file: URL, text: String, sidecar: String?, theme: String) async -> Bool {
        loads += 1
        folderRoot = file.deletingLastPathComponent()
        folderToken = folder.token(for: folderRoot)
        messages.removeAll()
        consoleErrors.removeAll()
        _ = try? await send(["type": "settings", "theme": theme, "face": "sans", "uiDir": "ltr", "lang": "en", "contrast": false, "foldArabic": true])
        var msg: [String: Any] = ["type": "load", "docId": "cli-\(loads)", "name": file.lastPathComponent, "path": file.path, "text": text,
                                  "plain": file.pathExtension.lowercased() == "txt", "version": loads, "meta": [:]]
        if file.pathExtension.lowercased() == "canvas" {
            msg["kind"] = "board"
            msg["sidecar"] = sidecar ?? NSNull()
            msg["refPath"] = file.path
        }
        Task { _ = try? await self.send(msg) }
        return (await wait(for: "rendered", timeout: 25))["type"] as? String == "rendered"
    }

    /// The longest full-page shot: past it the image is cut and says so (MCP-8).
    static let maxFullHeight = 4000.0
    private(set) var lastShotCropped = false

    func snapshot(fullHeight: Bool) async -> Data? {
        let frame = web.frame
        defer {
            // The next call starts at the window size it asked for, not at the last note's length.
            web.frame = frame
            window.setContentSize(frame.size)
        }
        lastShotCropped = false
        if fullHeight, let h = (try? await js("return document.documentElement.scrollHeight")) as? Double {
            let height = min(h, Self.maxFullHeight)
            lastShotCropped = h > Self.maxFullHeight
            web.frame.size.height = height
            window.setContentSize(NSSize(width: web.frame.width, height: height))
            try? await Task.sleep(for: .milliseconds(400))
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard let img = try? await web.takeSnapshot(configuration: WKSnapshotConfiguration()),
              let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
