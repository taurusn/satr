import AppKit
import WebKit

/// One sealed page in a tab (PRD-2 PAGE-1 to PAGE-12): its own configuration, non-persistent data store and
/// origin, the five walls (rule list, CSP, navigation gate, removal script, engine flags), every capability denied,
/// links through PAGE-11's allowlist, scripts by trust and by the seal check, a stall and memory watchdog with
/// crash recovery, reload holding the place, find and theme. Print and PDF here are WebKit's own; EXP-7 and EXP-8
/// (Paper, page numbers, searchable Arabic) are Linen/Export's, which calls `pdfData()` and `printOperation`.
/// The host (a document tab) puts `view` in its window and listens to the callbacks.
@MainActor
final class SealedPageController: NSViewController, WKNavigationDelegate, WKUIDelegate {
    /// The page's file, canonical (symlinks resolved once, here): policy, serving, links, reload and the source view
    /// all use this one identity (Codex m9 review, item 5).
    let fileURL: URL
    let options: SealOptions
    private(set) var web: SealedWebView?
    private(set) var scheme: PageScheme
    private let kit: KitScheme
    private let kitWorld = WKContentWorld.world(name: PageSeal.kitWorldName)
    private var theme: String
    private let bar = PageStateBar()
    private var sourceView: NSScrollView?
    private var crashes = 0
    /// Scripts forced off for this open (Stop page, a crash, the memory limit); cleared when the tab is reopened.
    private var stoppedThisOpen = false
    private var pendingPlace: Any?
    private var reloadedOnce = false
    private var pingSent: Date?
    private var watchdog: Timer?
    private var stalled = false
    private var transientLine: (text: String, until: Date)?
    private var persistentLine: PageStateBar.Line?
    private var drawsWithScripts = false
    /// True while the tab's own preflight page runs, before the author's page loads.
    private var preflighting = false
    private var showingSource = false

    // MARK: Callbacks for the host

    var onTitle: ((String) -> Void)?
    /// A real click on a note, board or page in the page's folder; `newTab` when ⌘ or the middle button was used.
    var onOpenInLinen: ((URL, Bool) -> Void)?
    /// The one state line the tab shows, or nil (also drawn by the controller's own bar).
    var onStateLine: ((String?) -> Void)?
    /// Opens an address in the browser after Hatim said yes to the full-address prompt.
    var openExternal: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Asks before a web link leaves Linen. The default shows a sheet with the full address; tests replace it.
    var confirmExternal: ((URL, @escaping @MainActor (Bool) -> Void) -> Void)?
    /// Every refusal and decision, for tests and the log (never page content).
    var onEvent: ((String) -> Void)?
    var onFinish: (() -> Void)?

    /// Whether page scripts are on in this tab right now, and why not.
    private(set) var scriptsOn = false
    private(set) var scriptsOffReason: String?
    /// The WebKit feature flags this tab turned off (SealOptions.engineFlags).
    private(set) var flagsOff: [String] = []

    init(url: URL, theme: String, options: SealOptions = .full, kit: KitScheme? = nil) {
        fileURL = url.standardizedFileURL.resolvingSymlinksInPath()
        self.theme = theme
        self.options = options
        self.kit = kit ?? KitScheme.bundled()
        virtualFiles = nil
        forcedScripts = nil
        folder = PinnedFolder(fileURL.deletingLastPathComponent())
        scheme = PageScheme(page: fileURL, scripts: false, options: options, pinned: folder)
        super.init(nibName: nil, bundle: nil)
    }

    /// An in-memory page with its scripts forced on or off: the self-test's probe pages (PAGE-10), which must run
    /// in exactly the configuration user pages get.
    init(virtual files: [String: Data], page: String, scripts: Bool, options: SealOptions, kit: KitScheme? = nil) {
        fileURL = URL(fileURLWithPath: "/var/empty").appendingPathComponent(page)
        theme = "paper"
        self.options = options
        self.kit = kit ?? KitScheme.bundled()
        virtualFiles = files
        forcedScripts = scripts
        folder = nil
        scheme = PageScheme(files: files, page: page, scripts: scripts, options: options)
        super.init(nibName: nil, bundle: nil)
    }

