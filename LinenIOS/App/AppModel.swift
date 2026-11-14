import LinenKit
import SwiftUI

/// One group in the Library: a pin and its files (IOS-1).
struct LibraryGroup: Identifiable, Equatable {
    var pin: Pin
    var files: [PinFile]
    var id: Pin.ID { pin.id }
}

/// What a document screen shows: a pinned file, or a file opened from elsewhere (IOS-6).
enum DocumentSource: Hashable {
    case pinned(PinFileRef)
    case opened(String)
}

/// Everything the phone's screens share: the library and the link (through LinenKit's contract), files opened from
/// elsewhere, the place and change stores, and the reader's settings.
@MainActor
@Observable
final class AppModel {
    let library: any PinLibrary
    let link: any PhoneLink
    let openedStore: OpenedFiles
    let places: PlaceStore
    let baselines: BaselineStore

    private(set) var groups: [LibraryGroup] = []
    private(set) var opened: [OpenedFile] = []
    private(set) var status: LinkStatus = .notPaired
    private(set) var pairedMac: PairedMac?
    private(set) var loaded = false
    /// When this install stops opening (IOS-10): the provisioning profile's expiry, nil on the simulator.
    let expiry: Date? = InstallExpiry.date()
    var search = ""
    var path: [DocumentSource] = []
    #if DEBUG
    /// Page errors by document, for the fixture sweep (`-LinenSweep`).
    var sweepErrors: [String: [String]] = [:]

    /// Opens every file in the library in turn, as the reader would, and writes the console and page errors each one
    /// raised to Documents/sweep.json.
    func sweep() async {
        var report: [[String: Any]] = []
        for g in groups {
            for f in g.files {
                path = [.pinned(f.ref)]
                try? await Task.sleep(for: .seconds(f.kind == .page ? 4 : 2.5))
                report.append(["file": f.ref.storeKey, "errors": sweepErrors[f.ref.storeKey] ?? []])
                path = []
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let total = report.reduce(0) { $0 + (($1["errors"] as? [String])?.count ?? 0) }
        let out: [String: Any] = ["files": report.count, "errors": total, "report": report]
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: docs.appendingPathComponent("sweep.json")) }
    }
    #endif

    /// A heading a link named, shown once its note renders (`[[Note#Heading]]`).
    var pendingHeadings: [PinFileRef: String] = [:]
    /// A file that could not be opened from elsewhere, with the reason, shown once in the Library.
    var openError: String?

