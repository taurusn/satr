import Foundation

/// Stable keys for remembering things about a file.
public enum FileKey {
    /// A key from the file's volume UUID and file ID (`id:<volume>:<file>`), which survive renames
    /// and moves within the volume. When either is unavailable, for example for a missing file, the
    /// key is the standardized path (`path:<path>`).
    ///
    /// Writers that save by replacing the file give it a new file ID, so the stores also remember
    /// each entry's path and fall back to it in their URL-based lookups.
    public static func make(for url: URL) -> String {
        let standard = url.standardizedFileURL
        var info = stat()
        if stat(standard.path, &info) == 0,
           let volume = try? standard.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString {
            return "id:\(volume):\(info.st_ino)"
        }
        return "path:" + standard.path
    }

    /// The path stores record beside a key: canonical, with symlinks resolved.
    static func path(for url: URL) -> String {
        Paths.canonical(url).path
    }
}

/// Bookmark data for finding a file again after it was renamed or moved.
public enum FileIdentity {
    /// Bookmark data for `url` (not security scoped; the app is not sandboxed), or nil when the file
    /// cannot be bookmarked.
    public static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// The file a bookmark points to now, and whether the bookmark is stale and should be remade.
    /// Nil when the file is gone. Never shows UI or mounts volumes.
    public static func resolve(_ data: Data) -> (url: URL, stale: Bool)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        return (url, stale)
    }
}
