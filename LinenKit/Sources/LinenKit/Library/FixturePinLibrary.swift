import Foundation
import Synchronization

/// A debug `PinLibrary` that serves folders on disk as pins, read in place, for building the iPhone app before the
/// link exists. `FixturePinLibrary(fixtures:support:)` serves Linen's `Tests/Fixtures` as two pins: the notes (with
/// `blocks/`) and the boards. Every pin starts at generation 1; `advance(_:)` moves one on, as a sync would.
public final class FixturePinLibrary: PinLibrary {
    /// One served folder.
    public struct Source: Sendable {
        public var id: Pin.ID
        public var name: String
        public var macPath: String
        public var root: URL
        /// Relative folders left out (the notes pin leaves `boards` to the boards pin).
        public var excluded: [String]

        public init(id: Pin.ID, name: String, macPath: String, root: URL, excluded: [String] = []) {
            self.id = id
            self.name = name
            self.macPath = macPath
            self.root = root
            self.excluded = excluded
        }
    }

    private let sources: [Source]
    private let reads: ReadMarks
    private let state = Mutex<(generations: [Pin.ID: PinGeneration], open: [UUID: PinGeneration], watchers: [UUID: AsyncStream<PinLibraryChange>.Continuation])>(([:], [:], [:]))

    public init(sources: [Source], reads: ReadMarks) {
        self.sources = sources
        self.reads = reads
    }

    /// `Tests/Fixtures` as two pins, with read marks kept in `support`.
    public convenience init(fixtures: URL, support: URL) {
        self.init(sources: [
            Source(id: "fixtures-notes", name: "Fixtures", macPath: "Satr/Tests/Fixtures", root: fixtures, excluded: ["boards"]),
            Source(id: "fixtures-boards", name: "boards", macPath: "Satr/Tests/Fixtures/boards", root: fixtures.appendingPathComponent("boards")),
        ], reads: ReadMarks(directory: support))
    }

    deinit {
        let watchers = state.withLock { $0.watchers.values }
        for w in watchers { w.finish() }
    }

    // MARK: PinLibrary

    public func pins() async -> [Pin] {
        sources.map { pin(for: $0) }.sorted { $0.lastChange > $1.lastChange }
    }

