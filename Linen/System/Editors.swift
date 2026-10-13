import AppKit
import CoreServices
import LinenKit
import UniformTypeIdentifiers

/// Open in Editor (EXP-2): the chosen editor, else Obsidian for vault notes, else the first other editor.
@MainActor
enum Editors {
    static func available() -> [(String, String)] {
        let type = UTType("net.daringfireball.markdown") ?? .plainText
        return NSWorkspace.shared.urlsForApplications(toOpen: type)
            .compactMap { url -> (String, String)? in
                guard let b = Bundle(url: url), let id = b.bundleIdentifier, id != Bundle.main.bundleIdentifier, id != "com.satr.reader" else { return nil }
                return (id, FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
            }
            .sorted { $0.1 < $1.1 }
    }

    static func open(_ file: URL, vault: Vault) {
        let ws = NSWorkspace.shared
        if let id = Settings.editorBundleID, !id.isEmpty, let app = ws.urlForApplication(withBundleIdentifier: id) {
            ws.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        if vault.kind == .obsidian, ws.urlForApplication(withBundleIdentifier: "md.obsidian") != nil {
            var c = URLComponents()
            c.scheme = "obsidian"
            c.host = "open"
            c.queryItems = [URLQueryItem(name: "path", value: file.path)]
            if let u = c.url { ws.open(u); return }
        }
        if let first = available().first, let app = ws.urlForApplication(withBundleIdentifier: first.0) {
            ws.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSSound.beep()
        }
    }
}

/// "Make Linen the Default Reader" (OPEN-1): only on request.
@MainActor
enum DefaultReader {
    static func make(includingPlainText: Bool) {
        let app = Bundle.main.bundleURL
        var types = [UTType("net.daringfireball.markdown")].compactMap { $0 }
        if includingPlainText { types.append(.plainText) }
        Task {
            for t in types { try? await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: t) }
        }
    }
}
