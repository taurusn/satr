import CryptoKit
import Darwin
import Foundation

/// The Mac's manifest of one pin (SYNC-4): every file with its size, time, hash and sequence, removals as tombstones,
/// and one durable sequence. A phone sends back the manifest ID and sequence it holds and gets only what is newer.
/// Tombstones are kept until every phone holding this manifest has acknowledged them; after 30 days the manifest
/// gets a new ID instead, so a phone that was away compares in full and removes what is gone.
public struct MacPinManifest: Codable, Sendable {
    public static let tombstoneLife: TimeInterval = 30 * 24 * 3600

    public var pin: String
    public var id: String
    public var sequence: UInt64
    public var trust: UInt64
    public var entries: [String: ManifestEntry]
    public var tombstones: [String: Tombstone]
    public var tombstoneDates: [String: Date]
    /// Why files were left out, as the pin's problem lines.
    public var problems: [String]
    /// What each file looked like when it was hashed, so an unchanged file is not hashed again.
    public var stamps: [String: FileStamp]
    /// The name on disk where it differs from the manifest's NFC path.
    public var disk: [String: String]

    public init(pin: String, trust: UInt64 = 1) {
        self.pin = pin
        id = UUID().uuidString.lowercased()
        sequence = 0
        self.trust = trust
        entries = [:]
        tombstones = [:]
        tombstoneDates = [:]
        problems = []
        stamps = [:]
        disk = [:]
    }

    public var totalSize: Int64 { entries.values.reduce(0) { $0 + $1.size } }

    /// Applies a scan. `hash` reads a file by its on-disk relative path; `scripts` gives a page's policy and `links`
    /// a note's resolved references, both by on-disk relative path (`links` also gets the file's hash). Returns true when anything a phone sees changed.
    @discardableResult
    public mutating func apply(_ scan: PinScan, now: Date = Date(), trust newTrust: UInt64? = nil,
                               hash: (String) -> String?, scripts: (String) -> PageScriptPolicy?,
                               links: (String, String) -> [String: LinkTargetRef]? = { _, _ in nil }) -> Bool {
        var changed = false
        if let newTrust, newTrust != trust {
            trust = newTrust
            changed = true
        }
        var seen = Set<String>()
        var newDisk: [String: String] = [:]
        problems = scan.problems
        for f in scan.files {
            seen.insert(f.path)
            if f.diskPath != f.path { newDisk[f.path] = f.diskPath }
            let old = entries[f.path]
            var sha = old?.sha
            if old == nil || stamps[f.path] != f.stamp {
                guard let h = hash(f.diskPath) else {
                    // A file that cannot be read now keeps its last entry; a new one waits for the next scan.
                    problems.append("\(f.path): could not be read")
                    if old == nil { seen.remove(f.path) }
                    continue
                }
                sha = h
                stamps[f.path] = f.stamp
            }
            guard let sha else { continue }
            let kind = DocumentKind(fileName: f.path)
            var e = ManifestEntry(path: f.path, size: f.stamp.size, mtime: f.stamp.mtime, sha: sha, seq: 0,
                                  scripts: kind == .page ? scripts(f.diskPath) : nil,
                                  links: kind == .note ? links(f.diskPath, sha) : nil)
            if let old, old.sameContent(as: e) {
                // Same content: keep its sequence; only the time may have moved, which the phone does not need.
                e.seq = old.seq
                if old.mtime != e.mtime { entries[f.path]?.mtime = e.mtime }
                continue
            }
            sequence += 1
            e.seq = sequence
            entries[f.path] = e
            tombstones[f.path] = nil
            tombstoneDates[f.path] = nil
            changed = true
        }
        for path in entries.keys where !seen.contains(path) {
            entries[path] = nil
            stamps[path] = nil
            sequence += 1
            tombstones[path] = Tombstone(path: path, seq: sequence)
            tombstoneDates[path] = now
            changed = true
        }
        disk = newDisk
        return changed
    }

    /// What a phone holding (`manifest`, `sequence`) is missing. A different manifest ID means a full compare.
    public func delta(heldManifest: String, heldSequence: UInt64) -> (full: Bool, entries: [ManifestEntry], removed: [Tombstone]) {
        if heldManifest != id {
            return (true, entries.values.sorted { $0.seq < $1.seq }, [])
        }
        return (false, entries.values.filter { $0.seq > heldSequence }.sorted { $0.seq < $1.seq },
                tombstones.values.filter { $0.seq > heldSequence }.sorted { $0.seq < $1.seq })
    }

