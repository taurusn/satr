import AppKit

/// Linen's menus (PRD 6.1 to 6.7), with the keys of section 14: ⌘P prints, ⇧⌘O is Open Quickly, ⌘I shows
/// properties, ⌃⌘S the outline, ⇧⌘E opens the editor, ⌥⌘C copies a reference.
@MainActor
enum Menus {
    static let recentID = NSUserInterfaceItemIdentifier("recent")

    static func make(target app: AppDelegate) -> NSMenu {
        let main = NSMenu()

        let appMenu = submenu(main, "Linen")
        appMenu.addItem(withTitle: String(localized: "About Linen"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        add(appMenu, String(localized: "Settings…"), #selector(AppDelegate.showSettings(_:)), ",", target: app)
        add(appMenu, String(localized: "Make Linen the Default Reader…"), #selector(AppDelegate.makeDefaultReader(_:)), "", target: app)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Hide Linen"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        add(appMenu, String(localized: "Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        appMenu.addItem(withTitle: String(localized: "Show All"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Quit Linen"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(main, String(localized: "File"))
        add(file, String(localized: "New Tab…"), #selector(AppDelegate.newTab(_:)), "t", target: app)
        add(file, String(localized: "Open…"), #selector(AppDelegate.openDocument(_:)), "o", target: app)
        add(file, String(localized: "Open Quickly…"), #selector(AppDelegate.showOpenQuickly(_:)), "o", [.command, .shift], target: app)
        let recentItem = NSMenuItem(title: String(localized: "Open Recent"), action: nil, keyEquivalent: "")
        let recent = NSMenu(title: String(localized: "Open Recent"))
        recent.identifier = recentID
        recent.delegate = app
        recentItem.submenu = recent
        file.addItem(recentItem)
        file.addItem(.separator())
        add(file, String(localized: "Close Tab"), #selector(NSWindow.performClose(_:)), "w")
        file.addItem(.separator())
        add(file, String(localized: "Open in Editor"), #selector(DocumentWindow.openInEditor(_:)), "e", [.command, .shift])
        add(file, String(localized: "Reveal in Finder"), #selector(DocumentWindow.revealInFinder(_:)), "r", [.command, .shift])
        file.addItem(.separator())
        add(file, String(localized: "Page Setup…"), #selector(NSApplication.runPageLayout(_:)), "p", [.command, .shift])
        add(file, String(localized: "Print…"), #selector(DocumentWindow.printDocument(_:)), "p")

        let edit = submenu(main, String(localized: "Edit"))
        edit.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        add(edit, String(localized: "Copy Reference"), #selector(DocumentWindow.copyReference(_:)), "c", [.command, .option])
        edit.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let findItem = NSMenuItem(title: String(localized: "Find"), action: nil, keyEquivalent: "")
        let find = NSMenu(title: String(localized: "Find"))
        add(find, String(localized: "Find…"), #selector(DocumentWindow.showFind(_:)), "f")
        add(find, String(localized: "Find Next"), #selector(DocumentWindow.findNextMatch(_:)), "g")
        add(find, String(localized: "Find Previous"), #selector(DocumentWindow.findPreviousMatch(_:)), "g", [.command, .shift])
        add(find, String(localized: "Use Selection for Find"), #selector(DocumentWindow.findSelection(_:)), "e")
        findItem.submenu = find
        edit.addItem(findItem)

        let view = submenu(main, String(localized: "View"))
        add(view, String(localized: "Show Outline"), #selector(DocumentWindow.toggleOutline(_:)), "s", [.command, .control])
        add(view, String(localized: "Show Properties"), #selector(DocumentWindow.showProperties(_:)), "i")
        view.addItem(.separator())
        add(view, String(localized: "Larger Text"), #selector(DocumentWindow.zoomIn(_:)), "+")
        add(view, String(localized: "Larger Text"), #selector(DocumentWindow.zoomIn(_:)), "=").isAlternate = false
        view.items.last?.isHidden = true
        add(view, String(localized: "Smaller Text"), #selector(DocumentWindow.zoomOut(_:)), "-")
        add(view, String(localized: "Actual Size"), #selector(DocumentWindow.zoomReset(_:)), "0")
        view.addItem(.separator())
        let encodingItem = NSMenuItem(title: String(localized: "Text Encoding"), action: nil, keyEquivalent: "")
        let encodings = NSMenu(title: String(localized: "Text Encoding"))
        for (i, (name, encoding)) in EncodingChoice.choices.enumerated() {
            let item = encodings.addItem(withTitle: name, action: #selector(DocumentWindow.chooseEncoding(_:)), keyEquivalent: "")
            item.representedObject = encoding?.rawValue
            if i == 0 { encodings.addItem(.separator()) }
        }
        encodingItem.submenu = encodings
        view.addItem(encodingItem)
        add(view, String(localized: "Reload"), #selector(DocumentWindow.reloadDocument(_:)), "r")
        view.addItem(.separator())
        add(view, String(localized: "Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])

        let go = submenu(main, String(localized: "Go"))
        add(go, String(localized: "Back"), #selector(DocumentWindow.goBack(_:)), "[")
        add(go, String(localized: "Forward"), #selector(DocumentWindow.goForward(_:)), "]")
        go.addItem(.separator())
        add(go, String(localized: "Next Change"), #selector(DocumentWindow.nextChange(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command, .option])
        add(go, String(localized: "Previous Change"), #selector(DocumentWindow.previousChange(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .option])

        let window = submenu(main, String(localized: "Window"))
        window.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: String(localized: "Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        add(window, String(localized: "Show Previous Tab"), #selector(NSWindow.selectPreviousTab(_:)), "\t", [.control, .shift])
        add(window, String(localized: "Show Next Tab"), #selector(NSWindow.selectNextTab(_:)), "\t", [.control])
        window.addItem(withTitle: String(localized: "Move Tab to New Window"), action: #selector(NSWindow.moveTabToNewWindow(_:)), keyEquivalent: "")
        window.addItem(withTitle: String(localized: "Merge All Windows"), action: #selector(NSWindow.mergeAllWindows(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: String(localized: "Bring All to Front"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window
        return main
    }

    private static func submenu(_ main: NSMenu, _ title: String) -> NSMenu {
        let item = NSMenuItem()
        let menu = NSMenu(title: title)
        item.submenu = menu
        main.addItem(item)
        return menu
    }

    @discardableResult
    private static func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.target = target
        return item
    }
}
