import Foundation

// The link's frames (PRD-2 section 9.3). A frame is one type byte, a four-byte big-endian length and the payload:
// JSON for every frame but `chunk`, which carries its hash, offset and bytes in binary. A frame that is not in this
// list, comes from the wrong side, belongs to the other kind of session or is larger than `LinkBounds.maxFrame` ends
// the session.

/// Which side sent a frame.
public enum LinkSide: Sendable, Hashable {
    case mac, phone
}

/// The two kinds of session: a pairing session (an unpinned phone certificate, pairing mode only) and a pinned one.
public enum LinkSessionKind: Sendable, Hashable {
    case pairing, pinned
}

public enum FrameType: UInt8, Sendable, CaseIterable {
    case hello = 1
    case pins = 2
    case pinsOK = 3
    case manifest = 4
    case want = 5
    case chunk = 6
    case done = 7
    case changed = 8
    case pairCode = 20
    case pairResult = 21

    public var sender: LinkSide {
        switch self {
        case .hello, .pinsOK, .want, .done, .pairCode: .phone
        case .pins, .manifest, .chunk, .changed, .pairResult: .mac
        }
    }

    public var session: LinkSessionKind {
        switch self {
        case .pairCode, .pairResult: .pairing
        default: .pinned
        }
    }

    /// True when a frame of this type may arrive on a session of `kind` from `side`.
    public func allowed(on kind: LinkSessionKind, from side: LinkSide) -> Bool {
        session == kind && sender == side
    }
}

public enum FrameError: Error, Sendable, Equatable {
    case unknownType(UInt8)
    case tooLarge(Int)
    case wrongDirection(FrameType)
    case wrongSession(FrameType)
    case malformed(FrameType)
}

/// One frame: its type and its payload bytes.
public struct Frame: Sendable, Equatable {
    public static let headerSize = 5

    public var type: FrameType
    public var payload: Data

    public init(type: FrameType, payload: Data) {
        self.type = type
        self.payload = payload
    }

    /// The header and payload as sent.
    public var encoded: Data {
        var d = Data(capacity: Self.headerSize + payload.count)
        d.append(type.rawValue)
        let n = UInt32(payload.count)
        d.append(contentsOf: [UInt8(n >> 24), UInt8((n >> 16) & 0xff), UInt8((n >> 8) & 0xff), UInt8(n & 0xff)])
        d.append(payload)
        return d
    }

    /// Reads a header: the type and the payload length, refusing an unknown type or a length over the bound.
    public static func header(_ bytes: some Collection<UInt8>) throws(FrameError) -> (FrameType, Int) {
        let b = Array(bytes.prefix(headerSize))
        precondition(b.count == headerSize)
        guard let type = FrameType(rawValue: b[0]) else { throw .unknownType(b[0]) }
        let n = Int(b[1]) << 24 | Int(b[2]) << 16 | Int(b[3]) << 8 | Int(b[4])
        guard n <= LinkBounds.maxFrame else { throw .tooLarge(n) }
        return (type, n)
    }

    // MARK: Typed payloads

    public static func json<T: Encodable>(_ type: FrameType, _ value: T) -> Frame {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        // Encoding plain structs of strings and numbers cannot fail.
        return Frame(type: type, payload: (try? e.encode(value)) ?? Data())
    }

    public func decode<T: Decodable>(_: T.Type) throws(FrameError) -> T {
        do { return try JSONDecoder().decode(T.self, from: payload) } catch { throw .malformed(type) }
    }
}

/// Splits a byte stream into frames; the loopback tests and any transport without `NWProtocolFramer` use it.
public struct FrameReader: Sendable {
    private var buffer = Data()

    public init() {}

    /// Adds bytes and returns the frames they complete. Throws at the first bad header; the session must end.
    public mutating func push(_ bytes: Data) throws(FrameError) -> [Frame] {
        buffer.append(bytes)
        var out: [Frame] = []
        while buffer.count >= Frame.headerSize {
            let (type, n) = try Frame.header(buffer.prefix(Frame.headerSize))
            guard buffer.count >= Frame.headerSize + n else { break }
            let start = buffer.startIndex + Frame.headerSize
            out.append(Frame(type: type, payload: Data(buffer[start..<start + n])))
            buffer = Data(buffer[(start + n)...])
        }
        return out
    }
}

// MARK: - Payloads

/// What the phone holds of one pin, in `hello`.
public struct HeldPin: Codable, Sendable, Hashable {
    public var id: String
    public var manifest: String
    public var sequence: UInt64
    public var trust: UInt64

