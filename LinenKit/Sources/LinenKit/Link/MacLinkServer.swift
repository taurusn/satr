import Darwin
import dnssd
import Foundation
import Network

/// The Mac's side of the link (section 9.3), run by the helper: it advertises `_linen._tcp`, accepts TLS 1.3 sessions
/// from pinned phones and, while the QR is up, one pairing session from an unknown certificate; it keeps the pin set
/// and a manifest per pin, answers `hello` with the pin set and the manifests' deltas, serves `want` by hash from
/// inside each pin's root, and pushes `changed` while phones are connected.
///
/// Everything runs on one queue. The public methods may be called from any thread.
public final class MacLinkServer: @unchecked Sendable {
    public struct Config: Sendable {
        /// The Mac's name for people, sent in the QR ("MacBook Air").
        public var macName: String
        /// The Bonjour instance name; nil listens without advertising (the loopback tests).
        public var serviceName: String?
        public var port: NWEndpoint.Port
        public var peerToPeer: Bool
        /// Where the pin set, the paired phones and the manifests are kept.
        public var stateDirectory: URL
        /// How long a QR stays good (2 minutes; the tests shorten it).
        public var pairingLifetime: TimeInterval

        public init(macName: String, serviceName: String?, port: NWEndpoint.Port = .any, peerToPeer: Bool = true, stateDirectory: URL,
                    pairingLifetime: TimeInterval = PairingMode.lifetime) {
            self.macName = macName
            self.serviceName = serviceName
            self.port = port
            self.peerToPeer = peerToPeer
            self.stateDirectory = stateDirectory
            self.pairingLifetime = pairingLifetime
        }
    }

    /// A paired phone.
    public struct PhoneRecord: Codable, Sendable, Hashable {
        public var certHash: Data
        public var name: String
        public var pairedAt: Date
        public var lastSeen: Date?
        /// What it last said it holds, by pin.
        public var held: [String: HeldPin]
    }

    /// A pin as the Mac keeps it.
    public struct PinRecord: Codable, Sendable, Hashable {
        public var info: PinInfo
        /// The folder or file on the Mac.
        public var path: String
        /// The security-scoped grant the app passed the helper (SYNC-2), when there is one.
        public var bookmark: Data?
    }

    struct Persisted: Codable {
        var phones: [PhoneRecord] = []
        var pinSet: UInt64 = 0
        var pins: [PinRecord] = []
        var trust = PageTrust()
        var totalLimit: Int64 = LinkBounds.defaultTotalLimit
    }

    /// What Settings > iPhone shows.
    public struct Snapshot: Sendable {
        public struct PinStatus: Sendable, Hashable {
            public var info: PinInfo
            public var path: String
            public var size: Int64
            public var files: Int
            public var problems: [String]
        }

        /// The phone that sent the right code: the name typed for it and the six digits.
        public struct WaitingPhone: Sendable, Hashable {
            public var name: String
            public var digits: String
        }

        public struct Pairing: Sendable, Hashable {
            public var invite: PairingInvite?
            public var expires: Date?
            public var waiting: WaitingPhone?
            public var ended: PairingMode.Ended?
        }

        public var phones: [PhoneRecord]
        public var connected: Set<Data>
        public var pins: [PinStatus]
        public var pairing: Pairing
        public var totalLimit: Int64
        public var listening: Bool
        /// The listener failed and is being made again (`listening` is false meanwhile).
        public var restarting: Bool
        /// How many times a failed listener was made again since the helper started.
        public var restarts: Int
        public var port: UInt16?
        public var serviceName: String?
        public var problem: String?
        public var unsentSince: Date?
    }

    public let identity: LinkIdentity
    public let config: Config
    let queue = DispatchQueue(label: "linen.link.mac")
    /// Scans run one at a time, off the server's queue.
    private let scanQueue = DispatchQueue(label: "linen.link.mac.scan")
    private var listener: NWListener?
    private var listening = false
    private var problem: String?
    private var registeredName: String?
    private var persisted = Persisted()
    private var manifests: [String: MacPinManifest] = [:]
    private var pairing = PairingMode()
    private var invite: PairingInvite?
    private var sessions: [UUID: MacSession] = [:]
    private var timer: (any DispatchSourceTimer)?
    private let resolveRoot: @Sendable (PinRecord) -> URL?
    private var roots: [String: URL] = [:]
    /// When pinned changes first waited for a phone that had not fetched them (SYNC-5's one-hour notice).
    private var unsentSince: Date?
    private var onChangeHandler: (@Sendable () -> Void)?
    private var linksFor: (@Sendable (URL, String) -> [String: LinkTargetRef]?)?
    /// Frames sent, by session kind and type: what the tests read to check that a refused session got no data.
    private var sent: [LinkSessionKind: [FrameType: Int]] = [:]
    /// Sessions whose TLS handshake completed, by kind.
    private var readied: [LinkSessionKind: Int] = [:]

