import AppKit
import Network
import WebKit

/// The seal self-test (PAGE-10), failing closed. On the first launch after a macOS or Linen update, and from Settings
/// on demand, Linen (1) checks the running WebKit build against the reviewed inventory it carries for that build,
/// (2) enumerates every script realm a page can reach in the sealed configuration and compares it with the
/// inventory, and (3) runs probe pages against an in-app loopback witness: first a control run with the seal off,
/// which the witness must see, then the sealed run, which it must not. Any unknown build, difference, escape, error
/// or timeout turns page scripts off everywhere, with one line saying why. Pages still open, with scripts off.
@MainActor
final class PageSelfTest {
    static let shared = PageSelfTest()

    enum State: Equatable {
        case idle
        case running
        case passed
        case failed(String)
    }

    private(set) var state: State = .idle

    /// Negative cases for the self-test's own tests (never set by the app): a page-world script standing in for a
    /// changed WebKit build, the sealed run's options, a dead witness, and a probe page that never reports.
    struct TestHooks {
        var injection: String?
        var sealedOptions: SealOptions?
        var deadWitness = false
        var hang = false
    }
    var hooks = TestHooks()
    var onChange: ((State) -> Void)?
    static let storeKey = "pageSelfTest"
    static let realms = ["page", "frame", "worker", "blobworker", "shared", "audio", "paint"]

    /// What a passed test is good for: this WebKit build, this system build, this Linen build.
    var key: String { [PageSeal.webKitBuild, Self.osBuild, Self.appVersion].joined(separator: " | ") }

