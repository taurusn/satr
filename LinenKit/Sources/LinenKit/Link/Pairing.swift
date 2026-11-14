import CryptoKit
import Foundation

/// What the Mac's QR code carries (SYNC-1): the Mac's certificate hash, its Bonjour instance name, its name for people,
/// and a random 128-bit one-time code. No lasting secret: the code is good for one pairing within 2 minutes.
///
/// Written as `linen://pair?v=1&h=<hash>&s=<service>&m=<name>&c=<code>`, hash and code in base64url.
public struct PairingInvite: Sendable, Hashable {
    public var macCertHash: Data
    public var service: String
    public var macName: String
    public var code: Data

    public init(macCertHash: Data, service: String, macName: String, code: Data) {
        self.macCertHash = macCertHash
        self.service = service
        self.macName = macName
        self.code = code
    }

    /// A fresh 128-bit code.
    public static func newCode() -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &g) })
    }

    public var text: String {
        var c = URLComponents()
        c.scheme = "linen"
        c.host = "pair"
        c.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "h", value: macCertHash.base64URL),
            URLQueryItem(name: "s", value: service),
            URLQueryItem(name: "m", value: macName),
            URLQueryItem(name: "c", value: code.base64URL),
        ]
        return c.string ?? ""
    }

    /// Reads a scanned code; nil when it is not a Linen pairing code.
    public init?(text: String) {
        guard let c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme == "linen", c.host == "pair" else { return nil }
        var q: [String: String] = [:]
        for item in c.queryItems ?? [] { q[item.name] = item.value }
        guard q["v"] == "1", let h = q["h"].flatMap(Data.init(base64URL:)), h.count == 32,
              let code = q["c"].flatMap(Data.init(base64URL:)), code.count == 16,
              let s = q["s"], !s.isEmpty, s.utf8.count <= 63 else { return nil }
        macCertHash = h
        service = s
        macName = (q["m"]?.isEmpty == false ? q["m"] : nil) ?? s
        self.code = code
    }
}

/// The six digits both screens show (section 9.3 step 4): derived from keying material exported from this TLS session
/// plus both certificate hashes, so they bind this exact session. Never sent.
public enum PairingDigits {
    public static let exporterLabel = "EXPORTER-linen-pairing"
    public static let exporterLength = 32

    public static func digits(exported: Data, macCertHash: Data, phoneCertHash: Data) -> String {
        var h = SHA256()
        h.update(data: Data("linen-pair-digits-v1".utf8))
        h.update(data: exported)
        h.update(data: macCertHash)
        h.update(data: phoneCertHash)
        let b = Array(h.finalize())
        let n = (UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])) % 1_000_000
        return String(format: "%06u", n)
    }

    /// "418 207", as both screens show them.
    public static func spaced(_ digits: String) -> String {
        guard digits.count == 6 else { return digits }
        return String(digits.prefix(3)) + " " + String(digits.suffix(3))
    }
}

/// The Mac's pairing mode (section 9.3, SYNC-1), as a state machine the server drives and the tests check directly.
///
/// While the QR is up, and only then, the listener accepts a TLS session from an unknown phone certificate, one at a
/// time. The phone sends one `pair-code`; a wrong code counts and three end pairing mode. A right code puts the six
/// digits on screen with Allow and Refuse; Hatim's answer, or 60 s, ends the session with one `pair-result`. A pairing
/// that ends, however it ends, closes pairing mode, so a photo of the QR is useless after it. Anything else on a
/// pairing session (a second `pair-code`, a `hello`, a `want`) ends pairing mode too.
public struct PairingMode: Sendable {
    public static let lifetime: TimeInterval = 120
    public static let answerTime: TimeInterval = 60
    public static let maxStrikes = 3

    /// Why pairing mode closed, for the Mac's screen.
    public enum Ended: Sendable, Hashable {
        case paired(phoneName: String)
        case refused
        case timeout
        case wrongCodes
        case expired
        case cancelled
        case violation
    }

    /// A phone that sent the right code and waits for Allow.
    public struct Waiting: Sendable, Hashable {
        public var session: UUID
        public var phoneName: String
        public var phoneCertHash: Data
        public var digits: String
        public var deadline: Date
    }

