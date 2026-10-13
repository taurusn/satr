import Foundation

/// Remembers, per file, the block hashes the reader has acknowledged (seen on screen), so changes
/// since then can be marked on reopening. Keeps the most recently used 500 files and at most 20,000
/// hashes per file (the first 20,000 in document order), in `baselines.json`.
public final class BaselineStore: Sendable {
    /// How many files are remembered.
    public let capacity: Int
    /// How many hashes are kept per file.
    public let maxHashes: Int
    private let file: JSONFileStore<LRUTable<[String]>>

    /// Opens (or creates) the store in `directory`.
    public init(directory: URL, capacity: Int = 500, maxHashes: Int = 20_000) {
        self.capacity = capacity
        self.maxHashes = maxHashes
        file = JSONFileStore(fileURL: directory.appendingPathComponent("baselines.json"), empty: LRUTable())
    }

    /// The acknowledged hashes stored under a file key.
    public func hashes(forKey key: String) -> [String]? {
        file.mutate { $0.value(forKey: key) }
    }

    /// Stores acknowledged hashes under a file key.
    public func set(_ hashes: [String], forKey key: String) {
        let kept = Array(hashes.prefix(maxHashes)), capacity = capacity
        file.mutate { $0.set(kept, forKey: key, path: nil, capacity: capacity) }
    }

    /// The acknowledged hashes for a file, found by its key, else by its path.
    public func hashes(for url: URL) -> [String]? {
        let key = FileKey.make(for: url), path = FileKey.path(for: url)
        return file.mutate { $0.value(forKey: key, path: path) }
    }

    /// Stores acknowledged hashes for a file under its key and path.
    public func set(_ hashes: [String], for url: URL) {
        let key = FileKey.make(for: url), path = FileKey.path(for: url)
        let kept = Array(hashes.prefix(maxHashes)), capacity = capacity
        file.mutate { $0.set(kept, forKey: key, path: path, capacity: capacity) }
    }

    /// Forgets a file.
    public func remove(forKey key: String) {
        file.mutate { $0.remove(forKey: key) }
    }

    /// The number of files remembered.
    public var count: Int { file.read { $0.count } }

    /// Writes pending changes now.
    public func flush() { file.flush() }
}
