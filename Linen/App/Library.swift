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
    private var indexes: [URL: VaultIndex] = [:]

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Linen", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        support = base
        places = PlaceStore(directory: base)
        baselines = BaselineStore(directory: base)
        sessions = SessionStore(directory: base)
    }

    /// The index of a vault, built in the background on first use and kept current from file events.
    func index(for vault: Vault) -> VaultIndex {
        if let i = indexes[vault.root] { return i }
        let i = VaultIndex(vault: vault)
        indexes[vault.root] = i
        Task.detached(priority: .utility) { await i.build() }
        return i
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
