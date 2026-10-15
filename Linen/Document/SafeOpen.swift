import Darwin
import Foundation

/// Opens files inside a vault without a race (SAFE-2): the path is walked from a descriptor of the vault root with
/// `openat`, one component at a time, never following a symlink unless it resolves inside the vault, in which case
/// the walk restarts from the root with the resolved path (at most 8 times).
enum SafeOpen {
    static let maxBytes = 50 * 1024 * 1024

    struct Opened {
        let fd: Int32
        let device: UInt64
        let inode: UInt64
        let size: Int
    }

    /// Normalises path components relative to the root; nil if `..` would leave it.
    static func normalise(_ parts: [String]) -> [String]? {
        var out: [String] = []
        for p in parts where !p.isEmpty && p != "." {
            if p == ".." { if out.isEmpty { return nil }; out.removeLast() } else { out.append(p) }
        }
        return out
    }

    static func open(root: URL, relative: String) -> Opened? {
        let rootPath = root.resolvingSymlinksInPath().path
        let rootFD = Darwin.open(rootPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFD >= 0 else { return nil }
        defer { close(rootFD) }
        guard var comps = normalise(relative.split(separator: "/").map(String.init)), !comps.isEmpty else { return nil }
        var hops = 0
        walk: while hops <= 8 {
            var dir = dup(rootFD)
            for (i, name) in comps.enumerated() {
                let last = i == comps.count - 1
                let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (last ? 0 : O_DIRECTORY))
                if fd >= 0 { close(dir); dir = fd; continue }
                let err = errno
                // A symlink: read it, resolve it against its folder, and restart if it stays inside the vault.
                var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                let n = readlinkat(dir, name, &buf, Int(PATH_MAX))
                close(dir)
                guard (err == ELOOP || err == ENOTDIR || err == EMLINK), n > 0, hops < 8 else { return nil }
                let target = String(decoding: buf[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                var base: [String]
                if target.hasPrefix("/") {
                    guard target == rootPath || target.hasPrefix(rootPath + "/") else { return nil }
                    base = target.dropFirst(rootPath.count).split(separator: "/").map(String.init)
                } else {
                    base = Array(comps[0..<i]) + target.split(separator: "/").map(String.init)
                }
                guard let next = normalise(base + comps[(i + 1)...]), !next.isEmpty else { return nil }
                comps = next
                hops += 1
                continue walk
            }
            var st = stat()
            guard fstat(dir, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, Int(st.st_size) <= maxBytes else { close(dir); return nil }
            return Opened(fd: dir, device: UInt64(st.st_dev), inode: UInt64(st.st_ino), size: Int(st.st_size))
        }
        return nil
    }

    /// Opens an absolute path outside a vault, for a file the reader allowed; the final component is not followed.
    static func openOutside(path: String) -> Opened? {
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, Int(st.st_size) <= maxBytes else { close(fd); return nil }
        return Opened(fd: fd, device: UInt64(st.st_dev), inode: UInt64(st.st_ino), size: Int(st.st_size))
    }

    /// Reads the whole file, or its first `limit` bytes, and closes the descriptor.
    static func read(_ o: Opened, limit: Int? = nil) -> Data? {
        defer { close(o.fd) }
        let want = min(o.size, limit ?? o.size)
        var data = Data(count: want)
        let got = data.withUnsafeMutableBytes { buf -> Int in
            var total = 0
            while total < want {
                let n = Darwin.read(o.fd, buf.baseAddress!.advanced(by: total), want - total)
                if n <= 0 { break }
                total += n
            }
            return total
        }
        return got == want ? data : nil
    }
}
