import AppKit
import LinenKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// One tab: a document in a page, its file watcher, its history and its place (PRD 6.1 to 6.7).
@MainActor
final class DocumentWindow: NSWindowController, NSWindowDelegate, WKNavigationDelegate, NSToolbarDelegate, NSMenuItemValidation {
    private(set) var url: URL
    private(set) var vault: Vault
    private var index: VaultIndex
    private(set) var web: WKWebView!
    private let local = LocalScheme()
    private let remote = RemoteScheme()
    private var watcher: FileWatcher?
    /// A board's sidecar notes (`map.canvas.notes.json`, NOTE-2), watched beside it so a note change redraws the board.
    private var sidecarWatcher: FileWatcher?
    private(set) var sidecarText: String?
    private var encoding: String.Encoding?
    private var encodingNote: String?
    private var rawData: Data?
    private(set) var text = ""
    private var version = 0
    private var built = false
    private var pageReady = false
    private var haveContent = false
    private var docID = UUID().uuidString
    private var back: [Step] = []
    private var forward: [Step] = []
    private var pendingPlace: [String: Any]?
    private var pendingHeading: String?
    /// A node or line `linen open` asked for, shown once the document has rendered (CLI-6, BRD-26).
    private var pendingReveal: [String: Any]?
    /// On a board, the view the page last reported at rest (selected node, node in view, unread changes), for agents (MCP-9).
    private(set) var lastView: [String: Any]?
    /// An `.html` tab shows a sealed page (PAGE-1 to PAGE-12) instead of the note renderer.
    private(set) var pageController: SealedPageController?
    private var lastPageFind = ""
    private var pageWatch: Timer?
    private var outlineShown = Settings.outlineShown
    private var zoom: Double = Settings.defaultZoom
    private var outsideAllowed: [String: FileID] = [:]
    private var remoteApproved = false
    private var loadGeneration = 0
    private var indexDirty = false
    private var hiddenSince: Date?
    private var stateOverlay: NSView?
    private(set) var fileState: FileState?
    private var stateTimer: Timer?
    var onClose: ((DocumentWindow) -> Void)?
    var onChange: (() -> Void)?

    struct Step {
        let url: URL
        let place: [String: Any]?
    }