    /// Offsets of `want` entries that resume a partial file.
    private var resumed: [Int64] = []
    func resumedOffsets() -> [Int64] { queue.sync { resumed } }

    /// What the Mac has sent so far (tests).
    func framesSent() -> [LinkSessionKind: [FrameType: Int]] { queue.sync { sent } }
    func sessionsReady() -> [LinkSessionKind: Int] { queue.sync { readied } }

    /// `resolveRoot` turns a pin into a usable folder or file URL (the helper starts its security-scoped access there);
    /// by default the stored path.
    public init(identity: LinkIdentity, config: Config, resolveRoot: @escaping @Sendable (PinRecord) -> URL? = { URL(fileURLWithPath: $0.path) }) {
        self.identity = identity
        self.config = config
        self.resolveRoot = resolveRoot
        try? FileManager.default.createDirectory(at: config.stateDirectory.appendingPathComponent("manifests"), withIntermediateDirectories: true)
        if let d = try? Data(contentsOf: stateURL), let p = try? JSONDecoder().decode(Persisted.self, from: d) { persisted = p }
        for p in persisted.pins {
            if let d = try? Data(contentsOf: manifestURL(p.info.id)), let m = try? JSONDecoder().decode(MacPinManifest.self, from: d) {
                manifests[p.info.id] = m
            }
        }
    }

    /// Called on the server's queue after anything Settings shows changed.
    public func onChange(_ f: @escaping @Sendable () -> Void) { queue.sync { onChangeHandler = f } }

    /// Resolves each note's references for the manifest (SYNC-4): given a note's URL and its pin, the references as
    /// written mapped to where they lead.
    public func linkResolver(_ f: @escaping @Sendable (URL, String) -> [String: LinkTargetRef]?) { queue.sync { linksFor = f } }

    private var stateURL: URL { config.stateDirectory.appendingPathComponent("link.json") }
    private func manifestURL(_ id: String) -> URL { config.stateDirectory.appendingPathComponent("manifests/\(id).json") }

    private func save() {
        let e = JSONEncoder()
        if let d = try? e.encode(persisted) { try? d.write(to: stateURL, options: .atomic) }
    }

    private func saveManifest(_ id: String) {
        guard let m = manifests[id], let d = try? JSONEncoder().encode(m) else { return }
        try? d.write(to: manifestURL(id), options: .atomic)
    }

    private func changed() { onChangeHandler?() }

    // MARK: - Listening

    public func start() throws {
        try queue.sync {
            guard !running else { return }
            try makeListener()
            running = true
            for p in persisted.pins { roots[p.info.id] = resolveRoot(p) }
        }
    }

    /// Set between `start()` and `stop()`: while it is, a listener that fails is made again.
    private var running = false
    /// The pending restart of a failed listener, and how long the next one waits.
    private var restart: DispatchWorkItem?
    private var restartDelay: TimeInterval = 1
    /// How many times a failed listener was made again (Settings and the tests read it).
    private var restarts = 0
    /// When the current listener became ready, and the delay the pending restart was given (tests).
    private var readyAt: Date?
    private var scheduledDelay: TimeInterval = 0

    /// Makes and starts the listener; on the server's queue.
    private func makeListener() throws {
        let params = LinkTLS.parameters(identity: identity, queue: queue, peerToPeer: config.peerToPeer) { [weak self] hash in
            self?.verify(hash) ?? false
        }
        let l = try NWListener(using: params, on: config.port)
        if let name = config.serviceName { l.service = NWListener.Service(name: name, type: linenServiceType) }
        l.serviceRegistrationUpdateHandler = { [weak self, weak l] change in
            guard let self, let l, l === self.listener else { return }
            if case let .add(endpoint) = change, case let .service(name, _, _, _) = endpoint { self.registeredName = name; self.changed() }
        }
        l.stateUpdateHandler = { [weak self, weak l] st in
            guard let self, let l, l === self.listener else { return }
            switch st {
            case .ready:
                self.listening = true
                self.problem = nil
                // The backoff resets only after a listener has held for a while (in listenerFailed): one that binds
                // and then fails at once must not restart every second (review P2-3).
                self.readyAt = Date()
            case let .failed(e):
                self.listenerFailed(e)
            case let .waiting(e): self.listening = false; self.problem = "\(e)"
            case .cancelled: self.listening = false
            default: break
            }
            self.changed()
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: queue)
        listener = l
    }

