import Foundation

/// Whether a page's scripts run (PAGE-7): a per-file choice wins, else a trusted folder turns them on, else they
/// are off. The trusted folders are `TrustedFolders` (Settings > Pages); the per-file choices ("Run this page",
/// View > Run Page Scripts) live here.
enum PagePolicy {
    static let perFileKey = "pageScriptsPerFile"

    enum Source: Equatable, Sendable {
        case root(String)
        case file
        case untrusted

        /// The manifest's form (SYNC-4): `root:<path>`, `file` or `untrusted`.
        var manifestValue: String {
            switch self {
            case let .root(p): "root:\(p)"
            case .file: "file"
            case .untrusted: "untrusted"
            }
        }
    }

    static func key(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    static func perFile(_ url: URL) -> Bool? {
        (UserDefaults.standard.dictionary(forKey: perFileKey) as? [String: Bool])?[key(url)]
    }

    static func setPerFile(_ url: URL, _ on: Bool?) { setPerFile(canonical: key(url), on) }

    static func setPerFile(canonical p: String, _ on: Bool?) {
        var all = (UserDefaults.standard.dictionary(forKey: perFileKey) as? [String: Bool]) ?? [:]
        all[p] = on
        UserDefaults.standard.set(all, forKey: perFileKey)
    }

    /// The page's own policy, before the self-test and a session's Stop (the controller applies those).
    static func effective(for url: URL) -> (on: Bool, source: Source) { effective(canonical: key(url)) }

    /// The same for a path already resolved once, when the page was opened: it is never resolved again, so swapping a
    /// folder for a link to a trusted one cannot lend this page that folder's trust (Codex verification 2).
    static func effective(canonical p: String) -> (on: Bool, source: Source) {
        if let v = (UserDefaults.standard.dictionary(forKey: perFileKey) as? [String: Bool])?[p] { return (v, .file) }
        if let root = TrustedFolders.all.first(where: { p.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) { return (true, .root(root)) }
        return (false, .untrusted)
    }
}

/// Where a link from a page may go (PAGE-11), decided only for clicks the isolated world saw as real (PAGE-8):
/// web addresses after Linen shows the full address and asks, every time; notes, boards and pages in the page's
/// own folder in Linen; everything else refused with one line naming it. Never SAFE-4's general routes.
enum PageLinks {
    enum Decision: Equatable {
        case inPage
        case openInLinen(URL)
        case ask(URL)
        case refuse(String)
    }

    static let readable: Set<String> = ["md", "markdown", "mdown", "mkd", "txt", "canvas", "html", "htm"]

    @MainActor
    static func decide(_ href: String, scheme: PageScheme) -> Decision {
        guard let u = URL(string: href), let s = u.scheme?.lowercased() else { return .refuse(String(href.prefix(80))) }
        switch s {
        case "http", "https":
            return .ask(u)
        case PageSeal.pageScheme:
            let (rel, reason) = scheme.relativePath(of: u)
            guard let rel else { return .refuse(reason == "another host" ? u.absoluteString : "a file outside this page's folder") }
            if rel == scheme.pagePath { return .inPage }
            let ext = (rel as NSString).pathExtension.lowercased()
            guard readable.contains(ext), scheme.virtualFiles == nil else { return .refuse((rel as NSString).lastPathComponent) }
            // Opened from the pinned folder, then handed on by where the kernel says the file is, so a symlink
            // changed after this check cannot redirect the open (Codex m9 review, item 6).
            guard let o = scheme.pinned?.open(rel) else { return .refuse((rel as NSString).lastPathComponent) }
            defer { close(o.fd) }
            guard let real = PinnedFolder.realPath(of: o.fd) else { return .refuse((rel as NSString).lastPathComponent) }
            // The link's name passed; the file it really is must pass too (a symlinked .md to a .command does not).
            guard readable.contains((real as NSString).pathExtension.lowercased()) else { return .refuse((real as NSString).lastPathComponent) }
            return .openInLinen(URL(fileURLWithPath: real))
        case "javascript":
            // The page's own script, run by WebKit in the page when scripts are on; nothing leaves.
            return .inPage
        case "about", "blob", "data":
            return .refuse("\(s):")
        default:
            return .refuse(s == "file" ? (u.lastPathComponent.isEmpty ? "a file" : u.lastPathComponent) : "\(s):")
        }
    }
}
