import Foundation

/// A file found by a walk.
struct ScannedFile: Sendable {
    let url: URL
    let path: String
    let size: Int
}

/// Walks a vault and reads notes, for `VaultIndex`.
enum VaultScanner {
    /// Folder names never walked, besides every hidden (dot) folder.
    static let skippedFolders: Set<String> = ["node_modules", ".git", ".obsidian", ".trash"]
    /// Notes larger than this are indexed by name only.
    static let maxNoteBytes = 16 * 1024 * 1024

    /// Every regular file under `folder` (the root when nil), as URL, vault-relative path and size.
    static func walk(root: URL, under folder: URL? = nil) -> [ScannedFile] {
        let start = folder ?? root
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: start, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var files: [ScannedFile] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isDirectory == true {
                if skippedFolders.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true, let path = relativePath(url, root: root) else { continue }
            files.append(ScannedFile(url: url, path: path, size: values?.fileSize ?? 0))
        }
        return files
    }

    /// The path of `url` relative to `root`, as written on disk, or nil when outside it.
    static func relativePath(_ url: URL, root: URL) -> String? {
        let rootPath = root.path
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        let path = url.standardizedFileURL.path
        if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        let canonical = Paths.canonical(url).path
        if canonical.hasPrefix(prefix) { return String(canonical.dropFirst(prefix.count)) }
        if canonical.folded.hasPrefix(prefix.folded) { return String(canonical.dropFirst(prefix.count)) }
        return nil
    }

    /// True when any component of a vault-relative path is hidden or a skipped folder.
    static func isSkipped(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0.hasPrefix(".") || skippedFolders.contains(String($0)) }
    }

    static func isNote(_ path: String) -> Bool {
        path.lowercased().hasSuffix(".md")
    }

    /// Reads and parses one note. Unreadable notes are still indexed by name.
    static func note(url: URL, path: String) -> NoteRecord {
        let file = FileEntry(url: url, path: path)
        let fileName = (file.path.split(separator: "/").last.map(String.init) ?? file.path)
        let name = String(fileName.dropLast(3))
        var parsed = ParsedNote()
        // An iCloud note that is not downloaded is indexed by name only: reading it would download it (OPEN-8).
        if !CloudFile.isDataless(url), let data = try? Data(contentsOf: url), data.count <= maxNoteBytes {
            parsed = NoteParser.parse(TextDecoder.decode(data).text)
        }
        return NoteRecord(file: file, name: name, aliases: parsed.aliases, headings: parsed.headings, links: parsed.links)
    }
}
