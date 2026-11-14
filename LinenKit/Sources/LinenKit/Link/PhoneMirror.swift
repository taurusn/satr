import CryptoKit
import Darwin
import Foundation
import Synchronization

/// The phone's copy of the Mac's pins, mirrored by generation (SYNC-4), and the `PinLibrary` the iPhone app reads.
///
/// On disk, under `root`: `state.json` (the pin set and read marks); per pin `pins/<id>/current`, a small pointer file
/// naming the current generation, the generation's folder beside it and its metadata as `<generation>.json`;
/// `partial/<hash>.partial` for transfers in flight and `objects/<hash>` for files fetched and checked. A new
/// generation is built as its own folder, unchanged files cloned from the current one and changed ones taken from
/// `objects`, then the pointer is replaced with one rename, so the generation and its metadata switch at once. A
/// document already open keeps its generation until it closes; old generations are deleted when nothing reads them.
/// The mirror is excluded from backup and, on the iPhone, unreadable while the phone is locked (IOS-9).
public final class PhoneMirror: PinLibrary, @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()
    private var state = MirrorState()
    private var gens: [String: GenMeta] = [:]
    private var opens: [String: Int] = [:]
    /// Hashes the plans in flight need, by pin, with their sizes.
    private var reserved: [String: [String: Int64]] = [:]
    private var listeners: [UUID: AsyncStream<PinLibraryChange>.Continuation] = [:]
    private var fm: FileManager { FileManager.default }

    struct MirrorState: Codable {
        var pinSet: UInt64 = 0
        var pins: [String: PinInfo] = [:]
        /// The hash each file had when it was last read (or when its pin first arrived).
        var reads: [String: String] = [:]
        var problems: [String: [String]] = [:]
        var lastSync: Date?
    }

    struct GenMeta: Codable {
        var dir: String
        var manifest: String
        var sequence: UInt64
        var trust: UInt64
        var entries: [String: ManifestEntry]
        var titles: [String: String]
    }

    public init(root: URL) throws {
        self.root = root
        for d in ["pins", "partial", "objects", "trash"] {
            try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        protect(root)
        for d in ["pins", "partial", "objects"] { protect(root.appendingPathComponent(d)) }
        var r = root
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        try? r.setResourceValues(v)
        if let d = try? Data(contentsOf: stateURL), let s = try? JSONDecoder().decode(MirrorState.self, from: d) { state = s }
        for id in state.pins.keys { gens[id] = loadCurrent(id) }
        cleanUp()
    }

    /// The default place: Application Support/Linen/Mirror.
    public static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Linen/Mirror", isDirectory: true)
    }

    private var stateURL: URL { root.appendingPathComponent("state.json") }
    private func pinDir(_ id: String) -> URL { root.appendingPathComponent("pins/\(id)", isDirectory: true) }
    private func partialURL(_ sha: String) -> URL { root.appendingPathComponent("partial/\(sha).partial") }
    private func objectURL(_ sha: String) -> URL { root.appendingPathComponent("objects/\(sha)") }

    private func saveState() {
        if let d = try? JSONEncoder().encode(state) { try? d.write(to: stateURL, options: .atomic) }
    }

    private func loadCurrent(_ id: String) -> GenMeta? {
        let dir = pinDir(id)
        guard let name = try? String(contentsOf: dir.appendingPathComponent("current"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              let d = try? Data(contentsOf: dir.appendingPathComponent("\(name).json")),
              let meta = try? JSONDecoder().decode(GenMeta.self, from: d),
              fm.fileExists(atPath: dir.appendingPathComponent(name).path) else { return nil }
        return meta
    }

    /// Deletes generations nothing reads, building folders left by a stop, unknown pins and the trash.
    private func cleanUp() {
        lock.lock()
        let known = state.pins
        let current = gens.mapValues(\.dir)
        let open = opens
        lock.unlock()
        let pins = root.appendingPathComponent("pins")
        for id in (try? fm.contentsOfDirectory(atPath: pins.path)) ?? [] {
            let dir = pins.appendingPathComponent(id)
            guard known[id] != nil else { trash(dir); continue }
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                if name == "current" { continue }
                let gen = name.hasSuffix(".json") ? String(name.dropLast(5)) : name
                if gen == current[id] || (open["\(id)/\(gen)"] ?? 0) > 0 { continue }
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
        }
        let t = root.appendingPathComponent("trash")
        for name in (try? fm.contentsOfDirectory(atPath: t.path)) ?? [] { try? fm.removeItem(at: t.appendingPathComponent(name)) }
    }

    private func trash(_ url: URL) {
        let dest = root.appendingPathComponent("trash/\(UUID().uuidString)")
        if (try? fm.moveItem(at: url, to: dest)) != nil { try? fm.removeItem(at: dest) } else { try? fm.removeItem(at: url) }
    }

    private func protect(_ url: URL) {
        #if os(iOS)
        try? fm.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: url.path)
        #endif
    }

    private func emit(_ c: PinLibraryChange) {
        let ls = lock.withLock { Array(listeners.values) }
        for l in ls { l.yield(c) }
    }

    // MARK: - What the link reads and writes

    /// What `hello` carries.
    public func held() -> Hello {
        lock.withLock {
            Hello(pinSet: state.pinSet, pins: state.pins.keys.sorted().map { id in
                let g = gens[id]
                return HeldPin(id: id, manifest: g?.manifest ?? "", sequence: g?.sequence ?? 0, trust: g?.trust ?? 0)
            })
        }
    }

    public var pinIDs: [String] { lock.withLock { state.pins.keys.sorted() } }
    public var lastSync: Date? { lock.withLock { state.lastSync } }

    public func markSynced(_ at: Date = Date()) {
        lock.withLock { state.lastSync = at; saveState() }
    }

    /// Reconciles the phone to the Mac's pin set: new pins added, renamed ones updated, absent ones removed with
    /// their files. The generation is stored only after that is done.
    public func applyPinSet(_ f: PinSetFrame) {
        let next = Dictionary(f.pins.filter { LinkPath.isValidPinID($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let removed: [(id: String, open: Bool)] = lock.withLock {
            let gone = state.pins.keys.filter { next[$0] == nil }
            for id in gone {
                gens[id] = nil
                reserved[id] = nil
                state.problems[id] = nil
                state.reads = state.reads.filter { !$0.key.hasPrefix("pin:\(id)/") }
            }
            state.pins = next
            return gone.map { id in (id, opens.keys.contains { $0.hasPrefix("\(id)/") }) }
        }
        // A removed pin's files go now, or when the last document open in it closes.
        for r in removed where !r.open { trash(pinDir(r.id)) }
        for id in next.keys where !fm.fileExists(atPath: pinDir(id).path) {
            try? fm.createDirectory(at: pinDir(id), withIntermediateDirectories: true)
            protect(pinDir(id))
        }
        lock.withLock {
            state.pinSet = f.generation
            saveState()
        }
        emit(.pins)
    }

    public enum MirrorError: Error, Sendable, Equatable {
        case unknownPin(String)
        /// A delta against a manifest this phone does not hold.
        case outOfStep(String)
        case tooManyEntries(String)
        case missingObject(String)
        case io(String)
    }

    /// What one pin needs to reach a manifest.
    public struct Plan: Sendable {
        public var pin: String
        public var manifest: String
        public var trust: UInt64
        public var sequence: UInt64
        public var entries: [String: ManifestEntry]
        public var wanted: [WantedFile]
        public var sizes: [String: Int64]
        public var problems: [String]
        /// Nothing the phone shows changes; only the sequence moves.
        public var unchanged: Bool
        /// Bytes still to fetch.
        public var bytes: Int64
    }

    /// Validates a complete manifest (all its pages) against the current generation and lists the hashes to fetch,
    /// with resume offsets from `.partial` files.
    public func plan(_ m: ManifestFrame) throws(MirrorError) -> Plan {
        lock.lock()
        defer { lock.unlock() }
        do {
            guard state.pins[m.pin] != nil else { throw .unknownPin(m.pin) }
            let cur = gens[m.pin]
            let sameManifest = cur?.manifest == m.manifest
            guard m.full || sameManifest else { throw .outOfStep(m.pin) }
            var map = m.full ? [:] : (cur?.entries ?? [:])
            var problems = m.problems ?? []
            for t in m.removed { map[t.path] = nil }
            for e in m.entries {
                if let p = LinkPath.problem(e.path) { problems.append("\(e.path): \(p)"); continue }
                guard LinkPath.isValidHash(e.sha), e.size >= 0, e.size <= LinkBounds.maxFileSize else {
                    problems.append("\(e.path): bad entry")
                    continue
                }
                map[e.path] = e
            }
            guard map.count <= LinkBounds.maxEntriesPerPin else { throw .tooManyEntries(m.pin) }
            let clashes = LinkPath.collisions(Array(map.keys))
            for p in clashes.sorted() {
                map[p] = nil
                problems.append("\(p): another file differs from it only by case or Unicode form")
            }
            // A file whose path is another file's folder cannot exist on disk beside it.
            let folders = Set(map.keys.flatMap { p -> [String] in
                let parts = p.split(separator: "/").map(String.init)
                return (1..<max(parts.count, 1)).map { parts[0..<$0].joined(separator: "/") }
            })
            for p in map.keys where folders.contains(p) {
                map[p] = nil
                problems.append("\(p): a file and a folder share this name")
            }
            let have = Set((cur?.entries.values.map(\.sha)) ?? [])
            var sizes: [String: Int64] = [:]
            for e in map.values where !have.contains(e.sha) { sizes[e.sha] = e.size }
            var wanted: [WantedFile] = []
            var bytes: Int64 = 0
            for (sha, size) in sizes.sorted(by: { $0.key < $1.key }) {
                if fm.fileExists(atPath: objectURL(sha).path) { continue }
                var offset = (try? fm.attributesOfItem(atPath: partialURL(sha).path)[.size] as? Int64) ?? 0
                if offset > size {
                    try? fm.removeItem(at: partialURL(sha))
                    offset = 0
                }
                wanted.append(WantedFile(sha: sha, offset: offset))
                bytes += size - offset
            }
            let unchanged = sameManifest && cur.map { c in
                c.entries.count == map.count && map.allSatisfy { k, v in c.entries[k].map { $0.sameContent(as: v) } ?? false }
            } ?? false
            reserved[m.pin] = sizes
            state.problems[m.pin] = problems.isEmpty ? nil : problems
            return Plan(pin: m.pin, manifest: m.manifest, trust: m.trust, sequence: m.sequence, entries: map, wanted: wanted,
                        sizes: sizes, problems: problems, unchanged: unchanged, bytes: bytes)
        }
    }

    /// Free space as the tests set it.
    nonisolated(unsafe) var spaceOverride: Int64?

    /// Space the phone can use now, in bytes.
    public func availableSpace() -> Int64? {
        if let spaceOverride { return spaceOverride }
        #if os(iOS)
        let v = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage
        #else
        let v = try? root.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return v?.volumeAvailableCapacity.map(Int64.init)
        #endif
    }

    public enum ChunkOutcome: Sendable, Equatable {
        case progress
        /// The file arrived whole and its hash matched.
        case complete(String)
        /// The bytes did not hash to what the manifest said; the partial file is gone and the file must be fetched
        /// again.
        case mismatch(String)
        /// A chunk for no file in flight, or out of order.
        case unexpected
    }

    /// Writes one chunk into its `.partial` file, and checks the hash when the file is complete.
    public func receive(_ c: Chunk) -> ChunkOutcome {
        guard let size = lock.withLock({ reserved.values.lazy.compactMap { $0[c.sha] }.first }) else { return .unexpected }
        let url = partialURL(c.sha)
        let have = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        if c.offset < have, c.offset + Int64(c.bytes.count) <= have { return .progress }
        guard c.offset == have, have + Int64(c.bytes.count) <= size else {
            try? fm.removeItem(at: url)
            return .mismatch(c.sha)
        }
        if have == 0, !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: url) else { return .unexpected }
        do {
            try h.seekToEnd()
            try h.write(contentsOf: c.bytes)
            try h.close()
        } catch {
            try? h.close()
            return .unexpected
        }
        guard have + Int64(c.bytes.count) == size else { return .progress }
        return finish(c.sha)
    }

    private func finish(_ sha: String) -> ChunkOutcome {
        let url = partialURL(sha)
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return .mismatch(sha) }
        let got = PinFiles.hash(fd: fd)
        close(fd)
        guard got == sha, (try? fm.moveItem(at: url, to: objectURL(sha))) != nil else {
            try? fm.removeItem(at: url)
            return .mismatch(sha)
        }
        return .complete(sha)
    }

    /// The number of transfers paused with partial files ("Finishing 3 files paused when you left").
    public func partialCount() -> Int {
        ((try? fm.contentsOfDirectory(atPath: root.appendingPathComponent("partial").path)) ?? []).filter { $0.hasSuffix(".partial") }.count
    }

    /// Builds the plan's generation and points the pin at it with one rename. Every wanted file must be in `objects`.
    @discardableResult
    public func commit(_ plan: Plan) throws(MirrorError) -> PinGeneration {
        let (cur, known) = lock.withLock { (gens[plan.pin], state.pins[plan.pin] != nil) }
        guard known else { throw .unknownPin(plan.pin) }
        let dir = pinDir(plan.pin)
        if plan.unchanged, var meta = cur {
            meta.sequence = plan.sequence
            meta.trust = plan.trust
            meta.entries = plan.entries
            try writeMeta(meta, in: dir)
            lock.withLock {
                gens[plan.pin] = meta
                reserved[plan.pin] = nil
            }
            return PinGeneration(plan.sequence)
        }
        for sha in plan.sizes.keys where !fm.fileExists(atPath: objectURL(sha).path) {
            if cur?.entries.values.contains(where: { $0.sha == sha }) != true { throw .missingObject(sha) }
        }
        let name = "g\(plan.sequence)-\(UUID().uuidString.prefix(8).lowercased())"
        let building = dir.appendingPathComponent(".building-\(name)")
        let target = dir.appendingPathComponent(name)
        do {
            try fm.createDirectory(at: building, withIntermediateDirectories: true)
            protect(building)
            var bySha: [String: URL] = [:]
            if let cur {
                for e in cur.entries.values where bySha[e.sha] == nil { bySha[e.sha] = dir.appendingPathComponent(cur.dir).appendingPathComponent(e.path) }
            }
            var titles: [String: String] = [:]
            for (path, e) in plan.entries {
                let dst = building.appendingPathComponent(path)
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                let obj = objectURL(e.sha)
                let src = fm.fileExists(atPath: obj.path) ? obj : bySha[e.sha]
                guard let src else { throw MirrorError.missingObject(e.sha) }
                guard copyfile(src.path, dst.path, nil, copyfile_flags_t(COPYFILE_CLONE)) == 0 else { throw MirrorError.io("copy \(path)") }
                if DocumentKind(fileName: path) != nil {
                    if let t = cur?.titles[path], cur?.entries[path]?.sha == e.sha { titles[path] = t } else if let t = Self.title(of: dst) { titles[path] = t }
                }
            }
            try fm.moveItem(at: building, to: target)
            let meta = GenMeta(dir: name, manifest: plan.manifest, sequence: plan.sequence, trust: plan.trust, entries: plan.entries, titles: titles)
            try writeMeta(meta, in: dir)
            let firstGeneration = cur == nil
            let old = cur?.dir
            var deleteOld = false
            lock.withLock {
                gens[plan.pin] = meta
                if firstGeneration {
                    for e in plan.entries.values { state.reads[PinFileRef(pin: plan.pin, path: e.path).storeKey] = e.sha }
                    saveState()
                }
                if let old { deleteOld = (opens["\(plan.pin)/\(old)"] ?? 0) == 0 }
                reserved[plan.pin] = nil
            }
            if let old, deleteOld {
                try? fm.removeItem(at: dir.appendingPathComponent(old))
                try? fm.removeItem(at: dir.appendingPathComponent("\(old).json"))
            }
            dropObjects(plan.sizes.keys)
        } catch let e as MirrorError {
            try? fm.removeItem(at: building)
            throw e
        } catch {
            try? fm.removeItem(at: building)
            throw .io(error.localizedDescription)
        }
        // IOS-9: checked after each generation switch; a problem shows as the pin's problem line.
        let protection = protectionProblems()
        if !protection.isEmpty {
            lock.withLock {
                state.problems[plan.pin] = (state.problems[plan.pin] ?? []) + protection
                saveState()
            }
        }
        emit(.generation(plan.pin, PinGeneration(plan.sequence)))
        return PinGeneration(plan.sequence)
    }

    /// Writes the generation's metadata, then points `current` at it with one rename.
    private func writeMeta(_ meta: GenMeta, in dir: URL) throws(MirrorError) {
        do {
            let d = try JSONEncoder().encode(meta)
            try d.write(to: dir.appendingPathComponent("\(meta.dir).json"), options: .atomic)
            let tmp = dir.appendingPathComponent("current.new")
            try Data(meta.dir.utf8).write(to: tmp)
            guard rename(tmp.path, dir.appendingPathComponent("current").path) == 0 else { throw MirrorError.io("rename current") }
        } catch let e as MirrorError {
            throw e
        } catch {
            throw .io(error.localizedDescription)
        }
    }

    private func dropObjects(_ shas: some Sequence<String>) {
        let still = lock.withLock { Set(reserved.values.flatMap(\.keys)) }
        for sha in shas where !still.contains(sha) { try? fm.removeItem(at: objectURL(sha)) }
    }

    /// Forgets everything: every pin with its files, partial transfers and the read marks.
    public func wipe() {
        lock.withLock {
            state = MirrorState()
            gens = [:]
            reserved = [:]
            saveState()
        }
        for d in ["pins", "partial", "objects"] {
            let u = root.appendingPathComponent(d)
            trash(u)
            try? fm.createDirectory(at: u, withIntermediateDirectories: true)
            protect(u)
        }
        emit(.pins)
    }

    /// IOS-9's check: the mirror is excluded from backup and, on the iPhone, its files use Complete Unless Open.
    public func protectionProblems() -> [String] {
        var out: [String] = []
        if (try? root.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup != true {
            out.append("The mirror is not excluded from backup")
        }
        // The simulator has no data protection classes, so only a device can check them.
        #if os(iOS) && !targetEnvironment(simulator)
        let samples = lock.withLock { gens.map { pinDir($0.key).appendingPathComponent($0.value.dir) } }
        for dir in [root] + samples {
            let p = (try? fm.attributesOfItem(atPath: dir.path)[.protectionKey]) as? FileProtectionType
            if p != .completeUnlessOpen { out.append("\(dir.lastPathComponent): protection \(p?.rawValue ?? "none")") }
            if let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil), let f = e.nextObject() as? URL {
                let fp = (try? fm.attributesOfItem(atPath: f.path)[.protectionKey]) as? FileProtectionType
                if fp != .completeUnlessOpen { out.append("\(f.lastPathComponent): protection \(fp?.rawValue ?? "none")") }
            }
        }
        #endif
        return out
    }

    /// The problem lines of a pin, from the Mac and from the phone's own checks.
    public func problems(_ pin: Pin.ID) -> [String] { lock.withLock { state.problems[pin] ?? [] } }

    /// The path set and hashes of a pin's current generation as files on disk, for the tests' "equal on the phone".
    public func filesOnDisk(_ pin: Pin.ID) -> [String: String] {
        guard let meta = lock.withLock({ gens[pin] }) else { return [:] }
        let base = pinDir(pin).appendingPathComponent(meta.dir)
        var out: [String: String] = [:]
        guard let e = fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
        for case let u as URL in e where (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            let rel = String(u.standardizedFileURL.path.dropFirst(base.standardizedFileURL.path.count + 1))
            let fd = Darwin.open(u.path, O_RDONLY | O_CLOEXEC)
            out[rel] = fd >= 0 ? PinFiles.hash(fd: fd) : nil
            if fd >= 0 { close(fd) }
        }
        return out
    }

    // MARK: - PinLibrary

    public func pins() async -> [Pin] {
        lock.withLock {
            state.pins.values.map { info -> Pin in
                let g = gens[info.id]
                let entries = g?.entries.values
                let last = entries?.map(\.mtime).max().map { Date(timeIntervalSince1970: $0) } ?? .distantPast
                return Pin(id: info.id, name: info.name, macPath: info.macPath, kind: info.kind, lastChange: last,
                           size: entries?.reduce(0) { $0 + $1.size } ?? 0, generation: PinGeneration(g?.sequence ?? 0))
            }
            .sorted { ($0.lastChange, $1.name) > ($1.lastChange, $0.name) }
        }
    }

    public func files(in pin: Pin.ID) async -> [PinFile] {
        lock.withLock {
            guard let g = gens[pin] else { return [] }
            return g.entries.values.compactMap { e -> PinFile? in
                guard let kind = DocumentKind(fileName: e.path) else { return nil }
                let ref = PinFileRef(pin: pin, path: e.path)
                let name = ((e.path as NSString).lastPathComponent as NSString).deletingPathExtension
                return PinFile(ref: ref, kind: kind, title: g.titles[e.path] ?? name, modified: Date(timeIntervalSince1970: e.mtime), size: e.size,
                               changedSinceRead: state.reads[ref.storeKey] != e.sha, scripts: kind == .page ? (e.scripts ?? .off) : nil)
            }
            .sorted { ($0.modified, $1.ref.path) > ($1.modified, $0.ref.path) }
        }
    }

    public func open(_ file: PinFileRef) async throws -> PinnedDocument {
        let (g, entry): (GenMeta, ManifestEntry) = try lock.withLock {
            guard state.pins[file.pin] != nil, let g = gens[file.pin] else { throw PinLibraryError.noSuchPin(file.pin) }
            guard let e = g.entries[file.path] else { throw PinLibraryError.noSuchFile(file) }
            opens["\(file.pin)/\(g.dir)", default: 0] += 1
            return (g, e)
        }
        let genRoot = pinDir(file.pin).appendingPathComponent(g.dir, isDirectory: true)
        let key = "\(file.pin)/\(g.dir)"
        let kind = DocumentKind(fileName: file.path) ?? .note
        return PinnedDocument(ref: file, kind: kind, url: genRoot.appendingPathComponent(file.path), root: genRoot,
                              generation: PinGeneration(g.sequence), scripts: kind == .page ? (entry.scripts ?? .off) : nil) { [weak self] in
            self?.release(key, pin: file.pin, dir: g.dir)
        }
    }

    private func release(_ key: String, pin: String, dir: String) {
        let (drop, pinGone) = lock.withLock { () -> (Bool, Bool) in
            let n = (opens[key] ?? 1) - 1
            opens[key] = n > 0 ? n : nil
            return (n <= 0 && gens[pin]?.dir != dir, state.pins[pin] == nil)
        }
        guard drop else { return }
        if pinGone, lock.withLock({ !opens.keys.contains { $0.hasPrefix("\(pin)/") } }) {
            trash(pinDir(pin))
            return
        }
        try? fm.removeItem(at: pinDir(pin).appendingPathComponent(dir))
        try? fm.removeItem(at: pinDir(pin).appendingPathComponent("\(dir).json"))
    }

    public func resolve(_ reference: String, from file: PinFileRef) async -> PinReference {
        var ref = reference
        if let i = ref.firstIndex(of: "|") { ref = String(ref[..<i]) }
        if let i = ref.firstIndex(of: "#") { ref = String(ref[..<i]) }
        ref = ref.trimmingCharacters(in: .whitespaces).precomposedStringWithCanonicalMapping
        guard !ref.isEmpty else { return .file(file) }
        return lock.withLock {
            // The Mac's own resolution first (SYNC-4).
            if let t = gens[file.pin]?.entries[file.path]?.links?[ref] ?? gens[file.pin]?.entries[file.path]?.links?[reference] {
                guard let pin = t.pin, let path = t.path else { return .notOnPhone }
                return gens[pin]?.entries[path] != nil ? .file(PinFileRef(pin: pin, path: path)) : .notOnPhone
            }
            // A relative path inside the pin.
            let decoded = ref.removingPercentEncoding ?? ref
            var stack = file.path.split(separator: "/").map(String.init).dropLast()
            var leftPin = false
            for p in decoded.split(separator: "/").map(String.init) {
                switch p {
                case ".", "": continue
                case "..": if stack.popLast() == nil { leftPin = true }
                default: stack.append(p)
                }
            }
            let joined = stack.joined(separator: "/")
            if !leftPin, gens[file.pin]?.entries[joined] != nil { return .file(PinFileRef(pin: file.pin, path: joined)) }
            if !leftPin, gens[file.pin]?.entries[joined + ".md"] != nil { return .file(PinFileRef(pin: file.pin, path: joined + ".md")) }
            // A wiki link by name: this pin first, then the others.
            let want = LinkPath.foldKey((decoded as NSString).lastPathComponent)
            let order = [file.pin] + gens.keys.sorted().filter { $0 != file.pin }
            for pin in order {
                guard let g = gens[pin] else { continue }
                let hit = g.entries.keys.sorted().first { path in
                    let name = (path as NSString).lastPathComponent
                    return LinkPath.foldKey(name) == want || LinkPath.foldKey((name as NSString).deletingPathExtension) == want
                }
                if let hit { return .file(PinFileRef(pin: pin, path: hit)) }
            }
            return leftPin ? .notOnPhone : .missing
        }
    }

    public func markRead(_ file: PinFileRef) async {
        let changed = lock.withLock { () -> Bool in
            guard let sha = gens[file.pin]?.entries[file.path]?.sha, state.reads[file.storeKey] != sha else { return false }
            state.reads[file.storeKey] = sha
            saveState()
            return true
        }
        if changed { emit(.read(file)) }
    }

    public func changes() -> AsyncStream<PinLibraryChange> {
        let id = UUID()
        return AsyncStream { c in
            lock.withLock { listeners[id] = c }
            c.onTermination = { [weak self] _ in _ = self?.lock.withLock { self?.listeners.removeValue(forKey: id) } }
        }
    }

    // MARK: Titles

    /// A note's first heading, a board's `linen.title`, a page's `<title>`, or nil.
    static func title(of url: URL) -> String? {
        guard let kind = DocumentKind(fileName: url.lastPathComponent), let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: kind == .board ? 4 << 20 : 64 << 10)) ?? Data()
        let text = String(decoding: head, as: UTF8.self)
        switch kind {
        case .note:
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false).makeIterator()
            var first = true
            var inFront = false
            while let raw = lines.next() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if first, line == "---" { inFront = true; first = false; continue }
                first = false
                if inFront { if line == "---" { inFront = false }; continue }
                if line.hasPrefix("# ") { return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            }
            return nil
        case .board:
            guard let obj = try? JSONSerialization.jsonObject(with: head) as? [String: Any],
                  let t = (obj["linen"] as? [String: Any])?["title"] as? String, !t.isEmpty else { return nil }
            return t
        case .page:
            guard let r = text.range(of: "<title[^>]*>([^<]{1,300})</title>", options: [.regularExpression, .caseInsensitive]) else { return nil }
            let inner = text[r].replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            return inner.isEmpty ? nil : inner
        }
    }
}
