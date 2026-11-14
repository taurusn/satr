import Foundation
import Synchronization

// The phone's view of what is kept on it (PRD-2 IOS-1, SYNC-3, SYNC-4). The iPhone app reads pinned files only
// through `PinLibrary`, and the link's state only through `PhoneLink`; the link (M12) implements both over its mirror,
// and `FixturePinLibrary` serves test files for development.
//
// The mirror's rules this contract keeps: the pin set is the Mac's (the phone never adds a pin); each pin points at
// one generation at a time and switches with one atomic rename; a document already open keeps reading the generation
// it opened until it is closed, so a board never shows with its old notes and a page never runs with its old scripts.

/// One pin as the phone holds it: a Mac folder, or a single Mac file, kept on this iPhone.
public struct Pin: Sendable, Hashable, Identifiable, Codable {
    /// The Mac's pin ID, stable for the pin's life.
    public typealias ID = String

    /// A folder carries its notes, boards, pages, sidecars and the files they reference inside it; a file pin is one
    /// file (SYNC-3's "Also keep these files").
    public enum Kind: String, Sendable, Codable {
        case folder, file
    }

    public var id: ID
    /// What the Library's group header shows, usually the folder's or file's name.
    public var name: String
    /// The Mac folder or file it was pinned from, as the Mac shows it (`projects/requests`); for display only.
    public var macPath: String
    public var kind: Kind
    /// The newest change among the pin's files in its current generation.
    public var lastChange: Date
    /// Bytes the current generation takes on this phone.
    public var size: Int64
    /// The generation the pin points at now.
    public var generation: PinGeneration

    public init(id: ID, name: String, macPath: String, kind: Kind, lastChange: Date, size: Int64, generation: PinGeneration) {
        self.id = id
        self.name = name
        self.macPath = macPath
        self.kind = kind
        self.lastChange = lastChange
        self.size = size
        self.generation = generation
    }
}

/// A pin's generation: the Mac's manifest sequence it was built from (SYNC-4). Newer generations compare greater.
public struct PinGeneration: Sendable, Hashable, Codable, Comparable, CustomStringConvertible {
    public var sequence: UInt64

    public init(_ sequence: UInt64) { self.sequence = sequence }

    public static func < (a: Self, b: Self) -> Bool { a.sequence < b.sequence }
    public var description: String { "g\(sequence)" }
}

/// A file inside a pin, by the pin and its relative path (NFC, `/`-separated, validated by the mirror). The same
/// reference names the file in every generation.
public struct PinFileRef: Sendable, Hashable, Codable, CustomStringConvertible {
    public var pin: Pin.ID
    public var path: String

    public init(pin: Pin.ID, path: String) {
        self.pin = pin
        self.path = path
    }

    /// A key for per-file stores (place, change baselines, read marks) that survives generation switches, which give
    /// every file a new location on disk.
    public var storeKey: String { "pin:\(pin)/\(path)" }
    public var description: String { storeKey }
}

/// What Linen shows a file as.
public enum DocumentKind: String, Sendable, Codable, CaseIterable {
    /// Markdown and plain text, in the note renderer.
    case note
    /// A JSON Canvas board.
    case board
    /// A sealed HTML page (PAGE-1 to PAGE-12).
    case page

    /// The kind for a file name, or nil for files the Library does not list (images, sidecars, scripts).
    public init?(fileName: String) {
        if fileName.hasSuffix(".notes.json") { return nil }
        switch (fileName as NSString).pathExtension.lowercased() {
        case "md", "markdown", "txt": self = .note
        case "canvas": self = .board
        case "html", "htm": self = .page
        default: return nil
        }
    }
}

/// A page's script policy as the Mac decided it (PAGE-7), carried in the manifest with its source: `root:<id>` for a
/// trusted folder, `file` for a trusted file, `untrusted` otherwise.
public struct PageScriptPolicy: Sendable, Hashable, Codable {
    public var on: Bool
    public var source: String

    public init(on: Bool, source: String) {
        self.on = on
        self.source = source
    }

    /// Scripts off, which is every page until the Mac's trust decisions arrive with the link.
    public static let off = PageScriptPolicy(on: false, source: "untrusted")
}