    init(url: URL, buildNow: Bool = true) {
        self.url = url.standardizedFileURL
        vault = VaultLocator.vault(for: self.url)
        index = Library.shared.index(for: vault)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: min(1180, screen.width - 40), height: min(820, screen.height - 40))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.delegate = self
        window.tabbingIdentifier = "com.hatim.linen.documents"
        window.tabbingMode = .preferred
        window.minSize = NSSize(width: 520, height: 400)
        window.titleVisibility = .visible
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("LinenDocument")
        let toolbar = NSToolbar(identifier: "LinenDocumentToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        if let place = Library.shared.places.place(for: self.url) { zoom = place.zoom > 0 ? place.zoom : zoom }
        updateTitle(nil)
        if buildNow { build() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Building the page (PERF-1)

    /// Builds the page and starts watching. Background tabs call this on first selection (section 9).
    func build() {
        guard !built, let window else { return }
        built = true
        if kind == .page { buildPage(in: window); return }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.setURLSchemeHandler(AppScheme(root: Bundle.main.resourceURL!.appendingPathComponent("renderer")), forURLScheme: "linen-app")
        config.setURLSchemeHandler(local, forURLScheme: "linen-local")
        config.setURLSchemeHandler(remote, forURLScheme: "linen-remote")
        config.userContentController.add(MessageProxy(self), name: "linen")
        config.userContentController.addUserScript(WKUserScript(source: """
          window.addEventListener('error', e => { try { webkit.messageHandlers.linen.postMessage({type: 'error', during: 'page', message: e.message + ' @' + (e.filename || '') + ':' + (e.lineno || '')}); } catch (_) {} });
          window.addEventListener('securitypolicyviolation', e => { try { webkit.messageHandlers.linen.postMessage({type: 'error', during: 'csp', message: e.violatedDirective + ' ' + e.blockedURI}); } catch (_) {} });
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: window.contentView?.bounds ?? .zero, configuration: config)
        web.navigationDelegate = self
        web.underPageBackgroundColor = Settings.theme(for: NSApp.effectiveAppearance) == "night" ? .linenInk2 : .linenPaper
        web.allowsMagnification = false
        // Swipes go through the page, which knows when a table or code block should take them (READ-5).
        web.allowsBackForwardNavigationGestures = false
        web.pageZoom = zoom
        if #available(macOS 13.3, *) { web.isInspectable = true }
        web.autoresizingMask = [.width, .height]
        window.contentView = web
        self.web = web
        web.load(URLRequest(url: URL(string: "linen-app://renderer/page.html")!))
        startWatching()
    }

    /// A sealed page: its own web view, scheme handlers and data store, never shared with notes or boards (PAGE-1).
    private func buildPage(in window: NSWindow) {
        let c = SealedPageController(url: url, theme: Settings.theme(for: window.effectiveAppearance))
        c.onTitle = { [weak self] t in self?.updateTitle(t) }
        // Links a page may open in Linen still pass Linen's one link gate (SAFE-4), always into a tab of their own.
        c.onOpenInLinen = { [weak self] u, _ in self?.openLocalFile(u, newTab: true, place: nil, heading: nil) }
        pageController = c
        c.view.frame = window.contentView?.bounds ?? .zero
        c.view.autoresizingMask = [.width, .height]
        window.contentView = c.view
        watchPage()
        Library.shared.noteOpened(url)
        NowState.changed()
    }

    /// A page is watched by its metadata only: the sealed scheme is the one thing that reads its bytes (with its
    /// 50 MB limit), so a huge file can never be pulled into Linen by the watcher. A change reloads once it settles.
    private func watchPage() {
        pageWatch?.invalidate()
        var last = Self.signature(url)
        var pending = false
        pageWatch = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.kind == .page else { return }
                let now = Self.signature(self.url)
                if now == nil { if self.fileState == nil { self.showState(Self.goneState(for: self.url)) }; return }
                if self.fileState != nil { self.clearState(); pending = true }
                if now != last { last = now; pending = true; return }   // still changing: wait for it to settle
                if pending { pending = false; self.pageController?.reload() }
            }
        }
    }

    private static func signature(_ u: URL) -> [Int]? {
        var st = stat()
        guard stat(u.path, &st) == 0 else { return nil }
        return [Int(st.st_ino), Int(st.st_size), Int(st.st_mtimespec.tv_sec), Int(st.st_mtimespec.tv_nsec)]
    }

    /// Paper or Night for a page, when the setting or the system look changes (PAGE-4).
    func applyPageTheme() {
        guard let pageController, let window else { return }
        pageController.setTheme(Settings.theme(for: window.effectiveAppearance))
    }

    @objc func togglePageScripts(_ sender: Any?) {
        guard let pageController else { NSSound.beep(); return }
        pageController.runScripts(!pageController.scriptsOn)
    }

    private func findInPage(backwards: Bool, ask: Bool) {
        guard let pageController, let window else { return }
        if ask || lastPageFind.isEmpty {
            let alert = NSAlert()
            alert.messageText = String(localized: "Find in Page")
            let field = NSSearchField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            field.stringValue = lastPageFind
            alert.accessoryView = field
            alert.addButton(withTitle: String(localized: "Find"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.window.initialFirstResponder = field
            alert.beginSheetModal(for: window) { [weak self] r in
                guard r == .alertFirstButtonReturn, let self else { return }
                self.lastPageFind = field.stringValue
                Task { @MainActor in if !(await pageController.find(self.lastPageFind, backwards: backwards)) { NSSound.beep() } }
            }
            return
        }
        Task { @MainActor in if !(await pageController.find(lastPageFind, backwards: backwards)) { NSSound.beep() } }
    }

    private func startWatching() {
        if kind == .page { watchPage(); return }   // pages: metadata only, never their bytes
        watcher?.stop()
        watcher = nil
        haveContent = false
        stopStateTimer()
        // An iCloud file that is not downloaded downloads now, with the mark drawing itself (OPEN-8).
        if CloudFile.isDataless(url) {
            showState(.downloading)
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            pollState(every: 0.5) { [weak self] in
                guard let self, !CloudFile.isDataless(self.url) else { return false }
                self.clearState()
                self.startWatching()
                return true
            }
            return
        }
        let w = FileWatcher(url: url) { [weak self] event in
            MainActor.assumeIsolated { self?.fileEvent(event) }
        }
        watcher = w
        w.start()
        startSidecar()
    }

    /// A file and its sidecars travel together (NOTE-2): a board or a note watches its notes file
    /// (`map.canvas.notes.json`, `report.md.notes.json`), present or not.
    private func startSidecar() {
        sidecarWatcher?.stop()
        sidecarWatcher = nil
        sidecarText = nil
        guard kind == .board || (kind == .note && !isPlain) else { return }
        let s = FileWatcher(url: URL(fileURLWithPath: url.path + ".notes.json")) { [weak self] event in
            MainActor.assumeIsolated { self?.sidecarEvent(event) }
        }
        sidecarWatcher = s
        s.start()
    }

    private func sidecarEvent(_ event: FileWatcher.Event) {
        switch event {
        case let .content(data, generation, inBurst):
            let fresh = TextDecoder.decode(data, override: nil).text
            guard fresh != sidecarText else { return }
            sidecarText = fresh
            // The notes' first read can land after the board has loaded without them: that is a change too.
            if haveContent, pageReady, !inBurst { sendUpdate(inBurst: false) }
            _ = generation
        case .missing, .unreadable:
            guard sidecarText != nil else { return }
            sidecarText = nil
            if haveContent, pageReady { sendUpdate(inBurst: false) }
        case .quiet, .moved:
            break
        }
    }

    private func sendUpdate(inBurst: Bool) {
        version += 1
        var msg: [String: Any] = ["type": "update", "docId": docID, "text": text, "sidecar": sidecarText ?? NSNull(), "inBurst": inBurst, "version": version, "meta": meta()]
        if kind == .board { msg["kind"] = "board" }
        send(msg)
    }

    private func fileEvent(_ event: FileWatcher.Event) {
        switch event {
        case let .content(data, generation, inBurst):
            clearState()
            // A page reloads itself from disk through its sealed scheme, holding its scroll (PAGE-5).
            if kind == .page {
                if haveContent && generation > 0 && !inBurst { pageController?.reload() }
                haveContent = true
                return
            }
            rawData = data
            let decoded = TextDecoder.decode(data, override: encoding ?? EncodingChoice.stored(for: url))
            if encoding == nil {
                encoding = decoded.encoding
                encodingNote = decoded.encoding == .utf8 ? nil : EncodingChoice.name(of: decoded.encoding)
            }
            text = decoded.text
            if !haveContent || generation == 0 {
                haveContent = true
                if pageReady { sendLoad() }
            } else if pageReady {
                sendUpdate(inBurst: inBurst)
            }
            // The index catches up once writes settle; a burst marks it out of date until then.
            if inBurst { indexDirty = true } else { indexDirty = false; let u = url; Task { await index.update(changed: [u]) } }
        case .quiet:
            send(["type": "quiet"])
            if indexDirty { indexDirty = false; let u = url; Task { await index.update(changed: [u]) } }
        case .missing:
            showState(Self.goneState(for: url))
        case let .unreadable(error):
            showState(error == EPERM ? .denied : .unreadable)
        case let .moved(newURL):
            // Renamed or moved (by Obsidian, Finder): the whole context follows, then a full load keeps the place.
            let old = url
            url = newURL.standardizedFileURL
            vault = VaultLocator.vault(for: url)
            index = Library.shared.index(for: vault)
            if let chosen = EncodingChoice.stored(for: old) {
                EncodingChoice.store(nil, for: old)
                EncodingChoice.store(chosen, for: url)
            }
            updateTitle(nil)
            onChange?()
            startSidecar()   // the notes file travels with the board's new name
            let new = url, newIndex = index, oldIndex = Library.shared.index(for: VaultLocator.vault(for: old))
            Task {
                await oldIndex.update(changed: [old])
                await newIndex.update(changed: [new])
            }
            if pageReady && haveContent { reloadKeepingPlace() }
        }
    }

    // MARK: Messages to the page

    private var isPlain: Bool { url.pathExtension.lowercased() == "txt" }

    /// What a tab shows: a note (Markdown or text), a board (JSON Canvas) or a sealed page (HTML).
    enum Kind { case note, board, page }

    static func kind(of u: URL) -> Kind? {
        switch u.pathExtension.lowercased() {
        case "md", "markdown", "mdown", "mkd", "txt": .note
        case "canvas": .board
        case "html", "htm": .page
        default: nil
        }
    }

    var kind: Kind { Self.kind(of: url) ?? .note }

    private func sendLoad() {
        local.reset()
        remote.allowed = Settings.remoteImagesAlways || remoteApproved
        loadGeneration += 1
        version += 1
        var msg: [String: Any] = [
            "type": "load", "docId": docID, "name": url.lastPathComponent, "path": url.path, "text": text, "plain": isPlain,
            "version": version, "allowRemote": remote.allowed, "meta": meta(),
        ]
        let stored = Library.shared.places.place(for: url)
        // The notes are read before the first load, so a board never loads without them and then "changes" when they
        // arrive (that made false change marks on a first open; Codex verification 2).
        if sidecarText == nil, kind == .board || (kind == .note && !isPlain),
           let data = try? Data(contentsOf: URL(fileURLWithPath: url.path + ".notes.json")) {
            sidecarText = TextDecoder.decode(data, override: nil).text
        }
        msg["sidecar"] = sidecarText ?? NSNull()
        if kind == .board {
            msg["kind"] = "board"
            msg["refPath"] = Self.referencePath(for: url)
            if let p = pendingPlace { msg["place"] = p } else if let b = stored?.board {
                msg["place"] = ["kind": "board", "cx": b.cx, "cy": b.cy, "zoom": b.zoom, "node": b.node ?? NSNull(), "mode": b.mode]
            }
        } else if let p = pendingPlace { msg["place"] = p } else if let p = stored {
            msg["place"] = ["hash": p.blockHash, "index": p.blockIndex, "offset": p.offset, "quote": p.quote, "atEnd": p.atEnd]
            msg["grown"] = p.atEnd
        }
        pendingPlace = nil
        if let base = Library.shared.baselines.hashes(for: url) {
            msg["baseline"] = base
            if let d = stored?.date { msg["baselineDate"] = d.formatted(.dateTime.day().month(.wide)) }
        }
        send(msg)
        Library.shared.noteOpened(url)
    }

    private func meta() -> [String: Any] {
        var m: [String: Any] = [:]
        if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
            m["modified"] = Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened) : date.formatted(.dateTime.day().month(.abbreviated).year())
        }
        if let e = encodingNote { m["encoding"] = e }
        return m
    }

    private func sendSettings() {
        send([
            "type": "settings", "theme": Settings.theme(for: window?.effectiveAppearance ?? NSApp.effectiveAppearance), "face": Settings.face,
            "uiDir": Settings.interfaceIsArabic ? "rtl" : "ltr", "lang": Settings.interfaceIsArabic ? "ar" : "en",
            "contrast": NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast, "foldArabic": Settings.foldArabic,
        ])
    }

    @discardableResult
    func send(_ msg: [String: Any]) -> Task<PageValue, Never>? {
        guard pageReady, let web else { return nil }
        let box = PageValue(msg)
        return Task { @MainActor in
            do {
                return PageValue(try await web.callAsyncJavaScript("return await window.linen.receive(msg)", arguments: ["msg": box.value ?? NSNull()], contentWorld: .page))
            } catch {
                Log.write("page call failed: \(error.localizedDescription)")
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

    // MARK: Messages from the page

    fileprivate func received(_ body: Any) {
        guard let msg = body as? [String: Any], let type = msg["type"] as? String else { return }
        // A message from the document this tab showed before a navigation is about that one, never this one.
        if ["rendered", "view", "place", "baseline", "openReference"].contains(type), let d = msg["docId"] as? String, d != docID { return }
        switch type {
        case "openReference":
            openReference(msg["path"] as? String ?? "", line: msg["line"] as? Int)
        case "ready":
            Log.write("page ready for \(url.lastPathComponent)")
            pageReady = true
            sendSettings()
            applyOutline()
            if haveContent { sendLoad() }
        case "firstPaint":
            break
        case "rendered":
            updateTitle(msg["title"] as? String)
            if let h = pendingHeading { pendingHeading = nil; send(["type": "command", "name": "heading", "text": h]) }
            if let r = pendingReveal { pendingReveal = nil; send(r) }
            NowState.changed()
        case "view":
            var v = msg
            v.removeValue(forKey: "type")
            lastView = v
            NowState.changed()
        case "place":
            if let p = msg["place"] as? [String: Any] { storePlace(p) }
        case "baseline":
            // Only for the document on the page now; a post from before a navigation must not land on the new file.
            if let hashes = msg["hashes"] as? [String], (msg["docId"] as? String).map({ $0 == docID }) ?? true {
                Library.shared.baselines.set(hashes, for: url)
            }
        case "openWiki":
            openWiki(msg["target"] as? String ?? "", newTab: msg["newTab"] as? Bool ?? false, place: msg["place"] as? [String: Any])
        case "openLocal":
            openLocal(msg["href"] as? String ?? "", newTab: msg["newTab"] as? Bool ?? false, place: msg["place"] as? [String: Any])
        case "openExternal":
            if let s = msg["url"] as? String, let u = URL(string: s), ["http", "https", "mailto", "tel"].contains(u.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(u) }
        case "openScheme":
            if let s = msg["url"] as? String, let u = URL(string: s) { confirmScheme(u) }
        case "pushStep":
            back.append(Step(url: url, place: msg["place"] as? [String: Any]))
            forward.removeAll()
        case "resolveLinks":
            resolveLinks(msg["targets"] as? [String] ?? [])
        case "imageInfo":
            imageInfo(msg["requests"] as? [String] ?? [])
        case "allowRemote":
            remoteApproved = true
            reloadKeepingPlace()
        case "allowOutside":
            allowOutside(msg["request"] as? String ?? "")
        case "setting":
            if msg["key"] as? String == "foldArabic", let v = msg["value"] as? Bool { Settings.foldArabic = v }
        case "swipe":
            if msg["direction"] as? String == "back" { goBack(nil) } else if msg["direction"] as? String == "forward" { goForward(nil) }
        case "copyText":
            if let t = msg["text"] as? String { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string) }
        case "showImage":
            showImage(msg["src"] as? String ?? "")
        case "error":
            Log.write("page error during \(msg["during"] as? String ?? "?"): \(msg["message"] as? String ?? "?")")
        default:
            break
        }
    }

    private func storePlace(_ p: [String: Any]) {
        if p["kind"] as? String == "board" {
            guard let cx = p["cx"] as? Double, let cy = p["cy"] as? Double, let z = p["zoom"] as? Double else { return }
            let node = p["node"] as? String
            let view = BoardView(cx: cx, cy: cy, zoom: z, node: node, mode: p["mode"] as? String ?? "canvas")
            Library.shared.places.set(Place(blockHash: node ?? "", blockIndex: 0, offset: 0, quote: "", zoom: zoom, atEnd: false, date: Date(), board: view), for: url)
            return
        }
        guard let hash = p["hash"] as? String else { return }
        let place = Place(blockHash: hash, blockIndex: p["index"] as? Int ?? 0, offset: p["offset"] as? Double ?? 0,
                          quote: p["quote"] as? String ?? "", zoom: zoom, atEnd: p["atEnd"] as? Bool ?? false, date: Date())
        Library.shared.places.set(place, for: url)
    }

    private func reloadKeepingPlace() {
        Task { @MainActor in
            pendingPlace = await command("place") as? [String: Any]
            sendLoad()
        }
    }

    // MARK: Links (SAFE-4, VAULT-2, READ-5)

    private func openWiki(_ target: String, newTab: Bool, place: [String: Any]?) {
        switch index.resolve(target, from: url) {
        case let .note(dest, heading, _):
            openLocalFile(dest, newTab: newTab, place: place, heading: heading)
        case let .ambiguous(candidates):
            let menu = NSMenu()
            for c in candidates {
                let item = NSMenuItem(title: c.path.replacingOccurrences(of: vault.root.path + "/", with: ""), action: #selector(pickCandidate(_:)), keyEquivalent: "")
                item.representedObject = c
                item.target = self
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        case .missing:
            NSSound.beep()
        }
    }

    @objc private func pickCandidate(_ sender: NSMenuItem) {
        if let u = sender.representedObject as? URL { openLocalFile(u, newTab: false, place: nil, heading: nil) }
    }

    private func openLocal(_ href: String, newTab: Bool, place: [String: Any]?) {
        let raw = href.removingPercentEncoding ?? href
        let pathPart = raw.split(separator: "#", maxSplits: 1).first.map(String.init) ?? raw
        let anchor = raw.contains("#") ? String(raw.split(separator: "#", maxSplits: 1).last ?? "") : nil
        let dest = pathPart.hasPrefix("/") ? URL(fileURLWithPath: pathPart) : url.deletingLastPathComponent().appendingPathComponent(pathPart)
        openLocalFile(dest, newTab: newTab, place: place, heading: anchor)
    }

    /// Every local link passes this one gate (SAFE-4). The file is judged after symlinks resolve: a Markdown or text
    /// file opens in Linen, which only reads it; anything else opens in its app without asking inside the vault, and
    /// after a confirmation when it is outside the vault or can run programs.
    private func openLocalFile(_ dest: URL, newTab: Bool, place: [String: Any]?, heading: String?) {
        let canonical = dest.standardizedFileURL.resolvingSymlinksInPath()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .isExecutableKey, .contentTypeKey]
        guard FileManager.default.fileExists(atPath: canonical.path), let values = try? canonical.resourceValues(forKeys: keys) else { NSSound.beep(); return }
        if values.isRegularFile == true, Self.isReadable(canonical) {
            navigate(to: canonical, newTab: newTab, place: place, heading: heading)
            return
        }
        let root = vault.root.standardizedFileURL.resolvingSymlinksInPath().path
        let inside = canonical.path.hasPrefix(root + "/")
        let executable = Self.canRunPrograms(canonical, values)
        if inside && !executable { NSWorkspace.shared.open(canonical); return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Open “\(canonical.lastPathComponent)”?")
        alert.informativeText = executable ? String(localized: "This file can run programs on your Mac.") : String(localized: "This file is outside this vault.")
        alert.addButton(withTitle: String(localized: "Open"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(canonical) }
    }

    /// Apps, packages, scripts, installers, disk images, executables and files that open URLs or run actions.
    static func canRunPrograms(_ u: URL, _ v: URLResourceValues) -> Bool {
        if v.isPackage == true { return true }
        if v.isRegularFile == true, v.isExecutable == true { return true }
        let risky: Set<String> = ["app", "command", "tool", "sh", "zsh", "bash", "csh", "ksh", "fish", "py", "rb", "pl", "js", "pkg", "mpkg",
                                  "dmg", "iso", "terminal", "workflow", "action", "scpt", "scptd", "applescript", "jar", "webloc", "inetloc",
                                  "fileloc", "prefpane", "saver", "mobileconfig", "shortcut", "kext", "plugin", "osax", "service", "definition"]
        if risky.contains(u.pathExtension.lowercased()) { return true }
        if let t = v.contentType, [UTType.executable, .script, .diskImage, .application, .applicationBundle, .package].contains(where: { t.conforms(to: $0) }) { return true }
        return false
    }

    private func confirmScheme(_ u: URL) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Open this link in another app?")
        alert.informativeText = u.absoluteString
        alert.addButton(withTitle: String(localized: "Open"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(u) }
    }

    static func isReadable(_ u: URL) -> Bool { kind(of: u) != nil }

    /// Follows a link in this tab (adding a back step) or in a new tab beside it.
    func navigate(to dest: URL, newTab: Bool, place: [String: Any]?, heading: String?) {
        // A page tab shows one page for its life (its seal is built for that file and folder), so anything opened from
        // it, and any page opened from a note or board, goes into a tab beside this one (PAGE-1).
        if newTab || kind == .page || Self.kind(of: dest) == .page {
            (NSApp.delegate as? AppDelegate)?.open(dest, besides: self)
            return
        }
        back.append(Step(url: url, place: place))
        forward.removeAll()
        replace(with: dest, place: nil, heading: heading)
    }

    private func replace(with dest: URL, place: [String: Any]?, heading: String?) {
        let target = dest.standardizedFileURL
        if target != url {
            url = target
            vault = VaultLocator.vault(for: url)
            index = Library.shared.index(for: vault)
            encoding = nil
            encodingNote = nil
            docID = UUID().uuidString
            lastView = nil
            outsideAllowed.removeAll()
            remoteApproved = false
            rawData = nil
            indexDirty = false
            clearState()
            pendingPlace = place
            pendingHeading = heading
            updateTitle(nil)
            startWatching()
            onChange?()
        } else if let place {
            send(["type": "command", "name": "restorePlace", "place": place])
        } else if let heading {
            send(["type": "command", "name": "heading", "text": heading])
        }
    }

    /// A source in a note card (`path:line`, BRD-6) opens in the editor, only when it resolves inside this file's vault or
    /// git repository; anything else is refused.
    private func openReference(_ path: String, line: Int?) {
        guard !path.isEmpty else { return }
        var root = vault.root.standardizedFileURL
        var dir = url.deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) { root = dir; break }
            dir = dir.deletingLastPathComponent()
        }
        let expanded = (path as NSString).expandingTildeInPath
        let target = (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : root.appendingPathComponent(expanded)).standardizedFileURL.resolvingSymlinksInPath()
        let base = root.resolvingSymlinksInPath().path
        guard target.path.hasPrefix(base + "/"), FileManager.default.fileExists(atPath: target.path) else { NSSound.beep(); return }
        if Self.kind(of: target) != nil {
            // A note, board or page opens in Linen, at the line when one is given.
            let doc = (NSApp.delegate as? AppDelegate)?.open(target, besides: self)
            if let line { doc?.reveal(node: nil, line: line) }
        } else {
            Editors.open(target, vault: vault)   // other files open in the editor (no line: editors take it differently)
        }
    }

    /// Shows a board's node or a note's line, now if the document has rendered, else when it does.
    func reveal(node: String?, line: Int?) {
        var msg: [String: Any]
        if let node, kind == .board { msg = ["type": "command", "name": "goNode", "id": node] }
        else if let line, kind == .note { msg = ["type": "command", "name": "line", "line": line] }
        else { return }
        msg["select"] = true
        if pageReady && haveContent { send(msg) } else { pendingReveal = msg }
    }

    @objc func goBack(_ sender: Any?) {
        // On a board, Back first returns to the previous view (BRD-7), then to the previous file.
        if kind == .board {
            Task { @MainActor in
                if (await command("back") as? Bool) == true { return }
                self.goBackInFiles()
            }
            return
        }
        goBackInFiles()
    }

    private func goBackInFiles() {
        guard let step = back.popLast() else { NSSound.beep(); return }
        Task { @MainActor in
            let here = await command("place") as? [String: Any]
            forward.append(Step(url: url, place: here))
            replace(with: step.url, place: step.place, heading: nil)
        }
    }

    @objc func goForward(_ sender: Any?) {
        guard let step = forward.popLast() else { NSSound.beep(); return }
        Task { @MainActor in
            let here = await command("place") as? [String: Any]
            back.append(Step(url: url, place: here))
            replace(with: step.url, place: step.place, heading: nil)
        }
    }

    // MARK: Link states and images

    private func resolveLinks(_ targets: [String]) {
        var map: [String: Any] = [:]
        for t in targets {
            switch index.resolve(t, from: url) {
            case let .note(u, _, _):
                map[t] = ["state": "ok", "hint": CloudFile.isDataless(u) ? String(localized: "Not downloaded")
                                                                          : u.path.replacingOccurrences(of: vault.root.path + "/", with: "")]
            case let .ambiguous(c): map[t] = ["state": "ambiguous", "hint": String(localized: "\(c.count) notes called \(t)")]
            case .missing: map[t] = ["state": "missing", "hint": String(localized: "No note called \(t)")]
            }
        }
        send(["type": "linkStatus", "map": map])
    }

    /// The file an image request names: a wiki embed by the index, a path beside the note.
    private func imageFile(_ req: String) -> URL? {
        if req.hasPrefix("wiki:") {
            if case let .note(u, _, _) = index.resolve(String(req.dropFirst(5)), from: url) { return u }
        } else if req.hasPrefix("path:") {
            let p = String(req.dropFirst(5))
            return p.hasPrefix("/") ? URL(fileURLWithPath: p) : url.deletingLastPathComponent().appendingPathComponent(p)
        }
        return nil
    }

    /// Checks image requests off the main thread (reads and decoding never block the window), then grants them.
    private func imageInfo(_ requests: [String]) {
        let root = vault.root.resolvingSymlinksInPath()
        let jobs = requests.map { ($0, imageFile($0)) }
        let allowed = outsideAllowed, generation = loadGeneration
        Task.detached(priority: .userInitiated) {
            let results = jobs.map { ($0.0, ImageProbe.check($0.1, root: root, allowed: allowed)) }
            await MainActor.run { [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                var map: [String: Any] = [:]
                for (req, result) in results {
                    switch result {
                    case .missing: map[req] = ["status": "missing"]
                    case let .outside(name): map[req] = ["status": "outside", "label": name]
                    case let .ok(grant, size):
                        var info: [String: Any] = ["status": "ok", "url": "linen-local://grant/\(self.local.grant(grant))"]
                        if let s = size {
                            let scale = min(1, Double(ImageCheck.maxEdge) / max(s.width, s.height))
                            info["width"] = Int(s.width * scale / 2)
                            info["height"] = Int(s.height * scale / 2)
                        }
                        map[req] = info
                    }
                }
                self.send(["type": "imageInfo", "map": map])
            }
        }
    }

    /// "Allow this file" (SAFE-2): a grant for exactly the file this image names, by device and inode, for this
    /// document while it is open.
    private func allowOutside(_ req: String) {
        guard let f = imageFile(req)?.standardizedFileURL.resolvingSymlinksInPath(), let o = SafeOpen.openOutside(path: f.path) else { NSSound.beep(); return }
        outsideAllowed[f.path] = FileID(device: o.device, inode: o.inode)
        Darwin.close(o.fd)
        reloadKeepingPlace()
    }

    /// A clicked image opens in its app, through the same gate as links (SAFE-4): asked outside the vault or when
    /// the "image" is really something that can run programs.
    private func showImage(_ src: String) {
        guard let f = imageFile(src) else { return }
        openLocalFile(f, newTab: false, place: nil, heading: nil)
    }

    // MARK: File states (OPEN-2, OPEN-8)

    /// A file that went away: its disk is gone, or the file is.
    static func goneState(for url: URL) -> FileState {
        let parts = url.pathComponents
        if parts.count > 2, parts[1] == "Volumes", !FileManager.default.fileExists(atPath: "/Volumes/" + parts[2]) { return .disconnected }
        return .missing
    }

    private func showState(_ state: FileState) {
        guard fileState != state, let content = window?.contentView else { return }
        stateOverlay?.removeFromSuperview()
        fileState = state
        let view = NSHostingView(rootView: LinenScreen {
            FileStateView(state: state, path: self.url.path, primary: { [weak self] in self?.statePrimary() }, close: { [weak self] in self?.close() })
        })
        view.frame = content.bounds
        view.autoresizingMask = [.width, .height]
        content.addSubview(view)
        stateOverlay = view
        if state == .disconnected {
            // The disk may come back: look for it every 2 s and read the file again when it does.
            pollState(every: 2) { [weak self] in
                guard let self, FileManager.default.fileExists(atPath: self.url.path) else { return false }
                self.recover()
                return true
            }
        } else if state == .denied || state == .unreadable {
            // Permission can arrive later (System Settings, chmod) without touching the file: try again every 2 s.
            pollState(every: 2) { [weak self] in
                guard let self else { return true }
                let fd = Darwin.open(self.url.path, O_RDONLY | O_CLOEXEC)
                guard fd >= 0 else { return false }
                Darwin.close(fd)
                self.recover()
                return true
            }
        }
    }

    /// The file is reachable again: the vault (found while it was not) is found again, then the file is read.
    private func recover() {
        clearState()
        vault = VaultLocator.vault(for: url)
        index = Library.shared.index(for: vault)
        updateTitle(nil)
        startWatching()
    }

    private func clearState() {
        stateOverlay?.removeFromSuperview()
        stateOverlay = nil
        fileState = nil
    }

    private func statePrimary() {
        switch fileState {
        case .missing: NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
        case .denied:
            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") { NSWorkspace.shared.open(u) }
        case .unreadable: NSWorkspace.shared.activateFileViewerSelecting([url])
        default: break
        }
    }

    /// Repeats `check` until it returns true or the tab closes.
    private func pollState(every seconds: TimeInterval, _ check: @escaping @MainActor () -> Bool) {
        stopStateTimer()
        stateTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] t in
            let done = MainActor.assumeIsolated { self == nil || check() }
            if done { t.invalidate() }
        }
    }

    private func stopStateTimer() {
        stateTimer?.invalidate()
        stateTimer = nil
    }

    // MARK: Text encoding (OPEN-6)

    var encodingChoice: String.Encoding? { EncodingChoice.stored(for: url) }

    @objc func chooseEncoding(_ sender: NSMenuItem) {
        let chosen = (sender.representedObject as? UInt).map { String.Encoding(rawValue: $0) }
        EncodingChoice.store(chosen, for: url)
        // Re-reading in another encoding is not an edit: no change marks against the old reading.
        Library.shared.baselines.remove(forKey: FileKey.make(for: url))
        encoding = nil
        guard let data = rawData else { return }
        let decoded = TextDecoder.decode(data, override: chosen)
        encoding = decoded.encoding
        encodingNote = decoded.encoding == .utf8 ? nil : EncodingChoice.name(of: decoded.encoding)
        text = decoded.text
        reloadKeepingPlace()
    }

    // MARK: Title (TAB-3)

    private func updateTitle(_ title: String?) {
        guard let window else { return }
        let name = url.deletingPathExtension().lastPathComponent
        window.title = (title?.isEmpty == false ? title! : name)
        let folder = url.deletingLastPathComponent()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        window.subtitle = folder.path.hasPrefix(vault.root.path + "/") ? String(folder.path.dropFirst(vault.root.path.count + 1))
            : (folder.path == vault.root.path ? vault.root.lastPathComponent : folder.path.replacingOccurrences(of: home, with: "~"))
        window.representedURL = url
        window.tab.title = window.title
    }

    // MARK: Menu actions

    @objc func showFind(_ sender: Any?) { if kind == .page { findInPage(backwards: false, ask: true) } else { Task { _ = await command("find") } } }
    @objc func findNextMatch(_ sender: Any?) { if kind == .page { findInPage(backwards: false, ask: false) } else { Task { _ = await command("findNext") } } }
    @objc func findPreviousMatch(_ sender: Any?) { if kind == .page { findInPage(backwards: true, ask: false) } else { Task { _ = await command("findPrevious") } } }
    @objc func findSelection(_ sender: Any?) { Task { _ = await command("findSelection") } }
    @objc func nextChange(_ sender: Any?) { Task { if (await command("nextChange") as? Bool) != true { NSSound.beep() } } }
    @objc func previousChange(_ sender: Any?) { Task { if (await command("previousChange") as? Bool) != true { NSSound.beep() } } }
    @objc func showProperties(_ sender: Any?) { Task { _ = await command("properties") } }
    @objc func toggleOutline(_ sender: Any?) {
        outlineShown.toggle()
        Settings.outlineShown = outlineShown
        applyOutline()
    }

    private func applyOutline() {
        let width = window?.contentView?.bounds.width ?? 1180
        send(["type": "command", "name": "outline", "show": outlineShown, "overlay": width < 220 + 640 + 80])
    }

    // On a board ⌘+ and ⌘− zoom the board, ⌘0 fits it and ⌘1 shows it at 100 percent (BRD-7); on a note they set text size.
    @objc func zoomIn(_ sender: Any?) { kind == .board ? boardCommand("zoomIn") : setZoom(zoom + 0.1) }
    @objc func zoomOut(_ sender: Any?) { kind == .board ? boardCommand("zoomOut") : setZoom(zoom - 0.1) }
    @objc func zoomReset(_ sender: Any?) { kind == .board ? boardCommand("fit") : setZoom(Settings.defaultZoom) }
    @objc func zoomActual(_ sender: Any?) { boardCommand("zoom100") }
    @objc func toggleList(_ sender: Any?) { boardCommand("toggleList") }
    private func boardCommand(_ name: String) { Task { _ = await command(name) } }
    private func setZoom(_ z: Double) {
        zoom = min(2.0, max(0.7, (z * 10).rounded() / 10))
        web?.pageZoom = zoom
        Task { if let p = await command("place") as? [String: Any] { storePlace(p) } }
    }

    @objc func reloadDocument(_ sender: Any?) { if kind == .page { pageController?.reload() } else { startWatching() } }
    @objc func revealInFinder(_ sender: Any?) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    @objc func openInEditor(_ sender: Any?) { Editors.open(url, vault: vault) }

    @objc func copyReference(_ sender: Any?) {
        Task { @MainActor in
            // A board builds its own reference (BRD-26: path#id, the line range, its sidecar key and its text).
            if kind == .board {
                guard let r = await command("copyReference", ["refPath": Self.referencePath(for: url)]) as? [String: Any], let t = r["text"] as? String else { NSSound.beep(); return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(t, forType: .string)
                return
            }
            guard let r = await command("copyReference") as? [String: Any], let start = r["start"] as? Int, let end = r["end"] as? Int else { NSSound.beep(); return }
            let lines = text.components(separatedBy: "\n")
            let lo = max(1, start), hi = min(lines.count, max(start, end))
            guard lo <= hi else { NSSound.beep(); return }
            let quoted = lines[(lo - 1)..<hi].map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }.joined(separator: "\n")
            let ref = "\(Self.referencePath(for: url)):\(lo == hi ? "\(lo)" : "\(lo)-\(hi)")"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("\(ref)\n```\n\(quoted)\n```\n", forType: .string)
        }
    }

    /// The path an agent understands: relative to the git root inside a repository, else ~/-relative (READ-6).
    static func referencePath(for url: URL) -> String {
        var dir = url.deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) { return String(url.path.dropFirst(dir.path.count + 1)) }
            dir = dir.deletingLastPathComponent()
        }
        return url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    @objc func printDocument(_ sender: Any?) {
        if kind == .page, let window, let op = pageController?.printOperation(with: NSPrintInfo.shared) {
            op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
            return
        }
        guard let window, let web else { return }
        Task { @MainActor in
            let info = await command("prepareForPrint") as? [String: Any]
            Printer.print(web: web, window: window, title: info?["title"] as? String ?? window.title,
                          headings: (info?["headings"] as? [[String: Any]]) ?? [])
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        // Page tabs first: the note-only commands are off there, never silently doing nothing.
        if kind == .page {
            switch item.action {
            case #selector(toggleOutline(_:)), #selector(copyReference(_:)), #selector(zoomIn(_:)), #selector(zoomOut(_:)),
                 #selector(zoomReset(_:)), #selector(zoomActual(_:)), #selector(toggleList(_:)), #selector(findSelection(_:)),
                 #selector(showProperties(_:)), #selector(chooseEncoding(_:)), #selector(nextChange(_:)), #selector(previousChange(_:)):
                return false
            default: break
            }
        }
        switch item.action {
        case #selector(goBack(_:)): return !back.isEmpty || kind == .board
        case #selector(goForward(_:)): return !forward.isEmpty
        case #selector(toggleOutline(_:)):
            item.title = outlineShown ? String(localized: "Hide Outline") : String(localized: "Show Outline")
            return true
        case #selector(chooseEncoding(_:)):
            let mine = (item.representedObject as? UInt).map { String.Encoding(rawValue: $0) }
            item.state = mine == encodingChoice ? .on : .off
            return rawData != nil && kind == .note
        case #selector(zoomActual(_:)), #selector(toggleList(_:)):
            return kind == .board
        case #selector(togglePageScripts(_:)):
            item.title = pageController?.scriptsOn == true ? String(localized: "Turn Off Page Scripts") : String(localized: "Run Page Scripts")
            return kind == .page
        case #selector(toggleOutline(_:)) where kind == .page, #selector(copyReference(_:)) where kind == .page,
             #selector(zoomIn(_:)) where kind == .page, #selector(zoomOut(_:)) where kind == .page, #selector(zoomReset(_:)) where kind == .page:
            return false
        case #selector(zoomIn(_:)):
            item.title = kind == .board ? String(localized: "Zoom In") : String(localized: "Larger Text")
            return true
        case #selector(zoomOut(_:)):
            item.title = kind == .board ? String(localized: "Zoom Out") : String(localized: "Smaller Text")
            return true
        case #selector(zoomReset(_:)):
            item.title = kind == .board ? String(localized: "Zoom to Fit") : String(localized: "Actual Size")
            return true
        case #selector(showProperties(_:)):
            return kind == .note
        default: return true
        }
    }

    // MARK: Window

    func windowDidBecomeKey(_ notification: Notification) {
        build()
        send(["type": "focus", "key": true])
        keepTabBarVisible()
        NowState.changed()
    }

    func windowDidResignKey(_ notification: Notification) {
        send(["type": "focus", "key": false])
        Task { if let p = await command("place") as? [String: Any] { storePlace(p) } }
    }

    func windowDidResize(_ notification: Notification) { if outlineShown { applyOutline() } }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window else { return }
        if window.occlusionState.contains(.visible) {
            hiddenSince = nil
            if !built { build() }
        } else {
            hiddenSince = Date()
            let since = hiddenSince
            // Idle background tabs unload after 10 minutes, keeping their place (section 9).
            DispatchQueue.main.asyncAfter(deadline: .now() + 600) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.hiddenSince == since, since != nil else { return }
                    self.unload()
                }
            }
        }
    }

    private func unload() {
        guard built else { return }
        // An idle page tab lets its page go too: its scripts, watchdog and web content process (built again on return).
        if kind == .page {
            pageWatch?.invalidate()
            pageWatch = nil
            pageController?.close()
            pageController?.view.removeFromSuperview()
            pageController = nil
            built = false
            return
        }
        Task { @MainActor in
            if let p = await command("place") as? [String: Any] { storePlace(p) }
            watcher?.stop()
            watcher = nil
            sidecarWatcher?.stop()
            sidecarWatcher = nil
            remote.close()
            web?.removeFromSuperview()
            web = nil
            built = false
            pageReady = false
            haveContent = false
        }
    }

    func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            if let p = await command("place") as? [String: Any] { storePlace(p) }
            Library.shared.flush()
        }
        watcher?.stop()
        watcher = nil
        sidecarWatcher?.stop()
        sidecarWatcher = nil
        stopStateTimer()
        remote.close()
        pageWatch?.invalidate()
        pageWatch = nil
        pageController?.close()
        pageController = nil
        onClose?(self)
        NowState.changed()
    }

    private func keepTabBarVisible() {
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window, window.isVisible, window.tabbedWindows == nil else { return }
            window.toggleTabBar(nil)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        Log.write("page failed to load: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        Log.write("page failed: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Log.write("web content process ended; reloading")
        // The page reloads once, at the same place, and says so (SAFE-5).
        pageReady = false
        pendingPlace = nil
        webView.reload()
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let u = action.request.url else { return .cancel }
        return u.scheme == "linen-app" ? .allow : .cancel
    }

    // MARK: Toolbar

    private static let backItem = NSToolbarItem.Identifier("back"), forwardItem = NSToolbarItem.Identifier("forward"),
                      outlineItem = NSToolbarItem.Identifier("outline"), findItem = NSToolbarItem.Identifier("find"),
                      sizeItem = NSToolbarItem.Identifier("size"), editorItem = NSToolbarItem.Identifier("editor"),
                      shareItem = NSToolbarItem.Identifier("share")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.backItem, Self.forwardItem, Self.outlineItem, .flexibleSpace, Self.findItem, Self.sizeItem, Self.editorItem, Self.shareItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func item(_ label: String, _ symbol: String, _ action: Selector) -> NSToolbarItem {
            let i = NSToolbarItem(itemIdentifier: id)
            i.label = label
            i.toolTip = label
            i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            i.target = self
            i.action = action
            i.isBordered = true
            return i
        }
        switch id {
        case Self.backItem: return item(String(localized: "Back"), "chevron.backward", #selector(goBack(_:)))
        case Self.forwardItem: return item(String(localized: "Forward"), "chevron.forward", #selector(goForward(_:)))
        case Self.outlineItem: return item(String(localized: "Outline"), "sidebar.leading", #selector(toggleOutline(_:)))
        case Self.findItem: return item(String(localized: "Find"), "magnifyingglass", #selector(showFind(_:)))
        case Self.sizeItem:
            let group = NSToolbarItemGroup(itemIdentifier: id, images: [NSImage(systemSymbolName: "textformat.size.smaller", accessibilityDescription: nil)!,
                                                                     NSImage(systemSymbolName: "textformat.size.larger", accessibilityDescription: nil)!],
                                           selectionMode: .momentary, labels: [String(localized: "Smaller"), String(localized: "Larger")], target: self, action: #selector(sizeGroup(_:)))
            group.label = String(localized: "Text Size")
            return group
        case Self.editorItem: return item(String(localized: "Open in Editor"), "square.and.pencil", #selector(openInEditor(_:)))
        case Self.shareItem:
            let s = NSSharingServicePickerToolbarItem(itemIdentifier: id)
            s.delegate = ShareDelegate.shared
            ShareDelegate.shared.current = { [weak self] in self.map { [$0.url] } ?? [] }
            return s
        default: return nil
        }
    }

    @objc private func sizeGroup(_ sender: NSToolbarItemGroup) {
        sender.selectedIndex == 0 ? zoomOut(nil) : zoomIn(nil)
    }
}

/// A value crossing to and from the page: plain JSON types, handled on the main actor only.
struct PageValue: @unchecked Sendable {
    let value: Any?
    init(_ v: Any?) { value = v }
}

/// Keeps the page from retaining its window controller.
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: DocumentWindow?
    init(_ t: DocumentWindow) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { target?.received(message.body) }
    }
}

@MainActor
final class ShareDelegate: NSObject, NSSharingServicePickerToolbarItemDelegate {
    static let shared = ShareDelegate()
    var current: () -> [Any] = { [] }
    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] { current() }
}

/// Why a tab shows no page (OPEN-2, OPEN-8).
enum FileState: Equatable {
    case missing, denied, disconnected, unreadable, downloading
}

/// The page shown instead of a document that cannot be read: gone, refused, on a missing disk, or downloading.
struct FileStateView: View {
    let state: FileState
    let path: String
    let primary: () -> Void
    let close: () -> Void
    @Environment(\.palette) private var palette

    private var title: LocalizedStringKey {
        switch state {
        case .missing: "This file is no longer here"
        case .denied: "Linen needs permission to read this folder"
        case .disconnected: "The disk holding this file is not connected"
        case .unreadable: "Linen could not read this file"
        case .downloading: "Downloading from iCloud"
        }
    }

    private var action: LocalizedStringKey? {
        switch state {
        case .missing: "Reveal Folder"
        case .denied: "Open System Settings"
        case .unreadable: "Reveal in Finder"
        case .disconnected, .downloading: nil
        }
    }

    var body: some View {
        ZStack {
            WeaveBackground()
            VStack(spacing: 14) {
                if state == .downloading {
                    WeaveIndicator().frame(width: 64, height: 28)
                } else {
                    LinenMark().stroke(palette.head, style: StrokeStyle(lineWidth: 2.4, lineCap: .round)).frame(width: 64, height: 28)
                }
                Text(title).font(Tok.serif(34)).foregroundStyle(palette.head).multilineTextAlignment(.center)
                Text(path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                    .font(Tok.sans(14)).foregroundStyle(palette.text).lineLimit(2).multilineTextAlignment(.center)
                if state == .disconnected {
                    Text("Linen opens it again when the disk is back.").font(Tok.sans(14)).foregroundStyle(palette.text)
                }
                HStack(spacing: 10) {
                    if let action { Button(action, action: primary).buttonStyle(LoomButtonStyle(kind: .fill)) }
                    Button("Close", action: close).buttonStyle(LoomButtonStyle(kind: action == nil ? .fill : .line))
                }
                .padding(.top, 6)
            }
            .padding(40)
        }
    }
}

/// Per-file text encoding choices (OPEN-6, View > Text Encoding), remembered by path.
enum EncodingChoice {
    static let choices: [(String, String.Encoding?)] = [
        (String(localized: "Automatic"), nil), ("UTF-8", .utf8), ("UTF-16", .utf16),
        (String(localized: "Arabic (Windows-1256)"), TextDecoder.windowsArabic), (String(localized: "Western (Windows-1252)"), .windowsCP1252),
    ]
    private static let key = "encodingOverrides"

    static func stored(for url: URL) -> String.Encoding? {
        let all = UserDefaults.standard.dictionary(forKey: key) as? [String: UInt] ?? [:]
        return all[url.standardizedFileURL.path].map { String.Encoding(rawValue: $0) }
    }

    static func store(_ encoding: String.Encoding?, for url: URL) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: UInt] ?? [:]
        all[url.standardizedFileURL.path] = encoding?.rawValue
        UserDefaults.standard.set(all, forKey: key)
    }

    static func name(of e: String.Encoding) -> String {
        switch e {
        case TextDecoder.windowsArabic: String(localized: "Arabic (Windows-1256)")
        case .windowsCP1252: String(localized: "Western (Windows-1252)")
        case .utf16, .utf16LittleEndian, .utf16BigEndian: "UTF-16"
        case .utf8: "UTF-8"
        default: e.description
        }
    }
}
