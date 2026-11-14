import ImageIO
import LinenKit
import UIKit
import WebKit

/// One note or board in Linen's renderer, hosted the way the Mac's DocumentWindow hosts it: linen-app for the
/// renderer, linen-local for images by grant, the `linen` message handler, the error and CSP listener at document
/// start, and the same `load`, `update`, `settings` and `command` messages. What the page asks of the app (images,
/// link states, links, places, change baselines) is answered from the document's own pin.
@MainActor
final class RendererHost: NSObject, WKNavigationDelegate {
    let web: WKWebView
    private let local = LocalScheme()
    weak var doc: DocumentModel?
    private(set) var ready = false
    private var version = 0
    private var docID = UUID().uuidString
    private var loaded = false

    init(doc: DocumentModel) {
        self.doc = doc
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.dataDetectorTypes = []
        config.setURLSchemeHandler(AppScheme(root: Bundle.main.resourceURL!.appendingPathComponent("renderer")), forURLScheme: "linen-app")
        config.setURLSchemeHandler(local, forURLScheme: "linen-local")
        config.userContentController.addUserScript(WKUserScript(source: """
          window.addEventListener('error', e => { try { webkit.messageHandlers.linen.postMessage({type: 'error', during: 'page', message: e.message + ' @' + (e.filename || '') + ':' + (e.lineno || '')}); } catch (_) {} });
          window.addEventListener('unhandledrejection', e => { try { webkit.messageHandlers.linen.postMessage({type: 'error', during: 'promise', message: String(e.reason && e.reason.message || e.reason)}); } catch (_) {} });
          window.addEventListener('securitypolicyviolation', e => { try { webkit.messageHandlers.linen.postMessage({type: 'error', during: 'csp', message: e.violatedDirective + ' ' + e.blockedURI}); } catch (_) {} });
          (() => { const ce = console.error.bind(console); console.error = (...a) => { try { webkit.messageHandlers.linen.postMessage({type: 'error', during: 'console', message: a.map(String).join(' ')}); } catch (_) {} ce(...a); }; })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.addUserScript(WKUserScript(source: PhoneStyle.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        web = WKWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.add(MessageProxy(self), name: "linen")
        web.navigationDelegate = self
        #if DEBUG
        web.isInspectable = true
        #endif
        web.allowsLinkPreview = false
        web.allowsBackForwardNavigationGestures = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.isOpaque = false
        web.accessibilityIdentifier = "renderer"
        web.load(URLRequest(url: URL(string: "linen-app://renderer/page.html")!))
    }

    func tearDown() {
        web.configuration.userContentController.removeAllScriptMessageHandlers()
        web.stopLoading()
        web.navigationDelegate = nil
    }

    // MARK: To the page

    @discardableResult
    func send(_ msg: [String: Any]) -> Task<PageValue, Never>? {
        guard ready else { return nil }
        let box = PageValue(msg)
        let web = web
        return Task { @MainActor in
            do {
                return PageValue(try await web.callAsyncJavaScript("return await window.linen.receive(msg)", arguments: ["msg": box.value ?? NSNull()], contentWorld: .page))
            } catch {
                return PageValue(nil)
            }
        }
    }

    func command(_ name: String, _ extra: [String: Any] = [:]) async -> Any? {
        var msg = extra
        msg["type"] = "command"
        msg["name"] = name
        guard let t = send(msg) else { return nil }
        return await t.value.value
    }

    /// Runs a function body in the page's world and returns its value (DOM reads for the outline and find).
    func js(_ body: String, _ args: [String: Any] = [:]) async -> Any? {
        guard ready else { return nil }
        let box = PageValue(args)
        do { return try await web.callAsyncJavaScript(body, arguments: box.value as? [String: Any] ?? [:], contentWorld: .page) } catch { return nil }
    }

    func sendSettings(_ palette: Palette, arabic: Bool) {
        web.underPageBackgroundColor = palette.groundUIColor
        web.backgroundColor = palette.groundUIColor
        send(["type": "settings", "theme": palette.theme, "face": "sans", "uiDir": arabic ? "rtl" : "ltr", "lang": arabic ? "ar" : "en",
              "contrast": UIAccessibility.isDarkerSystemColorsEnabled, "foldArabic": UserDefaults.standard.object(forKey: "foldArabic") as? Bool ?? true])
    }

    /// The document's first load, as DocumentWindow.sendLoad sends it.
    func sendLoad(_ d: OpenDocument, text: String, sidecar: String?, place: [String: Any]?, baseline: [String]?, baselineDate: Date?) {
        local.reset()
        version += 1
        docID = UUID().uuidString
        var msg: [String: Any] = [
            "type": "load", "docId": docID, "name": d.name, "path": d.displayPath, "text": text, "plain": d.plain,
            "version": version, "allowRemote": false, "meta": meta(d), "sidecar": sidecar ?? NSNull(),
        ]
        if d.kind == .board {
            msg["kind"] = "board"
            msg["refPath"] = d.referencePath
        } else if place != nil {
            msg["grown"] = place?["atEnd"] as? Bool ?? false
        }
        if let place { msg["place"] = place }
        if let baseline {
            msg["baseline"] = baseline
            if let baselineDate { msg["baselineDate"] = baselineDate.formatted(.dateTime.day().month(.wide)) }
        }
        loaded = true
        send(msg)
    }

    /// A newer generation of the open file (SYNC-4), as DocumentWindow.sendUpdate sends an outside change.
    func sendUpdate(_ d: OpenDocument, text: String, sidecar: String?) {
        version += 1
        var msg: [String: Any] = ["type": "update", "docId": docID, "text": text, "sidecar": sidecar ?? NSNull(), "inBurst": false, "version": version, "meta": meta(d)]
        if d.kind == .board { msg["kind"] = "board" }
        send(msg)
    }

    private func meta(_ d: OpenDocument) -> [String: Any] {
        guard let date = d.modified else { return [:] }
        return ["modified": Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened)
                                                                  : date.formatted(.dateTime.day().month(.abbreviated).year())]
    }

    // MARK: From the page

    func received(_ body: Any) {
        guard let msg = body as? [String: Any], let type = msg["type"] as? String else { return }
        if ["rendered", "view", "place", "baseline", "openReference"].contains(type), let d = msg["docId"] as? String, d != docID { return }
        switch type {
        case "ready":
            ready = true
            doc?.pageReady()
        case "firstPaint":
            doc?.firstPaint(msg)
        case "rendered":
            doc?.rendered(title: msg["title"] as? String)
        case "view":
            doc?.view(msg)
        case "place":
            if let p = msg["place"] as? [String: Any] { doc?.storePlace(p) }
        case "baseline":
            if let hashes = msg["hashes"] as? [String] { doc?.storeBaseline(hashes) }
        case "openWiki":
            doc?.openWiki(msg["target"] as? String ?? "")
        case "openLocal":
            doc?.openLocal(msg["href"] as? String ?? "")
        case "openExternal", "openScheme":
            if let s = msg["url"] as? String, let u = URL(string: s) { doc?.askExternal(u) }
        case "resolveLinks":
            let targets = msg["targets"] as? [String] ?? []
            Task { await answerLinks(targets) }
        case "imageInfo":
            let requests = msg["requests"] as? [String] ?? []
            Task { await answerImages(requests) }
        case "copyText":
            if let t = msg["text"] as? String { UIPasteboard.general.string = t }
        case "findState":
            doc?.findState(count: msg["count"] as? Int ?? 0, current: msg["current"] as? Int ?? 0)
        case "findClosed":
            doc?.findClosed()
        case "setting":
            if msg["key"] as? String == "foldArabic", let v = msg["value"] as? Bool { UserDefaults.standard.set(v, forKey: "foldArabic") }
        case "error":
            doc?.pageError("\(msg["during"] as? String ?? "?"): \(msg["message"] as? String ?? "?")")
        default:
            break
        }
    }

    private func answerLinks(_ targets: [String]) async {
        guard let doc else { return }
        var map: [String: Any] = [:]
        for t in targets {
            switch await doc.resolve(t) {
            case let .file(ref): map[t] = ["state": "ok", "hint": ref.path]
            case .notOnPhone: map[t] = ["state": "missing", "hint": String(localized: "Not on this iPhone")]
            case .missing: map[t] = ["state": "missing", "hint": doc.document?.ref == nil ? String(localized: "Not on this iPhone") : String(localized: "No note called \(t)")]
            }
        }
        send(["type": "linkStatus", "map": map])
    }

    private func answerImages(_ requests: [String]) async {
        guard let doc else { return }
        var map: [String: Any] = [:]
        for r in requests {
            let name: String
            var file: URL?
            if r.hasPrefix("path:") {
                let rel = String(r.dropFirst(5)).removingPercentEncoding ?? String(r.dropFirst(5))
                name = (rel as NSString).lastPathComponent
                file = await doc.asset(path: rel)
            } else if r.hasPrefix("wiki:") {
                let target = String(r.dropFirst(5))
                name = target
                file = await doc.asset(wiki: target)
            } else {
                name = r
            }
            if let file {
                var info: [String: Any] = ["status": "ok", "url": "linen-local://grant/\(local.grant(file))"]
                if let src = CGImageSourceCreateWithURL(file as CFURL, nil),
                   let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                   let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
                    let scale = min(1, 2880 / Double(max(w, h)))
                    info["width"] = Int(Double(w) * scale / 2)
                    info["height"] = Int(Double(h) * scale / 2)
                }
                map[r] = info
            } else {
                // iOS hands over one file, not its folder; and a pin carries only what is inside it (IOS-6, SYNC-3).
                map[r] = ["status": "unavailable", "label": String(localized: "\(name) · Not on this iPhone")]
            }
        }
        send(["type": "imageInfo", "map": map])
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let u = action.request.url else { return .cancel }
        if u.scheme == "linen-app" && action.targetFrame?.isMainFrame == true { return .allow }
        if u.scheme == "about" || u.scheme == "linen-app" || u.scheme == "blob" || u.scheme == "data" { return .allow }
        return .cancel
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
        doc?.pageError("web content ended")
        webView.load(URLRequest(url: URL(string: "linen-app://renderer/page.html")!))
    }
}