    public init(id: String, manifest: String, sequence: UInt64, trust: UInt64) {
        self.id = id
        self.manifest = manifest
        self.sequence = sequence
        self.trust = trust
    }
}

/// `hello` (P): the protocol version, the pin-set generation the phone holds, and per pin its manifest and sequence.
public struct Hello: Codable, Sendable, Hashable {
    public var version: Int
    public var pinSet: UInt64
    public var pins: [HeldPin]

    public init(version: Int = LinkBounds.protocolVersion, pinSet: UInt64, pins: [HeldPin]) {
        self.version = version
        self.pinSet = pinSet
        self.pins = pins
    }
}

/// One pin as the Mac's pin set lists it.
public struct PinInfo: Codable, Sendable, Hashable {
    public var id: String
    public var kind: Pin.Kind
    public var name: String
    /// The folder or file it was pinned from, shortened for display (`~/notes/plans`).
    public var macPath: String
    public var trust: UInt64

    public init(id: String, kind: Pin.Kind, name: String, macPath: String, trust: UInt64) {
        self.id = id
        self.kind = kind
        self.name = name
        self.macPath = macPath
        self.trust = trust
    }
}

/// `pins` (M): the whole pin set and its generation; a pin absent from it is removed with its files.
public struct PinSetFrame: Codable, Sendable, Hashable {
    public var generation: UInt64
    public var pins: [PinInfo]

    public init(generation: UInt64, pins: [PinInfo]) {
        self.generation = generation
        self.pins = pins
    }
}

/// `pins-ok` (P): the pin-set generation the phone has applied.
public struct PinsOK: Codable, Sendable, Hashable {
    public var generation: UInt64

    public init(generation: UInt64) { self.generation = generation }
}

/// Where a reference written in a note leads, as the Mac resolved it: a file in a pin, or nothing kept on the phone.
public struct LinkTargetRef: Codable, Sendable, Hashable {
    /// Nil when the Mac has the target but it is not pinned ("Not on this iPhone").
    public var pin: String?
    public var path: String?

    public init(pin: String?, path: String?) {
        self.pin = pin
        self.path = path
    }

    public static let notOnPhone = LinkTargetRef(pin: nil, path: nil)
}

/// One file in a manifest.
public struct ManifestEntry: Codable, Sendable, Hashable {
    public var path: String
    public var size: Int64
    /// Modification time, seconds since 1970.
    public var mtime: Double
    /// SHA-256, lowercase hex.
    public var sha: String
    public var seq: UInt64
    /// Pages only: the effective script policy and its source (PAGE-7).
    public var scripts: PageScriptPolicy?
    /// Notes only: each reference as written, resolved by the Mac.
    public var links: [String: LinkTargetRef]?

    public init(path: String, size: Int64, mtime: Double, sha: String, seq: UInt64, scripts: PageScriptPolicy? = nil, links: [String: LinkTargetRef]? = nil) {
        self.path = path
        self.size = size
        self.mtime = mtime
        self.sha = sha
        self.seq = seq
        self.scripts = scripts
        self.links = links
    }

    /// The same file for the phone's purposes: content, policy and links. Sequence and time alone do not count.
    public func sameContent(as other: ManifestEntry) -> Bool {
        sha == other.sha && size == other.size && scripts == other.scripts && links == other.links
    }
}

/// A removal: the path and the sequence it was removed at.
public struct Tombstone: Codable, Sendable, Hashable {
    public var path: String
    public var seq: UInt64

    public init(path: String, seq: UInt64) {
        self.path = path
        self.seq = seq
    }
}

/// `manifest` (M, per pin): entries newer than what the phone holds, and removals. `full` means the phone compares in
/// full: the manifest ID changed, so anything not listed is gone. A pin's manifest may come in several pages, the last
/// marked `last`; every page stays under `LinkBounds.maxFrame`.
public struct ManifestFrame: Codable, Sendable, Hashable {
    public var pin: String
    public var manifest: String
    public var trust: UInt64
    /// The manifest's highest sequence; the phone holds it once this delta is applied.
    public var sequence: UInt64
    public var full: Bool
    public var entries: [ManifestEntry]
    public var removed: [Tombstone]
    public var last: Bool
    /// Why files of the pin were left out (over the size limit, a case-only collision, a bad name).
    public var problems: [String]?

