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
        for u in urls where DocumentWindow.isReadable(u) {
            if let d = open(u, besides: anchor) { anchor = d }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { documents.isEmpty ? showWelcome() : documents.first?.showWindow(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        saveSession()
        Library.shared.flush()
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
        panel.allowedContentTypes = ["md", "markdown", "mdown", "mkd", "txt"].compactMap { UTType(filenameExtension: $0) }
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

    private func settingsChanged() {
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

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
