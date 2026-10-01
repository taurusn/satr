import Foundation

final class RecentDocuments {
    static let shared = RecentDocuments()
    static let didChange = Notification.Name("RecentDocumentsDidChange")

    private let defaults = UserDefaults.standard
    private let key = "RecentDocuments"
    private let limit = 10

    private var paths: [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    /// Recent files, most recent first, excluding files that no longer exist.
    var urls: [URL] {
        paths.filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    func note(_ url: URL) {
        let path = url.standardizedFileURL.path
        let existing = paths.filter { $0 != path && FileManager.default.fileExists(atPath: $0) }
        save([path] + existing)
    }

    func remove(_ url: URL) {
        let path = url.standardizedFileURL.path
        save(paths.filter { $0 != path })
    }

    func clear() {
        save([])
    }

    private func save(_ newPaths: [String]) {
        defaults.set(Array(newPaths.prefix(limit)), forKey: key)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
