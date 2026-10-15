import AppKit
import LinenKit
import SwiftUI
import UniformTypeIdentifiers

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var documents: [DocumentWindow] = []
    private var welcome: NSWindow?
    private var settingsWindow: NSWindow?
    private var quickPanel: NSPanel?
    private var restoring = false
    private var openedAtLaunch = false

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Menus.make(target: self)
        NSWindow.allowsAutomaticWindowTabbing = true
        // A fresh state for agents at once, so a previous run's file is never read as this one's (MCP-9).
        NowState.write(running: true)
        // The seal's self-test after any update of macOS or Linen; pages keep scripts off until it passes (PAGE-10).
        PageSelfTest.shared.runIfNeeded()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.openedAtLaunch { self.restoreSession() }
                if self.documents.isEmpty { self.showWelcome() }
            }
        }
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        openedAtLaunch = true
        var anchor = activeDocument
        for u in urls {
            if u.scheme == "linen" { openFromCommand(u); continue }
            guard u.isFileURL, DocumentWindow.isReadable(u) else { continue }
            if let d = open(u, besides: anchor) { anchor = d }
        }
    }

    /// `linen open` (CLI-6) arrives as `linen://open?path=/abs/file&node=id&line=12&focus=1`. It opens only what Linen
    /// reads, the same files a double-click would open, and takes focus only when asked: an agent's `linen open` must not
    /// pull Hatim out of the app he is in.
    private func openFromCommand(_ u: URL) {
        guard u.host == "open", let comps = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return }
        var q: [String: String] = [:]
        for item in comps.queryItems ?? [] where q[item.name] == nil { q[item.name] = item.value }
        guard let path = q["path"], path.hasPrefix("/") else { return }
        let file = URL(fileURLWithPath: path).standardizedFileURL
        // A regular file of a kind Linen reads, after links resolve: not a folder or a pipe that happens to end in .md.
        let real = file.resolvingSymlinksInPath()
        guard DocumentWindow.isReadable(real), (try? real.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return }
        let focus = q["focus"] == "1"
        let doc: DocumentWindow?
        if focus {
            doc = open(file, besides: activeDocument)
        } else {
            doc = open(file, besides: activeDocument, select: false)
            doc?.build()
            doc?.window?.orderFront(nil)
        }
        doc?.reveal(node: q["node"], line: q["line"].flatMap(Int.init))
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { documents.isEmpty ? showWelcome() : documents.first?.showWindow(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        saveSession()
        Library.shared.flush()
        NowState.write(running: false)
    }

    var activeDocument: DocumentWindow? { NSApp.keyWindow?.windowController as? DocumentWindow ?? documents.last }

    // MARK: Opening (OPEN-1)

    /// Opens a file in a new tab beside `anchor` (or brings its tab forward if it is already open).
    @discardableResult
    func open(_ url: URL, besides anchor: DocumentWindow? = nil, buildNow: Bool = true, select: Bool = true, allowMissing: Bool = false) -> DocumentWindow? {
        let target = url.standardizedFileURL
        if let existing = documents.first(where: { $0.url == target }) {
            if select { existing.window?.makeKeyAndOrderFront(nil) }
            return existing
        }
        guard allowMissing || FileManager.default.fileExists(atPath: target.path) else { return nil }
        welcome?.close()
        welcome = nil
        let doc = DocumentWindow(url: target, buildNow: buildNow)
        doc.onClose = { [weak self] d in self?.documents.removeAll { $0 === d }; self?.saveSession() }
        doc.onChange = { [weak self] in self?.saveSession() }
        documents.append(doc)
        if let anchorWindow = anchor?.window, let w = doc.window {
            anchorWindow.addTabbedWindow(w, ordered: .above)
        }
        if select {
            doc.showWindow(nil)
            doc.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        saveSession()
        return doc
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["md", "markdown", "mdown", "mkd", "txt", "canvas", "html", "htm"].compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK {
            var anchor = activeDocument
            for u in panel.urls { if let d = open(u, besides: anchor) { anchor = d } }
        }
    }

    @objc func newTab(_ sender: Any?) { openDocument(sender) }
    @objc func newWindowForTab(_ sender: Any?) { openDocument(sender) }

    @objc func openRecent(_ sender: NSMenuItem) {
        if let u = sender.representedObject as? URL { open(u, besides: activeDocument) }
    }

    // MARK: Session (OPEN-2)

    private func saveSession() {
        guard !restoring else { return }
        var groups: [[TabState]] = []
        var fronts: [Int] = []
        var seen = Set<ObjectIdentifier>()
        for d in documents {
            guard let w = d.window, !seen.contains(ObjectIdentifier(w)) else { continue }
            let tabs = (w.tabbedWindows ?? [w]).compactMap { $0.windowController as? DocumentWindow }
            for t in tabs { if let tw = t.window { seen.insert(ObjectIdentifier(tw)) } }
            // A file that is gone keeps its tab by path, so it comes back as "no longer here" (OPEN-2).
            let states = tabs.map { t in TabState(bookmark: FileIdentity.bookmark(for: t.url) ?? Data(), path: t.url.path) }
            if !states.isEmpty {
                groups.append(states)
                fronts.append(tabs.firstIndex { $0.window?.tabGroup?.selectedWindow === $0.window } ?? states.count - 1)
            }
        }
        Library.shared.sessions.save(Session(windows: groups, front: fronts))
    }

    private func restoreSession() {
        restoring = true
        defer { restoring = false; saveSession() }
        let session = Library.shared.sessions.session
        for (g, group) in session.windows.enumerated() {
            var anchor: DocumentWindow?
            var docs: [DocumentWindow] = []
            for tab in group {
                let url = FileIdentity.resolve(tab.bookmark)?.url ?? URL(fileURLWithPath: tab.path)
                // Tabs come back unbuilt and unselected; gone files come back too, showing their state.
                if let d = open(url, besides: anchor, buildNow: false, select: false, allowMissing: true) {
                    if anchor == nil { anchor = d }
                    docs.append(d)
                }
            }
            guard !docs.isEmpty else { continue }
            // Only the front tab is selected, so only it builds now; the others build on first selection (section 9).
            let front = docs[min(max(session.front?[safe: g] ?? docs.count - 1, 0), docs.count - 1)]
            front.window?.makeKeyAndOrderFront(nil)
            front.build()
        }
        if !documents.isEmpty { NSApp.activate() }
    }

    // MARK: Panels

    func showWelcome() {
        if let welcome { welcome.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.title = "Linen"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: LinenScreen { WelcomeView(open: { [weak self] in self?.openDocument(nil) },
                                                                          openURL: { [weak self] u in self?.open(u) }) })
        w.center()
        w.makeKeyAndOrderFront(nil)
        welcome = w
        NSApp.activate()
    }

    @objc func showSettings(_ sender: Any?) {
        if let settingsWindow { settingsWindow.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 470), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.title = String(localized: "Settings")
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: LinenScreen { SettingsView() })
        w.center()
        w.makeKeyAndOrderFront(nil)
        settingsWindow = w
    }

    @objc func showOpenQuickly(_ sender: Any?) {
        quickPanel?.close()
        let doc = activeDocument
        let index = doc.map { Library.shared.index(for: VaultLocator.vault(for: $0.url)) }
        let panel = OpenQuicklyPanel(index: index) { [weak self] url, newTab in
            guard let self else { return }
            if newTab || doc == nil { self.open(url, besides: doc) } else { doc?.navigate(to: url, newTab: false, place: nil, heading: nil) }
        }
        quickPanel = panel
        panel.present(over: doc?.window ?? NSApp.keyWindow)
    }

    /// Asks once, on request (OPEN-1): Markdown always, plain text only when Hatim ticks it.
    @objc func makeDefaultReader(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Make Linen the default reader for Markdown?")
        alert.informativeText = String(localized: "Markdown files will open in Linen when you double-click them.")
        let plain = NSButton(checkboxWithTitle: String(localized: "Also open plain text (.txt) files in Linen"), target: nil, action: nil)
        plain.state = .off
        alert.accessoryView = plain
        alert.addButton(withTitle: String(localized: "Make Default"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        DefaultReader.make(includingPlainText: plain.state == .on)
    }

    /// Links `~/.local/bin/linen` to the command inside this app (CLI-1), so agents can run `linen check`, `layout`, `shot`
    /// and `open`. A link, not a copy: it always runs the installed Linen's own renderer.
    @objc func installCommand(_ sender: Any?) {
        let tool = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/linen")
        let bin = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
        let link = bin.appendingPathComponent("linen")
        do {
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            // Only Linen's own link is ever replaced; a real file or folder at that name is someone else's and stays.
            var st = stat()
            if lstat(link.path, &st) == 0 {
                let isLink = (st.st_mode & S_IFMT) == S_IFLNK
                let target = isLink ? (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) : nil
                guard isLink, target?.hasSuffix("/Contents/Helpers/linen") == true else {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Something else is already called linen")
                    alert.informativeText = String(localized: "\(link.path) is not Linen's command, so Linen left it alone. Move it away and try again.")
                    alert.runModal()
                    return
                }
            }
            // A new link beside it, renamed over the old one in one step: there is never a moment without a command.
            let temp = bin.appendingPathComponent(".linen-\(UUID().uuidString)")
            try FileManager.default.createSymbolicLink(at: temp, withDestinationURL: tool)
            guard Darwin.rename(temp.path, link.path) == 0 else {
                try? FileManager.default.removeItem(at: temp)
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = String(localized: "Linen could not install the command")
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return
        }
        // Then the MCP server (MCP-2): shown first, added only to the agents that are installed.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let find = { (paths: [String]) in paths.first { FileManager.default.isExecutableFile(atPath: $0) } }
        let claude = find(["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"])
        let codex = find(["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex"])
        let alert = NSAlert()
        alert.messageText = String(localized: "The linen command is installed")
        var lines = [String(localized: "Linen can also add itself to your coding agents as an MCP server, so they can make boards, check them, see them as Linen draws them and open them for you:")]
        if claude != nil { lines.append("claude mcp add --scope user linen -- \(link.path) mcp") }
        if codex != nil { lines.append("codex mcp add linen -- \(link.path) mcp") }
        alert.informativeText = lines.joined(separator: "\n\n")
        let box = NSStackView()
        box.orientation = .vertical
        box.alignment = .leading
        let claudeBox = NSButton(checkboxWithTitle: String(localized: "Add Linen to Claude Code"), target: nil, action: nil)
        let codexBox = NSButton(checkboxWithTitle: String(localized: "Add Linen to Codex"), target: nil, action: nil)
        claudeBox.state = claude != nil ? .on : .off
        codexBox.state = codex != nil ? .on : .off
        if claude != nil { box.addArrangedSubview(claudeBox) }
        if codex != nil { box.addArrangedSubview(codexBox) }
        if claude != nil || codex != nil {
            box.frame = NSRect(x: 0, y: 0, width: 320, height: CGFloat(box.arrangedSubviews.count) * 24)
            alert.accessoryView = box
            alert.addButton(withTitle: String(localized: "Add"))
            alert.addButton(withTitle: String(localized: "Not Now"))
        } else {
            alert.informativeText = String(localized: "Agents can now run linen check, layout, shot, open and mcp.")
        }
        guard alert.runModal() == .alertFirstButtonReturn, claude != nil || codex != nil else { return }
        var jobs: [(String, [String], String)] = []
        if let claude, claudeBox.state == .on { jobs.append((claude, ["mcp", "add", "--scope", "user", "linen", "--", link.path, "mcp"], "Claude Code")) }
        if let codex, codexBox.state == .on { jobs.append((codex, ["mcp", "add", "linen", "--", link.path, "mcp"], "Codex")) }
        // Off the main thread, so a slow or chatty agent command never freezes Linen.
        Task.detached {
            var results: [String] = []
            for (exe, args, name) in jobs { results.append(AppDelegate.register(exe, args, name: name)) }
            let text = results.joined(separator: "\n")
            await MainActor.run {
                let done = NSAlert()
                done.messageText = String(localized: "Linen and your agents")
                done.informativeText = text
                done.runModal()
            }
        }
    }

    /// Runs an agent's own command to add Linen, reading its output while it runs and giving up after 20 seconds;
    /// "already exists" counts as done.
    nonisolated private static func register(_ exe: String, _ args: [String], name: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return "\(name): could not run (\(error.localizedDescription))" }
        // The output is drained on its own thread, and the wait is bounded no matter what the command or a child it
        // left behind does with the pipe: terminate at 20 s, kill at 23 s, stop waiting at 25 s.
        let collected = OutputBox()
        let reader = Thread {
            let d = pipe.fileHandleForReading.readDataToEndOfFile()
            collected.set(d)
        }
        reader.start()
        let pid = p.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 23) { if p.isRunning { kill(pid, SIGKILL) } }
        let deadline = Date().addingTimeInterval(25)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if p.isRunning { return "\(name): did not finish in 25 s; run the command yourself" }
        let out = String(decoding: collected.wait(until: Date().addingTimeInterval(2)) ?? Data(), as: UTF8.self)
        if p.terminationStatus == 0 { return "\(name): added" }
        if out.localizedCaseInsensitiveContains("already") { return "\(name): already added" }
        return "\(name): \(out.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))"
    }

    private func settingsChanged() {
        for d in documents where d.pageController != nil { d.applyPageTheme() }
        for d in documents where d.web != nil {
            d.send(["type": "settings", "theme": Settings.theme(for: d.window?.effectiveAppearance ?? NSApp.effectiveAppearance), "face": Settings.face])
            d.web.underPageBackgroundColor = Settings.theme(for: NSApp.effectiveAppearance) == "night" ? .linenInk2 : .linenPaper
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.identifier == Menus.recentID else { return }
        menu.removeAllItems()
        for u in Library.shared.recent {
            let item = NSMenuItem(title: u.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.representedObject = u
            item.target = self
            item.toolTip = u.path
            menu.addItem(item)
        }
        if menu.items.isEmpty { menu.addItem(withTitle: String(localized: "No Recent Files"), action: nil, keyEquivalent: "").isEnabled = false }
    }
}

extension AppDelegate: NSMenuDelegate {}

/// A command's output, handed from the thread that reads it to the one that waits, with a time limit.
final class OutputBox: @unchecked Sendable {
    private let lock = NSCondition()
    private var data: Data?
    func set(_ d: Data) { lock.lock(); data = d; lock.broadcast(); lock.unlock() }
    func wait(until limit: Date) -> Data? {
        lock.lock(); defer { lock.unlock() }
        while data == nil { if !lock.wait(until: limit) { break } }
        return data
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
