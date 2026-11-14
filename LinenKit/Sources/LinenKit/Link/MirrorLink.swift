import Foundation
import Network
#if canImport(UIKit)
import UIKit
#endif
#if os(iOS)
import BackgroundTasks
#endif

/// The phone's side of the link (section 9.3) and the `PhoneLink` the iPhone screens read: pairing by the Mac's QR,
/// then pinned sessions that bring the mirror up to the Mac's pins. The phone dials, every route at once; a session
/// that ends for any reason (a route change, the Mac sleeping, the app leaving) is dialled again and resumes from the
/// manifest sequences and `.partial` files the mirror holds (SYNC-5, RELAY-4).
public final class MirrorLink: PhoneLink, @unchecked Sendable {
    /// The paired Mac as the phone stores it.
    public struct MacRecord: Codable, Sendable, Hashable {
        public var certHash: Data
        public var service: String
        public var name: String
        public var phoneName: String
        public var pairedAt: Date
        public var lastSeen: Date?
    }

    public let mirror: PhoneMirror
    private let identities: any LinkIdentityStore
    private let recordURL: URL
    private let routes: any LinkRouteSource
    private let peerToPeer: Bool
    let queue = DispatchQueue(label: "linen.link.phone")
    private var record: MacRecord?
    private var current: LinkStatus = .notPaired
    private var listeners: [UUID: AsyncStream<LinkStatus>.Continuation] = [:]
    private var active = false
    private var dialer: LinkDialer?
    private var session: PhoneSession?
    private var retry: DispatchWorkItem?
    private var retryDelay: TimeInterval = 1
    private var asleep = false
    private var forgotten = false
    private var denied = false
    private var dialFailed = false
    private var pausedFiles = 0
    private var outOfSpace: Int64?
    private var monitor: NWPathMonitor?
    private var roundWaiters: [(id: UUID, c: CheckedContinuation<Bool, Never>)] = []
    private var pairingDialer: LinkDialer?
    private var pairingChannel: FrameChannel?
    private var observers: [any NSObjectProtocol] = []