/// One file of a pin's current generation, as the Library lists it.
public struct PinFile: Sendable, Hashable, Identifiable {
    public var ref: PinFileRef
    public var kind: DocumentKind
    /// A note's first heading, a board's own title, a page's `<title>`, else the file name without its extension.
    public var title: String
    public var modified: Date
    public var size: Int64
    /// True when the file changed after it was last opened on this phone (the Library's thread, IOS-1).
    public var changedSinceRead: Bool
    /// Pages only: what the Mac decided about its scripts.
    public var scripts: PageScriptPolicy?

    public var id: PinFileRef { ref }
    public var fileName: String { (ref.path as NSString).lastPathComponent }

    public init(ref: PinFileRef, kind: DocumentKind, title: String, modified: Date, size: Int64, changedSinceRead: Bool, scripts: PageScriptPolicy? = nil) {
        self.ref = ref
        self.kind = kind
        self.title = title
        self.modified = modified
        self.size = size
        self.changedSinceRead = changedSinceRead
        self.scripts = scripts
    }
}

/// Where a reference written in a pinned file (a wiki link, an image, an embed, a board's file node) leads on the
/// phone. The Mac resolves links with its own index and records the targets in the manifest, so the phone opens the
/// same file the Mac would (SYNC-4); references into another pin resolve there (SYNC-3).
public enum PinReference: Sendable, Hashable {
    /// A file kept on this phone, in this pin or another.
    case file(PinFileRef)
    /// The Mac has it, but it is not kept on this iPhone ("Not on this iPhone").
    case notOnPhone
    /// Nothing by that name.
    case missing
}

/// What changed in the library.
public enum PinLibraryChange: Sendable, Hashable {
    /// Pins were added, removed or renamed (the Mac's pin set).
    case pins
    /// A pin now points at a newer generation.
    case generation(Pin.ID, PinGeneration)
    /// A file's read state changed.
    case read(PinFileRef)
}

/// Errors from opening a pinned file.
public enum PinLibraryError: Error, Sendable, Equatable {
    case noSuchPin(Pin.ID)
    case noSuchFile(PinFileRef)
}

/// The files kept on this iPhone.
public protocol PinLibrary: AnyObject, Sendable {
    /// The pins, most recently changed first.
    func pins() async -> [Pin]
    /// The files of a pin's current generation, most recently changed first.
    func files(in pin: Pin.ID) async -> [PinFile]
    /// Opens one file read-only. The document holds the generation it was opened in until it is closed, even when
    /// the pin switches to a newer one meanwhile; to show the newer content, open the file again and close the old one.
    func open(_ file: PinFileRef) async throws -> PinnedDocument
    /// Resolves a reference as written in a file (`Linked Note`, `images/a.png`, `../plans/q3.canvas`).
    func resolve(_ reference: String, from file: PinFileRef) async -> PinReference
    /// Records that the file was read as it is now, clearing its thread.
    func markRead(_ file: PinFileRef) async
    /// Changes from now on. Each call returns its own stream; it ends when the library goes away.
    func changes() -> AsyncStream<PinLibraryChange>
}

/// One open pinned file, holding its generation until `close()` (or until it is released).
public final class PinnedDocument: Sendable {
    public let ref: PinFileRef
    public let kind: DocumentKind
    /// The file, read-only, inside its generation.
    public let url: URL
    /// The pin's root in that generation: references are resolved and served only inside it.
    public let root: URL
    public let generation: PinGeneration
    /// Pages only: their script policy in this generation (the trust revision travels with the generation).
    public let scripts: PageScriptPolicy?
    private let release: Mutex<(@Sendable () -> Void)?>

    public init(ref: PinFileRef, kind: DocumentKind, url: URL, root: URL, generation: PinGeneration, scripts: PageScriptPolicy?,
                release: @escaping @Sendable () -> Void) {
        self.ref = ref
        self.kind = kind
        self.url = url
        self.root = root
        self.generation = generation
        self.scripts = scripts
        self.release = Mutex(release)
    }

    /// Lets the generation go once nothing else reads it. Safe to call more than once.
    public func close() {
        let r = release.withLock { r -> (@Sendable () -> Void)? in
            defer { r = nil }
            return r
        }
        r?()
    }

    deinit { close() }

    /// A file inside the document's pin root by a path relative to the document's folder, or nil when it would leave
    /// the root or does not exist.
    public func sibling(_ relative: String) -> URL? {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, !relative.hasPrefix("/") else { return nil }
        var stack = ref.path.split(separator: "/").map(String.init).dropLast()
        for p in parts {
            switch p {
            case ".": continue
            case "..": if stack.popLast() == nil { return nil }
            default: stack.append(p)
            }
        }
        let file = stack.reduce(root) { $0.appendingPathComponent($1) }
        guard file.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"),
              FileManager.default.fileExists(atPath: file.path) else { return nil }
        return file
    }
}

