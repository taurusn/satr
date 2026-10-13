import Foundation
import Synchronization

/// A value kept in memory and saved to one JSON file: loaded once at init, written atomically at
/// most 500 ms after the first unsaved change, and at once on `flush()`.
final class JSONFileStore<Model: Codable & Sendable>: Sendable {
    static var debounce: Double { 0.5 }

    let fileURL: URL
    private let state: Mutex<(model: Model, dirty: Bool, scheduled: Bool)>
    private let queue = DispatchQueue(label: "linen.store", qos: .utility)

    init(fileURL: URL, empty: Model) {
        self.fileURL = fileURL
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var model = empty
        if let data = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder().decode(Model.self, from: data) {
            model = decoded
        }
        state = Mutex((model, false, false))
    }

    func read<Result: Sendable>(_ body: (Model) -> Result) -> Result {
        state.withLock { body($0.model) }
    }

    /// Changes the model and schedules a save.
    func mutate<Result: Sendable>(_ body: (inout Model) -> Result) -> Result {
        let (result, schedule) = state.withLock { current -> (Result, Bool) in
            let result = body(&current.model)
            current.dirty = true
            let schedule = !current.scheduled
            current.scheduled = true
            return (result, schedule)
        }
        if schedule {
            queue.asyncAfter(deadline: .now() + Self.debounce) { [weak self] in self?.writeIfDirty() }
        }
        return result
    }

    /// Writes any unsaved change now.
    func flush() {
        queue.sync { writeIfDirty() }
    }

    private func writeIfDirty() {
        let pending: Model? = state.withLock { current in
            current.scheduled = false
            guard current.dirty else { return nil }
            current.dirty = false
            return current.model
        }
        guard let pending else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(pending) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// A least-recently-used table of values by file key, with each entry's path for lookups after a
/// writer replaced the file and changed its key.
struct LRUTable<Value: Codable & Sendable>: Codable, Sendable {
    struct Entry: Codable, Sendable {
        var key: String
        var path: String?
        var value: Value
        var used: UInt64
    }

    private(set) var entries: [String: Entry] = [:]
    private var clock: UInt64 = 0

    init() {}

    init(from decoder: any Decoder) throws {
        let list = try decoder.singleValueContainer().decode([Entry].self)
        for entry in list { entries[entry.key] = entry }
        clock = list.map(\.used).max() ?? 0
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(entries.values.sorted { $0.used < $1.used })
    }

    var count: Int { entries.count }

    /// The value for a key, marking it used.
    mutating func value(forKey key: String) -> Value? {
        guard var entry = entries[key] else { return nil }
        clock += 1
        entry.used = clock
        entries[key] = entry
        return entry.value
    }

    /// The value for a key, else for the most recently used entry with the same path, which is moved
    /// to the new key.
    mutating func value(forKey key: String, path: String) -> Value? {
        if let value = value(forKey: key) { return value }
        guard let old = entries.values.filter({ $0.path == path }).max(by: { $0.used < $1.used }) else { return nil }
        entries[old.key] = nil
        set(old.value, forKey: key, path: path, capacity: Int.max)
        return old.value
    }

    /// Stores a value, drops other entries with the same path, and evicts the least recently used
    /// entries beyond `capacity`.
    mutating func set(_ value: Value, forKey key: String, path: String?, capacity: Int) {
        if let path {
            for other in entries.values where other.path == path && other.key != key { entries[other.key] = nil }
        }
        clock += 1
        entries[key] = Entry(key: key, path: path ?? entries[key]?.path, value: value, used: clock)
        while entries.count > max(capacity, 0), let oldest = entries.values.min(by: { $0.used < $1.used }) {
            entries[oldest.key] = nil
        }
    }

    mutating func remove(forKey key: String) {
        entries[key] = nil
    }
}