    public init(mirror: PhoneMirror, identities: any LinkIdentityStore, recordURL: URL, routes: any LinkRouteSource = BonjourRoutes(), peerToPeer: Bool = true) {
        self.mirror = mirror
        self.identities = identities
        self.recordURL = recordURL
        self.routes = routes
        self.peerToPeer = peerToPeer
        if let d = try? Data(contentsOf: recordURL), let r = try? JSONDecoder().decode(MacRecord.self, from: d) { record = r }
        current = computeStatus()
        #if canImport(UIKit) && os(iOS)
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in self?.activate() })
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in self?.deactivate() })
        #endif
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    /// The phone's link with its default places: the mirror in Application Support, the identity in the keychain.
    public static func makeDefault() throws -> MirrorLink {
        let mirror = try PhoneMirror(root: PhoneMirror.defaultRoot())
        let rec = PhoneMirror.defaultRoot().deletingLastPathComponent().appendingPathComponent("link.json")
        return MirrorLink(mirror: mirror, identities: KeychainIdentityStore(), recordURL: rec)
    }

    private func saveRecord() {
        if let record, let d = try? JSONEncoder().encode(record) {
            try? d.write(to: recordURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: recordURL)
        }
    }

    // MARK: - The app's life

    /// The app is in front: dial when paired, and again on every network change.
    public func activate() {
        queue.async { [self] in
            guard !active else { return }
            active = true
            pausedFiles = mirror.partialCount()
            let m = NWPathMonitor()
            m.pathUpdateHandler = { [weak self] _ in self?.networkChanged() }  // on `queue`
            m.start(queue: queue)
            monitor = m
            dial()
        }
    }

    /// The app left the front: the transfer stops with its partial files kept, and resumes when the app returns.
    public func deactivate() {
        queue.async { [self] in
            active = false
            monitor?.cancel()
            monitor = nil
            retry?.cancel()
            retry = nil
            dialer?.cancel()
            dialer = nil
            session?.channel.connection.cancel()
            session = nil
            pausedFiles = mirror.partialCount()
            publish()
        }
    }

    private func networkChanged() {
        guard active, record != nil, !forgotten else { return }
        // A route change ends the session; the phone dials again and resumes (RELAY-4).
        if session == nil {
            retry?.cancel()
            retryDelay = 1
            dial()
        }
    }

    // MARK: - Status

    private func computeStatus() -> LinkStatus {
        guard let r = record else { return .notPaired }
        if forgotten { return .forgotten }
        if denied { return .localNetworkOff }
        if let n = outOfSpace { return .outOfSpace(needed: n) }
        if let s = session, s.isReady {
            if s.total > s.done {
                if pausedFiles > 0 { return .finishing(files: max(pausedFiles - s.done, 1)) }
                return .receiving(mac: r.name, done: s.done, total: s.total)
            }
            return .upToDate(mac: r.name, at: mirror.lastSync ?? Date())
        }
        if asleep { return .asleep(mac: r.name, copiesFrom: mirror.lastSync) }
        if !dialFailed, active, let last = mirror.lastSync { return .upToDate(mac: r.name, at: last) }
        return .notNearby(copiesFrom: mirror.lastSync)
    }

    fileprivate func publish() {
        let s = computeStatus()
        guard s != current else { return }
        current = s
        for l in listeners.values { l.yield(s) }
    }

    public func status() async -> LinkStatus { queue.sync { current } }

    public func statusUpdates() -> AsyncStream<LinkStatus> {
        AsyncStream { c in
            let id = UUID()
            queue.async { [self] in
                listeners[id] = c
                c.yield(current)
            }
            c.onTermination = { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.listeners[id] = nil }
            }
        }
    }

    public func pairedMac() async -> PairedMac? {
        queue.sync { record.map { PairedMac(name: $0.name, phoneName: $0.phoneName, pairedAt: $0.pairedAt, lastSeen: $0.lastSeen) } }
    }

    /// The certificate hash this phone presents, for tests and the settings sheet.
    public func phoneCertHash() -> Data? { try? identities.load()?.certHash }

    // MARK: - Pinned sessions

    private func dial() {
        guard active, dialer == nil, session == nil, let r = record, !forgotten else { return }
        guard let identity = try? identities.loadOrCreate(commonName: "Linen iPhone") else { return }
        let d = LinkDialer(queue: queue, identity: identity, pin: r.certHash, routes: routes, service: r.service, peerToPeer: peerToPeer) { [weak self] result in
            self?.dialed(result)
        }
        dialer = d
        d.start()
    }

    private func dialed(_ result: Result<NWConnection, LinkDialer.Failure>) {
        dialer = nil
        switch result {
        case let .success(c):
            denied = false
            dialFailed = false
            asleep = false
            retryDelay = 1
            let s = PhoneSession(link: self, connection: c)
            session = s
            c.stateUpdateHandler = { [weak self, weak s] st in
                guard let self, let s else { return }
                // The state can report the end before the receive loop has delivered the last frames (the Mac's
                // sleep notice), so this path waits a moment; the receive loop ends the session first when it can.
                let end: (NWError?) -> Void = { e in self.queue.asyncAfter(deadline: .now() + 0.2) { self.sessionEnded(s, error: e) } }
                switch st {
                case let .failed(e): end(e)
                case .cancelled: end(nil)
                case let .waiting(e): end(e)
                default: break
                }
            }
            if var r = record {
                r.lastSeen = Date()
                record = r
                saveRecord()
            }
            s.start()
        case .failure(.refused):
            forgotten = true
            dialFailed = true
        case .failure(.localNetworkOff):
            denied = true
            dialFailed = true
            scheduleRetry()
        case .failure(.unreachable):
            dialFailed = true
            scheduleRetry()
        }
        publish()
    }

    fileprivate func sessionEnded(_ s: PhoneSession, error: NWError?) {
        guard session === s else { return }
        session = nil
        s.channel.connection.cancel()
        if !s.receivedAny, let error, case .tls = error {
            // The Mac proved itself in the handshake and then refused this phone's certificate.
            forgotten = true
        }
        for w in roundWaiters { w.c.resume(returning: false) }
        roundWaiters = []
        publish()
        if !forgotten { scheduleRetry(soon: !asleep) }
    }

    private func scheduleRetry(soon: Bool = false) {
        guard active, record != nil, !forgotten else { return }
        retry?.cancel()
        let delay = soon ? 0.5 : retryDelay
        retryDelay = min(retryDelay * 2, 30)
        let item = DispatchWorkItem { [weak self] in self?.dial() }
        retry = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// A round ended with every pin answered; `needed` is set when a pin could not be fetched for lack of space.
    fileprivate func roundCompleted(needed: Int64?) {
        pausedFiles = 0
        outOfSpace = needed
        mirror.markSynced()
        for w in roundWaiters { w.c.resume(returning: needed == nil) }
        roundWaiters = []
        publish()
    }

    fileprivate func setAsleep() {
        asleep = true
        publish()
    }

    /// Pull to sync: dial now if a Mac is in reach, and wait (up to 15 s) for the round to finish.
    public func syncNow() async {
        _ = await syncRound(timeout: 15)
    }

    /// Dials once and waits for one complete round; true when the phone is up to date. Background refresh uses it.
    public func syncRound(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            queue.async { [self] in
                guard record != nil, !forgotten else { return c.resume(returning: false) }
                if !active { active = true; standalone = true }
                let id = UUID()
                roundWaiters.append((id, c))
                if let s = session { s.newRound() } else {
                    retry?.cancel()
                    dial()
                }
                queue.asyncAfter(deadline: .now() + timeout) { [self] in
                    guard let i = roundWaiters.firstIndex(where: { $0.id == id }) else { return }
                    roundWaiters.remove(at: i).c.resume(returning: false)
                }
            }
        }
    }

    /// Set when a sync ran without the app in front (background refresh); the link stops after it.
    private var standalone = false

    /// Background refresh (SYNC-5): fetch what changed from an awake Mac in the time iOS gives, then stop.
    public func backgroundRefresh() async -> Bool {
        let ok = await syncRound(timeout: 25)
        queue.async { [self] in
            if standalone {
                standalone = false
                active = false
                session?.channel.connection.cancel()
                session = nil
                dialer?.cancel()
                dialer = nil
            }
        }
        return ok
    }

    #if os(iOS)
    /// Registers the refresh task; the app calls it once, before it finishes launching. The identifier must be in
    /// the app's `BGTaskSchedulerPermittedIdentifiers`.
    public func registerBackgroundRefresh(identifier: String) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { [weak self] task in
            guard let self else { return task.setTaskCompleted(success: false) }
            let box = TaskBox(task)
            self.scheduleBackgroundRefresh(identifier: identifier)
            let work = Task { await self.backgroundRefresh() }
            task.expirationHandler = { work.cancel(); self.deactivate() }
            Task {
                let ok = await work.value
                box.task.setTaskCompleted(success: ok)
            }
        }
    }

    private final class TaskBox: @unchecked Sendable {
        let task: BGTask
        init(_ task: BGTask) { self.task = task }
    }

    public func scheduleBackgroundRefresh(identifier: String) {
        let r = BGAppRefreshTaskRequest(identifier: identifier)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }
    #endif

    // MARK: - Pairing

    public func pair(scannedCode: String, phoneName: String) -> AsyncStream<PairingStep> {
        AsyncStream { c in
            queue.async { [self] in startPairing(scannedCode, phoneName, c) }
        }
    }

    private func startPairing(_ text: String, _ phoneName: String, _ c: AsyncStream<PairingStep>.Continuation) {
        guard let invite = PairingInvite(text: text) else {
            c.yield(.failed(.notALinenCode))
            return c.finish()
        }
        guard let identity = try? identities.loadOrCreate(commonName: "Linen iPhone") else {
            c.yield(.failed(.unreachable))
            return c.finish()
        }
        pairingDialer?.cancel()
        pairingChannel?.connection.cancel()
        c.yield(.dialing)
        let name = phoneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "iPhone" : phoneName
        let d = LinkDialer(queue: queue, identity: identity, pin: invite.macCertHash, routes: routes, service: invite.service, peerToPeer: peerToPeer, timeout: 15) { [weak self] result in
            guard let self else { return }
            self.pairingDialer = nil
            switch result {
            case .failure(.localNetworkOff):
                c.yield(.failed(.localNetworkOff))
                c.finish()
            case .failure(.refused):
                // The Mac proved itself but would not take an unknown phone: its code is no longer up.
                c.yield(.failed(.expired))
                c.finish()
            case .failure(.unreachable):
                c.yield(.failed(.unreachable))
                c.finish()
            case let .success(conn):
                self.pairingSession(conn, invite: invite, identity: identity, name: name, c)
            }
        }
        pairingDialer = d
        d.start()
    }

    private func pairingSession(_ conn: NWConnection, invite: PairingInvite, identity: LinkIdentity, name: String, _ c: AsyncStream<PairingStep>.Continuation) {
        guard let exported = LinkTLS.exported(conn) else {
            conn.cancel()
            c.yield(.failed(.unreachable))
            return c.finish()
        }
        let digits = PairingDigits.digits(exported: exported, macCertHash: invite.macCertHash, phoneCertHash: identity.certHash)
        let ch = FrameChannel(conn)
        pairingChannel = ch
        let finished = Flag()
        let shown = Flag()
        // In TLS 1.3 the phone's side is ready before the Mac has checked the phone's certificate, so a Mac that is not
        // pairing refuses the session just after. A refusal in the handshake means its code is no longer up.
        let end: @Sendable (NWError?) -> Void = { [weak self] e in
            guard finished.setOnce() else { return }
            if let e, case .tls = e, !shown.isSet {
                c.yield(.failed(.expired))
                return c.finish()
            }
            // The session ended without the Mac's answer, which a dropped link can swallow (seen over peer-to-peer
            // Wi-Fi, 2026-10-31). Ask the Mac itself: if it takes a pinned session from this phone, Allow went through.
            guard let self else { return c.finish() }
            self.queue.async { self.confirmPairing(invite: invite, identity: identity, name: name, c) }
        }
        conn.stateUpdateHandler = { [weak self] st in
            // As for sync sessions: give the receive loop a moment to deliver `pair-result` first.
            let later: (NWError?) -> Void = { e in
                self?.queue.asyncAfter(deadline: .now() + 0.2) {
                    end(e)
                    conn.cancel()
                }
            }
            switch st {
            case let .failed(e), let .waiting(e):
                later(e)
            case .cancelled:
                later(nil)
            default: break
            }
        }
        ch.send(.json(.pairCode, PairCode(code: invite.code.base64URL, name: name)))
        // The digits show once the Mac has had time to refuse the handshake or answer a wrong code.
        queue.asyncAfter(deadline: .now() + 0.3) {
            guard !finished.isSet, shown.setOnce() else { return }
            c.yield(.match(digits: digits, mac: invite.macName))
        }
        ch.startReceiving({ [weak self] f in
            guard let self else { return }
            self.queue.async {
                guard finished.setOnce() else { return }
                conn.cancel()
                self.pairingChannel = nil
                guard f.type == .pairResult, let r = try? f.decode(PairResult.self) else {
                    c.yield(.failed(.refused))
                    return c.finish()
                }
                guard r.allowed else {
                    c.yield(.failed(r.reason.flatMap { PairingFailure(rawValue: $0.rawValue) } ?? .refused))
                    return c.finish()
                }
                self.completePairing(invite: invite, macName: r.mac ?? invite.macName, name: name, c)
            }
        }, onEnd: { e in end(e) })
    }

    /// Stores the Mac and starts syncing on a new session in which both certificates are pinned.
    private func completePairing(invite: PairingInvite, macName: String, name: String, _ c: AsyncStream<PairingStep>.Continuation) {
        if record?.certHash != invite.macCertHash { mirror.wipe() }
        let rec = MacRecord(certHash: invite.macCertHash, service: invite.service, name: macName, phoneName: name, pairedAt: Date(), lastSeen: Date())
        record = rec
        forgotten = false
        denied = false
        saveRecord()
        c.yield(.paired(PairedMac(name: rec.name, phoneName: rec.phoneName, pairedAt: rec.pairedAt, lastSeen: rec.lastSeen)))
        c.finish()
        publish()
        session?.channel.connection.cancel()
        session = nil
        retry?.cancel()
        dial()
    }

    /// A pairing session ended without `pair-result`: dial the Mac as a paired phone. A pinned session it answers
    /// means it pinned this phone (Allow went through); a refusal in the handshake means it did not.
    private func confirmPairing(invite: PairingInvite, identity: LinkIdentity, name: String, _ c: AsyncStream<PairingStep>.Continuation) {
        let d = LinkDialer(queue: queue, identity: identity, pin: invite.macCertHash, routes: routes, service: invite.service, peerToPeer: peerToPeer, timeout: 10) { [weak self] result in
            guard let self else { return c.finish() }
            self.pairingDialer = nil
            let conn: NWConnection
            switch result {
            case let .success(x): conn = x
            case .failure(.refused):
                c.yield(.failed(.refused))
                return c.finish()
            case .failure:
                c.yield(.failed(.unreachable))
                return c.finish()
            }
            let answered = Flag()
            let ch = FrameChannel(conn)
            self.pairingChannel = ch
            // A pin-set generation the Mac never has, so it answers with its pin set at once.
            ch.send(.json(.hello, Hello(pinSet: .max, pins: [])))
            ch.startReceiving({ [weak self] _ in
                guard answered.setOnce(), let self else { return }
                self.queue.async {
                    conn.cancel()
                    self.pairingChannel = nil
                    self.completePairing(invite: invite, macName: invite.macName, name: name, c)
                }
            }, onEnd: { _ in
                guard answered.setOnce() else { return }
                c.yield(.failed(.refused))
                c.finish()
            })
            self.queue.asyncAfter(deadline: .now() + 5) {
                guard answered.setOnce() else { return }
                conn.cancel()
                c.yield(.failed(.unreachable))
                c.finish()
            }
        }
        pairingDialer = d
        d.start()
    }

    /// Forgets the Mac and removes every pin with its files.
    public func forgetMac() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                retry?.cancel()
                dialer?.cancel()
                dialer = nil
                session?.channel.connection.cancel()
                session = nil
                record = nil
                forgotten = false
                asleep = false
                outOfSpace = nil
                saveRecord()
                mirror.wipe()
                publish()
                c.resume()
            }
        }
    }
}

