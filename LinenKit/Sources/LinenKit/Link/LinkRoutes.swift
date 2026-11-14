import dnssd
import Foundation
import Network

/// Where the phone may find its Mac (SYNC-6). Routes are a list the dialer races, so a relay later is one more source
/// (RELAY-4): nothing above this layer assumes the Mac is on the local network.
public protocol LinkRouteSource: Sendable {
    /// Starts looking. `update` gets every endpoint found so far, each time the list grows or shrinks; `denied` says
    /// local network access is off for Linen. Calls arrive on `queue`.
    func find(service: String?, peerToPeer: Bool, queue: DispatchQueue,
              update: @escaping @Sendable ([NWEndpoint]) -> Void, denied: @escaping @Sendable () -> Void) -> any LinkRouteSearch
}

public protocol LinkRouteSearch: Sendable {
    func cancel()
}

/// Bonjour on Wi-Fi and peer-to-peer Wi-Fi, and the cable's network link when Bonjour reports it. Every service of
/// type `_linen._tcp` is a candidate, the named one first; the certificate pin decides which is the Mac.
public struct BonjourRoutes: LinkRouteSource {
    public init() {}

    public func find(service: String?, peerToPeer: Bool, queue: DispatchQueue,
                     update: @escaping @Sendable ([NWEndpoint]) -> Void, denied: @escaping @Sendable () -> Void) -> any LinkRouteSearch {
        let p = NWParameters()
        p.includePeerToPeer = peerToPeer
        let b = NWBrowser(for: .bonjour(type: linenServiceType, domain: nil), using: p)
        b.browseResultsChangedHandler = { results, _ in
            let eps = results.map(\.endpoint).sorted { a, b in
                Self.name(a) == service && Self.name(b) != service
            }
            update(eps)
        }
        b.stateUpdateHandler = { st in
            switch st {
            case let .waiting(e), let .failed(e):
                if case let .dns(code) = e, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) { denied() }
            default: break
            }
        }
        b.start(queue: queue)
        return Search(browser: b)
    }

    static func name(_ e: NWEndpoint) -> String? {
        if case let .service(name, _, _, _) = e { return name }
        return nil
    }

    final class Search: LinkRouteSearch, @unchecked Sendable {
        let browser: NWBrowser
        init(browser: NWBrowser) { self.browser = browser }
        func cancel() { browser.cancel() }
    }
}

/// Fixed endpoints: the loopback tests, and later a relay's address.
public struct FixedRoutes: LinkRouteSource {
    public var endpoints: [NWEndpoint]

    public init(_ endpoints: [NWEndpoint]) { self.endpoints = endpoints }

    public func find(service: String?, peerToPeer: Bool, queue: DispatchQueue,
                     update: @escaping @Sendable ([NWEndpoint]) -> Void, denied: @escaping @Sendable () -> Void) -> any LinkRouteSearch {
        let eps = endpoints
        queue.async { update(eps) }
        return Nothing()
    }

    struct Nothing: LinkRouteSearch {
        func cancel() {}
    }
}

/// Dials every route at once; the first session whose TLS completes with the pinned Mac wins and the rest are
/// cancelled (SYNC-6). All callbacks run on `queue`.
final class LinkDialer: @unchecked Sendable {
    enum Failure: Error, Sendable, Equatable {
        /// No route reached the Mac in time.
        case unreachable
        /// Local network access is off for Linen.
        case localNetworkOff
        /// The Mac proved itself and then refused this phone's certificate.
        case refused
    }

    private let queue: DispatchQueue
    private let params: NWParameters
    private let source: any LinkRouteSource
    private let service: String?
    private let peerToPeer: Bool
    private var search: (any LinkRouteSearch)?
    private var tried: Set<String> = []
    private var attempts: [NWConnection] = []
    private var finished = false
    private var denied = false
    private let completion: (Result<NWConnection, Failure>) -> Void
    private let timeout: TimeInterval