    public private(set) var code: Data?
    public private(set) var expires = Date.distantPast
    public private(set) var strikes = 0
    /// The one pairing session, while it is open.
    public private(set) var session: UUID?
    public private(set) var waiting: Waiting?
    public private(set) var ended: Ended?

    public init() {}

    public var isOpen: Bool { code != nil }

    /// Opens pairing mode with a new code (a new QR), valid for `lifetime`.
    public mutating func open(code: Data, now: Date, lifetime: TimeInterval = PairingMode.lifetime) {
        self.code = code
        expires = now.addingTimeInterval(lifetime)
        strikes = 0
        session = nil
        waiting = nil
        ended = nil
    }

    /// Whether the TLS verify block may accept a certificate it does not know: only while the QR is up and unexpired.
    public func acceptsUnknownCertificate(now: Date) -> Bool {
        code != nil && now < expires
    }

    public enum SessionDecision: Sendable, Equatable {
        /// This session is the pairing session.
        case pair
        /// Another phone is pairing: send `pair-result busy` and close.
        case busy
        /// Pairing mode is closed or expired: close without a frame.
        case close
    }

    /// A TLS session from an unknown certificate is ready.
    public mutating func sessionBegan(_ id: UUID, now: Date) -> SessionDecision {
        guard code != nil, now < expires || waiting != nil else { return .close }
        if session != nil { return .busy }
        session = id
        return .pair
    }

    public enum CodeDecision: Sendable, Equatable {
        /// The code is right: show these digits and wait for Allow.
        case wait(digits: String)
        /// End the session with this result.
        case result(PairResult)
    }

    /// The phone's `pair-code` arrived. `digits` are what this side computed from the session.
    public mutating func codeReceived(_ id: UUID, code sent: Data, phoneName: String, phoneCertHash: Data, digits: String, now: Date) -> CodeDecision {
        guard id == session, waiting == nil, let code else {
            // A second pair-code, or one on a session that is not the pairing session.
            close(.violation)
            return .result(.refused(.refused))
        }
        guard now < expires else {
            close(.expired)
            return .result(.refused(.expired))
        }
        guard constantTimeEqual(sent, code) else {
            strikes += 1
            session = nil
            if strikes >= Self.maxStrikes { close(.wrongCodes) }
            return .result(.refused(.code))
        }
        waiting = Waiting(session: id, phoneName: phoneName, phoneCertHash: phoneCertHash, digits: digits, deadline: now.addingTimeInterval(Self.answerTime))
        return .wait(digits: digits)
    }

    /// Hatim clicked Allow or Refuse. Returns the session to answer and its result, and the phone to pin on Allow.
    public mutating func answer(allow: Bool) -> (session: UUID, result: PairResult, pin: Waiting?)? {
        guard let w = waiting else { return nil }
        if allow {
            close(.paired(phoneName: w.phoneName))
            return (w.session, PairResult(allowed: true, reason: nil), w)
        }
        close(.refused)
        return (w.session, .refused(.refused), nil)
    }

    /// Time passed: the QR expired, or the answer did not come within 60 s. Returns a session to end with its result.
    public mutating func tick(now: Date) -> (session: UUID?, result: PairResult)? {
        if let w = waiting {
            guard now >= w.deadline else { return nil }
            close(.timeout)
            return (w.session, .refused(.timeout))
        }
        guard code != nil, now >= expires else { return nil }
        let s = session
        close(.expired)
        return (s, .refused(.expired))
    }

    /// The pairing session sent something other than its one `pair-code`, or closed early.
    public mutating func sessionEnded(_ id: UUID, violation: Bool) {
        guard id == session else { return }
        if violation || waiting != nil {
            close(violation ? .violation : .cancelled)
        } else {
            session = nil
        }
    }

    /// Hatim closed the pairing sheet or the QR.
    public mutating func cancel() -> UUID? {
        let s = session
        close(.cancelled)
        return s
    }

    private mutating func close(_ why: Ended) {
        code = nil
        expires = .distantPast
        session = nil
        waiting = nil
        ended = why
    }
}

func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for (x, y) in zip(a, b) { diff |= x ^ y }
    return diff == 0
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let d = Data(base64Encoded: b) else { return nil }
        self = d
    }
}
