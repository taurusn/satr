import Foundation

/// A folder that bounds link resolution, Open Quickly, Linked from and local file access for a document.
public struct Vault: Sendable, Hashable {
    /// How the vault root was found.
    public enum Kind: Sendable, Hashable {
        /// The root holds an `.obsidian` folder.
        case obsidian
        /// The root holds a `.git` folder or file.
        case git
        /// No marker was found, so the root is the document's own folder.
        case folder
    }

    /// The vault's root folder, with symlinks resolved.
    public let root: URL
    /// How the root was found.
    public let kind: Kind

    /// Makes a vault from a root folder and its kind.
    public init(root: URL, kind: Kind) {
        self.root = root
        self.kind = kind
    }
}

/// Finds the vault a document belongs to.
public enum VaultLocator {
    /// The vault for a document: the nearest ancestor holding an `.obsidian` folder, else the nearest
    /// holding `.git`, else the document's own folder. Symlinks are resolved first.
    public static func vault(for fileURL: URL) -> Vault {
        let file = Paths.canonical(fileURL)
        let start = Paths.isDirectory(file.path) ? file : file.deletingLastPathComponent()
        var nearestGit: String?
        var path = start.path
        while true {
            if Paths.isDirectory(path == "/" ? "/.obsidian" : path + "/.obsidian") {
                return Vault(root: URL(fileURLWithPath: path, isDirectory: true), kind: .obsidian)
            }
            if nearestGit == nil, Paths.exists(path == "/" ? "/.git" : path + "/.git") {
                nearestGit = path
            }
            if path == "/" || path.isEmpty { break }
            path = (path as NSString).deletingLastPathComponent
        }
        if let nearestGit { return Vault(root: URL(fileURLWithPath: nearestGit, isDirectory: true), kind: .git) }
        return Vault(root: URL(fileURLWithPath: start.path, isDirectory: true), kind: .folder)
    }
}
