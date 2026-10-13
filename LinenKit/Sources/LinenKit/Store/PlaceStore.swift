import Foundation

/// Where a reader was in a file: the block being read and the offset within it, plus text size.
public struct Place: Codable, Sendable, Equatable {
    /// Content hash of the block being read.
    public var blockHash: String
    /// Index of that block in the document, used when the hash is no longer found.
    public var blockIndex: Int
    /// Offset into the block, as a fraction of its height (0 is its top).
    public var offset: Double
    /// A short quote from the block, to find it again by text.
    public var quote: String
    /// Text size, 1 meaning 100 percent.
    public var zoom: Double
    /// True when the reader was at the end, so a file that grew opens at its new end.
    public var atEnd: Bool
    /// When the place was recorded.
    public var date: Date

    /// Makes a place.
    public init(blockHash: String, blockIndex: Int, offset: Double, quote: String, zoom: Double, atEnd: Bool, date: Date) {
        self.blockHash = blockHash
        self.blockIndex = blockIndex
        self.offset = offset
        self.quote = quote
        self.zoom = zoom
        self.atEnd = atEnd
        self.date = date
    }
}

/// Remembers the place in each file for the most recently used 500 files, in `places.json`.
public final class PlaceStore: Sendable {
    /// How many files are remembered.
    public let capacity: Int
    private let file: JSONFileStore<LRUTable<Place>>

    /// Opens (or creates) the store in `directory`.
    public init(directory: URL, capacity: Int = 500) {
        self.capacity = capacity
        file = JSONFileStore(fileURL: directory.appendingPathComponent("places.json"), empty: LRUTable())
    }

    /// The place stored under a file key.
    public func place(forKey key: String) -> Place? {
        file.mutate { $0.value(forKey: key) }
    }

    /// Stores a place under a file key.
    public func set(_ place: Place, forKey key: String) {
        let capacity = capacity
        file.mutate { $0.set(place, forKey: key, path: nil, capacity: capacity) }
    }

    /// The place for a file, found by its key, else by its path when a writer replaced the file.
    public func place(for url: URL) -> Place? {
        let key = FileKey.make(for: url), path = FileKey.path(for: url)
        return file.mutate { $0.value(forKey: key, path: path) }
    }

    /// Stores the place for a file under its key and path.
    public func set(_ place: Place, for url: URL) {
        let key = FileKey.make(for: url), path = FileKey.path(for: url), capacity = capacity
        file.mutate { $0.set(place, forKey: key, path: path, capacity: capacity) }
    }

    /// Forgets a file.
    public func remove(forKey key: String) {
        file.mutate { $0.remove(forKey: key) }
    }

    /// The number of files remembered.
    public var count: Int { file.read { $0.count } }

    /// Writes pending changes now, for example at quit.
    public func flush() { file.flush() }
}
