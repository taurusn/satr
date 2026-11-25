// Lane linen-lighter: measures what a VaultIndex costs, headless. Compiled together with LinenKit's sources (one
// module, so internals are visible): see build.sh beside this file.
//   measure each <folder>...     builds each vault's index alone, reports time, files, memory, then drops it
//   measure all <folder>...      builds every index and holds them together (Linen today keeps all), then drops them
//   measure digest <folder>...   prints every file URL the index hands out and every link's resolution, for diffing
import Darwin
import Foundation

func footprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Int(info.phys_footprint) : -1
}

func peakFootprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Int(info.ledger_phys_footprint_peak) : -1
}

let relief = ProcessInfo.processInfo.environment["LIGHTER_RELIEF"] != nil

func mallocInUse() -> Int {
    var stats = malloc_statistics_t()
    malloc_zone_statistics(nil, &stats)
    return Int(stats.size_in_use)
}

func mb(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }

func vaultFor(_ path: String) -> Vault {
    VaultLocator.vault(for: URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true))
}

func build(_ vault: Vault) async -> VaultIndex {
    let index = VaultIndex(vault: vault)
    await index.build()
    return index
}

func settle() {
    // Let autorelease pools drain and the allocator settle before reading memory.
    for _ in 0..<3 { autoreleasepool { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) } }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let mode = args.first, args.count > 1 else {
    print("usage: measure each|all|digest <folder>...")
    exit(2)
}
let folders = Array(args.dropFirst())

switch mode {
case "each":
    for folder in folders {
        let vault = vaultFor(folder)
        settle()
        let f0 = footprint(), m0 = mallocInUse()
        var index: VaultIndex? = VaultIndex(vault: vault)
        let start = Date()
        await index!.build()
        let seconds = Date().timeIntervalSince(start)
        settle()
        let f1 = footprint(), m1 = mallocInUse()
        let (notes, others) = (index!.snapshotTables.notes.count, index!.snapshotTables.attachments.count)
        let files = notes + others
        let s = index!.resolutionSummary()
        print("\(folder) [\(vault.kind)] notes \(notes), other files \(others), build \(Int(seconds * 1000)) ms")
        print("  held: footprint +\(mb(f1 - f0)) (peak \(mb(peakFootprint() - f0)) over start), malloc +\(mb(m1 - m0)) (\(files > 0 ? (m1 - m0) / files : 0) B per file)")
        print("  links \(s.links): resolved \(s.resolved), ambiguous \(s.ambiguous), missing \(s.missing)")
        if ProcessInfo.processInfo.environment["LIGHTER_PAUSE_HELD"] != nil { print("  pid \(getpid()) held"); fflush(stdout); sleep(20) }
        if relief { malloc_zone_pressure_relief(nil, 0); settle(); print("  held after pressure relief: footprint +\(mb(footprint() - f0))") }
        weak var gone = index
        index = nil
        _ = index
        settle()
        print("  index freed: \(gone == nil)")
        if ProcessInfo.processInfo.environment["LIGHTER_PAUSE"] != nil { print("  pid \(getpid()) paused"); sleep(30) }
        print("  after drop: footprint \(mb(footprint() - f0)) over start, malloc \(mb(mallocInUse() - m0)) over start")
        if relief { malloc_zone_pressure_relief(nil, 0); settle(); print("  after drop and pressure relief: footprint \(mb(footprint() - f0)) over start") }
    }
case "all":
    settle()
    let f0 = footprint(), m0 = mallocInUse()
    var held: [VaultIndex] = []
    var total = 0.0
    var files = 0
    for folder in folders {
        let index = VaultIndex(vault: vaultFor(folder))
        let start = Date()
        await index.build()
        total += Date().timeIntervalSince(start)
        files += index.snapshotTables.notes.count + index.snapshotTables.attachments.count
        held.append(index)
    }
    settle()
    let f1 = footprint(), m1 = mallocInUse()
    print("all \(folders.count) vaults held: \(files) files, build \(Int(total * 1000)) ms, footprint +\(mb(f1 - f0)), malloc +\(mb(m1 - m0)), process footprint \(mb(f1))")
    held.removeAll()
    settle()
    print("after drop: footprint \(mb(footprint() - f0)) over start, malloc \(mb(mallocInUse() - m0)) over start, process footprint \(mb(footprint()))")
case "digest":
    for folder in folders {
        let index = await build(vaultFor(folder))
        let tables = index.snapshotTables
        print("# \(folder)")
        for note in tables.notes {
            print("N \(tables.url(of: note.file).absoluteString) \(note.name)")
            for h in note.headings { print("  H \(h.level) \(h.line) \(h.text)") }
            for a in note.aliases { print("  AL \(a)") }
            for l in note.links { print("  W \(l.isEmbed) \(l.inFrontmatter) \(l.line) \(l.sentence)") }
            for link in note.links {
                switch index.resolve(link.raw, from: tables.url(of: note.file)) {
                case let .note(u, heading, block): print("  L \(link.raw) -> \(u.absoluteString) #\(heading ?? "") ^\(block ?? "")")
                case let .ambiguous(us): print("  L \(link.raw) -> ambiguous \(us.map(\.absoluteString).joined(separator: " | "))")
                case let .missing(p): print("  L \(link.raw) -> missing \(p)")
                }
            }
            for b in index.backlinks(to: tables.url(of: note.file), limit: 1000) { print("  B \(b.source.absoluteString) \(b.line) \(b.count) \(b.sentence)") }
        }
        for file in tables.attachments { print("A \(tables.url(of: file).absoluteString)") }
        for r in index.search("a", limit: 50) { print("S \(r.url.absoluteString)") }
    }
case "phases":
    for folder in folders {
        let root = Paths.canonical(vaultFor(folder).root)
        settle()
        let f0 = footprint(), m0 = mallocInUse()
        func line(_ label: String) { settle(); print("  \(label): footprint +\(mb(footprint() - f0)), peak +\(mb(peakFootprint() - f0)), malloc +\(mb(mallocInUse() - m0))") }
        print(folder)
        var files: [ScannedFile]? = VaultScanner.walk(root: root)
        line("walk (\(files!.count) files)")
        let markdown = files!.filter { VaultScanner.isNote($0.path) }
        let others = files!.filter { !VaultScanner.isNote($0.path) }.map { FileEntry(path: $0.path) }
        line("entries for other files")
        var records: [NoteRecord] = []
        for f in markdown { records.append(VaultScanner.note(root: root, path: f.path)) }
        line("notes parsed one at a time")
        files = nil
        line("scan list dropped")
        let snapshot = IndexSnapshot(root: root, notes: records, attachments: others)
        line("snapshot (\(snapshot.tables.notes.count) notes)")
    }
default:
    print("unknown mode \(mode)")
    exit(2)
}
