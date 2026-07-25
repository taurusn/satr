import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var documentWindows: [URL: DocumentWindowController] = [:]
    private var welcomeWindow: NSWindowController?
    private var welcomeWorkItem: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.documentWindows.isEmpty else { return }
            self.showWelcomeWindow()
        }
        welcomeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        welcomeWorkItem?.cancel()
        var openedAny = false

        for filename in filenames {
            let url = URL(fileURLWithPath: filename).standardizedFileURL
            guard Self.isMarkdown(url) else { continue }
            openDocument(url)
            openedAny = true
        }

        sender.reply(toOpenOrPrint: openedAny ? .success : .failure)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let controller = documentWindows.values.first {
                controller.showWindow(nil)
            } else {
                showWelcomeWindow()
            }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc func openDocumentAction(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Open Markdown"
        panel.prompt = "Open"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = Self.markdownTypes

        if panel.runModal() == .OK {
            for url in panel.urls where Self.isMarkdown(url) {
                openDocument(url)
            }
        }
    }

    func openDocument(_ url: URL) {
        let normalizedURL = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: normalizedURL.path) else {
            showMissingFileAlert(normalizedURL)
            return
        }

        welcomeWindow?.close()
        welcomeWindow = nil

        if let existing = documentWindows[normalizedURL] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        do {
            let controller = try DocumentWindowController(documentURL: normalizedURL) { [weak self] in
                self?.documentWindows.removeValue(forKey: normalizedURL)
            }
            documentWindows[normalizedURL] = controller
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Satr could not open this file"
            alert.runModal()
        }
    }

    @objc func increaseTextSize(_ sender: Any?) {
        activeDocumentController?.increaseTextSize(sender)
    }

    @objc func decreaseTextSize(_ sender: Any?) {
        activeDocumentController?.decreaseTextSize(sender)
    }

    @objc func resetTextSize(_ sender: Any?) {
        activeDocumentController?.resetTextSize(sender)
    }

    @objc func reloadDocument(_ sender: Any?) {
        activeDocumentController?.reloadDocument(sender)
    }

    @objc func revealDocument(_ sender: Any?) {
        activeDocumentController?.revealInFinder(sender)
    }

    private var activeDocumentController: DocumentWindowController? {
        NSApp.keyWindow?.windowController as? DocumentWindowController
    }

    private func showWelcomeWindow() {
        if let welcomeWindow {
            welcomeWindow.showWindow(nil)
            welcomeWindow.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let viewController = WelcomeViewController { [weak self] url in
            if let url {
                self?.openDocument(url)
            } else {
                self?.openDocumentAction(nil)
            }
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 470),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Satr"
        window.contentViewController = viewController
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = viewController

        let controller = NSWindowController(window: window)
        viewController.onWindowClose = { [weak self] in self?.welcomeWindow = nil }
        welcomeWindow = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func showMissingFileAlert(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "The Markdown file is unavailable"
        alert.informativeText = url.path
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func makeMainMenu() -> NSMenu {
        let menu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Satr")
        appMenu.addItem(withTitle: "About Satr", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Satr", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Satr", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let openItem = fileMenu.addItem(withTitle: "Open…", action: #selector(openDocumentAction(_:)), keyEquivalent: "o")
        openItem.target = self
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        menu.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let larger = viewMenu.addItem(withTitle: "Larger Text", action: #selector(increaseTextSize(_:)), keyEquivalent: "+")
        larger.target = self
        let smaller = viewMenu.addItem(withTitle: "Smaller Text", action: #selector(decreaseTextSize(_:)), keyEquivalent: "-")
        smaller.target = self
        let actual = viewMenu.addItem(withTitle: "Actual Size", action: #selector(resetTextSize(_:)), keyEquivalent: "0")
        actual.target = self
        viewMenu.addItem(.separator())
        let reload = viewMenu.addItem(withTitle: "Reload Document", action: #selector(reloadDocument(_:)), keyEquivalent: "r")
        reload.target = self
        let reveal = viewMenu.addItem(withTitle: "Reveal in Finder", action: #selector(revealDocument(_:)), keyEquivalent: "r")
        reveal.keyEquivalentModifierMask = [.command, .shift]
        reveal.target = self
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = viewMenu
        menu.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        return menu
    }

    private static let markdownTypes: [UTType] = {
        let extensions = ["md", "markdown", "mdown", "mkd"]
        return extensions.compactMap { UTType(filenameExtension: $0) }
    }()

    private static func isMarkdown(_ url: URL) -> Bool {
        ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased())
    }
}