    private let virtualFiles: [String: Data]?
    private let forcedScripts: Bool?
    /// The page's folder, pinned once for the tab's life: every rebuild and the source view use this descriptor.
    private let folder: PinnedFolder?
    /// Set by `close()`: a build waiting on the rule list gives up, and nothing is built again.
    private var closed = false
    private var watches: [any NSObjectProtocol] = []

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        container.wantsLayer = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        bar.isHidden = true
        bar.setTheme(theme)
        view = container
        // The seal check finishing, a trusted folder added or removed, a per-file choice: every change to what
        // decides this page's scripts is applied at once, and a revocation never waits on the page (items 9, 15).
        let center = NotificationCenter.default
        for name in [PageSelfTest.changed, UserDefaults.didChangeNotification] {
            watches.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.policyMayHaveChanged() }
            })
        }
        startBuild()
    }

    /// Stops observing and tears the web view down; the host calls it when the tab closes.
    func close() {
        closed = true
        buildGeneration += 1
        for w in watches { NotificationCenter.default.removeObserver(w) }
        watches.removeAll()
        teardown()
    }

    // MARK: Building

    /// Counts web views built for this tab: a build that finds a newer one started while it waited gives up, and
    /// late answers from a replaced web view are ignored (item 17).
    private var buildGeneration = 0
    private var titleWatch: NSKeyValueObservation?

    private func startBuild() {
        guard !closed else { return }
        buildGeneration += 1
        let g = buildGeneration
        Task { await build(g) }
    }

    private func build(_ generation: Int) async {
        let list: WKContentRuleList?
        do { list = options.rules ? try await PageSeal.ruleList() : nil } catch {
            guard generation == buildGeneration else { return }
            showSource(reason: String(localized: "Linen could not seal this page, so it shows its source"))
            onEvent?("seal failed: rules")
            return
        }
        guard generation == buildGeneration, !showingSource, !closed else { return }
        let policy = currentPolicy()
        scriptsOn = policy.on
        scheme.scripts = policy.on
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.isElementFullscreenEnabled = false
        config.preferences.isFraudulentWebsiteWarningEnabled = false
        if options.engineFlags { flagsOff = EngineFlags.apply(to: config.preferences) }
        config.allowsAirPlayForMediaPlayback = false
        config.upgradeKnownHostsToHTTPS = false
        config.defaultWebpagePreferences.allowsContentJavaScript = policy.on
        config.setURLSchemeHandler(scheme, forURLScheme: PageSeal.pageScheme)
        config.setURLSchemeHandler(kit, forURLScheme: PageSeal.kitScheme)
        let ucc = config.userContentController
        if let list, testDropWall != "rules" { ucc.add(list) }
        installScripts(ucc)
        ucc.add(KitMessageProxy(self), contentWorld: kitWorld, name: "linenKit")
        let web = SealedWebView(frame: view.bounds, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = false
        web.allowsLinkPreview = false
        web.allowsMagnification = true
        web.underPageBackgroundColor = theme == "night" ? .linenInk2 : .linenPaper
        #if DEBUG
        web.isInspectable = true
        #endif
        web.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(web, positioned: .below, relativeTo: bar)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        self.web = web
        titleWatch = web.observe(\.title, options: [.new]) { [weak self] _, change in
            let t = change.newValue ?? nil
            MainActor.assumeIsolated { if let t, !t.isEmpty { self?.onTitle?(t) } }
        }
        relayout()
        scheme.resetBudget()
        preflighting = true
        web.load(URLRequest(url: scheme.preflightURL))
        startWatchdog()
        updateLine()
    }

    private func installScripts(_ ucc: WKUserContentController) {
        ucc.removeAllUserScripts()
        if options.removal, testDropWall != "removal" {
            ucc.addUserScript(WKUserScript(source: PageSeal.removalScript, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        }
        ucc.addUserScript(WKUserScript(source: PageScripts.kit(theme: theme), injectionTime: .atDocumentStart, forMainFrameOnly: false, in: kitWorld))
        if let testScript {
            ucc.addUserScript(WKUserScript(source: testScript, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        }
    }

    /// The self-test's negative cases only: a script that stands in for a WebKit build with something new in it.
    var testScript: String?
    /// Tests only: leaves one wall ("rules" or "removal") out while the options still expect it, as a failed
    /// install would, to prove the preflight catches it.
    var testDropWall: String?

    /// Ends the current web view at once: no async work waits on it, its requests are dropped, its process is
    /// ended (WebKit's own call when present, else by releasing the view), and nothing of it is kept.
    private func teardown() {
        watchdog?.invalidate()
        watchdog = nil
        pingSent = nil
        stalled = false
        titleWatch = nil
        scheme.cancelAll()
        if let web {
            web.navigationDelegate = nil
            web.uiDelegate = nil
            web.configuration.userContentController.removeAllScriptMessageHandlers()
            web.stopLoading()
            let kill = Selector(("_killWebContentProcess"))
            if web.responds(to: kill) { web.perform(kill) }
            web.removeFromSuperview()
        }
        web = nil
    }

    /// Rebuilds from scratch (Stop page, crash recovery, a scripts change): a new configuration, data store, origin
    /// and handler, so a hung or crashed page leaves nothing behind.
    private func rebuild() {
        teardown()
        let old = scheme
        scheme = virtualFiles.map { PageScheme(files: $0, page: old.pagePath, scripts: false, options: options) }
            ?? PageScheme(page: fileURL, scripts: false, options: options, pinned: folder)
        scheme.onRequest = old.onRequest
        startBuild()
    }

    private func relayout() {
        guard let web else { return }
        for c in view.constraints where (c.firstItem as? NSView) === web && c.firstAttribute == .top { c.isActive = false }
        web.topAnchor.constraint(equalTo: bar.isHidden ? view.topAnchor : bar.bottomAnchor).isActive = true
    }

    // MARK: Scripts and trust (PAGE-7, PAGE-10)

    private func currentPolicy() -> (on: Bool, source: PagePolicy.Source) {
        if let forcedScripts { scriptsOffReason = nil; return (forcedScripts, .file) }
        let p = PagePolicy.effective(canonical: fileURL.path)
        if stoppedThisOpen { scriptsOffReason = "stopped"; return (false, p.source) }
        if let why = PageSelfTest.shared.blockReason { scriptsOffReason = why; return (false, p.source) }
        scriptsOffReason = p.on ? nil : (p.source == .file ? "file" : "untrusted")
        return p
    }

    /// Applies a change in what decides this page's scripts: a revocation tears the page down at once (it may be
    /// hung, so nothing waits on it); a grant keeps the place when the page answers within 300 ms.
    private func policyMayHaveChanged() {
        guard forcedScripts == nil, !showingSource, web != nil else { return }
        let was = scriptsOn
        let want = currentPolicy().on
        if was && !want { onEvent?("scripts revoked"); rebuild() } else if !was && want { capturePlaceThenRebuild() } else { updateLine() }
    }

    /// Runs or stops this page's scripts and remembers the choice for this file (View > Run Page Scripts). The
    /// change reaches the tab through `policyMayHaveChanged`.
    func runScripts(_ on: Bool) {
        stoppedThisOpen = false
        PagePolicy.setPerFile(canonical: fileURL.path, on)
        policyMayHaveChanged()
    }

    /// Trusts a folder (the suggested project root).
    func trust(_ folder: URL) {
        TrustedFolders.add(folder.path)
        policyMayHaveChanged()
    }

    private func capturePlaceThenRebuild() {
        guard let web else { rebuild(); return }
        let g = buildGeneration
        kitCall("return window.__linenKit ? __linenKit.place() : null", on: web, timeout: 0.3) { [weak self] place in
            guard let self, g == self.buildGeneration else { return }
            self.pendingPlace = place
            self.rebuild()
        }
    }

    // MARK: What the host calls

    /// Reload after the file changed on disk (PAGE-5), holding the place by the nearest element with an id.
    func reload() {
        guard let web else { return }
        let g = buildGeneration
        kitCall("return window.__linenKit ? __linenKit.place() : null", on: web, timeout: 0.5) { [weak self] place in
            guard let self, g == self.buildGeneration, let web = self.web else { return }
            self.pendingPlace = place
            if !self.reloadedOnce { self.reloadedOnce = true; self.flash(String(localized: "Changes are not marked in pages")) }
            self.scheme.resetBudget()
            web.load(URLRequest(url: self.scheme.pageURL))
        }
    }

    func setTheme(_ t: String) {
        theme = t
        bar.setTheme(t)
        guard let web else { return }
        web.underPageBackgroundColor = t == "night" ? .linenInk2 : .linenPaper
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

    /// WebKit's PDF of the page as one long page: the input to Linen/Export's EXP-7 pipeline, not a finished export.
    func pdfData() async throws -> Data {
        guard let web else { throw URLError(.cancelled) }
        return try await web.pdf(configuration: WKPDFConfiguration())
    }

    /// WebKit's print operation for the page, for Linen/Export to configure (Paper, page numbers) before running.
    func printOperation(with info: NSPrintInfo) -> NSPrintOperation? {
        web?.printOperation(with: info)
    }

    var pageTitle: String { web?.title ?? fileURL.deletingPathExtension().lastPathComponent }

    // MARK: Navigation gate (PAGE-1) and capabilities (PAGE-11)

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        let isPreflight = action.request.url.map { scheme.isOwn($0) && $0.path == "/" + PageSeal.preflightPath } ?? false
        preferences.allowsContentJavaScript = scriptsOn || (isPreflight && preflighting)
        if isPreflight { return (preflighting && (action.targetFrame?.isMainFrame ?? false) ? .allow : .cancel, preferences) }
        return (gate(action), preferences)
    }

    private func gate(_ action: WKNavigationAction) -> WKNavigationActionPolicy {
        guard options.gate else { return .allow }
        let u = action.request.url
        let s = u?.absoluteString ?? ""
        if action.shouldPerformDownload { onEvent?("refused download"); return .cancel }
        guard let frame = action.targetFrame else { onEvent?("refused new window"); return .cancel }
        if let u, scheme.isOwn(u) {
            if !frame.isMainFrame { return .allow }
            if Self.samePage(u, scheme.pageURL) { return .allow }
            onEvent?("refused main navigation \(u.path)")
            return .cancel
        }
        if !frame.isMainFrame && (s == "about:blank" || s == "about:srcdoc") { return .allow }
        onEvent?("refused navigation \(u?.scheme ?? "?")")
        return .cancel
    }

    static func samePage(_ a: URL, _ b: URL) -> Bool {
        var x = URLComponents(url: a, resolvingAgainstBaseURL: false), y = URLComponents(url: b, resolvingAgainstBaseURL: false)
        x?.fragment = nil; y?.fragment = nil; x?.query = nil; y?.query = nil
        return x?.url?.absoluteString == y?.url?.absoluteString
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if !response.canShowMIMEType { onEvent?("refused download"); return .cancel }
        return .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.cancel { _ in }
        onEvent?("refused download")
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.cancel { _ in }
        onEvent?("refused download")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === web else { return }
        if preflighting { finishPreflight(webView); return }
        if options.removal { verifySeal(webView) }
        onTitle?(pageTitle)
        if let p = pendingPlace, !(p is NSNull) {
            pendingPlace = nil
            kitCall("return window.__linenKit ? __linenKit.restore(p) : null", ["p": p], on: webView, timeout: 1) { _ in }
        }
        if !scriptsOn {
            let g = buildGeneration
            kitCall("return window.__linenKit ? __linenKit.looksEmpty() : false", on: webView, timeout: 1) { [weak self] v in
                guard let self, g == self.buildGeneration else { return }
                self.drawsWithScripts = v as? Bool ?? false
                self.updateLine()
            }
        }
        onFinish?()
    }

    /// PAGE-1, before any author code: reads the preflight page's verdict on each wall in this web view; the author's
    /// page loads only when every wall that should be on is on, else the tab shows the source with the reason.
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
            guard let verdict, !verdict.values.contains(false) else {
                onEvent?("preflight failed \(verdict.map { $0.filter { !$0.value }.keys.sorted().joined(separator: ",") } ?? "no answer")")
                showSource(reason: String(localized: "Linen could not seal this page, so it shows its source"))
                return
            }
            onEvent?("preflight passed \(verdict.keys.sorted().joined(separator: ","))")
            web.load(URLRequest(url: scheme.pageURL))
        }
    }

    /// PAGE-1: a page whose removal script did not run is shown as source. The script pins WebRTC to a
    /// non-configurable `undefined` on the page's own window, which only it can have done before the page ran; the
    /// check runs in the page's world (WebKit allows the app's own calls there even with page scripts off).
    private func verifySeal(_ webView: WKWebView) {
        let g = buildGeneration
        let once = OnceFlag()
        let js = "const d = Object.getOwnPropertyDescriptor(window, 'RTCPeerConnection'); return !!d && d.configurable === false && d.value === undefined;"
        webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { [weak self] result in
            let sealed = (try? result.get()) as? Bool ?? false
            MainActor.assumeIsolated {
                guard once.take(), let self, g == self.buildGeneration, !sealed else { return }
                self.onEvent?("seal missing")
                self.showSource(reason: String(localized: "Linen could not seal this page, so it shows its source"))
            }
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === web else { return }
        crashes += 1
        onEvent?("web content ended (\(crashes))")
        if crashes >= 2 {
            showSource(reason: String(localized: "This page stopped Linen's view again; showing its source"))
            return
        }
        stoppedThisOpen = true
        rebuild()
        flash(String(localized: "This page stopped Linen's view; opened without scripts"), seconds: 30)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        onEvent?("refused new window")
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        onEvent?("dropped alert")
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        onEvent?("dropped confirm")
        return false
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        onEvent?("dropped prompt")
        return nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        onEvent?("refused file picker")
        flash(String(localized: "Pages cannot open files from your Mac"))
        return nil
    }

    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        onEvent?("refused media capture")
        flash(String(localized: "Pages cannot use the camera or microphone"))
        return .deny
    }

    // MARK: Messages from the isolated world (PAGE-8)

    fileprivate func received(_ body: Any, from webView: WKWebView?) {
        guard webView == nil || webView === web else { return }
        guard let msg = body as? [String: Any], let type = msg["type"] as? String else { return }
        switch type {
        case "click":
            guard let href = msg["href"] as? String else { return }
            let newTab = msg["newTab"] as? Bool ?? false
            switch PageLinks.decide(href, scheme: scheme) {
            case .inPage:
                break
            case let .openInLinen(u):
                onEvent?("open in Linen \(u.lastPathComponent)")
                onOpenInLinen?(u, newTab)
            case let .ask(u):
                onEvent?("ask \(u.absoluteString)")
                askExternal(u)
            case let .refuse(what):
                onEvent?("refused link \(what)")
                flash(String(localized: "Linen does not open \(what) from a page"))
            }
        case "note":
            onEvent?("note shown")
        default:
            break
        }
    }

    private func askExternal(_ u: URL) {
        let decide: @MainActor (Bool) -> Void = { [weak self] yes in
            guard yes else { self?.onEvent?("declined \(u.absoluteString)"); return }
            self?.onEvent?("opened \(u.absoluteString)")
            self?.openExternal(u)
        }
        if let confirmExternal { confirmExternal(u, decide); return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Open this address in your browser?")
        alert.informativeText = u.absoluteString
        alert.addButton(withTitle: String(localized: "Open in Browser"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if let w = view.window {
            alert.beginSheetModal(for: w) { r in MainActor.assumeIsolated { decide(r == .alertFirstButtonReturn) } }
        } else {
            decide(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    // MARK: Stall and memory watchdog (PAGE-12)

    private func startWatchdog() {
        watchdog?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated { self.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        watchdog = t
    }

    /// A page allocating without limit keeps answering pings, so the watchdog also reads its web content process's
    /// footprint (WebKit's process id, an SPI, and `proc_pid_rusage`) and stops the page past this. When the
    /// footprint cannot be read, the page's scripts go off: an unwatched page is not left running (item 16).
    static let memoryBudget: UInt64 = 1024 * 1024 * 1024
    private var ticks = 0
    private var unmeasured = 0

    private var webProcessID: pid_t? {
        guard let web, web.responds(to: Selector(("_webProcessIdentifier"))) else { return nil }
        let n = (web.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value ?? 0
        return n > 0 ? n : nil
    }

    static func footprint(of pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return r == 0 ? info.ri_phys_footprint : nil
    }

    private func tick() {
        guard let web, scriptsOn else { return }
        ticks += 1
        if ticks % 4 == 0 {
            if let pid = webProcessID, let used = Self.footprint(of: pid) {
                unmeasured = 0
                if used > Self.memoryBudget {
                    onEvent?("over memory budget (\(used / 1_048_576) MB)")
                    stoppedThisOpen = true
                    rebuild()
                    flash(String(localized: "This page used too much memory; opened without scripts"), seconds: 30)
                    return
                }
            } else if !web.isLoading {
                unmeasured += 1
                if unmeasured >= 4 {
                    onEvent?("memory unmeasurable")
                    stoppedThisOpen = true
                    rebuild()
                    flash(String(localized: "Linen cannot watch this page's memory, so its scripts are off"), seconds: 30)
                    return
                }
            }
        }
        if let sent = pingSent {
            // A ping outstanding 4.75 s means the page has not answered for about 5 s (PAGE-12), checked every 0.25 s.
            if Date().timeIntervalSince(sent) > 4.75, !stalled {
                stalled = true
                onEvent?("stalled")
                updateLine()
            }
            return
        }
        pingSent = Date()
        let g = buildGeneration
        // The ping holds no reference to the web view, so a hung page's view can be released and its process end.
        kitCall("return window.__linenKit ? __linenKit.ping() : 1", on: web, timeout: 60) { [weak self] _ in
            guard let self, g == self.buildGeneration else { return }
            self.pingSent = nil
            if self.stalled { self.stalled = false; self.updateLine() }
        }
    }

    /// Stop page: reloads it with scripts off for this open.
    func stopPage() {
        onEvent?("stop page")
        stoppedThisOpen = true
        rebuild()
    }

    // MARK: State line

    private func updateLine() {
        var line: PageStateBar.Line?
        if stalled {
            line = .init(text: String(localized: "This page stopped responding"), actions: [(String(localized: "Stop page"), { [weak self] in self?.stopPage() })])
        } else if !scriptsOn, let why = scriptsOffReason {
            switch why {
            case "untrusted":
                var actions: [(String, () -> Void)] = [(String(localized: "Run this page"), { [weak self] in self?.runScripts(true) })]
                if let root = TrustedFolders.suggestion(for: fileURL) {
                    actions.append((String(localized: "Trust \(root.lastPathComponent)"), { [weak self] in self?.trust(root) }))
                }
                line = .init(text: drawsWithScripts ? String(localized: "This page draws with scripts") : String(localized: "Scripts are off for pages from here"), actions: actions)
            case "file":
                line = .init(text: String(localized: "Scripts are off for this page"), actions: [(String(localized: "Run this page"), { [weak self] in self?.runScripts(true) })])
            case "stopped":
                line = .init(text: String(localized: "Scripts are off for this page until you open it again"), actions: [])
            default:
                line = .init(text: why, actions: [])
            }
        }
        persistentLine = line
        render()
    }

    private func flash(_ text: String, seconds: Double = 6) {
        transientLine = (text, Date().addingTimeInterval(seconds))
        render()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let t = self.transientLine, t.until <= Date() else { return }
                self.transientLine = nil
                self.render()
            }
        }
    }

    private func render() {
        let line: PageStateBar.Line? = transientLine.map { .init(text: $0.text, actions: []) } ?? persistentLine
        bar.show(line)
        bar.isHidden = line == nil
        relayout()
        onStateLine?(line?.text)
    }

    // MARK: Source view (PAGE-1, PAGE-12)

    private func showSource(reason: String) {
        showingSource = true
        buildGeneration += 1
        teardown()
        let data = folder?.open(fileURL.lastPathComponent).flatMap { SafeOpen.read($0) } ?? Data()
        let scroll = NSTextView.scrollableTextView()
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            tv.string = String(decoding: data, as: UTF8.self)
        }
        scroll.translatesAutoresizingMaskIntoConstraints = false
        sourceView?.removeFromSuperview()
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        sourceView = scroll
        persistentLine = .init(text: reason, actions: [])
        render()
    }

    // MARK: Calls into the isolated world

    /// Evaluates in the isolated world (tests and the self-test only); nil after `timeout` seconds.
    func evaluateInKit(_ js: String, timeout: Double = 5) async -> Any? {
        guard let web else { return nil }
        let box: ValueBox = await withCheckedContinuation { (k: CheckedContinuation<ValueBox, Never>) in
            kitCall(js, on: web, timeout: timeout) { k.resume(returning: ValueBox($0)) }
        }
        return box.value
    }

    /// Runs a function body in the isolated world; `done` gets its value, or nil on error, undefined or timeout,
    /// exactly once. The completion handler keeps no reference to the web view.
    private func kitCall(_ body: String, _ args: [String: Any] = [:], on web: WKWebView, timeout: Double, done: @escaping @MainActor (Any?) -> Void) {
        let once = OnceFlag()
        web.callAsyncJavaScript(body, arguments: args, in: nil, in: kitWorld) { result in
            let value: Any? = (try? result.get()).flatMap { $0 is NSNull ? nil : $0 }
            let box = ValueBox(value)
            MainActor.assumeIsolated { if once.take() { done(box.value) } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            MainActor.assumeIsolated { if once.take() { done(nil) } }
        }
    }
}

/// Carries a value from WebKit's completion handler (main thread) into the main-actor callback.
private struct ValueBox: @unchecked Sendable {
    let value: Any?
    init(_ v: Any?) { value = v }
}

/// Routes the isolated world's messages to the controller without a retain cycle.
private final class KitMessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: SealedPageController?
    init(_ owner: SealedPageController) { self.owner = owner }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        let web = message.webView
        MainActor.assumeIsolated { owner?.received(body, from: web) }
    }
}

/// The web view of a sealed page: files dragged onto it are refused (PAGE-11), and its context menu keeps only
/// Copy, Look Up and Speech (no "Open Link", "Download", "Search with", "Share" or "Translate").
final class SealedWebView: WKWebView {
    override init(frame: NSRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        unregisterDraggedTypes()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {}
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { [] }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { [] }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { false }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { false }

    static let keptMenuItems: Set<String> = ["WKMenuItemIdentifierCopy", "WKMenuItemIdentifierCopyImage", "WKMenuItemIdentifierLookUp",
                                             "WKMenuItemIdentifierSpeechMenu", "WKMenuItemIdentifierInspectElement"]

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        for item in menu.items.reversed() {
            let id = item.identifier?.rawValue ?? ""
            #if !DEBUG
            if id == "WKMenuItemIdentifierInspectElement" { menu.removeItem(item); continue }
            #endif
            if !Self.keptMenuItems.contains(id) && !item.isSeparatorItem { menu.removeItem(item) }
        }
        while let first = menu.items.first, first.isSeparatorItem { menu.removeItem(first) }
        while let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
        super.willOpenMenu(menu, with: event)
    }
}

/// The one line a page tab shows (scripts off, a stall, a refusal), in Loom's paper and ink.
final class PageStateBar: NSView {
    struct Line {
        var text: String
        var actions: [(String, () -> Void)]
    }

    private let label = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private var handlers: [() -> Void] = []
    private var night = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.font = NSFont(name: "thmanyahsans-Regular", size: 13) ?? .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        stack.orientation = .horizontal
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 16, bottom: 6, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: 30),
        ])
        setTheme("paper")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setTheme(_ t: String) {
        night = t == "night"
        layer?.backgroundColor = (night ? NSColor.linenInk : NSColor(srgbRed: 0xFB / 255, green: 0xF9 / 255, blue: 0xF4 / 255, alpha: 1)).cgColor
        label.textColor = night ? .linenPaper : .linenInk2
        for case let b as NSButton in stack.arrangedSubviews { style(b) }
    }

    private func style(_ b: NSButton) {
        b.isBordered = false
        b.attributedTitle = NSAttributedString(string: b.title, attributes: [
            .font: NSFont(name: "thmanyahsans-Medium", size: 13) ?? .systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: night ? NSColor.linenPaper : NSColor.linenInk,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
    }

    func show(_ line: Line?) {
        for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
        handlers = []
        guard let line else { return }
        label.stringValue = line.text
        stack.addArrangedSubview(label)
        for (i, (title, action)) in line.actions.enumerated() {
            let b = NSButton(title: title, target: self, action: #selector(tap(_:)))
            b.tag = i
            style(b)
            handlers.append(action)
            stack.addArrangedSubview(b)
        }
    }

    @objc private func tap(_ sender: NSButton) {
        if sender.tag < handlers.count { handlers[sender.tag]() }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        (night ? NSColor(srgbRed: 0xF6 / 255, green: 0xF3 / 255, blue: 0xEB / 255, alpha: 0.14) : NSColor(srgbRed: 0xDA / 255, green: 0xD5 / 255, blue: 0xC8 / 255, alpha: 1)).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}