/// A one-shot flag shared between callbacks.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    /// True the first time only.
    func setOnce() -> Bool {
        lock.withLock {
            if done { return false }
            done = true
            return true
        }
    }

    var isSet: Bool { lock.withLock { done } }
}

/// One pinned session from the phone: `hello`, the pin set, the manifests, `want`, the chunks and `done`, round after
/// round while it lasts. Runs on the link's queue.
final class PhoneSession: @unchecked Sendable {
    let channel: FrameChannel
    private unowned let link: MirrorLink
    private var mirror: PhoneMirror { link.mirror }
    private var assembling: [String: ManifestFrame] = [:]
    private var plans: [String: PhoneMirror.Plan] = [:]
    private var waiting: [String: Set<String>] = [:]
    private var answered: Set<String> = []
    private var retries: [String: Int] = [:]
    /// Bytes a pin of this round needed beyond the free space.
    private var needed: Int64?
    private var inRound = false
    private var dirty = false
    private(set) var isReady = false
    private(set) var receivedAny = false
    private(set) var total = 0
    private(set) var done = 0

    init(link: MirrorLink, connection: NWConnection) {
        self.link = link
        channel = FrameChannel(connection)
    }

    func start() {
        isReady = true
        channel.startReceiving({ [weak self] f in
            guard let self else { return }
            self.link.queue.async { self.handle(f) }
        }, onEnd: { [weak self] e in
            guard let self else { return }
            self.link.queue.async { self.link.sessionEnded(self, error: e) }
        })
        newRound()
    }

