import Foundation
@testable import LinenKit

/// A fresh folder under the temporary directory, removed when released. Its URL is canonical
/// (`/private/var/...`), matching what the index and watcher report.
final class TempFolder: @unchecked Sendable {
    let url: URL

    init(_ label: String = "LinenKitTests") {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = Paths.canonical(base)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// Writes a UTF-8 file at a relative path, creating folders.
    @discardableResult
    func write(_ relative: String, _ text: String = "") -> URL {
        let file = url.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: file)
        return file
    }

    /// Writes a file through POSIX calls so the name's bytes reach the disk exactly as given (used
    /// for NFD names, which Foundation might normalize).
    @discardableResult
    func writeRaw(folder: String, name: String, _ text: String) -> URL {
        let folderURL = url.appendingPathComponent(folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let path = folderURL.path + "/" + name
        let descriptor = path.withCString { open($0, O_CREAT | O_WRONLY | O_TRUNC, 0o644) }
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        close(descriptor)
        return URL(fileURLWithPath: path)
    }

    func makeFolder(_ relative: String) {
        try? FileManager.default.createDirectory(at: url.appendingPathComponent(relative), withIntermediateDirectories: true)
    }

    /// Raw directory entry names as bytes, to check normalization on disk.
    func rawNames(in folder: String) -> [[UInt8]] {
        guard let directory = opendir(url.appendingPathComponent(folder).path) else { return [] }
        defer { closedir(directory) }
        var names: [[UInt8]] = []
        while let entry = readdir(directory) {
            var name = entry.pointee.d_name
            let length = Int(entry.pointee.d_namlen)
            let bytes = withUnsafeBytes(of: &name) { Array($0.prefix(length)) }
            names.append(bytes)
        }
        return names
    }
}

/// True when two file URLs name the same path, comparing in NFC with symlinks resolved.
func samePath(_ first: URL, _ second: URL) -> Bool {
    Paths.canonical(first).path.nfc == Paths.canonical(second).path.nfc
}

/// Polls until `condition` is true or `timeout` seconds pass.
func waitUntil(timeout: Double, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// Records watcher events with their arrival times.
final class EventRecorder: @unchecked Sendable {
    struct Entry {
        let event: FileWatcher.Event
        let time: Date
    }

    let queue = DispatchQueue(label: "linen.tests.events")
    private let lock = NSLock()
    private var stored: [Entry] = []

    func record(_ event: FileWatcher.Event) {
        let entry = Entry(event: event, time: Date())
        lock.withLock { stored.append(entry) }
    }

    var entries: [Entry] { lock.withLock { stored } }

    var contents: [(data: Data, generation: Int, inBurst: Bool, time: Date)] {
        entries.compactMap { entry in
            if case .content(let data, let generation, let inBurst) = entry.event {
                return (data, generation, inBurst, entry.time)
            }
            return nil
        }
    }

    func firstContent(_ text: String, after date: Date = .distantPast) -> (inBurst: Bool, time: Date)? {
        contents.first { String(decoding: $0.data, as: UTF8.self) == text && $0.time >= date }.map { ($0.inBurst, $0.time) }
    }

    var missingCount: Int { entries.filter { $0.event == .missing }.count }

    var moves: [(url: URL, time: Date)] {
        entries.compactMap { entry in
            if case .moved(let url) = entry.event { return (url, entry.time) }
            return nil
        }
    }

    var quiets: [(generation: Int, time: Date)] {
        entries.compactMap { entry in
            if case .quiet(let generation) = entry.event { return (generation, entry.time) }
            return nil
        }
    }
}

/// Writes in place: same inode, truncated then rewritten.
func writeInPlace(_ url: URL, _ text: String) throws {
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: Data(text.utf8))
    try handle.close()
}

func inode(_ url: URL) -> UInt64? {
    var info = stat()
    return stat(url.path, &info) == 0 ? info.st_ino : nil
}