    /// The delta as `manifest` frames, each under the frame bound; at least one, the last marked.
    public func frames(heldManifest: String, heldSequence: UInt64, budget: Int = LinkBounds.maxFrame - 64 * 1024) -> [ManifestFrame] {
        let d = delta(heldManifest: heldManifest, heldSequence: heldSequence)
        let enc = JSONEncoder()
        var pages: [ManifestFrame] = []
        var page = ManifestFrame(pin: pin, manifest: id, trust: trust, sequence: sequence, full: d.full, entries: [], removed: [], last: false,
                                 problems: problems.isEmpty ? nil : Array(problems.prefix(50)))
        var size = 512
        func flush() {
            pages.append(page)
            page.entries = []
            page.removed = []
            page.problems = nil
            size = 512
        }
        for e in d.entries {
            let n = (try? enc.encode(e).count) ?? 4096
            if size + n > budget, !page.entries.isEmpty || !page.removed.isEmpty { flush() }
            page.entries.append(e)
            size += n + 1
        }
        for t in d.removed {
            let n = (try? enc.encode(t).count) ?? 1024
            if size + n > budget, !page.entries.isEmpty || !page.removed.isEmpty { flush() }
            page.removed.append(t)
            size += n + 1
        }
        page.last = true
        pages.append(page)
        return pages
    }

    /// Drops tombstones every phone holding this manifest has acknowledged (`acked` holds their sequences), and starts
    /// a new manifest ID when a tombstone has waited 30 days. Returns true when the manifest ID changed.
    @discardableResult
    public mutating func prune(acked: [UInt64], now: Date = Date()) -> Bool {
        if let low = acked.min() {
            for (path, t) in tombstones where t.seq <= low {
                tombstones[path] = nil
                tombstoneDates[path] = nil
            }
        } else {
            tombstones = [:]
            tombstoneDates = [:]
        }
        if tombstoneDates.values.contains(where: { now.timeIntervalSince($0) > Self.tombstoneLife }) {
            id = UUID().uuidString.lowercased()
            tombstones = [:]
            tombstoneDates = [:]
            return true
        }
        return false
    }

    /// The entry with this hash, for serving a `want`.
    public func entry(sha: String) -> ManifestEntry? { entries.values.first { $0.sha == sha } }

    public func diskPath(_ path: String) -> String { disk[path] ?? path }
}

/// What a file looked like when hashed.
public struct FileStamp: Codable, Sendable, Hashable {
    public var size: Int64
    public var mtime: Double
    public var inode: UInt64
}

/// One file found in a pin.
public struct PinScanFile: Sendable, Hashable {
    /// The manifest's path: NFC, `/`-separated.
    public var path: String
    /// The path as the names are on disk.
    public var diskPath: String
    public var stamp: FileStamp
}

public struct PinScan: Sendable {
    public var files: [PinScanFile]
    public var problems: [String]

    public init(files: [PinScanFile], problems: [String]) {
        self.files = files
        self.problems = problems
    }
}

/// Reads a pin's files on the Mac with the descriptor rule (section 9.3, SAFE-2): every walk starts from a descriptor
/// of the pin's root and opens one component at a time without following a symlink, so nothing outside the root is
/// ever listed or served. A single-file pin's root is that file and its walk can reach only it.
public enum PinFiles {
    static let skippedNames: Set<String> = ["node_modules"]

