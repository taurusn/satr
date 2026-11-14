import CryptoKit
import Foundation
import Network
import Security

/// The Bonjour service type both apps list in `NSBonjourServices`.
public let linenServiceType = "_linen._tcp"

/// TLS 1.3 with a pinned certificate on each side (section 9.3), and the frame layer above it. No TLS 1.2 fallback:
/// both versions are fixed at 1.3, and each side requires the other's certificate.
enum LinkTLS {
    /// Parameters for either side. `verify` gets the SHA-256 of the peer's leaf certificate and decides alone; it
    /// runs on `queue`.
    /// `framed: false` leaves the frame layer out (a test that writes raw bytes).
    static func parameters(identity: LinkIdentity, queue: DispatchQueue, peerToPeer: Bool, framed: Bool = true,
                           verify: @escaping @Sendable (Data) -> Bool) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let s = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(s, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(s, .TLSv13)
        if let id = identity.secIdentity { sec_protocol_options_set_local_identity(s, id) }
        sec_protocol_options_set_peer_authentication_required(s, true)
        sec_protocol_options_set_verify_block(s, { _, trust, complete in
            complete(leafHash(trust).map(verify) ?? false)
        }, queue)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 8
        let p = NWParameters(tls: tls, tcp: tcp)
        p.includePeerToPeer = peerToPeer
        if framed { p.defaultProtocolStack.applicationProtocols.insert(NWProtocolFramer.Options(definition: LinkFramer.definition), at: 0) }
        return p
    }

    static func leafHash(_ trust: sec_trust_t) -> Data? {
        let t = sec_trust_copy_ref(trust).takeRetainedValue()
        guard let chain = SecTrustCopyCertificateChain(t) as? [SecCertificate], let leaf = chain.first else { return nil }
        return Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data))
    }

    private static func metadata(_ c: NWConnection) -> sec_protocol_metadata_t? {
        (c.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata)?.securityProtocolMetadata
    }

    /// The SHA-256 of the peer's certificate on a ready connection.
    static func peerCertHash(_ c: NWConnection) -> Data? {
        guard let md = metadata(c) else { return nil }
        var hash: Data?
        _ = sec_protocol_metadata_access_peer_certificate_chain(md) { cert in
            guard hash == nil else { return }
            let ref = sec_certificate_copy_ref(cert).takeRetainedValue()
            hash = Data(SHA256.hash(data: SecCertificateCopyData(ref) as Data))
        }
        return hash
    }

    /// Keying material exported from the session (RFC 8446 section 7.5), the six digits' input.
    static func exported(_ c: NWConnection) -> Data? {
        guard let md = metadata(c) else { return nil }
        let label = PairingDigits.exporterLabel
        let secret: DispatchData? = label.withCString { p in
            sec_protocol_metadata_create_secret(md, label.utf8.count, p, PairingDigits.exporterLength) as DispatchData?
        }
        return secret.map { Data($0) }
    }

    static func negotiatedVersion(_ c: NWConnection) -> tls_protocol_version_t? {
        metadata(c).map { sec_protocol_metadata_get_negotiated_tls_protocol_version($0) }
    }
}

/// Splits the TLS stream into frames (section 9.3, as Apple's peer-to-peer sample does). A header with an unknown type
/// or a length over `LinkBounds.maxFrame` fails the connection before its payload is read.
final class LinkFramer: NWProtocolFramerImplementation {
    static let definition = NWProtocolFramer.Definition(implementation: LinkFramer.self)
    static var label: String { "LinenLink" }

    required init(framer: NWProtocolFramer.Instance) {}
    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .ready }
    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}

    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete: Bool) {
        guard let raw = message["type"] as? UInt8, messageLength <= LinkBounds.maxFrame else {
            framer.markFailed(error: .posix(.EMSGSIZE))
            return
        }
        let n = UInt32(messageLength)
        framer.writeOutput(data: Data([raw, UInt8(n >> 24), UInt8((n >> 16) & 0xff), UInt8((n >> 8) & 0xff), UInt8(n & 0xff)]))
        do { try framer.writeOutputNoCopy(length: messageLength) } catch { framer.markFailed(error: .posix(.EIO)) }
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while true {
            var header: (FrameType, Int)?
            var bad = false
            let parsed = framer.parseInput(minimumIncompleteLength: Frame.headerSize, maximumLength: Frame.headerSize) { buf, _ in
                guard let buf, buf.count >= Frame.headerSize else { return 0 }
                do { header = try Frame.header(buf) } catch { bad = true }
                return Frame.headerSize
            }
            if bad {
                framer.markFailed(error: .posix(.EBADMSG))
                return 0
            }
            guard parsed, let (type, n) = header else { return Frame.headerSize }
            let message = NWProtocolFramer.Message(definition: Self.definition)
            message["type"] = type.rawValue
            if !framer.deliverInputNoCopy(length: n, message: message, isComplete: true) { return 0 }
        }
    }
}

/// Frames over one connection. All callbacks run on the connection's queue.
final class FrameChannel: @unchecked Sendable {
    let connection: NWConnection
    private var receiving = false

    init(_ connection: NWConnection) { self.connection = connection }

    func send(_ frame: Frame, completion: (@Sendable (NWError?) -> Void)? = nil) {
        let message = NWProtocolFramer.Message(definition: LinkFramer.definition)
        message["type"] = frame.type.rawValue
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [message])
        connection.send(content: frame.payload, contentContext: context, isComplete: true, completion: .contentProcessed { e in completion?(e) })
    }

    /// Delivers each frame in order until the connection ends; `onEnd` runs once with the error, if any.
    func startReceiving(_ onFrame: @escaping @Sendable (Frame) -> Void, onEnd: @escaping @Sendable (NWError?) -> Void) {
        guard !receiving else { return }
        receiving = true
        receiveNext(onFrame, onEnd)
    }

    private func receiveNext(_ onFrame: @escaping @Sendable (Frame) -> Void, _ onEnd: @escaping @Sendable (NWError?) -> Void) {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self else { return }
            // A frame that arrives with the connection's end is delivered first: a pairing's last frame is its result.
            if let msg = context?.protocolMetadata(definition: LinkFramer.definition) as? NWProtocolFramer.Message,
               let raw = msg["type"] as? UInt8, let type = FrameType(rawValue: raw) {
                onFrame(Frame(type: type, payload: content ?? Data()))
            } else if error == nil {
                onEnd(nil)
                return
            }
            if let error { onEnd(error); return }
            if self.connection.state == .cancelled { return }
            self.receiveNext(onFrame, onEnd)
        }
    }
}
