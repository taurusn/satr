import Foundation
import Synchronization

/// An in-memory index of a vault's notes: names, aliases, headings and outgoing wiki links, with
/// link resolution, Open Quickly search and backlinks. Nothing is written into the vault.
///
/// Builds and updates run one at a time on a background queue. Queries can be made from any thread,
/// including the main thread: they take the current snapshot under a lock held for a pointer copy,
/// then work on that snapshot without blocking anything.
public final class VaultIndex: Sendable {
    /// The vault this index covers.
    public let vault: Vault
    private let current: SnapshotBox
    private let worker: IndexWorker

    /// Makes an empty index for a vault. Call `build()` to fill it.
    public init(vault: Vault) {
        let root = Paths.canonical(vault.root)
        let box = SnapshotBox(IndexSnapshot.empty(root: root))
        self.vault = vault
        self.current = box
        self.worker = IndexWorker(root: root, box: box)
    }

    /// Walks the vault and indexes every `.md` note, skipping hidden folders, `node_modules`, `.git`,
    /// `.obsidian` and `.trash`. Other files are recorded so links to images and PDFs resolve.
    public func build() async {
        await worker.build()
    }

    /// Re-reads the given files or folders, adding, replacing or removing their entries, then
    /// recomputes link resolution. Paths outside the vault or in skipped folders are ignored.
    public func update(changed urls: [URL]) async {
        await worker.update(urls)
    }

    /// The number of Markdown notes indexed.
    public var noteCount: Int { current.snapshot.tables.notes.count }

    /// Resolves a wiki link's inner text (`target`, `target|label`, `target#heading`, `target#^block`)
    /// written in the note at `source`. The rules are listed on `LinkResolution` and in the README.
    public func resolve(_ target: String, from source: URL) -> LinkResolution {
        let tables = current.snapshot.tables
        let sourceKey = tables.relativeKey(for: source)
        switch tables.resolveMatch(target, sourceKey: sourceKey) {
        case .note(let index, let heading, let block):
            return .note(tables.notes[index].file.url, heading: heading, block: block)
        case .attachment(let index):
            return .note(tables.attachments[index].url, heading: nil, block: nil)
        case .selfLink(let heading, let block):
            if let key = sourceKey, let index = tables.noteByKey[key] {
                return .note(tables.notes[index].file.url, heading: tables.heading(heading, in: index), block: block)
            }
            return .note(source, heading: heading, block: block)
        case .ambiguous(let entries):
            return .ambiguous(entries.map(\.url))
        case .missing(let path):
            return .missing(path)
        }
    }

    /// The name a reader sees for a note: its file name without the extension, else its first alias.
    /// A file the index does not know gets its file name.
    public func noteName(for url: URL) -> String {
        let tables = current.snapshot.tables
        if let key = tables.relativeKey(for: url), let index = tables.noteByKey[key] {
            let note = tables.notes[index]
            if !note.name.trimmingCharacters(in: .whitespaces).isEmpty { return note.name }
            if let alias = note.aliases.first { return alias }
        }
        return url.deletingPathExtension().lastPathComponent.nfc
    }

    /// Fuzzy search over note names and aliases, NFC and case folded, at most `limit` notes. Ranked:
    /// prefix, then word start, then letters in order; shorter names first within each.
    public func search(_ query: String, limit: Int) -> [NoteRef] {
        let tables = current.snapshot.tables
        return tables.search(query, limit: limit).map { result in
            let note = tables.notes[result.entry.note]
            return NoteRef(url: note.file.url, name: note.name, path: note.file.path,
                           matchedAlias: result.entry.isAlias ? result.entry.text : nil)
        }
    }

    /// Notes that link to `url`, one entry per source note, sorted by name, at most `limit`.
    /// Links from a note to itself are left out.
    public func backlinks(to url: URL, limit: Int) -> [Backlink] {
        let snapshot = current.snapshot
        let tables = snapshot.tables
        guard limit > 0, let key = tables.relativeKey(for: url), let groups = snapshot.incoming[key] else { return [] }
        return groups.prefix(limit).map { group in
            let note = tables.notes[group.source]
            return Backlink(source: note.file.url, name: note.name, path: note.file.path,
                            sentence: group.sentence, line: group.line, count: group.count)
        }
    }

    /// How many notes link to `url`, for a "Show all" control.
    public func backlinkCount(to url: URL) -> Int {
        let snapshot = current.snapshot
        guard let key = snapshot.tables.relativeKey(for: url) else { return 0 }
        return snapshot.incoming[key]?.count ?? 0
    }