    /// A listener that fails stays failed, and nothing reaches the Mac while the helper keeps running: seen on
    /// 2026-11-12, when mDNSResponder restarted ("Error advertising bonjour service: ServiceNotRunning") and the helper
    /// listened nowhere for days while Settings still showed a pairing code. So it is made again, after 1 s, then up
    /// to 30 s between tries. Sessions already open are separate connections and carry on.
    private func listenerFailed(_ e: NWError) {
        listening = false
        problem = "\(e)"
        listener?.cancel()
        listener = nil
        registeredName = nil
        if let r = readyAt, Date().timeIntervalSince(r) > 30 { restartDelay = 1 }
        readyAt = nil
        guard running, restart == nil else { return }
        let delay = restartDelay
        scheduledDelay = delay
        restartDelay = min(restartDelay * 2, 30)
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restart = nil
            guard self.running, self.listener == nil else { return }
            self.restarts += 1
            do {
                try self.makeListener()
            } catch {
                self.listenerFailed((error as? NWError) ?? .posix(.EINVAL))
            }
            self.changed()
        }
        restart = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Makes a failed listener now instead of at its pending restart (Pair in Settings must not wait out a backoff).
    private func restartNow() {
        guard running, let r = restart else { return }
        r.cancel()
        restart = nil
        restartDelay = 1
        restarts += 1
        do { try makeListener() } catch { listenerFailed((error as? NWError) ?? .posix(.EINVAL)) }
    }

    #if DEBUG
    func restartDelayForTesting() -> TimeInterval { queue.sync { scheduledDelay } }

    /// Tests and the helper's development mode: run the failure path as if the listener had failed.
    public func failListenerForTesting() {
        queue.sync {
            listenerFailed(.dns(DNSServiceErrorType(kDNSServiceErr_ServiceNotRunning)))
            changed()
        }
    }
    #endif

    public func stop() {
        queue.sync {
            running = false
            restart?.cancel()
            restart = nil
            restartDelay = 1
            restarts = 0
            readyAt = nil
            listener?.cancel()
            listener = nil
            for s in sessions.values { s.channel.connection.cancel() }
            sessions = [:]
            timer?.cancel()
            timer = nil
        }
    }

    /// The listening port, once ready.
    public var port: UInt16? { queue.sync { listener?.port?.rawValue } }

    /// The TLS verify block: a pinned phone always; an unknown certificate only while the QR is up.
    private func verify(_ hash: Data) -> Bool {
        if persisted.phones.contains(where: { $0.certHash == hash }) { return true }
        return pairing.acceptsUnknownCertificate(now: Date())
    }

    private func accept(_ c: NWConnection) {
        let s = MacSession(channel: FrameChannel(c))
        sessions[s.id] = s
        c.stateUpdateHandler = { [weak self, weak s] st in
            guard let self, let s else { return }
            switch st {
            case .ready: self.ready(s)
            // A failed handshake (a stranger, a replay, an expired QR) is cancelled at once so its socket closes.
            case .failed, .waiting: self.close(s)
            case .cancelled: self.ended(s)
            default: break
            }
        }
        c.start(queue: queue)
    }

    private func ready(_ s: MacSession) {
        guard let hash = LinkTLS.peerCertHash(s.channel.connection) else { return close(s) }
        s.peer = hash
        defer { if let k = s.kind { readied[k, default: 0] += 1 } }
        if let i = persisted.phones.firstIndex(where: { $0.certHash == hash }) {
            s.kind = .pinned
            persisted.phones[i].lastSeen = Date()
            save()
            changed()
        } else {
            switch pairing.sessionBegan(s.id, now: Date()) {
            case .pair:
                s.kind = .pairing
                startTimer()
                changed()
            case .busy:
                s.kind = .pairing
                s.answered = true
                send(s, .json(.pairResult, PairResult.refused(.busy)), thenClose: true)
                return
            case .close:
                return close(s)
            }
        }
        s.channel.startReceiving({ [weak self, weak s] f in
            guard let self, let s else { return }
            self.queue.async { self.handle(f, on: s) }
        }, onEnd: { [weak self, weak s] _ in
            guard let self, let s else { return }
            self.queue.async { self.close(s) }
        })
    }

