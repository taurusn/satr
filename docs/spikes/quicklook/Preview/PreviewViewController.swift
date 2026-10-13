import AppKit
import QuickLookUI
import WebKit

/// Spike: can a view-based Quick Look preview host a WKWebView, run the page's script, and read a sibling image?
final class PreviewViewController: NSViewController, QLPreviewingController {
    private var web: WKWebView!

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(LocalFiles(), forURLScheme: "satr-local")
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        view = web
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? "(could not read the file)"
        let siblings = (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path))?.count ?? -1
        let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        let html = """
        <!doctype html><meta charset=utf-8><body style="background:#F6F3EB;color:#284734;font:16px -apple-system;padding:32px">
        <h1 id=t>Satr spike: script not run</h1><p>Siblings visible: \(siblings)</p>
        <img src="satr-local://asset?path=\(url.deletingLastPathComponent().appendingPathComponent("spike.png").path)" style="max-width:200px" onerror="document.getElementById('i').textContent='image blocked'" onload="document.getElementById('i').textContent='image loaded through satr-local'"><p id=i>image loaded or pending</p>
        <pre style="white-space:pre-wrap">\(escaped.prefix(2000))</pre>
        <script>document.getElementById('t').textContent='Satr spike: script ran in Quick Look';</script>
        """
        await MainActor.run { _ = web.loadHTMLString(html, baseURL: url.deletingLastPathComponent()) }
        try await Task.sleep(for: .milliseconds(400))
    }
}

/// Serves files to the page from the extension's own process, which holds the read exception.
final class LocalFiles: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let u = task.request.url, let path = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "path" })?.value,
              let data = FileManager.default.contents(atPath: path) else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
        task.didReceive(URLResponse(url: u, mimeType: "image/png", expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