    /// The headings of a note, in document order; empty when the note is not indexed.
    public func headings(for url: URL) -> [Heading] {
        let tables = current.snapshot.tables
        guard let key = tables.relativeKey(for: url), let index = tables.noteByKey[key] else { return [] }
        return tables.notes[index].headings
    }

    /// The aliases of a note from its frontmatter; empty when the note is not indexed.
    public func aliases(for url: URL) -> [String] {
        let tables = current.snapshot.tables
        guard let key = tables.relativeKey(for: url), let index = tables.noteByKey[key] else { return [] }
        return tables.notes[index].aliases
    }
}

extension VaultIndex {
    /// Counts of how every indexed link resolves, for corpus checks. Counts only, never content.
    func resolutionSummary() -> (links: Int, resolved: Int, ambiguous: Int, missing: Int) {
        let tables = current.snapshot.tables
        var summary = (links: 0, resolved: 0, ambiguous: 0, missing: 0)
        for note in tables.notes {
            for link in note.links {
                summary.links += 1
                switch tables.resolveMatch(link.raw, sourceKey: note.file.key) {
                case .note, .attachment, .selfLink: summary.resolved += 1
                case .ambiguous: summary.ambiguous += 1
                case .missing: summary.missing += 1
                }
            }
        }
        return summary
    }
}

/// Holds the published snapshot. The lock is held only to copy or swap a reference.
final class SnapshotBox: Sendable {
    private let mutex: Mutex<IndexSnapshot>

    init(_ snapshot: IndexSnapshot) { mutex = Mutex(snapshot) }

    var snapshot: IndexSnapshot { mutex.withLock { $0 } }

    func publish(_ snapshot: IndexSnapshot) { mutex.withLock { $0 = snapshot } }
}

/// Runs builds and updates one at a time on a serial queue that owns the mutable note tables.
final class IndexWorker: @unchecked Sendable {
    private let root: URL
    private let box: SnapshotBox
    private let queue = DispatchQueue(label: "linen.vault-index", qos: .userInitiated)
    // Owned by `queue`.
    private var notes: [String: NoteRecord] = [:]
    private var others: [String: FileEntry] = [:]

    init(root: URL, box: SnapshotBox) {
        self.root = root
        self.box = box
    }

    func build() async {
        await run { $0.rebuild() }
    }

    func update(_ urls: [URL]) async {
        await run { $0.apply(urls) }
    }

    private func run(_ work: @escaping @Sendable (IndexWorker) -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                work(self)
                continuation.resume()
            }
        }
    }

    private func rebuild() {
        let files = VaultScanner.walk(root: root)
        notes = [:]
        others = [:]
        add(files)
        publish()
    }

    private func apply(_ urls: [URL]) {
        for url in urls {
            guard let path = VaultScanner.relativePath(url, root: root), !path.isEmpty,
                  !VaultScanner.isSkipped(path) else { continue }
            let key = path.folded
            let nested = key + "/"
            notes = notes.filter { $0.key != key && !$0.key.hasPrefix(nested) }
            others = others.filter { $0.key != key && !$0.key.hasPrefix(nested) }
            let fileURL = root.appendingPathComponent(path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                add(VaultScanner.walk(root: root, under: fileURL))
            } else {
                add([ScannedFile(url: fileURL, path: path, size: 0)])
            }
        }
        publish()
    }

    /// Parses notes in parallel, largest first so one big note does not finish last, and records
    /// other files.
    private func add(_ files: [ScannedFile]) {
        let markdown = files.filter { VaultScanner.isNote($0.path) }.sorted { $0.size > $1.size }
        for file in files where !VaultScanner.isNote(file.path) {
            let entry = FileEntry(url: file.url, path: file.path)
            others[entry.key] = entry
        }
        let results = ParsedNotes(count: markdown.count)
        DispatchQueue.concurrentPerform(iterations: markdown.count) { index in
            results.set(index, VaultScanner.note(url: markdown[index].url, path: markdown[index].path))
        }
        for record in results.all { notes[record.file.key] = record }
    }

    private func publish() {
        box.publish(IndexSnapshot(root: root, notes: Array(notes.values), attachments: Array(others.values)))
    }
}

/// Collects parse results from concurrent workers.
private final class ParsedNotes: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [NoteRecord?]

    init(count: Int) { records = Array(repeating: nil, count: count) }

    func set(_ index: Int, _ record: NoteRecord) {
        lock.lock()
        records[index] = record
        lock.unlock()
    }

    var all: [NoteRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records.compactMap { $0 }
    }
}
