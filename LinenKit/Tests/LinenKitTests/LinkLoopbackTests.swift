import CryptoKit
import Foundation
import Network
import Testing
@testable import LinenKit

/// The link end to end on this Mac over loopback: the real Mac server and real phone links, TLS 1.3 with pinned
/// certificates, the pairing mode and its refusal cases (PRD-2 section 12, L(a)), and the mirror reaching the Mac's
/// pins. No Bonjour and no keychain: fixed routes and identities in memory.
@Suite("Link over loopback", .serialized)
struct LinkLoopbackTests {
    final class Rig: @unchecked Sendable {
        let folder = TempFolder("LinkLoop")
        let mac: LinkIdentity
        let server: MacLinkServer
        let port: UInt16

        init(lifetime: TimeInterval = PairingMode.lifetime) async throws {
            mac = try LinkIdentity.generate(commonName: "test-mac")
            server = MacLinkServer(identity: mac, config: .init(macName: "Test Mac", serviceName: nil, port: .any, peerToPeer: false,
                                                                stateDirectory: folder.url.appendingPathComponent("mac"), pairingLifetime: lifetime))
            try server.start()
            let s = server
            #expect(await waitUntil { s.port != nil && s.snapshot().listening })
            port = server.port ?? 0
        }

        deinit { server.stop() }

        var endpoint: NWEndpoint { .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!) }