    static var osBuild: String {
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("kern.osversion", &buf, &size, nil, 0)
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static var appVersion: String {
        let i = Bundle.main.infoDictionary
        return "\(i?["CFBundleShortVersionString"] as? String ?? "?") (\(i?["CFBundleVersion"] as? String ?? "?"))"
    }

    private var stored: [String: Any]? { UserDefaults.standard.dictionary(forKey: Self.storeKey) }

    /// Why page scripts are off everywhere right now, or nil when the seal check passed for this exact build.
    var blockReason: String? {
        switch state {
        case .passed: return nil
        case .running: return String(localized: "Linen is checking that pages stay sealed after an update")
        case let .failed(why): return why
        case .idle:
            guard let s = stored, s["key"] as? String == key else { return String(localized: "Page scripts wait for Linen's seal check") }
            if s["passed"] as? Bool == true { return nil }
            return s["reason"] as? String ?? String(localized: "Page scripts wait for Linen's seal check")
        }
    }

    var lastRun: Date? { stored?["date"] as? Date }

    /// At launch: runs the check when this build has not passed it yet.
    func runIfNeeded() {
        if let s = stored, s["key"] as? String == key, s["passed"] as? Bool == true, Self.inventoryURL() != nil { state = .passed; return }
        Task { await run() }
    }

    // MARK: The run

    private var host: NSWindow?

    /// Where the reviewed inventory for the running WebKit build is: the app bundle, or a folder a developer tool
    /// points at (`inventoryOverride`). Nil means this build was never reviewed.
    nonisolated(unsafe) static var inventoryOverride: URL?
    /// Set by the tool that writes a new build's inventory, so the walk runs with the same engine flags it will
    /// be checked against.
    nonisolated(unsafe) static var generatingInventory = false

    nonisolated static func inventoryURL() -> URL? {
        let name = "webkit-\(PageSeal.webKitBuild)"
        if let dir = inventoryOverride {
            let u = dir.appendingPathComponent("\(name).txt")
            return FileManager.default.fileExists(atPath: u.path) ? u : nil
        }
        return Bundle.main.url(forResource: name, withExtension: "txt")
    }

    @discardableResult
    func run(inventory: URL? = nil) async -> State {
        if state == .running { return state }
        // Before the first wait: a quit during the run must not leave an earlier pass standing (item 13).
        UserDefaults.standard.set(["key": key, "passed": false, "reason": String(localized: "Page scripts wait for Linen's seal check"), "date": Date()], forKey: Self.storeKey)
        set(.running)
        let result = await check(inventory: inventory ?? Self.inventoryURL())
        let final: State = result.map { .failed($0) } ?? .passed
        UserDefaults.standard.set(["key": key, "passed": result == nil, "reason": result ?? "", "date": Date()], forKey: Self.storeKey)
        set(final)
        Log.write("page seal check: \(result ?? "passed") [\(key)]")
        return final
    }

    private func set(_ s: State) {
        state = s
        onChange?(s)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    static let changed = Notification.Name("LinenPageSelfTestChanged")

    /// nil when everything held; else the one line to show.
    private func check(inventory: URL?) async -> String? {
        guard let inventory, let text = try? String(contentsOf: inventory, encoding: .utf8) else {
            return String(localized: "Page scripts are off: this version of WebKit (\(PageSeal.webKitBuild)) has not been reviewed for Linen yet")
        }
        let reviewed = Self.parse(text)
        guard let found = await enumerate() else { return String(localized: "Page scripts are off: the seal check did not finish") }
        if let bad = Self.realms.first(where: { found[$0]?.contains(where: { $0.hasPrefix("!") }) ?? true }) {
            return String(localized: "Page scripts are off: the seal check could not reach every part of a page (\(bad))")
        }
        if found["paint"] != ["absent"] {
            // Paint worklets cannot report back, so Linen cannot inventory them; their arrival blocks scripts.
            return String(localized: "Page scripts are off: WebKit added paint worklets, which Linen cannot check yet")
        }
        for realm in Self.realms {
            let a = Set(reviewed[realm] ?? []), b = Set(found[realm] ?? [])
            if a != b {
                let added = b.subtracting(a).sorted(), gone = a.subtracting(b).sorted()
                Log.write("page seal check: realm \(realm) +\(added.count) -\(gone.count) first +\(added.first ?? "-") -\(gone.first ?? "-")")
                return String(localized: "Page scripts are off: WebKit changed what pages can reach (\(added.count) new, \(gone.count) gone in \(realm))")
            }
        }
        // Each run has its own witness on its own ports, so late traffic from the control run (a worker still
        // inside importScripts, a connection the network process retries) can never be counted against the seal.
        let controlWitness = LoopbackWitness()
        guard (try? await controlWitness.start()) != nil else { return String(localized: "Page scripts are off: the seal check could not start its witness") }
        defer { controlWitness.stop() }
        guard let control = await probe(.open, witness: controlWitness, aim: hooks.deadWitness ? 1 : 0) else {
            return String(localized: "Page scripts are off: the seal check did not finish")
        }
        try? await Task.sleep(for: .seconds(1.5))
        let seen = controlWitness.counts
        guard seen.tcp > 0, seen.udp > 0, control.missing.isEmpty else {
            Log.write("page seal check: control saw \(seen.tcp) TCP \(seen.udp) UDP; realms missing \(control.missing)")
            return String(localized: "Page scripts are off: the seal check could not see its own test traffic")
        }
        let witness = LoopbackWitness()
        guard (try? await witness.start()) != nil else { return String(localized: "Page scripts are off: the seal check could not start its witness") }
        defer { witness.stop() }
        guard let sealed = await probe(hooks.sealedOptions ?? .full, witness: witness) else {
            return String(localized: "Page scripts are off: the seal check did not finish")
        }
        try? await Task.sleep(for: .seconds(3))
        let escaped = witness.counts
        if escaped.tcp + escaped.udp > 0 {
            Log.write("page seal check: \(escaped.tcp) TCP and \(escaped.udp) UDP escapes")
            return String(localized: "Page scripts are off: a test page got through the seal")
        }
        if !sealed.missing.isEmpty || !sealed.controlsFailed.isEmpty {
            Log.write("page seal check: sealed run missing \(sealed.missing), own-origin controls failed in \(sealed.controlsFailed)")
            return String(localized: "Page scripts are off: the seal check could not reach every part of a page")
        }
        if !sealed.granted.isEmpty {
            Log.write("page seal check: capabilities granted \(sealed.granted)")
            return String(localized: "Page scripts are off: a test page was given something pages must not have (\(sealed.granted.joined(separator: ", ")))")
        }
        return nil
    }

    static func parse(_ text: String) -> [String: [String]] {
        var out: [String: [String]] = [:]
        var realm = ""
        for line in text.split(separator: "\n") {
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") { realm = String(line.dropFirst().dropLast()); out[realm] = []; continue }
            out[realm, default: []].append(String(line))
        }
        return out
    }

    /// The inventory text for this Mac's WebKit build (`build/pagehost inventory`), refused when any realm could
    /// not be walked, so an error is never written into a reviewed baseline (item 12).
    func inventoryText() async -> String? {
        Self.generatingInventory = true
        defer { Self.generatingInventory = false }
        guard let found = await enumerate(),
              !Self.realms.contains(where: { found[$0]?.contains(where: { $0.hasPrefix("!") }) ?? true }) else { return nil }
        var lines = ["# Linen page seal inventory (PRD-2 PAGE-10). Generated by the self-test's own walk in the sealed configuration.",
                     "# webkit \(PageSeal.webKitBuild); system \(Self.osBuild); Linen \(Self.appVersion)"]
        for realm in Self.realms {
            lines.append("[\(realm)]")
            lines.append(contentsOf: found[realm] ?? [])
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Pages run in the sealed configuration

    private func window() -> NSWindow {
        if let host { return host }
        let w = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        host = w
        return w
    }

    /// Opens an in-memory page in a sealed controller and waits, with a hard deadline, for its `<pre>` to hold JSON.
    private func runPage(_ files: [String: Data], options: SealOptions, seconds: Double) async -> String? {
        let c = SealedPageController(virtual: files, page: "index.html", scripts: true, options: options)
        c.testScript = hooks.injection
        if hooks.hang { c.testScript = (c.testScript ?? "") + "\nif (window === top) document.addEventListener('DOMContentLoaded', () => { document.querySelector('pre')?.remove(); });" }
        var events: [String] = []
        c.onEvent = { events.append($0) }
        let w = window()
        w.contentViewController = c
        w.orderFrontRegardless()
        defer { c.close(); w.contentViewController = nil; w.orderOut(nil) }
        let end = Date().addingTimeInterval(seconds)
        var last: Any?
        while Date() < end {
            try? await Task.sleep(for: .milliseconds(250))
            let left = max(0.2, end.timeIntervalSinceNow)
            last = await c.evaluateInKit("if (location.pathname.endsWith('\(PageSeal.preflightPath)')) return 'preflight'; const p = document.querySelector('pre'); return p ? p.textContent : ('no pre, ' + document.readyState)", timeout: min(2, left))
            if let s = last as? String, s.hasPrefix("{") { return s }
        }
        Log.write("page seal check: a probe page did not report; last \(String(describing: last).prefix(200)); events \(events.suffix(12).joined(separator: " | "))")
        return nil
    }

    private func enumerate() async -> [String: [String]]? {
        let inv = PageScripts.inventoryFunction
        let frame = "<!doctype html><meta charset=\"utf-8\"><script>(() => { \(inv)\n parent.postMessage({inv: 'frame', lines: linenInventory()}, '*'); })();</script>"
        let worker = "(() => { \(inv)\n postMessage(linenInventory()); })();"
        let shared = "(() => { \(inv)\n const R = linenInventory(); onconnect = (e) => e.ports[0].postMessage(R); })();"
        let audio = "(() => { \(inv)\n const R = linenInventory(); registerProcessor('linen-inv', class extends AudioWorkletProcessor { constructor() { super(); this.port.postMessage(R); } process() { return false; } }); })();"
        let index = """
        <!doctype html><meta charset="utf-8"><title>Linen seal check</title><pre></pre><script>
        (async () => {
          \(inv)
          const out = {page: linenInventory()};
          const got = new Promise((done) => {
            let want = 5;
            const take = (realm, lines) => { if (!out[realm]) { out[realm] = lines; if (--want === 0) done(); } };
            addEventListener('message', (e) => { if (e.data && e.data.inv) take(e.data.inv, e.data.lines); });
            const f = document.createElement('iframe'); f.src = 'frame.html'; document.body.append(f);
            try { const w = new Worker('worker.js'); w.onmessage = (e) => take('worker', e.data); w.onerror = () => take('worker', ['!error']); } catch (e) { take('worker', ['!' + e.name]); }
            try { const b = new Worker(URL.createObjectURL(new Blob([\(PageScripts.jsString(worker))], {type: 'text/javascript'}))); b.onmessage = (e) => take('blobworker', e.data); b.onerror = () => take('blobworker', ['!error']); } catch (e) { take('blobworker', ['!' + e.name]); }
            try { const s = new SharedWorker('shared.js'); s.port.onmessage = (e) => take('shared', e.data); s.onerror = () => take('shared', ['!error']); s.port.start(); } catch (e) { take('shared', ['!' + e.name]); }
            (async () => { try { const ac = new AudioContext(); await ac.audioWorklet.addModule('audio.js'); const n = new AudioWorkletNode(ac, 'linen-inv'); n.port.onmessage = (e) => take('audio', e.data); } catch (e) { take('audio', ['!' + (e && e.name)]); } })();
          });
          out.paint = (typeof CSS !== 'undefined' && CSS.paintWorklet) ? ['present'] : ['absent'];
          await Promise.race([got, new Promise((r) => setTimeout(r, 8000))]);
          for (const r of ['frame', 'worker', 'blobworker', 'shared', 'audio']) if (!out[r]) out[r] = ['!no report'];
          document.querySelector('pre').textContent = JSON.stringify(out);
        })();
        </script>
        """
        let files: [String: Data] = ["index.html": Data(index.utf8), "frame.html": Data(frame.utf8), "worker.js": Data(worker.utf8),
                                     "shared.js": Data(shared.utf8), "audio.js": Data(audio.utf8)]
        guard let json = await runPage(files, options: .full, seconds: 20),
              let d = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: [String]] else { return nil }
        return d
    }

    struct ProbeReport {
        /// Realms that never reported.
        var missing: [String]
        /// Realms whose own-origin fetch failed (the page model broke there).
        var controlsFailed: [String]
        /// Capabilities a script-made probe was given (PAGE-11).
        var granted: [String]
    }

    /// The probe pages of P(a), P(b) and P(c) as the app runs them: every realm spike P(c) measured (the page, a
    /// frame, a srcdoc frame, an SVG document frame, a dedicated worker from a file and from a blob, a shared worker,
    /// an audio worklet) tries every way out at the loopback witness (IPv4 and IPv6), beside an own-origin control
    /// where the realm can have one; the page also runs PAGE-11's script-made capability probes. Nil when the page
    /// did not report in time; any realm that does not report is listed, never counted as done (item 10).
    private func probe(_ options: SealOptions, witness: LoopbackWitness, aim: UInt16 = 0) async -> ProbeReport? {
        let t = witness.tcpPort &+ aim, u = witness.udpPort &+ aim, t6 = witness.tcp6Port &+ aim, u6 = witness.udp6Port &+ aim
        let probe = """
        async function linenProbe(done) {
          const hs = ['http://127.0.0.1:\(t)/', 'http://[::1]:\(t6)/'], jobs = [];
          const q = (p) => jobs.push(Promise.resolve().then(p).catch(() => {}));
          const href = (typeof location !== 'undefined') ? String(location.href) : '';
          const own = (href.startsWith('blob:') ? href.slice(5).split('/').slice(0, 3).join('/') + '/' : '') + 'data.json';
          let control = 'none';
          if (typeof fetch === 'function') jobs.push(fetch(own).then((r) => r.json()).then((j) => { control = j.ok ? 'ok' : 'bad'; }, () => { control = 'failed'; }));
          for (const h of hs) {
            if (typeof fetch === 'function') { q(() => fetch(h + 'f')); q(() => fetch(h + 'n', {mode: 'no-cors'})); }
            if (typeof XMLHttpRequest === 'function') q(() => { const x = new XMLHttpRequest(); x.open('GET', h + 'x'); x.send(); });
            if (typeof WebSocket === 'function') q(() => new WebSocket(h.replace('http', 'ws') + 'w'));
            if (typeof EventSource === 'function') q(() => new EventSource(h + 'e'));
            if (typeof navigator !== 'undefined' && navigator.sendBeacon) q(() => navigator.sendBeacon(h + 'b', 'x'));
            if (typeof Image === 'function') q(() => { new Image().src = h + 'i'; });
          }
          if (typeof WebTransport === 'function') { q(() => new WebTransport('https://127.0.0.1:\(u)/').ready); q(() => new WebTransport('https://[::1]:\(u6)/').ready); }
          const R = globalThis.RTCPeerConnection;
          if (typeof R === 'function') q(() => { const pc = new R({iceServers: [{urls: 'stun:127.0.0.1:\(u)'}, {urls: 'stun:[::1]:\(u6)'}, {urls: 'turn:127.0.0.1:\(t)?transport=tcp', username: 'u', credential: 'p'}]}); pc.createDataChannel('x'); globalThis.__p = pc; return pc.createOffer().then((o) => pc.setLocalDescription(o)); });
          await Promise.race([Promise.all(jobs), new Promise((r) => setTimeout(r, 2500))]);
          done(control);
          // importScripts blocks the worker until it fails, so it goes after the report.
          if (typeof importScripts === 'function') for (const h of hs) { try { importScripts(h + 's'); } catch (e) {} }
        }
        """
        let worker = "\(probe)\nlinenProbe((c) => postMessage({realm: 'R', control: c}));"
        let frame = { (name: String) in "<!doctype html><meta charset=\"utf-8\"><script>\(probe)\nlinenProbe((c) => parent.postMessage({realm: '\(name)', control: c}, '*'));</script>" }
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"4\" height=\"4\"><script><![CDATA[\(probe)\nlinenProbe((c) => parent.postMessage({realm: 'svg', control: c}, '*'));]]></script></svg>"
        let shared = "\(probe)\nconst ports = []; onconnect = (e) => { ports.push(e.ports[0]); linenProbe((c) => e.ports[0].postMessage({realm: 'shared', control: c})); };"
        let audio = "const t = (n) => typeof globalThis[n]; const R = ['fetch','XMLHttpRequest','WebSocket','EventSource','WebTransport','RTCPeerConnection','importScripts'].filter((n) => t(n) !== 'undefined'); registerProcessor('linen-probe', class extends AudioWorkletProcessor { constructor() { super(); this.port.postMessage({realm: 'audio', control: R.length ? 'has ' + R.join(' ') : 'ok'}); } process() { return false; } });"
        let index = """
        <!doctype html><meta charset="utf-8"><title>Linen seal check</title><pre></pre><script>
        \(probe)
        (async () => {
          const got = {}, want = ['page', 'frame', 'srcdoc', 'svg', 'worker', 'blobworker', 'shared', 'audio'];
          const all = new Promise((ok) => {
            const take = (r, c) => { if (!(r in got)) { got[r] = c; if (want.every((w) => w in got)) ok(); } };
            addEventListener('message', (e) => { if (e.data && e.data.realm) take(e.data.realm, e.data.control); });
            linenProbe((c) => take('page', c));
            const f = document.createElement('iframe'); f.src = 'frame.html'; document.body.append(f);
            const s = document.createElement('iframe'); s.src = 'doc.svg'; document.body.append(s);
            const d = document.createElement('iframe'); d.srcdoc = \(PageScripts.jsString(frame("srcdoc"))); document.body.append(d);
            const w = (name, url) => { try { const k = new Worker(url); k.onmessage = (e) => take(name, e.data.control); k.onerror = () => take(name, 'error'); } catch (e) { take(name, 'threw'); } };
            w('worker', 'worker.js');
            w('blobworker', URL.createObjectURL(new Blob([\(PageScripts.jsString(worker.replacingOccurrences(of: "'R'", with: "'blobworker'")))], {type: 'text/javascript'})));
            try { const sw = new SharedWorker('shared.js'); sw.port.onmessage = (e) => take('shared', e.data.control); sw.onerror = () => take('shared', 'error'); sw.port.start(); } catch (e) { take('shared', 'threw'); }
            (async () => { try { const ac = new AudioContext(); await ac.audioWorklet.addModule('audio.js'); const n = new AudioWorkletNode(ac, 'linen-probe'); n.port.onmessage = (e) => take('audio', e.data.control); } catch (e) { take('audio', 'threw'); } })();
          });
          // PAGE-11, script-made: each must come back refused.
          const cap = {};
          // Each probe gets 1.5 s; one that never settles counts as refused (nothing was granted), never as a hang.
          const tryCap = async (name, f) => { try { cap[name] = await Promise.race([Promise.resolve().then(f), new Promise((r) => setTimeout(() => r('pending'), 1500))]); } catch (e) { cap[name] = false; } };
          await tryCap('alert', () => { const t0 = performance.now(); alert('x'); return performance.now() - t0 > 500; });
          await tryCap('confirm', () => confirm('x') === true);
          await tryCap('prompt', () => prompt('x') !== null);
          await tryCap('getUserMedia', async () => !!(await navigator.mediaDevices.getUserMedia({video: true})));
          await tryCap('getDisplayMedia', async () => !!(await navigator.mediaDevices.getDisplayMedia({video: true})));
          await tryCap('geolocation', () => new Promise((ok) => { navigator.geolocation.getCurrentPosition(() => ok(true), () => ok(false), {timeout: 1500}); }));
          await tryCap('notification', async () => (await Notification.requestPermission()) === 'granted');
          await tryCap('clipboardRead', async () => typeof (await navigator.clipboard.readText()) === 'string');
          await tryCap('execPaste', () => document.execCommand('paste') === true);
          await tryCap('share', async () => { await navigator.share({text: 'x'}); return true; });
          await tryCap('credentials', async () => !!(await navigator.credentials.get({password: true})));
          await tryCap('windowOpen', () => window.open('https://example.com/') !== null);
          await tryCap('fullscreen', async () => { await document.documentElement.requestFullscreen(); return true; });
          await tryCap('showOpenFilePicker', async () => !!(await window.showOpenFilePicker()));
          await tryCap('serviceWorker', async () => !!(await navigator.serviceWorker.register('worker.js')));
          await Promise.race([all, new Promise((r) => setTimeout(r, 7000))]);
          const missing = want.filter((w) => !(w in got));
          // Every realm must have started and reported; the shared worker's own-origin fetch fails on a custom scheme
          // in every seal (spike P(c)), so for it only 'failed' is accepted, never 'threw' or 'error'.
          const controlsFailed = want.filter((w) => w in got && !(['ok', 'none'].includes(got[w]) || (w === 'shared' && got[w] === 'failed')));
          const granted = Object.keys(cap).filter((k) => cap[k] === true);
          document.querySelector('pre').textContent = JSON.stringify({done: true, got, missing, controlsFailed, granted});
        })();
        </script>
        """
        let files: [String: Data] = [
            "index.html": Data(index.utf8), "frame.html": Data(frame("frame").utf8), "doc.svg": Data(svg.utf8),
            "worker.js": Data(worker.replacingOccurrences(of: "'R'", with: "'worker'").utf8), "shared.js": Data(shared.utf8),
            "audio.js": Data(audio.utf8), "data.json": Data("{\"ok\": true}".utf8),
        ]
        guard let json = await runPage(files, options: options, seconds: 25),
              let d = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], d["done"] as? Bool == true else { return nil }
        Log.write("page seal check: probe run (\(options == .full ? "sealed" : "control")) realms \(d["got"] ?? "?")")
        return ProbeReport(missing: d["missing"] as? [String] ?? ["?"], controlsFailed: d["controlsFailed"] as? [String] ?? ["?"],
                           granted: d["granted"] as? [String] ?? [])
    }
}

/// A loopback-only witness for the self-test (loopback needs no local network permission): TCP and UDP listeners
/// on 127.0.0.1 and ::1 that count what arrives.
final class LoopbackWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var listeners: [NWListener] = []
    private var tcpHits = 0
    private var udpHits = 0
    private(set) var tcpPort: UInt16 = 0
    private(set) var udpPort: UInt16 = 0
    private(set) var tcp6Port: UInt16 = 0
    private(set) var udp6Port: UInt16 = 0
    private let queue = DispatchQueue(label: "linen.seal.witness")

    var counts: (tcp: Int, udp: Int) { lock.withLock { (tcpHits, udpHits) } }
    func reset() { lock.withLock { tcpHits = 0; udpHits = 0 } }

    func start() async throws {
        let tcpHit: @Sendable () -> Void = { [weak self] in self?.lock.withLock { self?.tcpHits += 1 } }
        let udpHit: @Sendable () -> Void = { [weak self] in self?.lock.withLock { self?.udpHits += 1 } }
        tcpPort = try await listen(tcp: true, host: "127.0.0.1", hit: tcpHit)
        udpPort = try await listen(tcp: false, host: "127.0.0.1", hit: udpHit)
        tcp6Port = try await listen(tcp: true, host: "::1", hit: tcpHit)
        udp6Port = try await listen(tcp: false, host: "::1", hit: udpHit)
    }

    private func listen(tcp isTCP: Bool, host: NWEndpoint.Host, hit: @escaping @Sendable () -> Void) async throws -> UInt16 {
        let params: NWParameters = isTCP ? .tcp : .udp
        params.requiredLocalEndpoint = .hostPort(host: host, port: .any)
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params)
        let q = queue
        l.newConnectionHandler = { c in
            hit()
            c.stateUpdateHandler = { s in if case .ready = s { c.receiveMessage { _, _, _, _ in hit(); c.cancel() } } }
            c.start(queue: q)
            q.asyncAfter(deadline: .now() + 3) { c.cancel() }
        }
        listeners.append(l)
        return try await withCheckedThrowingContinuation { (k: CheckedContinuation<UInt16, Error>) in
            let once = OnceFlag()
            l.stateUpdateHandler = { [weak l] s in
                switch s {
                case .ready: if once.take() { k.resume(returning: l?.port?.rawValue ?? 0) }
                case let .failed(e): if once.take() { k.resume(throwing: e) }
                case .cancelled: if once.take() { k.resume(throwing: CancellationError()) }
                default: break
                }
            }
            l.start(queue: q)
            q.asyncAfter(deadline: .now() + 5) { [weak l] in if once.take() { l?.cancel(); k.resume(throwing: CancellationError()) } }
        }
    }

    func stop() {
        for l in listeners {
            l.stateUpdateHandler = nil
            l.newConnectionHandler = nil
            l.cancel()
        }
        listeners.removeAll()
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}