    /// Sends `hello` with what the mirror holds; the Mac answers with the pin set if it moved and one manifest per pin.
    func newRound() {
        guard !inRound else { dirty = true; return }
        inRound = true
        answered = []
        assembling = [:]
        channel.send(.json(.hello, mirror.held()))
    }

    private func fail() {
        channel.connection.cancel()
    }

    private func handle(_ f: Frame) {
        receivedAny = true
        guard f.type.allowed(on: .pinned, from: .mac) else { return fail() }
        do {
            switch f.type {
            case .pins:
                let p = try f.decode(PinSetFrame.self)
                mirror.applyPinSet(p)
                channel.send(.json(.pinsOK, PinsOK(generation: p.generation)))
                for id in plans.keys where !mirror.pinIDs.contains(id) { plans[id] = nil; waiting[id] = nil }
            case .manifest:
                try manifestPage(f.decode(ManifestFrame.self))
            case .chunk:
                chunk(try Chunk(frame: f))
            case .changed:
                let c = try f.decode(Changed.self)
                if c.sleep == true { link.setAsleep() } else { newRound() }
            default:
                fail()
            }
        } catch {
            fail()
        }
        link.publish()
    }

    private func manifestPage(_ page: ManifestFrame) throws {
        guard LinkPath.isValidPinID(page.pin) else { return fail() }
        var m = page
        if let a = assembling[page.pin] {
            m = a
            m.entries += page.entries
            m.removed += page.removed
            m.problems = (a.problems ?? []) + (page.problems ?? [])
            m.sequence = page.sequence
            m.trust = page.trust
            m.last = page.last
        }
        guard m.entries.count <= LinkBounds.maxEntriesPerPin, m.removed.count <= LinkBounds.maxEntriesPerPin * 2 else { return fail() }
        guard m.last else { assembling[page.pin] = m; return }
        assembling[page.pin] = nil
        let plan: PhoneMirror.Plan
        do { plan = try mirror.plan(m) } catch .unknownPin {
            // The pin set moved under this round; the next round brings it.
            dirty = true
            return pinAnswered(m.pin)
        } catch {
            return pinAnswered(m.pin)
        }
        if plan.bytes > 0, let free = mirror.availableSpace(), plan.bytes > free - 200 * 1024 * 1024 {
            needed = (needed ?? 0) + plan.bytes
            return pinAnswered(m.pin)
        }
        if plan.wanted.isEmpty {
            commit(plan)
            return
        }
        if let old = waiting[plan.pin] { total -= old.count }
        plans[plan.pin] = plan
        waiting[plan.pin] = Set(plan.wanted.map(\.sha))
        total += plan.wanted.count
        var page: [WantedFile] = []
        for w in plan.wanted {
            page.append(w)
            if page.count == 2000 {
                channel.send(.json(.want, Want(pin: plan.pin, files: page)))
                page = []
            }
        }
        if !page.isEmpty { channel.send(.json(.want, Want(pin: plan.pin, files: page))) }
    }