    public func files(in pin: Pin.ID) async -> [PinFile] {
        guard let source = sources.first(where: { $0.id == pin }) else { return [] }
        return scan(source).map { entry in
            let ref = PinFileRef(pin: pin, path: entry.path)
            let stamp = ReadMarks.stamp(size: entry.size, modified: entry.modified)
            return PinFile(ref: ref, kind: entry.kind, title: DocumentTitle.title(of: entry.url, kind: entry.kind), modified: entry.modified,
                           size: entry.size, changedSinceRead: reads.changed(ref, stamp: stamp), scripts: entry.kind == .page ? .off : nil)
        }.sorted { $0.modified != $1.modified ? $0.modified > $1.modified : $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    public func open(_ file: PinFileRef) async throws -> PinnedDocument {
        guard let source = sources.first(where: { $0.id == file.pin }) else { throw PinLibraryError.noSuchPin(file.pin) }
        let url = source.root.appendingPathComponent(file.path)
        guard let kind = DocumentKind(fileName: url.lastPathComponent), FileManager.default.fileExists(atPath: url.path),
              url.standardizedFileURL.path.hasPrefix(source.root.standardizedFileURL.path + "/") else { throw PinLibraryError.noSuchFile(file) }
        let lease = UUID()
        let generation = state.withLock { s -> PinGeneration in
            let g = s.generations[file.pin] ?? PinGeneration(1)
            s.open[lease] = g
            return g
        }
        return PinnedDocument(ref: file, kind: kind, url: url, root: source.root, generation: generation, scripts: kind == .page ? .off : nil) { [weak self] in
            _ = self?.state.withLock { $0.open.removeValue(forKey: lease) }
        }
    }

    public func resolve(_ reference: String, from file: PinFileRef) async -> PinReference {
        var target = reference
        if let bar = target.firstIndex(of: "|") { target = String(target[..<bar]) }
        if let hash = target.firstIndex(of: "#") { target = String(target[..<hash]) }
        target = target.trimmingCharacters(in: .whitespaces).precomposedStringWithCanonicalMapping
        guard !target.isEmpty else { return .file(file) }
        // A path beside the file first, then a name anywhere: in the file's own pin, then in the others.
        if let source = sources.first(where: { $0.id == file.pin }) {
            let folder = (file.path as NSString).deletingLastPathComponent
            for candidate in [target, target + ".md"] {
                let rel = ((folder as NSString).appendingPathComponent(candidate) as NSString).standardizingPath
                if !rel.hasPrefix("..") && !rel.hasPrefix("/") && FileManager.default.fileExists(atPath: source.root.appendingPathComponent(rel).path) {
                    return .file(PinFileRef(pin: source.id, path: rel))
                }
            }
        }
        let ordered = sources.filter { $0.id == file.pin } + sources.filter { $0.id != file.pin }
        let wanted = (target as NSString).lastPathComponent.lowercased()
        for source in ordered {
            let hits = scan(source, documentsOnly: false).filter {
                let name = ($0.path as NSString).lastPathComponent.lowercased()
                return name == wanted || name == wanted + ".md"
            }
            if let best = hits.min(by: { $0.path.split(separator: "/").count < $1.path.split(separator: "/").count }) {
                return .file(PinFileRef(pin: source.id, path: best.path))
            }
        }
        return .missing
    }

    public func markRead(_ file: PinFileRef) async {
        guard let source = sources.first(where: { $0.id == file.pin }) else { return }
        let url = source.root.appendingPathComponent(file.path)
        guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        reads.markRead(file, stamp: ReadMarks.stamp(size: Int64(v.fileSize ?? 0), modified: v.contentModificationDate ?? .distantPast))
        emit(.read(file))
    }

    public func changes() -> AsyncStream<PinLibraryChange> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<PinLibraryChange>.makeStream()
        continuation.onTermination = { [weak self] _ in _ = self?.state.withLock { $0.watchers.removeValue(forKey: id) } }
        state.withLock { $0.watchers[id] = continuation }
        return stream
    }

    // MARK: For development

    /// Moves a pin to its next generation and tells watchers, as a finished sync would.
    public func advance(_ pin: Pin.ID) {
        let g = state.withLock { s -> PinGeneration in
            let next = PinGeneration((s.generations[pin] ?? PinGeneration(1)).sequence + 1)
            s.generations[pin] = next
            return next
        }
        emit(.generation(pin, g))
    }

    /// Shows a file as changed since read (for screenshots of the Library's thread).
    public func markChanged(_ file: PinFileRef) {
        reads.markStale(file)
        emit(.read(file))
    }

    /// The generations open documents hold, for tests.
    public var openGenerations: [PinGeneration] { state.withLock { Array($0.open.values) } }

    // MARK: Inside

    private struct Entry {
        var path: String
        var url: URL
        var kind: DocumentKind
        var size: Int64
        var modified: Date
    }

    private func emit(_ change: PinLibraryChange) {
        let watchers = state.withLock { Array($0.watchers.values) }
        for w in watchers { w.yield(change) }
    }

    private func pin(for source: Source) -> Pin {
        let entries = scan(source, documentsOnly: false)
        let generation = state.withLock { $0.generations[source.id] } ?? PinGeneration(1)
        return Pin(id: source.id, name: source.name, macPath: source.macPath, kind: .folder,
                   lastChange: entries.map(\.modified).max() ?? .distantPast, size: entries.reduce(0) { $0 + $1.size }, generation: generation)
    }

    private func scan(_ source: Source, documentsOnly: Bool = true) -> [Entry] {
        let root = source.root.standardizedFileURL
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var out: [Entry] = []
        let base = root.path + "/"
        for case let url as URL in walker {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base) else { continue }
            let rel = String(path.dropFirst(base.count))
            if source.excluded.contains(where: { rel == $0 || rel.hasPrefix($0 + "/") }) { walker.skipDescendants(); continue }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let kind = DocumentKind(fileName: url.lastPathComponent)
            if documentsOnly && kind == nil { continue }
            out.append(Entry(path: rel, url: url, kind: kind ?? .note, size: Int64(v.fileSize ?? 0), modified: v.contentModificationDate ?? .distantPast))
        }
        return out
    }
}
