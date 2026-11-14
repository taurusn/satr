import LinenKit
import UIKit
import WebKit

/// A sealed page on the iPhone (IOS-4, PAGE-1 to PAGE-12), built as the Mac's SealedPageController builds it, from the
/// same seal (Linen/Pages: PageSeal, PageScheme, PageScripts): its own configuration, non-persistent data store and
/// web content process; a per-open `linen-page://<random>/` origin whose handler serves only the page's folder, by a
/// descriptor walk, with the CSP on every response; the kit as `linen-kit://kit/`; the content rule list; the removal
/// script in every frame; the preflight page that proves the walls in this very web view before the author's page
/// loads; the navigation gate; every capability refused; real clicks only, through PAGE-11's link rules.
///
/// Scripts are off for every page in M11: turning them on needs the Mac's trust decisions, which arrive with the link
/// (M12). So the self-test's inventory (PAGE-10) and the stall watchdog (PAGE-12) have nothing to guard yet.
@MainActor
final class SealedPage: NSObject, WKNavigationDelegate, WKUIDelegate {
    let view = UIView()
    private var web: WKWebView?
    private var scheme: PageScheme
    private var folder: PinnedFolder?
    private var fileURL: URL
    private let kit = KitScheme.bundled()
    private let kitWorld = WKContentWorld.world(name: PageSeal.kitWorldName)
    private let options = SealOptions.full
    private var theme: String
    private var preflighting = false
    private var buildGeneration = 0
    private var closed = false
    private var pendingPlace: Any?
    private var titleWatch: NSKeyValueObservation?
    private var crashes = 0

    var onTitle: ((String) -> Void)?
    /// A real click on a note, board or page in the page's folder, by its path relative to the page.
    var onOpenInLinen: ((String) -> Void)?
    /// A web address to open after Hatim says yes to its full address.
    var onAsk: ((URL) -> Void)?
    var onToast: ((String) -> Void)?
    /// The one state line (PAGE-7): scripts are off here, and whether the page needs them to draw.
    var onStateLine: ((String?) -> Void)?
    /// Every refusal and decision, for tests and the log (never page content).
    private(set) var events: [String] = []

    init(document: OpenDocument, theme: String) {
        fileURL = document.url.standardizedFileURL.resolvingSymlinksInPath()
        self.theme = theme
        folder = PinnedFolder(fileURL.deletingLastPathComponent())
        scheme = PageScheme(page: fileURL, scripts: false, options: .full, pinned: folder)
        super.init()
        view.backgroundColor = theme == "night" ? .linenInk2 : .linenPaper
        startBuild()
    }

    func close() {
        closed = true
        buildGeneration += 1
        teardown()
    }

    // MARK: Building

    private func startBuild() {
        guard !closed else { return }
        buildGeneration += 1
        let g = buildGeneration
        Task { await build(g) }
    }

    private func build(_ generation: Int) async {
        let list: WKContentRuleList
        do { list = try await PageSeal.ruleList() } catch {
            guard generation == buildGeneration else { return }
            showSource(reason: String(localized: "Linen could not seal this page, so it shows its source"))
            event("seal failed: rules")
            return
        }
        guard generation == buildGeneration, !closed else { return }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.isElementFullscreenEnabled = false
        config.preferences.isFraudulentWebsiteWarningEnabled = false
        _ = EngineFlags.apply(to: config.preferences)
        config.allowsAirPlayForMediaPlayback = false
        config.allowsPictureInPictureMediaPlayback = false
        config.upgradeKnownHostsToHTTPS = false
        config.dataDetectorTypes = []
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.setURLSchemeHandler(scheme, forURLScheme: PageSeal.pageScheme)
        config.setURLSchemeHandler(kit, forURLScheme: PageSeal.kitScheme)
        let ucc = config.userContentController
        ucc.add(list)
        installScripts(ucc)
        ucc.add(KitProxy(self), contentWorld: kitWorld, name: "linenKit")
        let web = WKWebView(frame: view.bounds, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = false
        web.allowsLinkPreview = false
        web.isOpaque = false
        web.backgroundColor = theme == "night" ? .linenInk2 : .linenPaper
        web.underPageBackgroundColor = web.backgroundColor
        web.accessibilityIdentifier = "sealedPage"
        #if DEBUG
        web.isInspectable = true
        #endif
        web.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor), web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            web.topAnchor.constraint(equalTo: view.topAnchor), web.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        self.web = web
        titleWatch = web.observe(\.title, options: [.new]) { [weak self] _, change in
            let t = change.newValue ?? nil
            MainActor.assumeIsolated { if let t, !t.isEmpty, self?.preflighting == false { self?.onTitle?(t) } }
        }
        scheme.resetBudget()
        preflighting = true
        web.load(URLRequest(url: scheme.preflightURL))
        onStateLine?(nil)
    }

