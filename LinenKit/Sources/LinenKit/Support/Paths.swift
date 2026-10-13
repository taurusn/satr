import Foundation

/// Path helpers shared by the vault, watch and store code.
enum Paths {
    /// The canonical form of a file URL: symlinks resolved with `realpath`, so `/var` and `/private/var`
    /// compare equal. A missing file is resolved through its nearest existing ancestor.
    static func canonical(_ url: URL) -> URL {
        let path = url.standardizedFileURL.path
        if let real = realPath(path) { return URL(fileURLWithPath: real) }
        var missing: [String] = []
        var current = URL(fileURLWithPath: path)
        while current.path != "/" {
            missing.insert(current.lastPathComponent, at: 0)
            current = current.deletingLastPathComponent()
            if let real = realPath(current.path) {
                var result = URL(fileURLWithPath: real, isDirectory: true)
                for name in missing { result.appendPathComponent(name) }
                return result
            }
        }
        return URL(fileURLWithPath: path)
    }

    static func realPath(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }
}