    private func ended(_ s: MacSession) {
        guard sessions.removeValue(forKey: s.id) != nil else { return }
        s.closeFiles()
        if s.kind == .pairing { pairing.sessionEnded(s.id, violation: false) }
        changed()
    }

    private func close(_ s: MacSession) {
        s.channel.connection.cancel()
        ended(s)
    }

    private func send(_ s: MacSession, _ f: Frame, thenClose: Bool = false) {
        sent[s.kind ?? .pinned, default: [:]][f.type, default: 0] += 1
        s.channel.send(f) { [weak self, weak s] _ in
            guard thenClose, let self, let s else { return }
            self.queue.async { self.close(s) }
        }
    }

    // MARK: - Frames

    private func handle(_ f: Frame, on s: MacSession) {
        guard sessions[s.id] != nil, let kind = s.kind else { return }
        s.framesIn += 1
        // A first `hello` from an unpinned certificate is a phone confirming its own pairing (its answer was lost, or it
        // gave up waiting): closed quietly, nothing sent, and pairing mode stays open (review P2-4; lead, 2026-11-14).
        // An unknown certificate gets nothing from it. Every other misstep still ends pairing mode.
        if kind == .pairing, f.type == .hello, s.framesIn == 1, !s.answered {
            pairing.sessionEnded(s.id, violation: false)
            return close(s)
        }
        guard f.type.allowed(on: kind, from: .phone), !(kind == .pairing && s.answered) else {
            // Any frame not in the list, from the wrong side, or after pair-result: the session ends, and a pairing
            // session's misstep ends pairing mode.
            if kind == .pairing {
                pairing.sessionEnded(s.id, violation: true)
                invite = nil
            }
            return close(s)
        }
        do {
            switch f.type {
            case .pairCode: try pairCode(f.decode(PairCode.self), on: s)
            case .hello: try hello(f.decode(Hello.self), on: s)
            case .pinsOK: _ = try f.decode(PinsOK.self)
            case .want: try want(f.decode(Want.self), on: s)
            case .done: try done(f.decode(Done.self), on: s)
            default: close(s)
            }
        } catch {
            if kind == .pairing { pairing.sessionEnded(s.id, violation: true); invite = nil }
            close(s)
        }
    }

    // MARK: Pairing

    /// Opens pairing mode with a new one-time code; the QR's text is `invite.text`.
    public func beginPairing() -> PairingInvite {
        queue.sync {
            restartNow()
            if let s = pairing.cancel(), let session = sessions[s] { close(session) }
            let code = PairingInvite.newCode()
            pairing.open(code: code, now: Date(), lifetime: config.pairingLifetime)
            let inv = PairingInvite(macCertHash: identity.certHash, service: registeredName ?? config.serviceName ?? config.macName, macName: config.macName, code: code)
            invite = inv
            startTimer()
            changed()
            return inv
        }
    }

    public func cancelPairing() {
        queue.sync {
            if let s = pairing.cancel(), let session = sessions[s] { close(session) }
            invite = nil
            changed()
        }
    }

    /// Allow or Refuse on the Mac.
    public func answerPairing(allow: Bool) {
        queue.sync {
            guard let (sid, result, pin) = pairing.answer(allow: allow) else { return }
            invite = nil
            if let pin {
                persisted.phones.removeAll { $0.certHash == pin.phoneCertHash }
                persisted.phones.append(PhoneRecord(certHash: pin.phoneCertHash, name: pin.phoneName, pairedAt: Date(), lastSeen: Date(), held: [:]))
                save()
            }
            if let s = sessions[sid] {
                s.answered = true
                var r = result
                if r.allowed { r.mac = config.macName }
                send(s, .json(.pairResult, r), thenClose: true)
            }
            changed()
        }
    }