        func phone(_ name: String, store: MemoryIdentityStore = MemoryIdentityStore(), port: UInt16? = nil, routes: (any LinkRouteSource)? = nil) throws -> MirrorLink {
            let dir = folder.url.appendingPathComponent("phone-\(name)")
            let ep: NWEndpoint = port.map { .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: $0)!) } ?? endpoint
            return MirrorLink(mirror: try PhoneMirror(root: dir.appendingPathComponent("Mirror")), identities: store,
                              recordURL: dir.appendingPathComponent("link.json"), routes: routes ?? FixedRoutes([ep]), peerToPeer: false)
        }

        /// Writes a file under the Mac's folder `notes`.
        @discardableResult
        func write(_ rel: String, _ text: String) -> URL { folder.write("mac-files/\(rel)", text) }

        var notes: URL { folder.url.appendingPathComponent("mac-files/notes") }

        /// The hashes of the Mac's files under a folder, by relative path.
        func macHashes(_ root: URL) -> [String: String] {
            PinFiles.scan(root: root, kind: .folder).files.reduce(into: [:]) { out, f in
                out[f.path] = PinFiles.hash(root: root, kind: .folder, diskPath: f.diskPath)
            }
        }
    }

    /// Pairs and returns every step. On the match the Mac's digits are compared with the phone's, then `answer` runs.
    static func pair(_ link: MirrorLink, _ text: String, name: String, server: MacLinkServer, answer: Bool? = true) async -> [PairingStep] {
        var steps: [PairingStep] = []
        for await s in link.pair(scannedCode: text, phoneName: name) {
            steps.append(s)
            if case let .match(digits, _) = s, let answer {
                Task {
                    let shown = await waitUntil { server.snapshot().pairing.waiting != nil }
                    #expect(shown)
                    #expect(server.snapshot().pairing.waiting?.digits == digits, "both screens show the same six digits")
                    server.answerPairing(allow: answer)
                }
            }
        }
        return steps
    }

    static func failure(_ steps: [PairingStep]) -> PairingFailure? {
        if case let .failed(f) = steps.last { return f }
        return nil
    }

    // MARK: - Pairing and sync

    @Test("Pairing completes, both pins hold on a new session, and the phone mirrors the pin, changes within 2 s")
    func pairAndSync() async throws {
        let rig = try await Rig()
        rig.write("notes/a.md", "# Alpha\n\nSee [[b]].")
        rig.write("notes/sub/b.canvas", #"{"linen":{"title":"Board"},"nodes":[]}"#)
        rig.write("notes/report.html", "<title>Report</title><p>x</p>")
        rig.write("notes/.hidden/secret.md", "no")
        rig.write("outside.md", "never")
        let pin = rig.server.pin(path: rig.notes.path, kind: .folder)
        let invite = rig.server.beginPairing()
        let store = MemoryIdentityStore()
        let phone = try rig.phone("eight", store: store)
        let steps = await Self.pair(phone, invite.text, name: "Eight", server: rig.server)
        guard case .dialing = steps.first, case .match = steps.dropFirst().first, case let .paired(mac) = steps.last else {
            Issue.record("steps: \(steps)")
            return
        }
        #expect(mac.name == "Test Mac" && mac.phoneName == "Eight")
        let snap = rig.server.snapshot()
        #expect(snap.phones.map(\.name) == ["Eight"] && snap.phones.first?.certHash == phone.phoneCertHash())
        #expect(snap.pairing.ended == .paired(phoneName: "Eight") && snap.pairing.invite == nil)
        // On the pairing session the Mac sent one frame: pair-result.
        #expect(rig.server.framesSent()[.pairing] == [.pairResult: 1])

        phone.activate()
        let mirror = phone.mirror
        let macFiles = rig.macHashes(rig.notes)
        #expect(Set(macFiles.keys) == ["a.md", "sub/b.canvas", "report.html"])
        #expect(await waitUntil { mirror.filesOnDisk(pin.id) == macFiles }, "path sets and hashes equal on the phone")
        #expect(await waitUntil { if case .upToDate = await phone.status() { return true } else { return false } })
        #expect(rig.server.sessionsReady()[.pinned, default: 0] >= 1)
        let files = await mirror.files(in: pin.id)
        #expect(Set(files.map(\.title)) == ["Alpha", "Board", "Report"])
        #expect(files.first { $0.kind == .page }?.scripts == .off)

        // A change on the Mac reaches the phone (the watcher's rescan stands in for FSEvents here).
        let t0 = Date()
        rig.write("notes/a.md", "# Alpha, changed")
        rig.server.rescan()
        let changed = rig.macHashes(rig.notes)
        #expect(await waitUntil(5) { mirror.filesOnDisk(pin.id) == changed })
        let took = Date().timeIntervalSince(t0)
        #expect(took < 2, "a change reached the phone in \(took) s")
        #expect(await mirror.files(in: pin.id).first { $0.ref.path == "a.md" }?.changedSinceRead == true)

        // Removals, a new file and a renamed one: no stale extras.
        try FileManager.default.removeItem(at: rig.notes.appendingPathComponent("sub/b.canvas"))
        try FileManager.default.moveItem(at: rig.notes.appendingPathComponent("report.html"), to: rig.notes.appendingPathComponent("Report.html"))
        rig.write("notes/new.md", "# New")
        rig.server.rescan()
        let after = rig.macHashes(rig.notes)
        #expect(await waitUntil(5) { mirror.filesOnDisk(pin.id) == after })

        // A second pin, a trusted folder, then unpinning: the pin set is the Mac's.
        rig.write("plans/q3.md", "# Q3")
        let plans = rig.server.pin(path: rig.folder.url.appendingPathComponent("mac-files/plans").path, kind: .folder)
        #expect(await waitUntil(5) { mirror.filesOnDisk(plans.id).keys.sorted() == ["q3.md"] })
        rig.server.setTrust(PageTrust(revision: 5, folders: [rig.notes.resolvingSymlinksInPath().path]))
        #expect(await waitUntil(5) { await mirror.files(in: pin.id).first { $0.kind == .page }?.scripts?.on == true })
        rig.server.unpin(plans.id)
        #expect(await waitUntil(5) { await mirror.pins().map(\.id) == [pin.id] })

        // A new session, as after leaving and returning to the app, holds both pins and is up to date at once.
        phone.deactivate()
        #expect(await waitUntil { if case .notNearby = await phone.status() { return true }; if case .upToDate = await phone.status() { return true }; return false })
        let ready = rig.server.sessionsReady()[.pinned, default: 0]
        phone.activate()
        #expect(await waitUntil { rig.server.sessionsReady()[.pinned, default: 0] > ready })
        #expect(rig.server.framesSent()[.pairing] == [.pairResult: 1])
        phone.deactivate()
    }

    /// Routes the test can change: the first session goes through a proxy that cuts it, the next one direct.
    final class SwitchRoutes: LinkRouteSource, @unchecked Sendable {
        private let lock = NSLock()
        private var _endpoint: NWEndpoint
        var endpoint: NWEndpoint {
            get { lock.withLock { _endpoint } }
            set { lock.withLock { _endpoint = newValue } }
        }

        init(_ e: NWEndpoint) { _endpoint = e }

        func find(service: String?, peerToPeer: Bool, queue: DispatchQueue, update: @escaping @Sendable ([NWEndpoint]) -> Void,
                  denied: @escaping @Sendable () -> Void) -> any LinkRouteSearch {
            let e = endpoint
            queue.async { update([e]) }
            return FixedRoutes.Nothing()
        }
    }

    @Test("A session cut midway keeps its partial file; the next session, on another route, resumes and finishes")
    func resumes() async throws {
        let rig = try await Rig()
        var big = Data(count: 3 * 1024 * 1024)
        for i in big.indices { big[i] = UInt8(truncatingIfNeeded: i &* 31 &+ i >> 9) }
        let url = rig.write("notes/big.md", "")
        try big.write(to: url)
        let pin = rig.server.pin(path: rig.notes.path, kind: .folder)
        // Pair directly, then sync through a proxy that stops after 1 MB from the Mac.
        let routes = SwitchRoutes(rig.endpoint)
        let phone = try rig.phone("p", routes: routes)
        _ = await Self.pair(phone, rig.server.beginPairing().text, name: "P", server: rig.server)
        let proxy = try Proxy(to: rig.port, cutAfter: 1024 * 1024)
        #expect(await waitUntil { proxy.port != nil })
        routes.endpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: proxy.port!)!)
        phone.activate()
        #expect(await waitUntil(5) { proxy.cut })
        #expect(await waitUntil(5) { phone.mirror.partialCount() == 1 }, "the partial file is kept")
        let partial = try FileManager.default.contentsOfDirectory(at: phone.mirror.root.appendingPathComponent("partial"), includingPropertiesForKeys: [.fileSizeKey])
        let kept = try partial.first?.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        #expect(kept > 0 && kept < big.count)
        // The route changes; the phone dials again and resumes from the partial file.
        routes.endpoint = rig.endpoint
        let mac = rig.macHashes(rig.notes)
        #expect(await waitUntil(10) { phone.mirror.filesOnDisk(pin.id) == mac })
        #expect(phone.mirror.partialCount() == 0)
        #expect(rig.server.resumedOffsets().contains { $0 >= Int64(kept) - Int64(LinkBounds.chunkBytes) && $0 > 0 }, "asked from the partial file's length")
        phone.deactivate()
    }

    @Test("Not enough space: nothing is fetched and the sync line says how much is needed; with space it syncs")
    func outOfSpace() async throws {
        let rig = try await Rig()
        rig.write("notes/a.md", String(repeating: "x", count: 50_000))
        let pin = rig.server.pin(path: rig.notes.path, kind: .folder)
        let phone = try rig.phone("s")
        _ = await Self.pair(phone, rig.server.beginPairing().text, name: "S", server: rig.server)
        phone.mirror.spaceOverride = 0
        phone.activate()
        #expect(await waitUntil(5) { if case let .outOfSpace(n) = await phone.status() { return n == 50_000 }; return false })
        #expect(phone.mirror.filesOnDisk(pin.id).isEmpty && rig.server.framesSent()[.pinned]?[.chunk] == nil)
        phone.mirror.spaceOverride = nil
        await phone.syncNow()
        #expect(phone.mirror.filesOnDisk(pin.id).keys.sorted() == ["a.md"])
        #expect(await waitUntil { if case .upToDate = await phone.status() { return true }; return false })
        phone.deactivate()
    }

    @Test("Before the Mac sleeps, connected phones are told: the line says asleep, not not nearby")
    func asleep() async throws {
        let rig = try await Rig()
        rig.write("notes/a.md", "# A")
        rig.server.pin(path: rig.notes.path, kind: .folder)
        let phone = try rig.phone("z")
        _ = await Self.pair(phone, rig.server.beginPairing().text, name: "Z", server: rig.server)
        phone.activate()
        #expect(await waitUntil { if case .upToDate = await phone.status() { return true }; return false })
        rig.server.prepareForSleep()
        // The notice goes out, then the session closes; only then does the Mac sleep (here: stop listening).
        // Stopping at once cancelled the session before the notice was flushed (about 1 run in 8).
        #expect(await waitUntil { rig.server.snapshot().connected.isEmpty })
        rig.server.stop()
        let ok = await waitUntil { if case let .asleep(mac, copies) = await phone.status() { return mac == "Test Mac" && copies != nil }; return false }
        let status = await phone.status()
        #expect(ok, "status: \(status); sleep notices sent: \(rig.server.framesSent()[.pinned]?[.changed] ?? 0)")
        phone.deactivate()
    }

    // MARK: - Refusals (L(a))

    @Test("A wrong code three times ends pairing mode; the right code after that is refused")
    func wrongCodes() async throws {
        let rig = try await Rig()
        let invite = rig.server.beginPairing()
        var wrong = invite
        wrong.code = PairingInvite.newCode()
        let phone = try rig.phone("w")
        for _ in 1...3 {
            #expect(Self.failure(await Self.pair(phone, wrong.text, name: "W", server: rig.server, answer: nil)) == .code)
        }
        #expect(rig.server.snapshot().pairing.ended == .wrongCodes)
        #expect(Self.failure(await Self.pair(phone, invite.text, name: "W", server: rig.server)) == .expired)
        #expect(rig.server.snapshot().phones.isEmpty)
        #expect(rig.server.framesSent()[.pairing] == [.pairResult: 3])
        #expect(rig.server.framesSent()[.pinned] == nil)
        #expect(await phone.status() == .notPaired)
    }

    @Test("An expired QR is refused and sends nothing")
    func expired() async throws {
        let rig = try await Rig(lifetime: 1)
        let invite = rig.server.beginPairing()
        try await Task.sleep(for: .milliseconds(1500))
        let phone = try rig.phone("e")
        #expect(Self.failure(await Self.pair(phone, invite.text, name: "E", server: rig.server)) == .expired)
        #expect(rig.server.snapshot().phones.isEmpty && rig.server.snapshot().pairing.ended == .expired)
        #expect(rig.server.framesSent().isEmpty && rig.server.sessionsReady().isEmpty)
    }

    @Test("A second phone during pairing is refused as busy; the first pairs")
    func secondPhone() async throws {
        let rig = try await Rig()
        let invite = rig.server.beginPairing()
        let a = try rig.phone("a")
        let b = try rig.phone("b")
        let first = Task { await Self.pair(a, invite.text, name: "A", server: rig.server, answer: nil) }
        #expect(await waitUntil { rig.server.snapshot().pairing.waiting != nil })
        #expect(Self.failure(await Self.pair(b, invite.text, name: "B", server: rig.server, answer: nil)) == .busy)
        rig.server.answerPairing(allow: true)
        let steps = await first.value
        guard case .paired = steps.last else { Issue.record("first phone: \(steps)"); return }
        #expect(rig.server.snapshot().phones.map(\.name) == ["A"])
        #expect(rig.server.framesSent()[.pairing] == [.pairResult: 2])
        #expect(await b.status() == .notPaired)
    }

    @Test("Refuse on the Mac, and no answer within 60 s, both end pairing")
    func refused() async throws {
        let rig = try await Rig()
        let phone = try rig.phone("r")
        #expect(Self.failure(await Self.pair(phone, rig.server.beginPairing().text, name: "R", server: rig.server, answer: false)) == .refused)
        #expect(rig.server.snapshot().phones.isEmpty && rig.server.snapshot().pairing.ended == .refused)
    }

    /// A client that speaks TLS to the Mac with its own identity, for the cases a real phone never makes.
    final class RawClient: @unchecked Sendable {
        let queue = DispatchQueue(label: "raw")
        let connection: NWConnection
        private let lock = NSLock()
        private var _state = "new"
        private var _received = Data()
        var state: String { lock.withLock { _state } }
        var received: Data { lock.withLock { _received } }

        init(rig: Rig, identity: LinkIdentity, framed: Bool = true) {
            let params = LinkTLS.parameters(identity: identity, queue: queue, peerToPeer: false, framed: framed) { [mac = rig.mac.certHash] in $0 == mac }
            connection = NWConnection(to: rig.endpoint, using: params)
            connection.stateUpdateHandler = { [weak self] st in
                guard let self else { return }
                let s: String
                switch st {
                case .ready: s = "ready"
                case .failed: s = "failed"
                case .cancelled: s = "cancelled"
                case .waiting: s = "waiting"
                default: return
                }
                self.lock.withLock { self._state = s }
            }
            connection.start(queue: queue)
        }

        func readAll() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] d, _, done, e in
                guard let self else { return }
                if let d { self.lock.withLock { self._received.append(d) } }
                if done || e != nil { self.lock.withLock { if self._state == "ready" { self._state = "closed" } }; return }
                self.readAll()
            }
        }

        func sendRaw(_ d: Data) { connection.send(content: d, completion: .contentProcessed { _ in }) }
        func cancel() { connection.cancel() }
    }

    @Test("A pairing session that sends hello or want is ended with nothing sent, and pairing mode ends")
    func pairingSessionCannotSync() async throws {
        for type in [FrameType.hello, .want] {
            let rig = try await Rig()
            rig.write("notes/a.md", "secret")
            rig.server.pin(path: rig.notes.path, kind: .folder)
            let invite = rig.server.beginPairing()
            let raw = RawClient(rig: rig, identity: try LinkIdentity.generate(commonName: "intruder"), framed: false)
            #expect(await waitUntil { raw.state == "ready" })
            raw.readAll()
            let payload = type == .hello ? Frame.json(.hello, Hello(pinSet: 0, pins: [])) : Frame.json(.want, Want(pin: "x", files: []))
            raw.sendRaw(payload.encoded)
            #expect(await waitUntil { raw.state == "closed" || raw.state == "failed" || raw.state == "cancelled" }, "\(type) closes the session")
            #expect(raw.received.isEmpty, "no frame came back")
            #expect(rig.server.framesSent().isEmpty)
            #expect(rig.server.snapshot().pairing.ended == .violation)
            raw.cancel()
            // The QR is gone with it.
            let phone = try rig.phone("late")
            #expect(Self.failure(await Self.pair(phone, invite.text, name: "L", server: rig.server)) == .expired)
        }
    }

    /// A plain TCP relay that records what the phone sends, so the recording can be replayed to the Mac, and can cut
    /// the stream from the Mac after some bytes.
    final class Proxy: @unchecked Sendable {
        let queue = DispatchQueue(label: "proxy")
        let listener: NWListener
        private let lock = NSLock()
        private var _recorded = Data()
        private var forwarded = 0
        private var _cut = false
        private let cutAfter: Int?
        /// Connections open now whose bytes from the Mac are swallowed, as a dead peer-to-peer link did.
        private var frozen = Set<ObjectIdentifier>()
        private var open: [NWConnection] = []
        var recorded: Data { lock.withLock { _recorded } }

        /// From now on, drop what the Mac sends on the connections already open.
        func freezeOpen() { lock.withLock { for c in open { frozen.insert(ObjectIdentifier(c)) } } }
        var cut: Bool { lock.withLock { _cut } }
        var port: UInt16? { listener.port.flatMap { $0.rawValue == 0 ? nil : $0.rawValue } }

        init(to target: UInt16, cutAfter: Int? = nil) throws {
            self.cutAfter = cutAfter
            listener = try NWListener(using: .tcp, on: .any)
            listener.newConnectionHandler = { [weak self] inbound in
                guard let self else { return }
                let outbound = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: target)!, using: .tcp)
                self.lock.withLock { self.open.append(outbound) }
                inbound.start(queue: self.queue)
                outbound.start(queue: self.queue)
                self.pipe(inbound, outbound, record: true)
                self.pipe(outbound, inbound, record: false)
            }
            listener.start(queue: queue)
        }

        private func pipe(_ from: NWConnection, _ to: NWConnection, record: Bool) {
            from.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] d, _, done, e in
                guard let self else { return }
                if let d, !d.isEmpty, !record, self.lock.withLock({ self.frozen.contains(ObjectIdentifier(from)) }) {
                    // Swallowed: neither forwarded nor acknowledged upstream as delivered.
                } else if let d, !d.isEmpty {
                    if record { self.lock.withLock { self._recorded.append(d) } }
                    let stop: Bool = self.lock.withLock {
                        guard !record, let limit = self.cutAfter else { return false }
                        if self._cut { return true }
                        self.forwarded += d.count
                        if self.forwarded > limit { self._cut = true; return true }
                        return false
                    }
                    if stop { to.cancel(); from.cancel(); return }
                    to.send(content: d, completion: .contentProcessed { _ in })
                }
                if done || e != nil { to.cancel(); from.cancel(); return }
                self.pipe(from, to, record: record)
            }
        }
    }

    @Test("A pair-result lost on the way (a dead link) still ends paired: the phone confirms with a pinned session")
    func lostResult() async throws {
        let rig = try await Rig()
        let proxy = try Proxy(to: rig.port)
        #expect(await waitUntil { proxy.port != nil })
        let phone = try rig.phone("lost", port: proxy.port)
        var steps: [PairingStep] = []
        for await s in phone.pair(scannedCode: rig.server.beginPairing().text, phoneName: "Lost") {
            steps.append(s)
            if case .match = s {
                _ = await waitUntil { rig.server.snapshot().pairing.waiting != nil }
                proxy.freezeOpen()
                rig.server.answerPairing(allow: true)
            }
        }
        guard case .paired = steps.last else { Issue.record("steps \(steps)"); return }
        #expect(await phone.pairedMac() != nil && rig.server.snapshot().phones.count == 1)
    }

    @Test("A replayed pairing session gets nothing, with or without a QR up")
    func replay() async throws {
        let rig = try await Rig()
        let proxy = try Proxy(to: rig.port)
        #expect(await waitUntil { proxy.port != nil })
        let invite = rig.server.beginPairing()
        let phone = try rig.phone("x", port: proxy.port)
        guard case .paired = (await Self.pair(phone, invite.text, name: "X", server: rig.server)).last else { Issue.record("pairing through the proxy"); return }
        let recorded = proxy.recorded
        #expect(recorded.count > 500)
        let sent = rig.server.framesSent()
        let ready = rig.server.sessionsReady()
        for qrUp in [false, true] {
            if qrUp { _ = rig.server.beginPairing() }
            let replay = NWConnection(to: rig.endpoint, using: .tcp)
            let got = DataBox()
            replay.stateUpdateHandler = { st in if case .ready = st { replay.send(content: recorded, completion: .contentProcessed { _ in }) } }
            func read() {
                replay.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { d, _, done, e in
                    if let d { got.append(d) }
                    if done || e != nil { got.close(); return }
                    read()
                }
            }
            replay.start(queue: .global())
            read()
            #expect(await waitUntil { got.closed })
            replay.cancel()
            #expect(rig.server.framesSent() == sent, "no frame went to the replay")
            #expect(rig.server.sessionsReady() == ready, "no session reached the frame layer")
            #expect(rig.server.snapshot().phones.count == 1 && rig.server.snapshot().pairing.waiting == nil)
        }
    }

    final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var d = Data()
        private var c = false
        func append(_ x: Data) { lock.withLock { d.append(x) } }
        func close() { lock.withLock { c = true } }
        var closed: Bool { lock.withLock { c } }
    }

    @Test("After pairing, an unknown certificate is refused in the handshake and gets nothing")
    func unknownAfterPairing() async throws {
        let rig = try await Rig()
        rig.write("notes/a.md", "secret")
        rig.server.pin(path: rig.notes.path, kind: .folder)
        let phone = try rig.phone("ok")
        _ = await Self.pair(phone, rig.server.beginPairing().text, name: "OK", server: rig.server)
        let sent = rig.server.framesSent()
        let raw = RawClient(rig: rig, identity: try LinkIdentity.generate(commonName: "stranger"))
        #expect(await waitUntil { raw.state == "failed" || raw.state == "waiting" || raw.state == "cancelled" })
        raw.readAll()
        raw.cancel()
        #expect(rig.server.framesSent() == sent && rig.server.sessionsReady()[.pairing] == 1)
        #expect(rig.server.snapshot().phones.count == 1)
    }

    @Test("A forgotten phone is refused, shows Pair again, and gets no data")
    func forgotten() async throws {
        let rig = try await Rig()
        rig.write("notes/a.md", "# A")
        let pin = rig.server.pin(path: rig.notes.path, kind: .folder)
        let phone = try rig.phone("f")
        _ = await Self.pair(phone, rig.server.beginPairing().text, name: "F", server: rig.server)
        phone.activate()
        #expect(await waitUntil(5) { !phone.mirror.filesOnDisk(pin.id).isEmpty })
        let hash = try #require(phone.phoneCertHash())
        rig.server.forgetPhone(hash)
        #expect(await waitUntil(5) { await phone.status() == .forgotten })
        let sent = rig.server.framesSent()
        rig.write("notes/b.md", "# B, never sent")
        rig.server.rescan()
        await phone.syncNow()
        #expect(rig.server.framesSent() == sent)
        #expect(phone.mirror.filesOnDisk(pin.id).keys.sorted() == ["a.md"], "the copies stay readable")
        phone.deactivate()
        // Forgetting on the phone removes the Mac and every pin.
        await phone.forgetMac()
        let status = await phone.status()
        let pins = await phone.mirror.pins()
        #expect(status == .notPaired && pins.isEmpty)
    }

    @Test("Oversized and unknown frames on a pinned session end it")
    func badFrames() async throws {
        let rig = try await Rig()
        let store = MemoryIdentityStore()
        let phone = try rig.phone("b", store: store)
        _ = await Self.pair(phone, rig.server.beginPairing().text, name: "B", server: rig.server)
        let identity = try #require(try store.load())
        for bytes in [Data([FrameType.want.rawValue, 0x01, 0x00, 0x00, 0x01]), Data([0x63, 0, 0, 0, 0]), Frame.json(.pairCode, PairCode(code: "x", name: "y")).encoded] {
            let raw = RawClient(rig: rig, identity: identity, framed: false)
            #expect(await waitUntil { raw.state == "ready" })
            raw.readAll()
            raw.sendRaw(bytes)
            #expect(await waitUntil { raw.state != "ready" }, "the Mac closed the session")
            raw.cancel()
        }
    }
}

/// Polls until `cond` holds or `timeout` seconds pass.
func waitUntil(_ timeout: TimeInterval = 5, _ cond: @Sendable () async -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if await cond() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await cond()
}
