import Foundation

/// A file found by a walk.
struct ScannedFile: Sendable {
    /// The vault-relative path as written on disk.
    let path: String
    let size: Int
}

/// Walks a vault and reads notes, for `VaultIndex`.
enum VaultScanner {
    /// Folder names never walked, besides every hidden (dot) folder.
    static let skippedFolders: Set<String> = ["node_modules", ".git", ".obsidian", ".trash"]
    /// Notes larger than this are indexed by name only.
    static let maxNoteBytes = 16 * 1024 * 1024
    /// Notes this large or larger are parsed at most `largeNotesAtOnce` at a time (`IndexWorker.add`).
    static let largeNoteBytes = 256 * 1024
    static let largeNotesAtOnce = 4

    /// Every regular file under `folder` (the root when nil), as vault-relative path and size. Each entry is read
    /// in its own autorelease pool, so the enumerator's URLs and their cached resource values go as soon as the
    /// path is taken instead of piling up until the walk ends.
    static func walk(root: URL, under folder: URL? = nil) -> [ScannedFile] {
        let start = folder ?? root
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: start, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var files: [ScannedFile] = []
        // The walk's URLs are spelled as on disk; `relativePath` standardizes, which decomposes some names (an
        // Arabic hamza seen 2026-11-24), so the plain path is taken when it lies under the root.
        let prefix = root.path == "/" ? "/" : root.path + "/"
        var more = true
        while more {
            autoreleasepool {
                guard let url = enumerator.nextObject() as? URL else { more = false; return }
                let values = try? url.resourceValues(forKeys: keys)
                if values?.isDirectory == true {
                    if skippedFolders.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                    return
                }
                guard values?.isRegularFile == true else { return }
                let full = url.path
                guard let path = full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count)) : relativePath(url, root: root) else { return }
                files.append(ScannedFile(path: path, size: values?.fileSize ?? 0))
            }
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

    /// Reads and parses one note, `path` being vault-relative as written on disk. Unreadable notes are still
    /// indexed by name. The file's bytes and text live only inside an autorelease pool of their own.
    static func note(root: URL, path: String) -> NoteRecord {
        let file = FileEntry(path: path)
        let fileName = (file.path.split(separator: "/").last.map(String.init) ?? file.path)
        let name = String(fileName.dropLast(3))
        let parsed = autoreleasepool { () -> ParsedNote in
            let url = file.url(in: root)
            // An iCloud note that is not downloaded is indexed by name only: reading it would download it (OPEN-8).
            guard !CloudFile.isDataless(url), let data = try? Data(contentsOf: url), data.count <= maxNoteBytes else { return ParsedNote() }
            return NoteParser.parse(data: data)
        }
        return NoteRecord(file: file, name: name, aliases: parsed.aliases, headings: parsed.headings, links: parsed.links)
    }
}