    private func pairCode(_ p: PairCode, on s: MacSession) throws {
        guard let peer = s.peer, let exported = LinkTLS.exported(s.channel.connection) else { return close(s) }
        let digits = PairingDigits.digits(exported: exported, macCertHash: identity.certHash, phoneCertHash: peer)
        let name = String(p.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        let code = Data(base64URL: p.code) ?? Data()
        switch pairing.codeReceived(s.id, code: code, phoneName: name.isEmpty ? "iPhone" : name, phoneCertHash: peer, digits: digits, now: Date()) {
        case .wait:
            changed()
        case let .result(r):
            if !pairing.isOpen { invite = nil }
            s.answered = true
            send(s, .json(.pairResult, r), thenClose: true)
            changed()
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        if let (sid, r) = pairing.tick(now: Date()) {
            invite = nil
            if let sid, let s = sessions[sid] {
                s.answered = true
                send(s, .json(.pairResult, r), thenClose: true)
            }
            changed()
        }
        if !pairing.isOpen {
            timer?.cancel()
            timer = nil
        }
    }

    /// Forgets a phone: its certificate is refused from now on, and its sessions end.
    public func forgetPhone(_ certHash: Data) {
        queue.sync {
            persisted.phones.removeAll { $0.certHash == certHash }
            save()
            for s in sessions.values where s.peer == certHash && s.kind == .pinned { close(s) }
            changed()
        }
    }

    // MARK: Pins

    /// Keep on iPhone (SYNC-3): pins a folder or a single file. Returns the pin, or the existing one for that path.
    @discardableResult
    public func pin(path: String, kind: Pin.Kind, name: String? = nil, bookmark: Data? = nil) -> PinInfo {
        let path = Paths.canonical(URL(fileURLWithPath: path)).path
        let info: PinInfo = queue.sync {
            if let p = persisted.pins.first(where: { $0.path == path }) { return p.info }
            let id = UUID().uuidString.lowercased()
            let display = path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            let info = PinInfo(id: id, kind: kind, name: name ?? (path as NSString).lastPathComponent, macPath: display, trust: persisted.trust.revision)
            let rec = PinRecord(info: info, path: path, bookmark: bookmark)
            persisted.pins.append(rec)
            persisted.pinSet += 1
            roots[id] = resolveRoot(rec)
            manifests[id] = MacPinManifest(pin: id, trust: persisted.trust.revision)
            save()
            return info
        }
        rescan([info.id])
        queue.sync {
            for s in sessions.values where s.kind == .pinned { send(s, .json(.changed, Changed(pinSet: persisted.pinSet))) }
        }
        return info
    }

    public func unpin(_ id: String) {
        queue.sync {
            guard persisted.pins.contains(where: { $0.info.id == id }) else { return }
            persisted.pins.removeAll { $0.info.id == id }
            persisted.pinSet += 1
            manifests[id] = nil
            roots[id] = nil
            try? FileManager.default.removeItem(at: manifestURL(id))
            save()
            for s in sessions.values where s.kind == .pinned { send(s, .json(.changed, Changed(pinSet: persisted.pinSet))) }
            changed()
        }
    }

    /// The app's page trust (PAGE-7). A new revision re-sends the pages whose policy changed.
    public func setTrust(_ t: PageTrust) {
        let changedTrust: Bool = queue.sync {
            guard t.folders != persisted.trust.folders || t.perFile != persisted.trust.perFile else { return false }
            var t = t
            t.revision = max(t.revision, persisted.trust.revision + 1)
            persisted.trust = t
            save()
            return true
        }
        if changedTrust { rescan() }
    }

    public func setTotalLimit(_ n: Int64) {
        queue.sync {
            persisted.totalLimit = max(n, 1)
            save()
        }
        rescan()
    }

    /// Walks the pins again and tells connected phones about any that changed. The watcher calls it.
    public func rescan(_ ids: [String]? = nil) {
        scanQueue.sync { scan(ids) }
    }

    private func scan(_ ids: [String]?) {
        let work: [(PinRecord, URL?, MacPinManifest, PageTrust, Int64)] = queue.sync {
            var used: Int64 = 0
            return persisted.pins.compactMap { p in
                let m = manifests[p.info.id] ?? MacPinManifest(pin: p.info.id, trust: persisted.trust.revision)
                defer { used += m.totalSize }
                guard ids == nil || ids!.contains(p.info.id) else { return nil }
                return (p, roots[p.info.id], m, persisted.trust, persisted.totalLimit - used)
            }
        }
        let (resolver, limit) = queue.sync { (linksFor, persisted.totalLimit) }
        var results: [(String, MacPinManifest, Bool)] = []
        for (p, root, old, trust, room) in work {
            var m = old
            guard let root else {
                m.problems = ["\(p.info.name): Linen cannot read this folder any more; pin it again"]
                results.append((p.info.id, m, false))
                continue
            }
            var scan = PinFiles.scan(root: root, kind: p.info.kind)
            let size = scan.files.reduce(Int64(0)) { $0 + $1.stamp.size }
            if size > room {
                scan = PinScan(files: [], problems: ["Keeping this would pass the \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .binary)) limit for the iPhone"])
            }
            let canonical = root.resolvingSymlinksInPath().path
            let changed = m.apply(scan, trust: trust.revision,
                                  hash: { PinFiles.hash(root: root, kind: p.info.kind, diskPath: $0) },
                                  scripts: { disk in trust.policy(canonicalPath: p.info.kind == .file ? canonical : canonical + "/" + disk) },
                                  links: { disk, _ in resolver?(p.info.kind == .file ? root : root.appendingPathComponent(disk), p.info.id) })
            results.append((p.info.id, m, changed))
        }
        queue.sync {
            for (id, m, didChange) in results where persisted.pins.contains(where: { $0.info.id == id }) {
                manifests[id] = m
                saveManifest(id)
                if let i = persisted.pins.firstIndex(where: { $0.info.id == id }), persisted.pins[i].info.trust != m.trust {
                    persisted.pins[i].info.trust = m.trust
                    persisted.pinSet += 1
                    save()
                }
                guard didChange else { continue }
                if unsentSince == nil { unsentSince = Date() }
                for s in sessions.values where s.kind == .pinned {
                    send(s, .json(.changed, Changed(pin: id, sequence: m.sequence, trust: m.trust)))
                }
            }
            changed()
        }
    }

    /// The helper calls this before the Mac sleeps: connected phones show "Mac asleep" instead of "not nearby".
    public func prepareForSleep() {
        queue.sync {
            for s in sessions.values where s.kind == .pinned { send(s, .json(.changed, Changed(sleep: true)), thenClose: true) }
        }
    }

    public func snapshot() -> Snapshot {
        queue.sync {
            let w = pairing.waiting.map { Snapshot.WaitingPhone(name: $0.phoneName, digits: $0.digits) }
            let connected = Set(sessions.values.filter { $0.kind == .pinned }.compactMap(\.peer))
            return Snapshot(
                phones: persisted.phones,
                connected: connected,
                pins: persisted.pins.map { p in
                    let m = manifests[p.info.id]
                    return .init(info: p.info, path: p.path, size: m?.totalSize ?? 0, files: m?.entries.count ?? 0, problems: m?.problems ?? [])
                },
                pairing: .init(invite: pairing.isOpen || pairing.waiting != nil ? invite : nil, expires: pairing.isOpen ? pairing.expires : nil, waiting: w, ended: pairing.ended),
                totalLimit: persisted.totalLimit, listening: listening, restarting: running && restart != nil, restarts: restarts,
                port: listener?.port?.rawValue,
                serviceName: registeredName ?? config.serviceName, problem: problem, unsentSince: unsentSince)
        }
    }

    /// The pins with their roots, for the watcher.
    public func pinRoots() -> [(id: String, url: URL)] {
        queue.sync { persisted.pins.compactMap { p in roots[p.info.id].map { (p.info.id, $0) } } }
    }

    // MARK: Pinned sessions

    private func hello(_ h: Hello, on s: MacSession) throws {
        guard h.version == LinkBounds.protocolVersion, let peer = s.peer,
              let i = persisted.phones.firstIndex(where: { $0.certHash == peer }) else { return close(s) }
        var held: [String: HeldPin] = [:]
        for p in h.pins.prefix(1000) { held[p.id] = p }
        persisted.phones[i].held = held
        persisted.phones[i].lastSeen = Date()
        save()
        if h.pinSet != persisted.pinSet {
            send(s, .json(.pins, PinSetFrame(generation: persisted.pinSet, pins: persisted.pins.map(\.info))))
        }
        for p in persisted.pins {
            guard let m = manifests[p.info.id] else { continue }
            let hp = held[p.info.id]
            for page in m.frames(heldManifest: hp?.manifest ?? "", heldSequence: hp?.sequence ?? 0) {
                send(s, .json(.manifest, page))
            }
        }
        changed()
    }

    private func want(_ w: Want, on s: MacSession) throws {
        guard let m = manifests[w.pin], let rec = persisted.pins.first(where: { $0.info.id == w.pin }), let root = roots[w.pin],
              w.files.count <= LinkBounds.maxEntriesPerPin, s.queued.count + w.files.count <= LinkBounds.maxEntriesPerPin else { return close(s) }
        for f in w.files {
            guard LinkPath.isValidHash(f.sha), f.offset >= 0, let e = m.entry(sha: f.sha), f.offset <= e.size else { continue }
            if f.offset > 0 { resumed.append(f.offset) }
            s.queued.append(MacSession.Serve(pin: w.pin, kind: rec.info.kind, root: root, diskPath: m.diskPath(e.path), sha: f.sha, offset: f.offset, size: e.size))
        }
        pump(s)
    }

    /// Sends the queued files a chunk at a time, keeping a few chunks in flight.
    private func pump(_ s: MacSession) {
        while s.inFlight < 4, sessions[s.id] != nil {
            guard var job = s.queued.first else { return }
            if s.fd < 0 {
                guard let (fd, size) = PinFiles.open(root: job.root, kind: job.kind, diskPath: job.diskPath), size == job.size else {
                    // Gone or changed since the manifest: the next scan sends a new one.
                    s.queued.removeFirst()
                    let pin = job.pin
                    scanQueue.async { [weak self] in self?.scan([pin]) }
                    continue
                }
                s.fd = fd
            }
            let n = Int(min(Int64(LinkBounds.chunkBytes), job.size - job.offset))
            guard n > 0 || job.size == 0, let bytes = PinFiles.read(fd: s.fd, offset: job.offset, count: n), bytes.count == n else {
                s.closeFiles()
                s.queued.removeFirst()
                continue
            }
            let chunk = Chunk(sha: job.sha, offset: job.offset, bytes: bytes)
            job.offset += Int64(n)
            if job.offset >= job.size {
                s.closeFiles()
                s.queued.removeFirst()
            } else {
                s.queued[0] = job
            }
            s.inFlight += 1
            sent[.pinned, default: [:]][.chunk, default: 0] += 1
            s.channel.send(chunk.frame) { [weak self, weak s] _ in
                guard let self, let s else { return }
                self.queue.async {
                    s.inFlight -= 1
                    self.pump(s)
                }
            }
        }
    }

    private func done(_ d: Done, on s: MacSession) throws {
        guard let peer = s.peer, let i = persisted.phones.firstIndex(where: { $0.certHash == peer }) else { return }
        guard var m = manifests[d.pin] else { return }
        persisted.phones[i].held[d.pin] = HeldPin(id: d.pin, manifest: d.manifest, sequence: d.sequence, trust: m.trust)
        let acked = persisted.phones.compactMap { $0.held[d.pin] }.filter { $0.manifest == m.id }.map(\.sequence)
        m.prune(acked: acked)
        manifests[d.pin] = m
        saveManifest(d.pin)
        let caughtUp = persisted.phones.allSatisfy { ph in
            persisted.pins.allSatisfy { p in
                guard let mm = manifests[p.info.id] else { return true }
                return ph.held[p.info.id].map { $0.manifest == mm.id && $0.sequence >= mm.sequence } ?? false
            }
        }
        if caughtUp { unsentSince = nil }
        save()
        changed()
    }
}

/// One phone's connection to the Mac.
final class MacSession: @unchecked Sendable {
    struct Serve {
        var pin: String
        var kind: Pin.Kind
        var root: URL
        var diskPath: String
        var sha: String
        var offset: Int64
        var size: Int64
    }

    let id = UUID()
    let channel: FrameChannel
    var kind: LinkSessionKind?
    /// Frames received so far.
    var framesIn = 0
    var peer: Data?
    /// The pairing session's one `pair-result` went out; anything after it ends pairing.
    var answered = false
    var queued: [Serve] = []
    var inFlight = 0
    var fd: Int32 = -1

    init(channel: FrameChannel) { self.channel = channel }

    func closeFiles() {
        if fd >= 0 { close(fd) }
        fd = -1
    }

    deinit { closeFiles() }
}