    /// `pin` is the Mac's certificate hash; `verified` is set when the Mac proved it in some handshake.
    init(queue: DispatchQueue, identity: LinkIdentity, pin: Data, routes: any LinkRouteSource, service: String?, peerToPeer: Bool,
         timeout: TimeInterval = 8, completion: @escaping (Result<NWConnection, Failure>) -> Void) {
        self.queue = queue
        self.source = routes
        self.service = service
        self.peerToPeer = peerToPeer
        self.completion = completion
        self.timeout = timeout
        let flag = VerifyFlag()
        self.flag = flag
        let verify: @Sendable (Data) -> Bool = { hash in
            let ok = hash == pin
            if ok { flag.set() }
            return ok
        }
        params = LinkTLS.parameters(identity: identity, queue: queue, peerToPeer: false, verify: verify)
        p2pParams = peerToPeer ? LinkTLS.parameters(identity: identity, queue: queue, peerToPeer: true, verify: verify) : nil
    }

    /// Peer-to-peer Wi-Fi is dialled this long after the local network, so a phone on the same network or hotspot
    /// uses it, and peer-to-peer still wins when Wi-Fi is off. On Hatim's iPhone with Personal Hotspot on, a pairing
    /// session that won over peer-to-peer Wi-Fi lost the Mac's last frame after 8 s idle (2026-10-31).
    static let peerToPeerDelay: TimeInterval = 0.5
    private let p2pParams: NWParameters?

    private let flag: VerifyFlag

    final class VerifyFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var on = false
        func set() { lock.withLock { on = true } }
        var value: Bool { lock.withLock { on } }
    }

    func start() {
        // The source calls back on `queue`, the dialer's own.
        // A refusal of local network access is noted, not final: while iOS still shows its question (the first dial,
        // at pairing), Bonjour reports the same refusal, and it finds the Mac once the person allows. So the dialer
        // keeps looking until its deadline and only then says local network access is off.
        search = source.find(service: service, peerToPeer: peerToPeer, queue: queue, update: { [weak self] eps in
            self?.dial(eps)
        }, denied: { [weak self] in
            self?.denied = true
        })
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.fail() }
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        search?.cancel()
        for a in attempts { a.cancel() }
        attempts = []
    }

    private func dial(_ eps: [NWEndpoint]) {
        guard !finished else { return }
        // Results mean local network access is allowed now (the question was answered): a later failure is the Mac's.
        if !eps.isEmpty { denied = false }
        for ep in eps where !tried.contains("\(ep)") {
            tried.insert("\(ep)")
            attempt(ep, params)
            if let p2p = p2pParams {
                queue.asyncAfter(deadline: .now() + Self.peerToPeerDelay) { [weak self] in
                    guard let self, !self.finished else { return }
                    self.attempt(ep, p2p)
                }
            }
        }
    }

    private func attempt(_ ep: NWEndpoint, _ params: NWParameters) {
        let c = NWConnection(to: ep, using: params)
        attempts.append(c)
        c.stateUpdateHandler = { [weak self, weak c] st in
            guard let self, let c, !self.finished else { return }
            switch st {
            case .ready: self.win(c)
            case let .waiting(e):
                if c.currentPath?.unsatisfiedReason == .localNetworkDenied {
                    // As above: the connection goes on by itself once access is allowed.
                    self.denied = true
                } else {
                    self.denied = false
                    if self.isTLSRefusal(e) { self.lost(c) }
                }
            case .failed:
                self.lost(c)
            default: break
            }
        }
        c.start(queue: queue)
    }

    private func isTLSRefusal(_ e: NWError) -> Bool {
        if case .tls = e { return true }
        return false
    }

    private func win(_ c: NWConnection) {
        finished = true
        search?.cancel()
        for a in attempts where a !== c { a.cancel() }
        attempts = []
        completion(.success(c))
    }

    private func lost(_ c: NWConnection) {
        c.cancel()
        attempts.removeAll { $0 === c }
        // The Mac proved itself and the session still failed: it refused this phone.
        if flag.value {
            finished = true
            search?.cancel()
            for a in attempts { a.cancel() }
            attempts = []
            completion(.failure(.refused))
        }
    }

    private func fail() {
        guard !finished else { return }
        finished = true
        search?.cancel()
        for a in attempts { a.cancel() }
        attempts = []
        completion(.failure(denied ? .localNetworkOff : flag.value ? .refused : .unreachable))
    }
}
