import AppKit
import LinenKit

/// Everything documents share: the stores, the vault indexes, settings and recent files.
@MainActor
final class Library {
    static let shared = Library()

    let support: URL
    let places: PlaceStore
    let baselines: BaselineStore
    let sessions: SessionStore
    private let indexes = VaultIndexCache()

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(Self.folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        support = base
        places = PlaceStore(directory: base)
        baselines = BaselineStore(directory: base)
        sessions = SessionStore(directory: base)
    }

    /// "Linen". A debug build copied under another bundle identifier (a test copy run beside Hatim's Linen) keeps its
    /// session, places and reader state in its own folder, so it never restores or overwrites his.
    static var folderName: String {
        #if DEBUG
        if let id = Bundle.main.bundleIdentifier, id != "com.hatim.linen" { return "Linen Lab" }
        #endif
        return "Linen"
    }

    /// The index of a vault for a lookup that does not outlive the caller (Open Quickly, Keep on iPhone): the one a
    /// document uses, else one built in the background that goes when the caller drops it.
    func index(for vault: Vault) -> VaultIndex {
        indexes.index(for: vault)
    }

    /// The index for a tab that shows a file in `vault`, built in the background on first use and kept current from
    /// the tab's file events. Balance every call with `stopUsing(_:)`.
    func useIndex(for vault: Vault) -> VaultIndex {
        indexes.acquire(vault)
    }

    /// A tab no longer uses `index`. When it was the last, the index stays for a quick reopen until another index is
    /// let go or 10 minutes pass, as idle background tabs unload (section 9).
    func stopUsing(_ index: VaultIndex) {
        guard indexes.release(index) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 601) { [weak self] in
            MainActor.assumeIsolated { self?.indexes.dropKept(olderThan: 600) }
        }
    }

    func flush() {
        places.flush()
        baselines.flush()
        sessions.flush()
    }

    // MARK: Recent files (OPEN-4)

    private let recentKey = "recentFiles"
    var recent: [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: recentKey) ?? []
        return paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func noteOpened(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: recentKey) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(12)), forKey: recentKey)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }
}

/// Settings (SYS-1), stored in user defaults.
enum Settings {
    static var appearance: String { UserDefaults.standard.string(forKey: "appearance") ?? "system" }
    static var face: String { UserDefaults.standard.string(forKey: "bodyFace") ?? "sans" }
    /// The note column's width (READ-11): "reading" (the default), "wide" or "full".
    static var textWidth: String {
        let v = UserDefaults.standard.string(forKey: "textWidth") ?? "reading"
        return ["reading", "wide", "full"].contains(v) ? v : "reading"
    }
    static var defaultZoom: Double { let v = UserDefaults.standard.double(forKey: "defaultZoom"); return v > 0 ? v : 1 }
    static var editorBundleID: String? { UserDefaults.standard.string(forKey: "editorBundleID") }
    static var remoteImagesAlways: Bool { UserDefaults.standard.bool(forKey: "remoteImagesAlways") }
    /// Find folds Arabic letter forms unless the reader turns it off in the find bar (READ-3).
    static var foldArabic: Bool {
        get { UserDefaults.standard.object(forKey: "foldArabic") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "foldArabic") }
    }
    static var outlineShown: Bool {
        get { UserDefaults.standard.object(forKey: "outlineShown") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "outlineShown") }
    }

    /// The theme for the page: Paper, Night, or the system's look.
    static func theme(for appearance: NSAppearance?) -> String {
        switch Self.appearance {
        case "paper": return "paper"
        case "night": return "night"
        default: return appearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "night" : "paper"
        }
    }

    static var interfaceIsArabic: Bool { Locale.preferredLanguages.first?.hasPrefix("ar") ?? false }
}
