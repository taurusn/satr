import CryptoKit
import Foundation
import Security

/// One device's identity on the link (section 9.3): a P-256 key made once, a self-signed certificate built here in DER
/// and signed with it, and the `SecIdentity` TLS presents. The other side pins the certificate by its SHA-256. No
/// PKCS#12 and no certificate authority; the certificate's dates are wide and ignored, since the pin is the trust.
public final class LinkIdentity: @unchecked Sendable {
    public let certificateDER: Data
    public let certHash: Data
    let key: SecKey
    let certificate: SecCertificate
    let identity: SecIdentity

    /// Makes a new key and certificate. `commonName` is only a label.
    public static func generate(commonName: String) throws -> LinkIdentity {
        var err: Unmanaged<CFError>?
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits: 256]
        guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &err) else { throw LinkIdentityError.key }
        return try LinkIdentity(key: key, certificateDER: selfSigned(key: key, commonName: commonName))
    }

    /// Rebuilds an identity from stored parts.
    public convenience init(privateKey raw: Data, certificateDER: Data) throws {
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass: kSecAttrKeyClassPrivate, kSecAttrKeySizeInBits: 256]
        guard let key = SecKeyCreateWithData(raw as CFData, attrs as CFDictionary, nil) else { throw LinkIdentityError.key }
        try self.init(key: key, certificateDER: certificateDER)
    }

    init(key: SecKey, certificateDER: Data) throws {
        guard let cert = SecCertificateCreateWithData(nil, certificateDER as CFData) else { throw LinkIdentityError.certificate }
        guard let id = SecIdentityCreate(nil, cert, key) else { throw LinkIdentityError.identity }
        self.key = key
        self.certificate = cert
        self.identity = id
        self.certificateDER = certificateDER
        self.certHash = Data(SHA256.hash(data: certificateDER))
    }

    /// The private key's raw form, for the keychain.
    public func privateKeyData() throws -> Data {
        guard let d = SecKeyCopyExternalRepresentation(key, nil) as Data? else { throw LinkIdentityError.key }
        return d
    }

    var secIdentity: sec_identity_t? { sec_identity_create(identity) }

    // MARK: DER

    private static func len(_ n: Int) -> [UInt8] {
        n < 128 ? [UInt8(n)] : n < 256 ? [0x81, UInt8(n)] : [0x82, UInt8(n >> 8), UInt8(n & 0xff)]
    }
    private static func tlv(_ tag: UInt8, _ c: [UInt8]) -> [UInt8] { [tag] + len(c.count) + c }
    private static func seq(_ parts: [UInt8]...) -> [UInt8] { tlv(0x30, parts.flatMap { $0 }) }
    private static let oidEcdsaSha256: [UInt8] = [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]
    private static let oidEcPublicKey: [UInt8] = [0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
    private static let oidP256: [UInt8] = [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]
    private static func name(_ cn: String) -> [UInt8] {
        seq(tlv(0x31, seq([0x06, 0x03, 0x55, 0x04, 0x03], tlv(0x0C, Array(cn.utf8.prefix(64))))))
    }

    static func selfSigned(key: SecKey, commonName: String) throws -> Data {
        var err: Unmanaged<CFError>?
        guard let pubKey = SecKeyCopyPublicKey(key), let pub = SecKeyCopyExternalRepresentation(pubKey, &err) as Data? else { throw LinkIdentityError.key }
        let spki = seq(seq(oidEcPublicKey, oidP256), tlv(0x03, [0x00] + Array(pub)))
        var serial = (0..<16).map { _ in UInt8.random(in: 0...255) }
        serial[0] &= 0x7f
        serial[0] |= 0x01
        let tbs = seq(tlv(0xA0, tlv(0x02, [0x02])), tlv(0x02, serial), seq(oidEcdsaSha256), name(commonName),
                      seq(tlv(0x17, Array("260101000000Z".utf8)), tlv(0x18, Array("20991231000000Z".utf8))), name(commonName), spki)
        guard let sig = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, Data(tbs) as CFData, &err) as Data? else { throw LinkIdentityError.signature }
        return Data(seq(tbs, seq(oidEcdsaSha256), tlv(0x03, [0x00] + Array(sig))))
    }
}

public enum LinkIdentityError: Error, Sendable {
    case key, certificate, identity, signature, keychain(OSStatus)
}

/// Where a device keeps its identity.
public protocol LinkIdentityStore: Sendable {
    func load() throws -> LinkIdentity?
    func save(_ identity: LinkIdentity) throws
    func delete() throws
}

extension LinkIdentityStore {
    /// The stored identity, or a new one made and stored now.
    public func loadOrCreate(commonName: String) throws -> LinkIdentity {
        if let id = try load() { return id }
        let id = try LinkIdentity.generate(commonName: commonName)
        try save(id)
        return id
    }
}

/// The identity in this device's keychain: one generic-password item, never synchronised, readable after the first
/// unlock on this device only (the phone's background refresh runs while it is locked).
public struct KeychainIdentityStore: LinkIdentityStore {
    public let service: String
    public let account: String

    public init(service: String = "com.hatim.linen.link", account: String = "identity") {
        self.service = service
        self.account = account
    }

    private var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account, kSecAttrSynchronizable: false]
    }

    public func load() throws -> LinkIdentity? {
        var q = query
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        let s = SecItemCopyMatching(q as CFDictionary, &out)
        if s == errSecItemNotFound { return nil }
        guard s == errSecSuccess, let data = out as? Data else { throw LinkIdentityError.keychain(s) }
        guard let parts = try? JSONDecoder().decode(StoredIdentity.self, from: data) else { return nil }
        return try LinkIdentity(privateKey: parts.key, certificateDER: parts.cert)
    }

    public func save(_ identity: LinkIdentity) throws {
        let data = try JSONEncoder().encode(StoredIdentity(key: identity.privateKeyData(), cert: identity.certificateDER))
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData] = data
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let s = SecItemAdd(add as CFDictionary, nil)
        guard s == errSecSuccess else { throw LinkIdentityError.keychain(s) }
    }

    public func delete() throws {
        let s = SecItemDelete(query as CFDictionary)
        guard s == errSecSuccess || s == errSecItemNotFound else { throw LinkIdentityError.keychain(s) }
    }
}

private struct StoredIdentity: Codable {
    var key: Data
    var cert: Data
}

/// An identity kept in memory, for tests.
public final class MemoryIdentityStore: LinkIdentityStore, @unchecked Sendable {
    private let lock = NSLock()
    private var identity: LinkIdentity?

    public init(_ identity: LinkIdentity? = nil) { self.identity = identity }

    public func load() throws -> LinkIdentity? { lock.withLock { identity } }
    public func save(_ identity: LinkIdentity) throws { lock.withLock { self.identity = identity } }
    public func delete() throws { lock.withLock { identity = nil } }
}
