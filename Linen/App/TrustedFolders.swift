import Foundation

/// The folders whose pages run their scripts by default (PAGE-7), kept in user defaults under `trustedFolders`
/// as standardized paths. A page is trusted when its file sits inside one of them, at any depth.
enum TrustedFolders {
    static let key = "trustedFolders"

    static var all: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    static func add(_ path: String) {
        let p = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        var list = all
        guard !list.contains(p) else { return }
        list.append(p)
        UserDefaults.standard.set(list.sorted(), forKey: key)
    }

    static func remove(_ path: String) {
        UserDefaults.standard.set(all.filter { $0 != path }, forKey: key)
    }

    /// True when `file` is inside a trusted folder (symlinks resolved first, so a link cannot borrow trust).
    static func contains(_ file: URL) -> Bool {
        let p = file.standardizedFileURL.resolvingSymlinksInPath().path
        return all.contains { p.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    /// The folder to suggest trusting for a page: the enclosing git repository or Obsidian vault, never the task folder
    /// an agent made for one page (PAGE-7). Nil when the page sits in no project.
    static func suggestion(for file: URL) -> URL? {
        var dir = file.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        while dir.path != "/" && dir.path != home {
            let fm = FileManager.default
            if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) || fm.fileExists(atPath: dir.appendingPathComponent(".obsidian").path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}
