import UIKit
import UniformTypeIdentifiers
import WebKit

/// Serves the renderer from the app bundle as linen-app://renderer/ (the Mac's AppScheme).
final class AppScheme: NSObject, WKURLSchemeHandler {
    private let root: URL

    init(root: URL) {
        self.root = root.standardizedFileURL
        super.init()
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, url.host == "renderer" else { task.didFailWithError(URLError(.badURL)); return }
        let rel = url.path.split(separator: "/").map(String.init).filter { $0 != ".." && $0 != "." }
        let file = rel.reduce(root) { $0.appendingPathComponent($1) }
        guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file) else {
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

/// Images beside the open document, by grant: linen-local://grant/<random id>. The page sees only the id; each grant
/// is one file Linen checked inside the pin's root (SAFE-2's rule on the phone): its name and its first bytes name the
/// same image kind, at most 50 MB, 200 MB served per document.
@MainActor
final class LocalScheme: NSObject, WKURLSchemeHandler {
    private var grants: [String: URL] = [:]
    private var served = 0
    static let maxFile = 50 * 1024 * 1024
    static let maxPerDocument = 200 * 1024 * 1024
    static let kinds: [String: String] = ["png": "png", "jpg": "jpeg", "jpeg": "jpeg", "gif": "gif", "webp": "webp", "heic": "heif",
                                          "heif": "heif", "avif": "heif", "svg": "svg"]
    static let mimes: [String: String] = ["png": "image/png", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
                                          "heif": "image/heif", "svg": "image/svg+xml"]

    func reset() {
        grants.removeAll()
        served = 0
    }

    func grant(_ file: URL) -> String {
        let id = UUID().uuidString.lowercased()
        grants[id] = file
        return id
    }

    /// The image kind by first bytes, or nil when the bytes are not an image Linen shows.
    nonisolated static func kind(of data: Data) -> String? {
        let b = [UInt8](data.prefix(16))
        guard b.count >= 4 else { return nil }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpeg" }
        if b.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "gif" }
        if b.count >= 12, Array(b[0...3]) == [0x52, 0x49, 0x46, 0x46], Array(b[8...11]) == [0x57, 0x45, 0x42, 0x50] { return "webp" }
        if b.count >= 12, Array(b[4...7]) == [0x66, 0x74, 0x79, 0x70] { return "heif" }
        return String(decoding: data.prefix(1024), as: UTF8.self).lowercased().contains("<svg") ? "svg" : nil
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, url.host == "grant", let file = grants[url.lastPathComponent],
              let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= Self.maxFile, served + size <= Self.maxPerDocument,
              let data = try? Data(contentsOf: file),
              let want = Self.kinds[file.pathExtension.lowercased()], Self.kind(of: data) == want, let mime = Self.mimes[want] else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        served += data.count
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                        headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)", "X-Content-Type-Options": "nosniff"])!)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// Carries a value WebKit returns across to the main actor.
struct PageValue: @unchecked Sendable {
    let value: Any?
    init(_ v: Any?) { value = v }
}

/// Keeps the page's message handler from holding its host.
final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: RendererHost?
    init(_ t: RendererHost) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = PageValue(message.body)
        MainActor.assumeIsolated { target?.received(body.value as Any) }
    }
}

/// What the phone changes in the renderer's look, from outside it (no renderer file changes): the zoom panel without
/// minus and plus (pinch does that, IOS-3), a board's note card as a sheet from the bottom (sketch screen 13),
/// the cards' layer kept composited while the board is open, so a pan does not promote it in the frame where the
/// finger lands (spike I(a) finding 2: one 28 to 49 ms frame per pan on the simulator, gone with this), and
/// the in-page find bars hidden, since the phone shows its own find bar (the keyboard comes up only for a field the
/// reader touched; the renderer's find runs the same behind it).
enum PhoneStyle {
    static let css = """
    .b-zin, .b-zout { display: none !important; }
    .b-over { will-change: transform; }
    #findbar, .b-find { display: none !important; }
    .b-notecard { position: fixed !important; left: 0 !important; right: 0 !important; top: auto !important; bottom: 0 !important;
      width: auto !important; max-height: 62% !important; padding: 10px 20px calc(20px + env(safe-area-inset-bottom)) !important;
      border-radius: 0 !important; border-width: 1px 0 0 0 !important; box-shadow: 0 -12px 30px rgba(40, 71, 52, .16) !important; }
    .b-notecard::before { content: ""; display: block; width: 38px; height: 5px; border-radius: 3px; background: var(--edge); margin: 0 auto 12px; }
    """

    static let script = """
    (() => { const s = document.createElement('style'); s.id = 'linen-phone'; s.textContent = \(jsString(css)); (document.head || document.documentElement).appendChild(s); })();
    """

    static func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        let arr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
    }
}
