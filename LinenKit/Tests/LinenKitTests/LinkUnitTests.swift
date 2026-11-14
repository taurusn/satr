import CryptoKit
import Foundation
import Testing
@testable import LinenKit

@Suite("Link: frames, paths, pairing, manifest, mirror")
struct LinkUnitTests {
    // MARK: Frames

    @Test("Frames round-trip through the reader, split anywhere")
    func frameRoundTrip() throws {
        let frames = [
            Frame.json(.hello, Hello(pinSet: 3, pins: [HeldPin(id: "p1", manifest: "m", sequence: 9, trust: 2)])),
            Chunk(sha: String(repeating: "ab", count: 32), offset: 1 << 33, bytes: Data([1, 2, 3])).frame,
            Frame.json(.pairResult, PairResult.refused(.busy)),
        ]
        let stream = frames.reduce(Data()) { $0 + $1.encoded }
        var reader = FrameReader()
        var got: [Frame] = []
        var i = stream.startIndex
        while i < stream.endIndex {
            let j = min(i + 3, stream.endIndex)
            got += try reader.push(Data(stream[i..<j]))
            i = j
        }
        #expect(got == frames)
        let hello = try got[0].decode(Hello.self)
        #expect(hello.pins.first?.sequence == 9 && hello.version == LinkBounds.protocolVersion)
        let chunk = try Chunk(frame: got[1])
        #expect(chunk.offset == 1 << 33 && chunk.bytes == Data([1, 2, 3]) && chunk.sha == String(repeating: "ab", count: 32))
        #expect(try got[2].decode(PairResult.self) == .refused(.busy))
    }