    init(library: any PinLibrary, link: any PhoneLink) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Linen", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        var noBackup = URLResourceValues()
        noBackup.isExcludedFromBackup = true
        var s = support
        try? s.setResourceValues(noBackup)
        self.library = library
        self.link = link
        openedStore = OpenedFiles(directory: support.appendingPathComponent("Opened", isDirectory: true))
        places = PlaceStore(directory: support)
        baselines = BaselineStore(directory: support)
    }

    /// The library as the app starts it: the link's mirror of what the Mac keeps on this iPhone (M12). A debug build
    /// serves Linen's test fixtures instead, unless it is launched with `-LinenLink`.
    static func standard() -> AppModel {
        #if DEBUG
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Linen", isDirectory: true)
        if !Launch.has("-LinenLink"), let fixtures = Bundle.main.resourceURL?.appendingPathComponent("fixtures"),
           FileManager.default.fileExists(atPath: fixtures.path), !Launch.has("-LinenNoFixtures") {
            var sources = [
                FixturePinLibrary.Source(id: "fixtures-notes", name: "Fixtures", macPath: "Satr/Tests/Fixtures", root: fixtures, excluded: ["boards"]),
                FixturePinLibrary.Source(id: "fixtures-boards", name: "boards", macPath: "Satr/Tests/Fixtures/boards", root: fixtures.appendingPathComponent("boards")),
            ]
            // A folder of the developer's own in the app's Documents, served as a third pin (pages with sibling files).
            if let dev = Launch.value("-LinenDevPin") {
                let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(dev)
                sources.append(FixturePinLibrary.Source(id: "dev", name: dev, macPath: "dev/\(dev)", root: root))
            }
            let f = FixturePinLibrary(sources: sources, reads: ReadMarks(directory: support))
            for ref in Launch.list("-LinenChanged").compactMap(Launch.ref) { f.markChanged(ref) }
            let link: any PhoneLink = Launch.value("-LinenStatus").map { DemoLink($0) } ?? UnpairedLink()
            return AppModel(library: f, link: link)
        }
        #endif
        if let link = try? MirrorLink.makeDefault() {
            link.registerBackgroundRefresh(identifier: Self.refreshTask)
            return AppModel(library: link.mirror, link: link)
        }
        return AppModel(library: EmptyPinLibrary(), link: UnpairedLink())
    }

    /// The background refresh task (SYNC-5), also in Info.plist's BGTaskSchedulerPermittedIdentifiers.
    static let refreshTask = "com.hatim.linen.ios.refresh"

    /// A pairing code handed over by the Camera app (`linen://pair?...`), for the pairing screen.
    var pendingPairCode: String?

    /// Leaving the front: ask iOS for a background refresh later.
    func enteredBackground() {
        (link as? MirrorLink)?.scheduleBackgroundRefresh(identifier: Self.refreshTask)
        flush()
    }

    /// A URL handed to Linen: a pairing code from the Camera app, or a file from Files, AirDrop or the share sheet.
    func handle(_ url: URL) {
        if url.scheme?.lowercased() == "linen" {
            pendingPairCode = url.absoluteString
        } else {
            openFromElsewhere(url)
        }
    }

    // MARK: Keeping current

    func start() async {
        await refresh()
        async let pins: Void = follow(library.changes())
        async let line: Void = follow(link.statusUpdates())
        _ = await (pins, line)
    }

    private func follow(_ changes: AsyncStream<PinLibraryChange>) async {
        for await _ in changes { await refresh() }
    }

    private func follow(_ updates: AsyncStream<LinkStatus>) async {
        for await s in updates {
            status = s
            pairedMac = await link.pairedMac()
        }
    }

    func refresh() async {
        var out: [LibraryGroup] = []
        for pin in await library.pins() {
            out.append(LibraryGroup(pin: pin, files: await library.files(in: pin.id)))
        }
        groups = out.sorted { ($0.files.map(\.modified).max() ?? $0.pin.lastChange) > ($1.files.map(\.modified).max() ?? $1.pin.lastChange) }
        opened = openedStore.all()
        status = await link.status()
        pairedMac = await link.pairedMac()
        loaded = true
    }

    /// Groups and opened files narrowed by the search field (by name, IOS-1).
    var filteredGroups: [LibraryGroup] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return groups }
        return groups.compactMap { g in
            let files = g.files.filter { $0.title.localizedStandardContains(q) || $0.fileName.localizedStandardContains(q) }
            return files.isEmpty ? nil : LibraryGroup(pin: g.pin, files: files)
        }
    }

    var filteredOpened: [OpenedFile] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return opened }
        return opened.filter { $0.title.localizedStandardContains(q) || $0.name.localizedStandardContains(q) }
    }

    /// Bytes kept for pins on this phone.
    var keptBytes: Int64 { groups.reduce(0) { $0 + $1.pin.size } }

    /// The install's last two days (IOS-10): the sync line warns before the app stops opening.
    var expiryWarningDays: Int? {
        #if DEBUG
        if let d = Launch.value("-LinenExpiryDays").flatMap(Int.init) { return d }
        #endif
        guard let expiry else { return nil }
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: Calendar.current.startOfDay(for: expiry)).day ?? 0
        return days <= 2 ? max(days, 0) : nil
    }

    // MARK: Opening from elsewhere (IOS-6)

    /// A file handed over by Files, AirDrop or the share sheet: copied, listed under "Opened on this iPhone", shown.
    func openFromElsewhere(_ url: URL) {
        guard url.isFileURL else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let file = try openedStore.add(copying: url)
            // iOS copies a file it hands over into Documents/Inbox; Linen keeps its own copy only.
            let inbox = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Inbox").standardizedFileURL
            if url.standardizedFileURL.path.hasPrefix(inbox.path + "/") { try? FileManager.default.removeItem(at: url) }
            opened = openedStore.all()
            path = [.opened(file.id)]
        } catch {
            openError = String(localized: "Linen opens notes, boards and pages (.md, .txt, .canvas, .html); \(url.lastPathComponent) is not one.")
        }
    }

    func removeOpened(_ id: String) {
        openedStore.remove(id)
        opened = openedStore.all()
        places.remove(forKey: "opened:\(id)")
        baselines.remove(forKey: "opened:\(id)")
    }

    func flush() {
        places.flush()
        baselines.flush()
    }
}

/// The library before the link: no pins.
final class EmptyPinLibrary: PinLibrary {
    func pins() async -> [Pin] { [] }
    func files(in pin: Pin.ID) async -> [PinFile] { [] }
    func open(_ file: PinFileRef) async throws -> PinnedDocument { throw PinLibraryError.noSuchPin(file.pin) }
    func resolve(_ reference: String, from file: PinFileRef) async -> PinReference { .missing }
    func markRead(_ file: PinFileRef) async {}
    func changes() -> AsyncStream<PinLibraryChange> { AsyncStream { _ in } }
}

/// This install's expiry from its provisioning profile (IOS-10). Development installs on the paid team last a year.
enum InstallExpiry {
    static func date() -> Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.range(of: "<?xml"), let end = text.range(of: "</plist>", range: start.upperBound..<text.endIndex) else { return nil }
        let plist = Data(text[start.lowerBound..<end.upperBound].utf8)
        let obj = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]
        return obj?["ExpirationDate"] as? Date
    }
}

/// Launch arguments for development and screenshots (`-LinenOpen fixtures-boards/big-500.canvas`).
enum Launch {
    static func has(_ name: String) -> Bool { ProcessInfo.processInfo.arguments.contains(name) }
    static func value(_ name: String) -> String? {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
        return a[i + 1]
    }
    static func list(_ name: String) -> [String] { value(name)?.split(separator: ",").map(String.init) ?? [] }
    /// `pin/relative/path`.
    static func ref(_ s: String) -> PinFileRef? {
        guard let slash = s.firstIndex(of: "/") else { return nil }
        return PinFileRef(pin: String(s[..<slash]), path: String(s[s.index(after: slash)...]))
    }
}
