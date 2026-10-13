import AppKit
import LinenKit
import os
import QuickLookUI
import UniformTypeIdentifiers
import WebKit

/// Linen in Finder's Quick Look (QL-1): the same renderer, sandboxed, with only the previewed file. Paper is
/// painted before the renderer runs; local images show as named placeholders (images arrive in 1.x).
@MainActor
final class PreviewViewController: NSViewController, QLPreviewingController, WKScriptMessageHandler, WKNavigationDelegate {
    static let log = Logger(subsystem: "com.hatim.linen.quicklook", category: "preview")
    private var web: WKWebView!
    private let ready = Gate()
    private var painted = Gate()
    /// The last settings and load sent, sent again if the page turns ready after the wait ran out.
    private var pending: [[String: Any]] = []

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(RendererScheme(root: Bundle.main.resourceURL!.appendingPathComponent("renderer")), forURLScheme: "linen-app")
        config.userContentController.add(WeakHandler(self), name: "linen")
        config.userContentController.addUserScript(WKUserScript(source: """
          window.addEventListener('error', e => { try { webkit.messageHandlers.linen.postMessage({type: 'error', message: e.message + ' @' + (e.filename || '') + ':' + (e.lineno || '')}); } catch (_) {} });
          window.addEventListener('securitypolicyviolation', e => { try { webkit.messageHandlers.linen.postMessage({type: 'error', message: 'csp ' + e.violatedDirective + ' ' + e.blockedURI}); } catch (_) {} });
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 820, height: 600), configuration: config)
        web.navigationDelegate = self
        let paper = Self.dark ? NSColor(srgbRed: 0x1F / 255, green: 0x33 / 255, blue: 0x28 / 255, alpha: 1)
                              : NSColor(srgbRed: 0xF6 / 255, green: 0xF3 / 255, blue: 0xEB / 255, alpha: 1)
        web.underPageBackgroundColor = paper
        // Paper first (QL-1): a plain layer behind the page, so the preview is never a grey box.
        let ground = NSView(frame: web.frame)
        ground.wantsLayer = true
        ground.layer?.backgroundColor = paper.cgColor
        web.autoresizingMask = [.width, .height]
        web.setValue(false, forKey: "drawsBackground")
        ground.addSubview(web)
        view = ground
        Self.log.notice("loadView")
        web.load(URLRequest(url: URL(string: "linen-app://renderer/page.html")!))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        Self.log.error("provisional fail \(error.localizedDescription, privacy: .public)")
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        Self.log.error("fail \(error.localizedDescription, privacy: .public)")
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { Self.log.notice("didFinish") }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { Self.log.error("content process terminated") }

    private static var dark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    func preparePreviewOfFile(at url: URL) async throws {
        let decoded = TextDecoder.decode(try Data(contentsOf: url))
        Self.log.notice("prepare \(url.lastPathComponent, privacy: .public), \(decoded.text.count) chars")
        if web == nil { loadView() }
        // The preview always appears: at most 2 s for the page, then at most 1.5 s for its first paint.
        await ready.wait(seconds: 2)
        painted = Gate()
        pending = [["type": "settings", "theme": Self.dark ? "night" : "paper", "quickLook": true, "uiDir": "ltr"],
                   ["type": "load", "docId": "ql", "name": url.lastPathComponent, "path": url.lastPathComponent, "text": decoded.text,
                    "plain": url.pathExtension.lowercased() == "txt", "version": 1]]
        if ready.isOpen { pending.forEach(send) }
        await painted.wait(seconds: 1.5)
        Self.log.notice("prepared")
    }

    private func send(_ msg: [String: Any]) {
        web.callAsyncJavaScript("return await window.linen.receive(msg)", arguments: ["msg": msg], in: nil, in: .page) { result in
            if case let .failure(e) = result { Self.log.error("send failed \(e.localizedDescription, privacy: .public)") }
        }
    }

    fileprivate func received(_ body: Any) {
        guard let msg = body as? [String: Any], let type = msg["type"] as? String else { return }
        Self.log.notice("message \(type, privacy: .public) \((msg["message"] as? String) ?? "", privacy: .public)")
        switch type {
        case "ready":
            ready.signal()
            pending.forEach(send)
        case "firstPaint":
            painted.signal()
        case "imageInfo":
            guard let reqs = msg["requests"] as? [String] else { return }
            var map: [String: Any] = [:]
            for r in reqs { map[r] = ["status": "unavailable", "label": (r.split(separator: ":", maxSplits: 1).last.map(String.init) ?? r)] }
            send(["type": "imageInfo", "map": map])
        default:
            break
        }
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) { received(message.body) }
}

/// A one-shot signal to wait on with a time limit. Any number of waiters; a waiter whose time runs out goes on
/// alone, and the gate stays closed until the real signal.
@MainActor
private final class Gate {
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private(set) var isOpen = false

    func signal() {
        isOpen = true
        let all = waiters.values
        waiters.removeAll()
        for w in all { w.resume() }
    }

    func wait(seconds: Double) async {
        guard !isOpen else { return }
        let id = UUID()
        await withCheckedContinuation { c in
            waiters[id] = c
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                self.waiters.removeValue(forKey: id)?.resume()
            }
        }
    }
}

/// Keeps the page from retaining the controller.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: PreviewViewController?
    init(_ t: PreviewViewController) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { target?.received(message.body) }
    }
}

/// Serves the renderer from the extension's own bundle.
final class RendererScheme: NSObject, WKURLSchemeHandler {
    private let root: URL
    init(root: URL) { self.root = root.standardizedFileURL }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, url.host == "renderer" else { task.didFailWithError(URLError(.badURL)); return }
        let rel = url.path.split(separator: "/").map(String.init).filter { $0 != ".." && $0 != "." }
        let file = rel.reduce(root) { $0.appendingPathComponent($1) }
        guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file) else {
            PreviewViewController.log.error("renderer file missing \(url.path, privacy: .public)")
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime])!)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