    public init(pin: String, manifest: String, trust: UInt64, sequence: UInt64, full: Bool, entries: [ManifestEntry], removed: [Tombstone], last: Bool, problems: [String]? = nil) {
        self.pin = pin
        self.manifest = manifest
        self.trust = trust
        self.sequence = sequence
        self.full = full
        self.entries = entries
        self.removed = removed
        self.last = last
        self.problems = problems
    }
}

/// A file the phone wants, by hash, from a resume offset.
public struct WantedFile: Codable, Sendable, Hashable {
    public var sha: String
    public var offset: Int64

    public init(sha: String, offset: Int64) {
        self.sha = sha
        self.offset = offset
    }
}

/// `want` (P): hashes with resume offsets, after the phone's space check. Never a path.
public struct Want: Codable, Sendable, Hashable {
    public var pin: String
    public var files: [WantedFile]

    public init(pin: String, files: [WantedFile]) {
        self.pin = pin
        self.files = files
    }
}

/// `chunk` (M): bytes of one file by its hash, at an offset. Binary: 32 bytes of hash, an 8-byte big-endian offset,
/// then the bytes.
public struct Chunk: Sendable, Hashable {
    public var sha: String
    public var offset: Int64
    public var bytes: Data

    public init(sha: String, offset: Int64, bytes: Data) {
        self.sha = sha
        self.offset = offset
        self.bytes = bytes
    }

    public var frame: Frame {
        var d = Data(capacity: 40 + bytes.count)
        d.append(Data(hexString: sha) ?? Data(count: 32))
        let o = UInt64(offset)
        for shift in stride(from: 56, through: 0, by: -8) { d.append(UInt8((o >> UInt64(shift)) & 0xff)) }
        d.append(bytes)
        return Frame(type: .chunk, payload: d)
    }

    public init(frame: Frame) throws(FrameError) {
        let p = frame.payload
        guard frame.type == .chunk, p.count >= 40 else { throw .malformed(.chunk) }
        let b = [UInt8](p.prefix(40))
        sha = b[0..<32].map { String(format: "%02x", $0) }.joined()
        offset = Int64(bitPattern: b[32..<40].reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
        guard offset >= 0 else { throw .malformed(.chunk) }
        bytes = Data(p.dropFirst(40))
    }
}

/// `done` (P): a pin's generation switched; the phone now holds this manifest and sequence.
public struct Done: Codable, Sendable, Hashable {
    public var pin: String
    public var manifest: String
    public var sequence: UInt64

    public init(pin: String, manifest: String, sequence: UInt64) {
        self.pin = pin
        self.manifest = manifest
        self.sequence = sequence
    }
}

/// `changed` (M, while connected): a pin moved to a new sequence or trust revision, the pin set changed, or the Mac
/// is about to sleep (SYNC-7's "Mac asleep": the helper tells connected phones before the Mac sleeps).
public struct Changed: Codable, Sendable, Hashable {
    public var pin: String?
    public var sequence: UInt64?
    public var trust: UInt64?
    public var pinSet: UInt64?
    public var sleep: Bool?

    public init(pin: String? = nil, sequence: UInt64? = nil, trust: UInt64? = nil, pinSet: UInt64? = nil, sleep: Bool? = nil) {
        self.pin = pin
        self.sequence = sequence
        self.trust = trust
        self.pinSet = pinSet
        self.sleep = sleep
    }
}

/// `pair-code` (P, the one frame a pairing phone sends): the code from the QR and the name typed for the phone.
public struct PairCode: Codable, Sendable, Hashable {
    public var code: String
    public var name: String

    public init(code: String, name: String) {
        self.code = code
        self.name = name
    }
}

/// Why the Mac ended a pairing session.
public enum PairReason: String, Codable, Sendable, Hashable {
    case code, expired, refused, timeout, busy
}

/// `pair-result` (M, the one frame the Mac sends on a pairing session): allowed or refused, with the reason.
public struct PairResult: Codable, Sendable, Hashable {
    public var allowed: Bool
    public var reason: PairReason?
    /// The Mac's name, sent with `allowed`.
    public var mac: String?

    public init(allowed: Bool, reason: PairReason?, mac: String? = nil) {
        self.allowed = allowed
        self.reason = reason
        self.mac = mac
    }

    public static func refused(_ r: PairReason) -> PairResult { PairResult(allowed: false, reason: r) }
}

extension Data {
    /// Bytes from lowercase or uppercase hex, or nil.
    init?(hexString s: String) {
        guard s.count % 2 == 0 else { return nil }
        var out = Data(capacity: s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        self = out
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