    @Test("A header with an unknown type or over the bound is refused before its payload")
    func frameBounds() {
        #expect(throws: FrameError.unknownType(99)) { try Frame.header([99, 0, 0, 0, 1]) }
        let big = LinkBounds.maxFrame + 1
        #expect(throws: FrameError.tooLarge(big)) {
            try Frame.header([FrameType.manifest.rawValue, UInt8(big >> 24), UInt8((big >> 16) & 0xff), UInt8((big >> 8) & 0xff), UInt8(big & 0xff)])
        }
        var r = FrameReader()
        #expect(throws: FrameError.self) { _ = try r.push(Data([FrameType.chunk.rawValue, 0x7f, 0, 0, 0])) }
        #expect(throws: FrameError.malformed(.chunk)) { try Chunk(frame: Frame(type: .chunk, payload: Data(count: 10))) }
    }

    @Test("Each frame belongs to one side and one kind of session")
    func frameDirections() {
        #expect(FrameType.hello.allowed(on: .pinned, from: .phone))
        #expect(!FrameType.hello.allowed(on: .pairing, from: .phone))
        #expect(!FrameType.want.allowed(on: .pairing, from: .phone))
        #expect(!FrameType.manifest.allowed(on: .pinned, from: .phone))
        #expect(FrameType.pairCode.allowed(on: .pairing, from: .phone))
        #expect(!FrameType.pairCode.allowed(on: .pinned, from: .phone))
        #expect(!FrameType.pairResult.allowed(on: .pairing, from: .phone))
        #expect(FrameType.pairResult.allowed(on: .pairing, from: .mac))
        let phone = FrameType.allCases.filter { $0.sender == .phone }
        #expect(Set(phone) == [.hello, .pinsOK, .want, .done, .pairCode])
    }

    // MARK: Paths

    @Test("Paths are relative, NFC and checked component by component")
    func paths() {
        #expect(LinkPath.isValid("notes/plan.md"))
        #expect(LinkPath.isValid("ملاحظات/خطة.md"))
        for bad in ["", "/etc/passwd", "a//b", "./a", "a/../b", "..", "a/.", "a\u{0}b", "Cafe\u{301}.md", String(repeating: "x", count: 256)] {
            #expect(!LinkPath.isValid(bad), "\(bad.debugDescription) should be refused")
        }
        #expect(LinkPath.collisions(["A.md", "a.md", "b.md"]) == ["A.md", "a.md"])
        #expect(!LinkPath.collisions(["Caf\u{E9}.md", "Cafe\u{301}.md"]).isEmpty)
        #expect(LinkPath.collisions(["Caf\u{E9}.md", "CAF\u{C9}.md"]).count == 2)
        #expect(LinkPath.isValidPinID("3f1c-aa09"))
        #expect(!LinkPath.isValidPinID("../x") && !LinkPath.isValidPinID("a/b") && !LinkPath.isValidPinID(""))
        #expect(LinkPath.isValidHash(String(repeating: "0f", count: 32)) && !LinkPath.isValidHash("XYZ"))
    }

    // MARK: Pairing

    @Test("The QR text carries hash, service, name and code, and nothing else parses")
    func invite() throws {
        let inv = PairingInvite(macCertHash: Data(repeating: 7, count: 32), service: "MacBook Air", macName: "MacBook Air", code: PairingInvite.newCode())
        let back = try #require(PairingInvite(text: inv.text))
        #expect(back == inv)
        #expect(PairingInvite(text: "https://example.com") == nil)
        #expect(PairingInvite(text: inv.text.replacingOccurrences(of: "v=1", with: "v=2")) == nil)
        #expect(PairingInvite(text: "linen://pair?v=1&h=AAAA&s=x&c=AAAA") == nil)
    }

    @Test("Six digits bind the session and both certificates")
    func digits() {
        let a = PairingDigits.digits(exported: Data(repeating: 1, count: 32), macCertHash: Data(repeating: 2, count: 32), phoneCertHash: Data(repeating: 3, count: 32))
        #expect(a.count == 6 && a.allSatisfy(\.isNumber))
        #expect(a == PairingDigits.digits(exported: Data(repeating: 1, count: 32), macCertHash: Data(repeating: 2, count: 32), phoneCertHash: Data(repeating: 3, count: 32)))
        #expect(a != PairingDigits.digits(exported: Data(repeating: 9, count: 32), macCertHash: Data(repeating: 2, count: 32), phoneCertHash: Data(repeating: 3, count: 32)))
        #expect(a != PairingDigits.digits(exported: Data(repeating: 1, count: 32), macCertHash: Data(repeating: 2, count: 32), phoneCertHash: Data(repeating: 4, count: 32)))
        #expect(PairingDigits.spaced("418207") == "418 207")
    }

    @Test("Pairing mode: three wrong codes end it, one pairing at a time, Allow pins and closes")
    func pairingMode() {
        let t0 = Date()
        let code = Data(repeating: 5, count: 16)
        var m = PairingMode()
        #expect(!m.acceptsUnknownCertificate(now: t0))
        #expect(m.sessionBegan(UUID(), now: t0) == .close)
        m.open(code: code, now: t0)
        #expect(m.acceptsUnknownCertificate(now: t0))
        for i in 1...3 {
            let s = UUID()
            #expect(m.sessionBegan(s, now: t0) == .pair)
            #expect(m.codeReceived(s, code: Data(repeating: 6, count: 16), phoneName: "x", phoneCertHash: Data(), digits: "000000", now: t0) == .result(.refused(.code)))
            #expect(m.isOpen == (i < 3))
        }
        #expect(m.ended == .wrongCodes && !m.acceptsUnknownCertificate(now: t0))

        m.open(code: code, now: t0)
        let a = UUID(), b = UUID()
        #expect(m.sessionBegan(a, now: t0) == .pair)
        #expect(m.sessionBegan(b, now: t0) == .busy)
        #expect(m.codeReceived(a, code: code, phoneName: "Eight", phoneCertHash: Data([1]), digits: "123456", now: t0) == .wait(digits: "123456"))
        // A second pair-code on the same session is a violation and ends pairing.
        var m2 = m
        #expect(m2.codeReceived(a, code: code, phoneName: "Eight", phoneCertHash: Data([1]), digits: "123456", now: t0) == .result(.refused(.refused)))
        #expect(m2.ended == .violation && !m2.isOpen)
        let answer = m.answer(allow: true)
        #expect(answer?.session == a && answer?.result.allowed == true && answer?.pin?.phoneName == "Eight")
        #expect(m.ended == .paired(phoneName: "Eight") && !m.isOpen)
        // The QR is useless after one pairing.
        #expect(m.sessionBegan(UUID(), now: t0) == .close)
    }

    @Test("Pairing mode: the QR expires, an unanswered match times out, a misstep ends it")
    func pairingTimes() {
        let t0 = Date()
        let code = Data(repeating: 5, count: 16)
        var m = PairingMode()
        m.open(code: code, now: t0)
        let s = UUID()
        #expect(m.sessionBegan(s, now: t0) == .pair)
        #expect(m.codeReceived(s, code: code, phoneName: "x", phoneCertHash: Data(), digits: "1", now: t0 + 121) == .result(.refused(.expired)))
        #expect(m.ended == .expired)

        m.open(code: code, now: t0)
        #expect(m.tick(now: t0 + 60) == nil)
        #expect(m.tick(now: t0 + 121)?.result == .refused(.expired))
        #expect(!m.acceptsUnknownCertificate(now: t0 + 1))

        m.open(code: code, now: t0)
        let w = UUID()
        _ = m.sessionBegan(w, now: t0)
        _ = m.codeReceived(w, code: code, phoneName: "x", phoneCertHash: Data(), digits: "1", now: t0 + 100)
        // Waiting for Allow outlives the QR's 2 minutes, up to 60 s.
        #expect(m.tick(now: t0 + 130) == nil)
        let late = m.tick(now: t0 + 161)
        #expect(late?.session == w && late?.result == .refused(.timeout) && m.ended == .timeout)

        m.open(code: code, now: t0)
        let v = UUID()
        _ = m.sessionBegan(v, now: t0)
        m.sessionEnded(v, violation: true)
        #expect(m.ended == .violation && !m.isOpen)
    }

    // MARK: Manifest

    private func scan(_ files: [(String, Int64, Double)]) -> PinScan {
        PinScan(files: files.map { PinScanFile(path: $0.0, diskPath: $0.0, stamp: FileStamp(size: $0.1, mtime: $0.2, inode: 1)) }, problems: [])
    }

    @Test("The manifest numbers changes, keeps tombstones, and sends only what is newer")
    func manifestDeltas() {
        var m = MacPinManifest(pin: "p")
        var hashes = ["a.md": String(repeating: "a", count: 64), "b.canvas": String(repeating: "b", count: 64)]
        let r1 = m.apply(scan([("a.md", 1, 1), ("b.canvas", 2, 1)]), hash: { hashes[$0] }, scripts: { _ in nil })
        #expect(r1)
        #expect(m.sequence == 2)
        let full = m.delta(heldManifest: "", heldSequence: 0)
        #expect(full.full && full.entries.count == 2)
        // Nothing changed: no new sequence.
        let r2 = m.apply(scan([("a.md", 1, 1), ("b.canvas", 2, 1)]), hash: { hashes[$0] }, scripts: { _ in nil })
        #expect(!r2)
        hashes["a.md"] = String(repeating: "c", count: 64)
        let r3 = m.apply(scan([("a.md", 3, 2)]), hash: { hashes[$0] }, scripts: { _ in nil })
        #expect(r3)
        let d = m.delta(heldManifest: m.id, heldSequence: 2)
        #expect(!d.full && d.entries.map(\.path) == ["a.md"] && d.removed.map(\.path) == ["b.canvas"])
        #expect(m.delta(heldManifest: m.id, heldSequence: m.sequence).entries.isEmpty)
        // A phone that acknowledged the removal lets its tombstone go; one that did not keeps it.
        m.prune(acked: [2])
        #expect(m.tombstones.count == 1)
        m.prune(acked: [m.sequence])
        #expect(m.tombstones.isEmpty)
    }

    @Test("A tombstone 30 days old starts a new manifest ID, so a phone away compares in full")
    func manifestRenews() {
        var m = MacPinManifest(pin: "p")
        let t0 = Date()
        m.apply(scan([("a.md", 1, 1)]), now: t0, hash: { _ in String(repeating: "a", count: 64) }, scripts: { _ in nil })
        m.apply(scan([]), now: t0, hash: { _ in nil }, scripts: { _ in nil })
        let old = m.id
        let r4 = m.prune(acked: [0], now: t0 + 86400)
        #expect(!r4)
        let r5 = m.prune(acked: [0], now: t0 + 31 * 86400)
        #expect(r5)
        #expect(m.id != old && m.delta(heldManifest: old, heldSequence: 99).full)
    }

    @Test("A trust change re-sends the page with its new policy, though its bytes did not change")
    func manifestTrust() {
        var m = MacPinManifest(pin: "p")
        let h = String(repeating: "d", count: 64)
        m.apply(scan([("r.html", 5, 1)]), hash: { _ in h }, scripts: { _ in .off })
        let s = m.sequence
        let t = PageTrust(revision: 2, folders: ["/x"])
        let r6 = m.apply(scan([("r.html", 5, 1)]), trust: 2, hash: { _ in h }, scripts: { _ in t.policy(canonicalPath: "/x/r.html") })
        #expect(r6)
        let d = m.delta(heldManifest: m.id, heldSequence: s)
        #expect(d.entries.first?.scripts == PageScriptPolicy(on: true, source: "root:/x") && m.trust == 2)
    }

    @Test("Manifest pages stay under the frame bound")
    func manifestPages() throws {
        var m = MacPinManifest(pin: "p")
        let files = (0..<6000).map { ("folder/a-rather-long-file-name-number-\($0).md", Int64($0), 1.0) }
        m.apply(scan(files), hash: { _ in String(repeating: "e", count: 64) }, scripts: { _ in nil })
        let pages = m.frames(heldManifest: "", heldSequence: 0, budget: 200_000)
        #expect(pages.count > 1 && pages.last?.last == true && pages.dropLast().allSatisfy { !$0.last })
        #expect(pages.reduce(0) { $0 + $1.entries.count } == 6000)
        for p in pages { #expect(Frame.json(.manifest, p).payload.count < 200_000 + 4096) }
        #expect(m.frames(heldManifest: m.id, heldSequence: m.sequence).count == 1)
    }

    @Test("The scan lists a pin from its root without hidden files, links or anything outside")
    func scanner() throws {
        let f = TempFolder()
        f.write("pin/a.md", "# A")
        f.write("pin/sub/b.canvas", "{}")
        f.write("pin/.obsidian/x.json", "{}")
        f.write("pin/node_modules/y.js", "")
        f.write("outside.md", "secret")
        try FileManager.default.createSymbolicLink(atPath: f.url.appendingPathComponent("pin/link.md").path, withDestinationPath: f.url.appendingPathComponent("outside.md").path)
        try FileManager.default.createSymbolicLink(atPath: f.url.appendingPathComponent("pin/dirlink").path, withDestinationPath: f.url.path)
        let root = f.url.appendingPathComponent("pin")
        let s = PinFiles.scan(root: root, kind: .folder)
        #expect(Set(s.files.map(\.path)) == ["a.md", "sub/b.canvas"])
        // Serving walks the same way: a link inside the pin is never followed.
        #expect(PinFiles.open(root: root, kind: .folder, diskPath: "link.md") == nil)
        #expect(PinFiles.open(root: root, kind: .folder, diskPath: "dirlink/outside.md") == nil)
        #expect(PinFiles.open(root: root, kind: .folder, diskPath: "../outside.md") == nil)
        let h = try #require(PinFiles.hash(root: root, kind: .folder, diskPath: "a.md"))
        #expect(h == Data(SHA256.hash(data: Data("# A".utf8))).hexString)
        let single = PinFiles.scan(root: f.url.appendingPathComponent("outside.md"), kind: .file)
        #expect(single.files.map(\.path) == ["outside.md"])
        #expect(PinFiles.open(root: f.url.appendingPathComponent("outside.md"), kind: .file, diskPath: "a.md") == nil)
        // A single file carries its notes sidecar and nothing else from its folder.
        f.write("pin/sub/b.canvas.notes.json", "{}")
        let board = f.url.appendingPathComponent("pin/sub/b.canvas")
        #expect(PinFiles.scan(root: board, kind: .file).files.map(\.path) == ["b.canvas", "b.canvas.notes.json"])
        #expect(PinFiles.open(root: board, kind: .file, diskPath: "b.canvas.notes.json") != nil)
        #expect(PinFiles.open(root: board, kind: .file, diskPath: "../a.md") == nil)
    }

    // MARK: Mirror

    private func entry(_ path: String, _ text: String, seq: UInt64, mtime: Double = 1) -> (ManifestEntry, Data) {
        let d = Data(text.utf8)
        return (ManifestEntry(path: path, size: Int64(d.count), mtime: mtime, sha: Data(SHA256.hash(data: d)).hexString, seq: seq), d)
    }

    private func feed(_ mirror: PhoneMirror, _ plan: PhoneMirror.Plan, _ bodies: [String: Data]) {
        for w in plan.wanted {
            let d = bodies[w.sha]!
            var o = Int(w.offset)
            repeat {
                let n = min(3, d.count - o)
                _ = mirror.receive(Chunk(sha: w.sha, offset: Int64(o), bytes: d.subdata(in: o..<o + n)))
                o += n
            } while o < d.count
        }
    }

    @Test("A generation switches whole, an open document keeps its own, and old ones go when closed")
    func mirrorGenerations() async throws {
        let f = TempFolder()
        let mirror = try PhoneMirror(root: f.url.appendingPathComponent("Mirror"))
        mirror.applyPinSet(PinSetFrame(generation: 1, pins: [PinInfo(id: "p1", kind: .folder, name: "plans", macPath: "~/plans", trust: 1)]))
        let (a, ad) = entry("a.md", "# Alpha\nbody", seq: 1)
        let (b, bd) = entry("board.canvas", #"{"linen":{"title":"The board"},"nodes":[]}"#, seq: 2)
        let m1 = ManifestFrame(pin: "p1", manifest: "M", trust: 1, sequence: 2, full: true, entries: [a, b], removed: [], last: true)
        let p1 = try mirror.plan(m1)
        #expect(p1.wanted.count == 2 && p1.bytes == Int64(ad.count + bd.count))
        feed(mirror, p1, [a.sha: ad, b.sha: bd])
        #expect(try mirror.commit(p1) == PinGeneration(2))
        #expect(mirror.filesOnDisk("p1") == ["a.md": a.sha, "board.canvas": b.sha])
        let files = await mirror.files(in: "p1")
        #expect(Set(files.map(\.title)) == ["Alpha", "The board"])
        // The first generation is the read baseline: no threads.
        #expect(files.allSatisfy { !$0.changedSinceRead })

        let doc = try await mirror.open(PinFileRef(pin: "p1", path: "a.md"))
        let (a2, a2d) = entry("a.md", "# Alpha two", seq: 3, mtime: 2)
        let p2 = try mirror.plan(ManifestFrame(pin: "p1", manifest: "M", trust: 1, sequence: 4, full: false, entries: [a2], removed: [Tombstone(path: "board.canvas", seq: 4)], last: true))
        #expect(p2.wanted.map(\.sha) == [a2.sha])
        feed(mirror, p2, [a2.sha: a2d])
        try mirror.commit(p2)
        #expect(mirror.filesOnDisk("p1") == ["a.md": a2.sha])
        // The open document still reads its generation.
        #expect(try String(contentsOf: doc.url, encoding: .utf8) == "# Alpha\nbody" && doc.generation == PinGeneration(2))
        #expect(FileManager.default.fileExists(atPath: doc.url.path))
        let changed = await mirror.files(in: "p1")
        #expect(changed.count == 1 && changed[0].changedSinceRead)
        doc.close()
        #expect(!FileManager.default.fileExists(atPath: doc.url.path))
        await mirror.markRead(PinFileRef(pin: "p1", path: "a.md"))
        #expect(await mirror.files(in: "p1").allSatisfy { !$0.changedSinceRead })

        // A reload from disk sees the same pin.
        let again = try PhoneMirror(root: f.url.appendingPathComponent("Mirror"))
        #expect(again.filesOnDisk("p1") == ["a.md": a2.sha] && again.held().pins.first?.sequence == 4)
        // The pin leaves the pin set: its files go.
        again.applyPinSet(PinSetFrame(generation: 2, pins: []))
        #expect(await again.pins().isEmpty && !FileManager.default.fileExists(atPath: f.url.appendingPathComponent("Mirror/pins/p1").path))
    }

    @Test("A transfer resumes from its partial file, and bytes that do not match the hash are thrown away")
    func mirrorPartials() throws {
        let f = TempFolder()
        let mirror = try PhoneMirror(root: f.url.appendingPathComponent("Mirror"))
        mirror.applyPinSet(PinSetFrame(generation: 1, pins: [PinInfo(id: "p", kind: .folder, name: "n", macPath: "~/n", trust: 1)]))
        let (e, d) = entry("x.md", "0123456789", seq: 1)
        let m = ManifestFrame(pin: "p", manifest: "M", trust: 1, sequence: 1, full: true, entries: [e], removed: [], last: true)
        _ = try mirror.plan(m)
        #expect(mirror.receive(Chunk(sha: e.sha, offset: 0, bytes: d.prefix(4))) == .progress)
        #expect(mirror.partialCount() == 1)
        // A new session asks from the partial file's length.
        let again = try PhoneMirror(root: f.url.appendingPathComponent("Mirror"))
        let p = try again.plan(m)
        #expect(p.wanted == [WantedFile(sha: e.sha, offset: 4)])
        #expect(again.receive(Chunk(sha: e.sha, offset: 4, bytes: Data("456789".utf8))) == .complete(e.sha))
        try again.commit(p)
        #expect(again.filesOnDisk("p") == ["x.md": e.sha] && again.partialCount() == 0)

        let (bad, _) = entry("y.md", "good bytes", seq: 2)
        let p2 = try again.plan(ManifestFrame(pin: "p", manifest: "M", trust: 1, sequence: 2, full: false, entries: [bad], removed: [], last: true))
        #expect(again.receive(Chunk(sha: bad.sha, offset: 0, bytes: Data("evil bytes".utf8))) == .mismatch(bad.sha))
        #expect(again.partialCount() == 0)
        #expect(throws: PhoneMirror.MirrorError.missingObject(bad.sha)) { try again.commit(p2) }
        #expect(again.receive(Chunk(sha: String(repeating: "f", count: 64), offset: 0, bytes: Data([1]))) == .unexpected)
    }

    @Test("The mirror refuses bad paths and collisions from the Mac, and resolves references")
    func mirrorChecksAndResolves() async throws {
        let f = TempFolder()
        let mirror = try PhoneMirror(root: f.url.appendingPathComponent("Mirror"))
        mirror.applyPinSet(PinSetFrame(generation: 1, pins: [PinInfo(id: "p", kind: .folder, name: "n", macPath: "~/n", trust: 1),
                                                             PinInfo(id: "q", kind: .file, name: "q", macPath: "~/q.md", trust: 1)]))
        let (n, nd) = entry("notes/Plan.md", "# Plan", seq: 1)
        var linked = entry("notes/index.md", "[[Plan]] [[Elsewhere]]", seq: 2).0
        linked.links = ["Elsewhere": .notOnPhone, "Q": LinkTargetRef(pin: "q", path: "q.md")]
        let (img, imgd) = entry("notes/images/a.png", "png", seq: 3)
        let evil = ManifestEntry(path: "../escape.md", size: 1, mtime: 1, sha: n.sha, seq: 4)
        let caseA = ManifestEntry(path: "A.md", size: nd.count.int64, mtime: 1, sha: n.sha, seq: 5)
        let caseB = ManifestEntry(path: "a.md", size: nd.count.int64, mtime: 1, sha: n.sha, seq: 6)
        let p = try mirror.plan(ManifestFrame(pin: "p", manifest: "M", trust: 1, sequence: 6, full: true, entries: [n, linked, img, evil, caseA, caseB], removed: [], last: true))
        #expect(Set(p.entries.keys) == ["notes/Plan.md", "notes/index.md", "notes/images/a.png"])
        #expect(p.problems.count == 3)
        let ld = Data("[[Plan]] [[Elsewhere]]".utf8)
        feed(mirror, p, [n.sha: nd, linked.sha: ld, img.sha: imgd])
        try mirror.commit(p)
        let (q, qd) = entry("q.md", "# Q", seq: 1)
        let pq = try mirror.plan(ManifestFrame(pin: "q", manifest: "N", trust: 1, sequence: 1, full: true, entries: [q], removed: [], last: true))
        feed(mirror, pq, [q.sha: qd])
        try mirror.commit(pq)
        let from = PinFileRef(pin: "p", path: "notes/index.md")
        #expect(await mirror.resolve("Plan", from: from) == .file(PinFileRef(pin: "p", path: "notes/Plan.md")))
        #expect(await mirror.resolve("Plan#Heading|label", from: from) == .file(PinFileRef(pin: "p", path: "notes/Plan.md")))
        #expect(await mirror.resolve("images/a.png", from: from) == .file(PinFileRef(pin: "p", path: "notes/images/a.png")))
        #expect(await mirror.resolve("Elsewhere", from: from) == .notOnPhone)
        #expect(await mirror.resolve("Q", from: from) == .file(PinFileRef(pin: "q", path: "q.md")))
        #expect(await mirror.resolve("../../outside.md", from: from) == .notOnPhone)
        #expect(await mirror.resolve("Nothing", from: from) == .missing)
        let doc = try await mirror.open(from)
        #expect(doc.sibling("images/a.png") != nil && doc.sibling("../../../etc/passwd") == nil)
        #expect(mirror.protectionProblems().isEmpty)
    }
}

private extension Int {
    var int64: Int64 { Int64(self) }
}

