import Foundation
import Synchronization

/// A file that came from elsewhere (Files, AirDrop, the share sheet) and is listed under "Opened on this iPhone"
/// (IOS-6). iOS hands over the one file, not its folder, so what it references is not here.
public struct OpenedFile: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    /// The file name as it arrived.
    public var name: String
    public var kind: DocumentKind
    public var title: String
    public var size: Int64
    /// When it was last opened from elsewhere (arriving again moves it to the top).
    public var opened: Date
}

/// The files opened from elsewhere: each copied into its own folder under `directory`, listed newest first in
/// `opened.json`. Linen never writes to them; a file that arrives again with the same name replaces its older copy.
public final class OpenedFiles: Sendable {
    private let directory: URL
    private let list: JSONFileStore<[OpenedFile]>
    private let lock = Mutex(())

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        list = JSONFileStore(fileURL: directory.appendingPathComponent("opened.json"), empty: [])
    }

    /// The files, most recently opened first, leaving out any whose copy is gone.
    public func all() -> [OpenedFile] {
        list.read { $0 }.filter { FileManager.default.fileExists(atPath: url(for: $0).path) }.sorted { $0.opened > $1.opened }
    }

    /// Where a file's copy is.
    public func url(for file: OpenedFile) -> URL {
        directory.appendingPathComponent(file.id, isDirectory: true).appendingPathComponent(file.name)
    }

    /// Copies a file handed to Linen and lists it. The caller holds any security scope `source` needs while this runs.
    @discardableResult
    public func add(copying source: URL) throws -> OpenedFile {
        let name = source.lastPathComponent
        guard let kind = DocumentKind(fileName: name) else { throw CocoaError(.fileReadUnsupportedScheme) }
        return try lock.withLock { _ in
            let id = UUID().uuidString
            let folder = directory.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let dest = folder.appendingPathComponent(name)
            var coordination: NSError?
            var copyError: (any Error)?
            NSFileCoordinator().coordinate(readingItemAt: source, options: [.withoutChanges], error: &coordination) { url in
                do { try FileManager.default.copyItem(at: url, to: dest) } catch { copyError = error }
            }
            if let err = copyError ?? coordination {
                try? FileManager.default.removeItem(at: folder)
                throw err
            }
            let size = Int64((try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            let file = OpenedFile(id: id, name: name, kind: kind, title: DocumentTitle.title(of: dest, kind: kind), size: size, opened: Date())
            let replaced = list.mutate { files -> [OpenedFile] in
                let old = files.filter { $0.name == name }
                files.removeAll { $0.name == name }
                files.insert(file, at: 0)
                return old
            }
            for old in replaced { try? FileManager.default.removeItem(at: directory.appendingPathComponent(old.id, isDirectory: true)) }
            list.flush()
            return file
        }
    }

    /// Removes a file and its copy.
    public func remove(_ id: String) {
        lock.withLock { _ in
            list.mutate { $0.removeAll { $0.id == id } }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(id, isDirectory: true))
            list.flush()
        }
    }
}