    private func installScripts(_ ucc: WKUserContentController) {
        ucc.removeAllUserScripts()
        ucc.addUserScript(WKUserScript(source: PageSeal.removalScript, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        ucc.addUserScript(WKUserScript(source: PageScripts.kit(theme: theme), injectionTime: .atDocumentStart, forMainFrameOnly: false, in: kitWorld))
    }

    private func teardown() {
        titleWatch = nil
        scheme.cancelAll()
        if let web {
            web.navigationDelegate = nil
            web.uiDelegate = nil
            web.configuration.userContentController.removeAllScriptMessageHandlers()
            web.stopLoading()
            web.removeFromSuperview()
        }
        web = nil
    }

    /// A newer generation of the page's pin: a new folder, origin and web view, holding the place by the nearest id.
    func reload(document: OpenDocument) {
        guard let web else { return }
        let g = buildGeneration
        kitCall("return window.__linenKit ? __linenKit.place() : null", on: web, timeout: 0.5) { [weak self] place in
            guard let self, g == self.buildGeneration else { return }
            self.pendingPlace = place
            self.teardown()
            self.fileURL = document.url.standardizedFileURL.resolvingSymlinksInPath()
            self.folder = PinnedFolder(self.fileURL.deletingLastPathComponent())
            self.scheme = PageScheme(page: self.fileURL, scripts: false, options: .full, pinned: self.folder)
            self.onToast?(String(localized: "Changes are not marked in pages"))
            self.startBuild()
        }
    }

    func setTheme(_ t: String) {
        theme = t
        view.backgroundColor = t == "night" ? .linenInk2 : .linenPaper
        guard let web else { return }
        web.backgroundColor = view.backgroundColor
        web.underPageBackgroundColor = view.backgroundColor
        installScripts(web.configuration.userContentController)
        kitCall("return window.__linenKit ? __linenKit.setTheme(t) : null", ["t": t], on: web, timeout: 1) { _ in }
    }

    /// Find in page (PAGE-6) through WebKit's find.
    func find(_ text: String, backwards: Bool = false) async -> Bool {
        guard let web, !text.isEmpty else { return false }
        let c = WKFindConfiguration()
        c.backwards = backwards
        c.caseSensitive = false
        c.wraps = true
        return (try? await web.find(text, configuration: c))?.matchFound ?? false
    }

    // MARK: Navigation gate (PAGE-1) and capabilities (PAGE-11)

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        let isPreflight = action.request.url.map { scheme.isOwn($0) && $0.path == "/" + PageSeal.preflightPath } ?? false
        preferences.allowsContentJavaScript = isPreflight && preflighting
        if isPreflight { return (preflighting && (action.targetFrame?.isMainFrame ?? false) ? .allow : .cancel, preferences) }
        return (gate(action), preferences)
    }

    private func gate(_ action: WKNavigationAction) -> WKNavigationActionPolicy {
        let u = action.request.url
        let s = u?.absoluteString ?? ""
        if action.shouldPerformDownload { event("refused download"); return .cancel }
        guard let frame = action.targetFrame else { event("refused new window"); return .cancel }
        if let u, scheme.isOwn(u) {
            if !frame.isMainFrame { return .allow }
            if Self.samePage(u, scheme.pageURL) { return .allow }
            event("refused main navigation \(u.path)")
            return .cancel
        }
        if !frame.isMainFrame && (s == "about:blank" || s == "about:srcdoc") { return .allow }
        event("refused navigation \(u?.scheme ?? "?")")
        return .cancel
    }

    static func samePage(_ a: URL, _ b: URL) -> Bool {
        var x = URLComponents(url: a, resolvingAgainstBaseURL: false), y = URLComponents(url: b, resolvingAgainstBaseURL: false)
        x?.fragment = nil; y?.fragment = nil; x?.query = nil; y?.query = nil
        return x?.url?.absoluteString == y?.url?.absoluteString
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if !response.canShowMIMEType { event("refused download"); return .cancel }
        return .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.cancel { _ in }
        event("refused download")
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.cancel { _ in }
        event("refused download")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === web else { return }
        if preflighting { finishPreflight(webView); return }
        verifySeal(webView)
        if let t = webView.title, !t.isEmpty { onTitle?(t) }
        if let p = pendingPlace, !(p is NSNull) {
            pendingPlace = nil
            kitCall("return window.__linenKit ? __linenKit.restore(p) : null", ["p": p], on: webView, timeout: 1) { _ in }
        }
        let g = buildGeneration
        kitCall("return window.__linenKit ? __linenKit.looksEmpty() : false", on: webView, timeout: 1) { [weak self] v in
            guard let self, g == self.buildGeneration else { return }
            self.onStateLine?((v as? Bool ?? false) ? String(localized: "This page draws with scripts, and scripts are off on this iPhone")
                                                      : String(localized: "Scripts are off for pages on this iPhone"))
        }
    }

    /// PAGE-1, before any author code: the preflight page's verdict on each wall in this web view; the author's page
    /// loads only when every wall is on, else the source shows with the reason.
    private func finishPreflight(_ webView: WKWebView) {
        let g = buildGeneration
        Task {
            var verdict: [String: Bool]?
            for _ in 0..<12 {
                if let s = await evaluateInKit("const p = document.querySelector('pre'); return p ? p.textContent : ''", timeout: 1) as? String,
                   s.hasPrefix("{"), let d = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Bool] { verdict = d; break }
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard g == buildGeneration, let web, web === webView else { return }
            preflighting = false
            guard let verdict, !verdict.values.contains(false), verdict.count == 3 else {
                event("preflight failed \(verdict.map { $0.filter { !$0.value }.keys.sorted().joined(separator: ",") } ?? "no answer")")
                showSource(reason: String(localized: "Linen could not seal this page, so it shows its source"))
                return
            }
            event("preflight passed \(verdict.keys.sorted().joined(separator: ","))")
            web.load(URLRequest(url: scheme.pageURL))
        }
    }

    /// PAGE-1: a page whose removal script did not run is shown as source.
    private func verifySeal(_ webView: WKWebView) {
        let g = buildGeneration
        let js = "const d = Object.getOwnPropertyDescriptor(window, 'RTCPeerConnection'); return !!d && d.configurable === false && d.value === undefined;"
        webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { [weak self] result in
            let sealed = (try? result.get()) as? Bool ?? false
            MainActor.assumeIsolated {
                guard let self, g == self.buildGeneration, !sealed else { return }
                self.event("seal missing")
                self.showSource(reason: String(localized: "Linen could not seal this page, so it shows its source"))
            }
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === web else { return }
        crashes += 1
        event("web content ended (\(crashes))")
        if crashes >= 2 { showSource(reason: String(localized: "This page stopped Linen's view again; showing its source")); return }
        teardown()
        scheme = PageScheme(page: fileURL, scripts: false, options: .full, pinned: folder)
        startBuild()
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        event("refused new window")
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        event("dropped alert")
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        event("dropped confirm")
        return false
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        event("dropped prompt")
        return nil
    }

    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        event("refused media capture")
        onToast?(String(localized: "Pages cannot use the camera or microphone"))
        return .deny
    }

    func webView(_ webView: WKWebView, requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo) async -> WKPermissionDecision {
        event("refused motion")
        return .deny
    }

    /// No long-press menu: its Open and Share would hand a page's link around the gate (PAGE-11).
    func webView(_ webView: WKWebView, contextMenuConfigurationFor elementInfo: WKContextMenuElementInfo) async -> UIContextMenuConfiguration? {
        nil
    }

    // MARK: Messages from the isolated world (PAGE-8)

    fileprivate func received(_ body: Any, from webView: WKWebView?) {
        guard webView == nil || webView === web else { return }
        guard let msg = body as? [String: Any], let type = msg["type"] as? String, type == "click", let href = msg["href"] as? String else { return }
        switch PhoneLinks.decide(href, scheme: scheme) {
        case .inPage:
            break
        case let .openInLinen(rel):
            event("open in Linen \((rel as NSString).lastPathComponent)")
            onOpenInLinen?(rel)
        case let .ask(u):
            event("ask \(u.absoluteString)")
            onAsk?(u)
        case let .refuse(what):
            event("refused link \(what)")
            onToast?(String(localized: "Linen does not open \(what) from a page"))
        }
    }

    // MARK: Source view (PAGE-1)

    private func showSource(reason: String) {
        buildGeneration += 1
        teardown()
        let data = folder?.open(fileURL.lastPathComponent).flatMap { SafeOpen.read($0) } ?? Data()
        let tv = UITextView()
        tv.isEditable = false
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.text = String(decoding: data, as: UTF8.self)
        tv.backgroundColor = view.backgroundColor
        tv.textColor = theme == "night" ? .linenPaper : .linenInk2
        tv.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tv)
        NSLayoutConstraint.activate([
            tv.leadingAnchor.constraint(equalTo: view.leadingAnchor), tv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tv.topAnchor.constraint(equalTo: view.topAnchor), tv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        onStateLine?(reason)
    }

    // MARK: Calls into the isolated world

    func evaluateInKit(_ js: String, timeout: Double = 5) async -> Any? {
        guard let web else { return nil }
        let box: PageValue = await withCheckedContinuation { (k: CheckedContinuation<PageValue, Never>) in
            kitCall(js, on: web, timeout: timeout) { k.resume(returning: PageValue($0)) }
        }
        return box.value
    }

    private func kitCall(_ body: String, _ args: [String: Any] = [:], on web: WKWebView, timeout: Double, done: @escaping @MainActor (Any?) -> Void) {
        let once = OnceFlag()
        web.callAsyncJavaScript(body, arguments: args, in: nil, in: kitWorld) { result in
            let box = PageValue((try? result.get()).flatMap { $0 is NSNull ? nil : $0 })
            MainActor.assumeIsolated { if once.take() { done(box.value) } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            MainActor.assumeIsolated { if once.take() { done(nil) } }
        }
    }

    private func event(_ s: String) {
        events.append(s)
        #if DEBUG
        print("[linen seal] \(s)")
        #endif
    }
}

private final class KitProxy: NSObject, WKScriptMessageHandler {
    weak var target: SealedPage?
    init(_ t: SealedPage) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = PageValue(message.body)
        let web = message.webView
        MainActor.assumeIsolated { target?.received(body.value as Any, from: web) }
    }
}

/// Where a link from a page may go on the phone (PAGE-11), decided only for clicks the isolated world saw as real
/// (PAGE-8): web addresses after the full address is shown and confirmed; notes, boards and pages in the page's own
/// folder, in Linen; everything else refused with one line naming it.
enum PhoneLinks {
    enum Decision: Equatable {
        case inPage
        case openInLinen(String)
        case ask(URL)
        case refuse(String)
    }

    static let readable: Set<String> = ["md", "markdown", "txt", "canvas", "html", "htm"]

    @MainActor
    static func decide(_ href: String, scheme: PageScheme) -> Decision {
        guard let u = URL(string: href), let s = u.scheme?.lowercased() else { return .refuse(String(href.prefix(80))) }
        switch s {
        case "http", "https":
            return .ask(u)
        case PageSeal.pageScheme:
            let (rel, reason) = scheme.relativePath(of: u)
            guard let rel else { return .refuse(reason == "another host" ? u.absoluteString : String(localized: "a file outside this page's folder")) }
            if rel == scheme.pagePath { return .inPage }
            guard readable.contains((rel as NSString).pathExtension.lowercased()), let o = scheme.pinned?.open(rel) else {
                return .refuse((rel as NSString).lastPathComponent)
            }
            close(o.fd)
            return .openInLinen(rel)
        case "javascript":
            return .inPage
        default:
            return .refuse(s == "file" ? (u.lastPathComponent.isEmpty ? String(localized: "a file") : u.lastPathComponent) : "\(s):")
        }
    }
}
