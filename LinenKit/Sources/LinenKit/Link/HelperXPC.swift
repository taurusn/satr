#if os(macOS)
import Foundation

/// The helper's XPC service (SYNC-2): the Mac app and the helper talk only over it, each checking the other's code
/// signature. The helper's bundle identifier is its Mach service name, as for every login item.
public enum LinenHelperXPC {
    public static let serviceName = "com.hatim.linen.helper"
    public static let appIdentifier = "com.hatim.linen"
    public static let team = "2U8YZJV343"

    /// The code requirement each side sets on the other: signed by Apple for this team, with this identifier.
    public static func requirement(identifier: String) -> String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(identifier)\""
    }

    public static func interface() -> NSXPCInterface { NSXPCInterface(with: (any LinenHelperProtocol).self) }
}

/// What the helper does for the app. Values cross as plain types and JSON.
@objc public protocol LinenHelperProtocol {
    /// The state Settings > iPhone shows, as JSON of `HelperState`.
    func state(reply: @escaping @Sendable (Data) -> Void)
    /// Opens pairing mode; replies with the QR's text.
    func beginPairing(reply: @escaping @Sendable (String) -> Void)
    func cancelPairing()
    func answerPairing(_ allow: Bool)
    func forgetPhone(_ certHash: Data)
    /// Keep on iPhone: a folder (`kind` "folder") or a single file ("file"). Replies with the pin's ID.
    func pin(_ path: String, kind: String, reply: @escaping @Sendable (String) -> Void)
    func unpin(_ id: String)
    /// The app's page trust, JSON of `PageTrust`.
    func setTrust(_ json: Data)
    func setLimit(_ bytes: Int64)
}

/// Settings > iPhone's view of the helper.
public struct HelperState: Codable, Sendable, Hashable {
    public struct Phone: Codable, Sendable, Hashable {
        public var name: String
        public var certHash: Data
        public var pairedAt: Date
        public var lastSeen: Date?
        public var connected: Bool
    }

    public struct PinRow: Codable, Sendable, Hashable {
        public var id: String
        public var name: String
        public var path: String
        public var kind: String
        public var size: Int64
        public var files: Int
        public var problems: [String]
    }

    public struct Pairing: Codable, Sendable, Hashable {
        public var qr: String?
        public var expires: Date?
        public var phoneName: String?
        public var digits: String?
        /// Why pairing mode last closed, in words for the pane.
        public var ended: String?
    }

    public var phones: [Phone]
    public var pins: [PinRow]
    public var pairing: Pairing
    public var limit: Int64
    public var listening: Bool
    public var serviceName: String?
    public var problem: String?
    public var unsentSince: Date?

    public init(_ s: MacLinkServer.Snapshot) {
        phones = s.phones.map { Phone(name: $0.name, certHash: $0.certHash, pairedAt: $0.pairedAt, lastSeen: $0.lastSeen, connected: s.connected.contains($0.certHash)) }
        pins = s.pins.map { PinRow(id: $0.info.id, name: $0.info.name, path: $0.path, kind: $0.info.kind.rawValue, size: $0.size, files: $0.files, problems: $0.problems) }
        let ended: String? = switch s.pairing.ended {
        case let .paired(name)?: "Paired with \(name)."
        case .refused?: "Pairing refused."
        case .timeout?: "No answer within a minute; pairing ended."
        case .wrongCodes?: "Three wrong codes; pairing ended."
        case .expired?: "The code expired."
        case .cancelled?: nil
        case .violation?: "A phone broke the pairing rules; pairing ended."
        case nil: nil
        }
        pairing = Pairing(qr: s.pairing.invite?.text, expires: s.pairing.expires, phoneName: s.pairing.waiting?.name, digits: s.pairing.waiting?.digits, ended: ended)
        limit = s.totalLimit
        listening = s.listening
        serviceName = s.serviceName
        problem = s.problem
        unsentSince = s.unsentSince
    }
}
#endif