// MARK: - The link's state, for the sync line, Settings and pairing (SYNC-1, SYNC-7, IOS-10)

/// The one sync line in the Library (SYNC-7). The app adds the install's expiry (IOS-10) itself.
public enum LinkStatus: Sendable, Hashable {
    /// No Mac paired yet.
    case notPaired
    /// "Up to date with MacBook Air, 2 min ago".
    case upToDate(mac: String, at: Date)
    /// "Mac not nearby; showing copies from 09:14".
    case notNearby(copiesFrom: Date?)
    /// "MacBook Air is asleep; copies from 13:02".
    case asleep(mac: String, copiesFrom: Date?)
    /// "Receiving 3 of 9 files from MacBook Air".
    case receiving(mac: String, done: Int, total: Int)
    /// "Finishing 3 files paused when you left".
    case finishing(files: Int)
    /// "Local network access is off for Linen", with the way to Settings.
    case localNetworkOff
    /// "This Mac no longer knows this iPhone · Pair again".
    case forgotten
    /// "Not enough space on this iPhone: 1.2 GB needed".
    case outOfSpace(needed: Int64)
}

/// The Mac this phone is paired with.
public struct PairedMac: Sendable, Hashable, Codable {
    /// The Mac's name as it gave it at pairing ("MacBook Air").
    public var name: String
    /// The name Hatim typed for this phone at pairing.
    public var phoneName: String
    public var pairedAt: Date
    public var lastSeen: Date?

    public init(name: String, phoneName: String, pairedAt: Date, lastSeen: Date?) {
        self.name = name
        self.phoneName = phoneName
        self.pairedAt = pairedAt
        self.lastSeen = lastSeen
    }
}

/// Where a pairing stands (section 9.3's pairing mode).
public enum PairingStep: Sendable, Hashable {
    /// Dialing the Mac named in the code; iOS may ask for local network access now.
    case dialing
    /// Both screens show these six digits; the Mac waits for Allow.
    case match(digits: String, mac: String)
    /// Allowed on the Mac; the phone is paired.
    case paired(PairedMac)
    /// Pairing ended without a pairing.
    case failed(PairingFailure)
}

/// Why a pairing ended (the Mac's `pair-result` reasons, plus what the phone finds itself).
public enum PairingFailure: String, Sendable, Hashable, Codable {
    case code, expired, refused, timeout, busy
    /// The scanned code is not a Linen pairing code.
    case notALinenCode
    /// The Mac in the code was not found.
    case unreachable
    case localNetworkOff
}

/// The link to the Mac as the phone's screens see it.
public protocol PhoneLink: AnyObject, Sendable {
    /// The sync line now.
    func status() async -> LinkStatus
    /// The sync line from now on; each call returns its own stream.
    func statusUpdates() -> AsyncStream<LinkStatus>
    /// The paired Mac, or nil.
    func pairedMac() async -> PairedMac?
    /// Pairs from the text of a scanned QR code and the name Hatim typed for this phone.
    func pair(scannedCode: String, phoneName: String) -> AsyncStream<PairingStep>
    /// The paired Mac's name when pairing with this code would replace it with another Mac (the screen asks first).
    func replacesPairedMac(scannedCode: String) async -> String?
    /// Forgets the Mac and removes every pin with its files.
    func forgetMac() async
    /// Pull to sync: dial now if a Mac is in reach.
    func syncNow() async
}

/// The link before M12: never paired, and pairing says the Mac cannot be reached.
public final class UnpairedLink: PhoneLink {
    public init() {}
    public func status() async -> LinkStatus { .notPaired }
    public func statusUpdates() -> AsyncStream<LinkStatus> {
        AsyncStream { $0.yield(.notPaired) }
    }
    public func pairedMac() async -> PairedMac? { nil }
    public func pair(scannedCode: String, phoneName: String) -> AsyncStream<PairingStep> {
        AsyncStream { c in
            c.yield(.dialing)
            c.yield(.failed(.unreachable))
            c.finish()
        }
    }
    public func forgetMac() async {}
    public func syncNow() async {}
}

public extension PhoneLink {
    func replacesPairedMac(scannedCode: String) async -> String? { nil }
}