    /// Lists a pin. Hidden names, symlinks, files over 200 MB and paths that collide by case or Unicode form are left
    /// out with a problem line.
    public static func scan(root: URL, kind: Pin.Kind, maxFiles: Int = LinkBounds.maxEntriesPerPin) -> PinScan {
        var files: [PinScanFile] = []
        var problems: [String] = []
        switch kind {
        case .file:
            let fd = Darwin.open(root.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { return PinScan(files: [], problems: ["\(root.lastPathComponent): could not be opened"]) }
            defer { close(fd) }
            var st = stat()
            guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return PinScan(files: [], problems: ["\(root.lastPathComponent): not a file"]) }
            let name = root.lastPathComponent
            if Int64(st.st_size) > LinkBounds.maxFileSize {
                problems.append("\(name): over 200 MB")
            } else {
                files.append(PinScanFile(path: name.precomposedStringWithCanonicalMapping, diskPath: name, stamp: stamp(st)))
            }
            // A board's or a note's notes travel with it (NOTE-2): `name.notes.json` beside it, opened the same way.
            let side = sidecarName(name)
            let sfd = Darwin.open(root.deletingLastPathComponent().appendingPathComponent(side).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if sfd >= 0 {
                var sst = stat()
                if fstat(sfd, &sst) == 0, (sst.st_mode & S_IFMT) == S_IFREG, Int64(sst.st_size) <= LinkBounds.maxFileSize {
                    files.append(PinScanFile(path: side.precomposedStringWithCanonicalMapping, diskPath: side, stamp: stamp(sst)))
                }
                close(sfd)
            }
        case .folder:
            let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard fd >= 0 else { return PinScan(files: [], problems: ["\(root.lastPathComponent): could not be opened"]) }
            walk(fd, prefix: [], depth: 0, files: &files, problems: &problems, maxFiles: maxFiles)
        }
        let clashes = LinkPath.collisions(files.map(\.path))
        if !clashes.isEmpty {
            files.removeAll { clashes.contains($0.path) }
            for p in clashes.sorted() { problems.append("\(p): another file differs from it only by case or Unicode form") }
        }
        return PinScan(files: files, problems: problems)
    }

    private static func stamp(_ st: stat) -> FileStamp {
        FileStamp(size: Int64(st.st_size), mtime: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9, inode: UInt64(st.st_ino))
    }

    /// Takes ownership of `dirFD`.
    private static func walk(_ dirFD: Int32, prefix: [String], depth: Int, files: inout [PinScanFile], problems: inout [String], maxFiles: Int) {
        guard let dir = fdopendir(dirFD) else { close(dirFD); return }
        defer { closedir(dir) }
        var names: [String] = []
        while let ent = readdir(dir) {
            let name = withUnsafePointer(to: ent.pointee.d_name) { p in
                p.withMemoryRebound(to: CChar.self, capacity: Int(ent.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name.hasPrefix(".") || skippedNames.contains(name) { continue }
            names.append(name)
        }
        let fd = dirfd(dir)
        for name in names.sorted() {
            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let parts = prefix + [name]
            let disk = parts.joined(separator: "/")
            let path = disk.precomposedStringWithCanonicalMapping
            switch st.st_mode & S_IFMT {
            case S_IFDIR:
                guard depth < 32 else { problems.append("\(path): folders nested too deep"); continue }
                let sub = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if sub >= 0 { walk(sub, prefix: parts, depth: depth + 1, files: &files, problems: &problems, maxFiles: maxFiles) }
            case S_IFREG:
                if let p = LinkPath.problem(path) { problems.append("\(path): \(p)"); continue }
                if Int64(st.st_size) > LinkBounds.maxFileSize { problems.append("\(path): over 200 MB"); continue }
                guard files.count < maxFiles else {
                    if !problems.contains(where: { $0.hasPrefix("More than") }) { problems.append("More than \(maxFiles) files; the rest are not kept") }
                    continue
                }
                files.append(PinScanFile(path: path, diskPath: disk, stamp: stamp(st)))
            default:
                continue
            }
        }
    }

    /// Opens a file of a pin read-only by its on-disk relative path, one component at a time, never following a
    /// symlink. Returns the descriptor and size, or nil.
    public static func open(root: URL, kind: Pin.Kind, diskPath: String) -> (fd: Int32, size: Int64)? {
        let fd: Int32
        switch kind {
        case .file:
            // A single-file pin reaches its file and that file's notes sidecar, nothing else.
            if diskPath == root.lastPathComponent {
                fd = Darwin.open(root.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            } else if diskPath == sidecarName(root.lastPathComponent) {
                fd = Darwin.open(root.deletingLastPathComponent().appendingPathComponent(diskPath).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            } else {
                return nil
            }
        case .folder:
            let parts = diskPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
            var dir = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard dir >= 0 else { return nil }
            for (i, name) in parts.enumerated() {
                let last = i == parts.count - 1
                let next = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (last ? 0 : O_DIRECTORY))
                close(dir)
                guard next >= 0 else { return nil }
                dir = next
            }
            fd = dir
        }
        guard fd >= 0 else { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { close(fd); return nil }
        return (fd, Int64(st.st_size))
    }

    /// The notes sidecar of a file: `map.canvas.notes.json` beside `map.canvas` (NOTE-2).
    public static func sidecarName(_ name: String) -> String { name + ".notes.json" }

    /// The SHA-256 of a pin's file, in hex.
    public static func hash(root: URL, kind: Pin.Kind, diskPath: String) -> String? {
        guard let (fd, _) = open(root: root, kind: kind, diskPath: diskPath) else { return nil }
        defer { close(fd) }
        return hash(fd: fd)
    }

    static func hash(fd: Int32) -> String? {
        var h = SHA256()
        var buf = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n < 0 { return nil }
            if n == 0 { break }
            buf.withUnsafeBytes { h.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
        }
        return Data(h.finalize()).hexString
    }

    /// Reads up to `count` bytes at `offset`.
    public static func read(fd: Int32, offset: Int64, count: Int) -> Data? {
        var d = Data(count: count)
        let n = d.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
        guard n >= 0 else { return nil }
        d.count = n
        return d
    }
}

/// The Mac's trust decisions for pages (PAGE-7) as the helper receives them from the app: trusted folders and per-file
/// choices, with a revision that rises on every change.
public struct PageTrust: Codable, Sendable, Hashable {
    public var revision: UInt64
    public var folders: [String]
    public var perFile: [String: Bool]

    public init(revision: UInt64 = 1, folders: [String] = [], perFile: [String: Bool] = [:]) {
        self.revision = revision
        self.folders = folders
        self.perFile = perFile
    }

    /// The same rule as the Mac app's `PagePolicy.effective(canonical:)`: a per-file choice wins, else a trusted
    /// folder turns scripts on, else they are off.
    public func policy(canonicalPath p: String) -> PageScriptPolicy {
        if let v = perFile[p] { return PageScriptPolicy(on: v, source: "file") }
        if let root = folders.first(where: { p.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) { return PageScriptPolicy(on: true, source: "root:\(root)") }
        return .off
    }
}