    private func chunk(_ c: Chunk) {
        switch mirror.receive(c) {
        case .progress, .unexpected:
            break
        case let .complete(sha):
            for (pin, var w) in waiting where w.contains(sha) {
                w.remove(sha)
                waiting[pin] = w
                done += 1
                if w.isEmpty, let plan = plans[pin] { commit(plan) }
            }
        case let .mismatch(sha):
            for (pin, w) in waiting where w.contains(sha) {
                let n = (retries[sha] ?? 0) + 1
                retries[sha] = n
                if n <= 2 {
                    channel.send(.json(.want, Want(pin: pin, files: [WantedFile(sha: sha, offset: 0)])))
                } else {
                    // The Mac keeps sending bytes that do not match: wait for its next manifest.
                    waiting[pin] = nil
                    plans[pin] = nil
                    pinAnswered(pin)
                }
            }
        }
    }

    private func commit(_ plan: PhoneMirror.Plan) {
        plans[plan.pin] = nil
        waiting[plan.pin] = nil
        if (try? mirror.commit(plan)) != nil {
            channel.send(.json(.done, Done(pin: plan.pin, manifest: plan.manifest, sequence: plan.sequence)))
        }
        pinAnswered(plan.pin)
    }

    private func pinAnswered(_ pin: String) {
        answered.insert(pin)
        guard inRound, plans.isEmpty, Set(mirror.pinIDs).isSubset(of: answered) else { return }
        inRound = false
        total = 0
        done = 0
        let short = needed
        needed = nil
        link.roundCompleted(needed: short)
        if dirty {
            dirty = false
            newRound()
        }
    }
}
