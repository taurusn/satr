import Foundation

/// The vault indexes an app shares between its documents. An index lives while a document shows a file in its vault
/// (`acquire` and `release`); when its last document lets go it is kept, in place of the one kept before, so closing
/// and reopening a file does not walk its vault again. Lookups that hold no document (`index(for:)`) get the live
/// index, or a new one that goes when they drop it.
///
/// Before 2026-11-24 every index ever opened stayed in memory until the app quit: a code repository opened once
/// (13,000 files with its build output) kept its index for days. Use from one thread (Linen: the main thread).
public final class VaultIndexCache {
    private final class Entry {
        weak var index: VaultIndex?
        init(_ index: VaultIndex) { self.index = index }
    }

    private var entries: [URL: Entry] = [:]
    private var users: [URL: Int] = [:]
    private let make: (Vault) -> VaultIndex
    /// The index whose last document let go most recently.
    public private(set) var kept: VaultIndex?
    private var keptAt = Date.distantPast

    /// - Parameter make: makes a vault's index; by default it starts building it in the background.
    public init(make: @escaping (Vault) -> VaultIndex = VaultIndexCache.buildInBackground) {
        self.make = make
    }

    /// Makes an index and builds it on a background task.
    public static func buildInBackground(_ vault: Vault) -> VaultIndex {
        let index = VaultIndex(vault: vault)
        Task.detached(priority: .utility) { await index.build() }
        return index
    }

    /// The live index of `vault`, else a new one. It lives only as long as someone holds it.
    public func index(for vault: Vault) -> VaultIndex {
        if let index = existing(for: vault) { return index }
        entries = entries.filter { $0.value.index != nil }
        let index = make(vault)
        entries[vault.root] = Entry(index)
        return index
    }

    /// The live index of `vault`, without making one.
    public func existing(for vault: Vault) -> VaultIndex? {
        entries[vault.root]?.index
    }

    /// The index for a document showing a file in `vault`. Balance every call with `release(_:)`.
    public func acquire(_ vault: Vault) -> VaultIndex {
        users[vault.root, default: 0] += 1
        return index(for: vault)
    }

    /// A document stopped using `index`. Returns true when that was its last document and the index is now the kept
    /// one; the index kept before is let go (it lives on only if something else holds it).
    @discardableResult
    public func release(_ index: VaultIndex, now: Date = Date()) -> Bool {
        let root = index.vault.root
        guard let count = users[root] else { return false }
        if count > 1 {
            users[root] = count - 1
            return false
        }
        users[root] = nil
        kept = index
        keptAt = now
        return true
    }

    /// Lets go of the kept index once it has been kept, unused, for `age` seconds.
    public func dropKept(olderThan age: TimeInterval, now: Date = Date()) {
        guard let index = kept, users[index.vault.root] == nil, now.timeIntervalSince(keptAt) >= age else { return }
        kept = nil
    }

    /// How many indexes are alive, for tests and measurement.
    public var liveCount: Int { entries.values.filter { $0.index != nil }.count }
}
