// Spike P(c): the page model of PRD-2 section 9.2, run against Linen/Pages' own code (PageScheme, KitScheme, the
// seal and SealedPageController), not a copy of it. One probe page tries every way out from every script realm
// (the page, a frame, a srcdoc frame, an SVG document frame, a dedicated worker from a file and from a blob, a shared
// worker, an audio worklet and a paint worklet), each beside a positive control that reaches its own origin; it
// checks sibling files and the kit, the handler's refusals, the capability probes of PAGE-11 and script-made
// clicks; the driver then sends real mouse clicks and hovers into the web view. A second pair of pages checks that
// two open pages cannot reach each other's storage or files. The witness (pc-witness.py) is the judge.
//
//   swiftc -swift-version 6 -parse-as-library -o build/pc/pc docs/spikes/pages/pc.swift Linen/Pages/*.swift \
//     Linen/Document/Schemes.swift Linen/Document/SafeOpen.swift Linen/System/Log.swift Linen/App/TrustedFolders.swift Linen/Design/Tokens.swift \
//     -framework AppKit -framework WebKit
//   python3 -I docs/spikes/pages/pc-witness.py 48731 <lan-ip> 48900 build/pc/witness.log &
//   ./build/pc/pc 48731 <lan-ip> 48900 build/pc/witness.log build/pc/sites
import AppKit
import WebKit

struct Variant {
    let name: String
    let index: Int
    let options: SealOptions
}

let variants = [
    Variant(name: "open", index: 0, options: .open),
    Variant(name: "full", index: 1, options: .full),
    Variant(name: "csponly", index: 2, options: SealOptions(rules: false, csp: true, removal: false, gate: true, engineFlags: false)),
    Variant(name: "rulesonly", index: 3, options: SealOptions(rules: true, csp: false, removal: false, gate: true, engineFlags: false)),
    Variant(name: "sandbox", index: 4, options: SealOptions(rules: true, csp: true, removal: true, gate: true, sandbox: true)),
    Variant(name: "flagscsp", index: 5, options: SealOptions(rules: false, csp: true, removal: false, gate: true, engineFlags: true)),
    Variant(name: "flagsrules", index: 6, options: SealOptions(rules: true, csp: false, removal: false, gate: true, engineFlags: true)),
]

let realms = ["page", "frame", "srcdoc", "worker", "blobworker", "shared", "audio", "paint", "svg"]

@main
struct PC {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            await Spike().run()
            exit(0)
        }
        app.run()
    }
}

@MainActor
final class Spike {
    let args = CommandLine.arguments
    lazy var httpPort = Int(args[1])!
    lazy var lan = args[2]
    lazy var base = Int(args[3])!
    lazy var logPath = args[4]
    lazy var sites = URL(fileURLWithPath: args[5])
    let fonts = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Fonts")
    let css = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Linen/Pages/Kit/loom.css")
    var window: NSWindow!
    var lines: [String] = []

    func say(_ s: String) { print(s); lines.append(s) }

    func run() async {
        try? FileManager.default.removeItem(at: sites)
        writeSites()
        window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1000, height: 820), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
        say("P(c) on WebKit \(PageSeal.webKitBuild), \(ProcessInfo.processInfo.operatingSystemVersionString)")
        // Page scripts stay off until the seal check passes (PAGE-10), so the spike runs it first, as the app does.
        PageSelfTest.inventoryOverride = css.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Inventory")
        let inventory = PageSelfTest.inventoryURL()
        let check = await PageSelfTest.shared.run(inventory: inventory)
        say("seal check: \(check)")
        for v in variants { await runVariant(v) }
        await scriptsOff()
        await crossPage()
        unitChecks()
        let out = sites.deletingLastPathComponent().appendingPathComponent("pc-results.txt")
        try? lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
    }

    // MARK: One variant

    func open(_ page: URL, _ options: SealOptions, scripts: Bool, onScreen: Bool) async -> (SealedPageController, [String]) {
        PagePolicy.setPerFile(page, scripts)
        let kit = KitScheme(css: css, fonts: fonts)
        let c = SealedPageController(url: page, theme: "paper", options: options, kit: kit)
        let box = EventBox()
        c.onEvent = { box.events.append($0) }
        c.onOpenInLinen = { u, _ in box.events.append("OPEN-IN-LINEN \(u.lastPathComponent)") }
        c.confirmExternal = { u, decide in box.events.append("ASKED \(u.absoluteString)"); decide(false) }
        c.openExternal = { u in box.events.append("OPENED-EXTERNAL \(u.absoluteString)") }
        c.scheme.onRequest = { u, served, why in box.events.append("\(served ? "served" : "REFUSED") \(u)\(why.isEmpty ? "" : " (\(why))")") }
        kit.onRequest = { u, served in box.events.append("\(served ? "served" : "REFUSED") kit \(u)") }
        window.contentViewController = c
        if onScreen {
            window.setFrameOrigin(NSPoint(x: 80, y: 80))
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
            window.orderFrontRegardless()
        }
        boxes[ObjectIdentifier(c)] = box
        return (c, [])
    }

    var boxes: [ObjectIdentifier: EventBox] = [:]

    func waitOut(_ c: SealedPageController, seconds: Double = 20) async -> [String: Any]? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try? await Task.sleep(for: .milliseconds(300))
            if let s = await c.evaluateInKit("const o = document.getElementById('out'); return o ? o.textContent : ''") as? String, !s.isEmpty,
               let d = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any], d["done"] as? Bool == true {
                return d
            }
        }
        return nil
    }

    func runVariant(_ v: Variant) async {
        writePage(v)
        let mark = witnessLines().count
        let onScreen = v.name == "full"
        let (c, _) = await open(sites.appendingPathComponent("site-a/page.html"), v.options, scripts: true, onScreen: onScreen)
        let result = await waitOut(c)
        say("")
        say("== \(v.name) [rules \(v.options.rules), csp \(v.options.csp), removal \(v.options.removal), gate \(v.options.gate), sandbox \(v.options.sandbox), engine flags \(c.flagsOff.isEmpty ? "none" : c.flagsOff.joined(separator: " "))]")
        guard let result else { say("   page: NO REPORT"); return }
        say("   shared worker with importScripts: \(result["sharedImport"] ?? "no report")")
        for key in ["siblings", "kit", "isolation", "capabilities", "scriptClicks"] {
            if let d = result[key] as? [String: Any] { say("   \(key): " + d.keys.sorted().map { "\($0)=\(d[$0]!)" }.joined(separator: "; ")) }
        }
        if let r = result["realms"] as? [String: Any] {
            for name in realms {
                if let d = r[name] as? [String: Any] { say("   realm \(name): " + d.keys.sorted().map { "\($0)=\(d[$0]!)" }.joined(separator: "; ")) }
                else { say("   realm \(name): no report") }
            }
        }
        if v.name == "full" { await interact(c) }
        if v.name == "full" || v.name == "sandbox" {
            if let paint = await paintColor(c) { say("   paint worklet pixel: \(paint)") }
        }
        try? await Task.sleep(for: .seconds(2))
        let box = boxes[ObjectIdentifier(c)]!
        let refused = box.events.filter { $0.hasPrefix("REFUSED") }
        say("   handler refused \(refused.count): " + refused.map { String($0.prefix(140)) }.joined(separator: " | "))
        let served = Set(box.events.filter { $0.hasPrefix("served") }.map { String($0.split(separator: "/").last ?? "") })
        say("   handler served: " + served.sorted().joined(separator: ", "))
        let other = box.events.filter { !$0.hasPrefix("served") && !$0.hasPrefix("REFUSED") }
        say("   controller events: " + other.joined(separator: " | "))
        let hits = witnessLines().dropFirst(mark).filter { $0.contains("\(v.name)-") || portBelongs($0, v.index) }
        say("   WITNESS (\(hits.count)): " + hits.map { String($0.split(separator: " ", maxSplits: 1).last ?? "") }.joined(separator: " | "))
        window.contentViewController = nil
        window.orderOut(nil)
        try? await Task.sleep(for: .seconds(1))
    }

    func portBelongs(_ line: String, _ vi: Int) -> Bool {
        guard let r = line.range(of: "off=") else { return false }
        let n = Int(line[r.upperBound...].prefix { $0.isNumber }) ?? -1
        let lo = vi * 16, wt = 120 + vi * 16
        return (n >= lo && n < lo + 16) || (n >= wt && n < wt + 16)
    }

    func witnessLines() -> [String] {
        ((try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    // MARK: Real clicks, hovers, theme (full seal, on screen)

    func rect(_ c: SealedPageController, _ id: String) async -> CGRect? {
        guard let d = await c.evaluateInKit("const e = document.getElementById(id); if (!e) return null; e.scrollIntoView({block: 'center'}); const r = e.getBoundingClientRect(); return [r.left, r.top, r.width, r.height];".replacingOccurrences(of: "(id)", with: "('\(id)')")) as? [Double], d.count == 4 else { return nil }
        return CGRect(x: d[0], y: d[1], width: d[2], height: d[3])
    }

    func point(_ c: SealedPageController, _ r: CGRect) -> NSPoint? {
        guard let web = c.web else { return nil }
        let p = NSPoint(x: r.midX, y: r.midY)
        let local = web.isFlipped ? p : NSPoint(x: p.x, y: web.bounds.height - p.y)
        return web.convert(local, to: nil)
    }

    func mouse(_ type: NSEvent.EventType, _ p: NSPoint, clicks: Int = 1) {
        if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1) {
            window.sendEvent(e)
        }
    }

    func interact(_ c: SealedPageController) async {
        let box = boxes[ObjectIdentifier(c)]!
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .milliseconds(500))
        say("   drag types registered on the web view: \(c.web?.registeredDraggedTypes.count ?? -1)")
        // Theme: Linen sets the attribute and sends linen:theme; the page sees both.
        c.setTheme("night")
        try? await Task.sleep(for: .milliseconds(400))
        let theme = await c.evaluateInKit("return [document.documentElement.getAttribute('data-linen-theme'), document.documentElement.dataset.pcThemeEvents || '']")
        say("   theme after setTheme(night): \(String(describing: theme))")
        c.setTheme("paper")
        // Hover a data-note element with the real pointer.
        if let r = await rect(c, "noted"), let p = point(c, r) {
            let before = box.events.count
            for dx in stride(from: -30.0, through: 0, by: 6) { mouse(.mouseMoved, NSPoint(x: p.x + dx, y: p.y)); try? await Task.sleep(for: .milliseconds(30)) }
            try? await Task.sleep(for: .milliseconds(700))
            let card = await c.evaluateInKit("const h = document.querySelector('linen-note'); return h ? 'host present, shadow ' + (h.shadowRoot === null ? 'closed' : 'open') : 'no card'")
            say("   hover data-note: events \(box.events.dropFirst(before).joined(separator: ","))  card: \(String(describing: card))")
            let pageView = await c.evaluateInKit("return document.documentElement.dataset.pcNoteSeen || ''")
            say("   page saw the card's text: \(String(describing: pageView))")
            mouse(.mouseMoved, NSPoint(x: 5, y: 5))
        }
        for id in ["l-mailto", "l-obsidian", "l-app", "l-outside", "l-https", "l-sibling", "l-note", "l-frag", "l-download", "l-winopen", "l-file"] {
            guard let r = await rect(c, id), let p = point(c, r) else { say("   real click \(id): no element"); continue }
            try? await Task.sleep(for: .milliseconds(250))
            let before = box.events.count
            mouse(.leftMouseDown, p)
            mouse(.leftMouseUp, p)
            try? await Task.sleep(for: .milliseconds(900))
            let ev = box.events.dropFirst(before).filter { !$0.hasPrefix("served") }
            let still = await c.evaluateInKit("return location.pathname + location.hash + ' winopen=' + (document.documentElement.dataset.winopen || '-')")
            say("   real click \(id): \(ev.isEmpty ? "nothing" : ev.joined(separator: ", "))  page now \(String(describing: still))")
        }
        let opened = box.events.filter { $0.hasPrefix("OPENED-EXTERNAL") }
        say("   opened outside Linen: \(opened.count)")
    }

    func paintColor(_ c: SealedPageController) async -> String? {
        guard let web = c.web, let r = await rect(c, "painted"), r.width > 0 else { return nil }
        let conf = WKSnapshotConfiguration()
        conf.rect = r
        guard let img = try? await web.takeSnapshot(configuration: conf), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let col = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB) else { return "no snapshot" }
        return String(format: "r%.2f g%.2f b%.2f", col.redComponent, col.greenComponent, col.blueComponent)
    }

    // MARK: Scripts off

    func scriptsOff() async {
        writePage(variants[1])
        let (c, _) = await open(sites.appendingPathComponent("site-a/page.html"), .full, scripts: false, onScreen: false)
        try? await Task.sleep(for: .seconds(4))
        let ran = await c.evaluateInKit("return [document.getElementById('out').textContent.length, document.documentElement.getAttribute('data-linen-theme'), document.documentElement.dataset.inline || 'no']")
        let line = await c.evaluateInKit("return 1")
        say("")
        say("== scripts off (untrusted, full seal)")
        say("   page out length, theme attribute from the kit world, inline script ran: \(String(describing: ran))  kit world alive: \(String(describing: line))")
        say("   controller scriptsOn \(c.scriptsOn), reason \(c.scriptsOffReason ?? "-")")
        let box = boxes[ObjectIdentifier(c)]!
        say("   events: " + box.events.filter { !$0.hasPrefix("served") }.joined(separator: " | "))
        window.contentViewController = nil
        window.orderOut(nil)
    }

    // MARK: Two pages

    func crossPage() async {
        say("")
        say("== two pages")
        let (a, _) = await open(sites.appendingPathComponent("site-c/store.html"), .full, scripts: true, onScreen: false)
        let stored = await waitOut(a)
        say("   writer: \(String(describing: stored))")
        // Keep the writer open in its own window while the reader runs.
        let keep = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        keep.isReleasedWhenClosed = false
        window.contentViewController = nil
        keep.contentViewController = a
        keep.orderFrontRegardless()
        writeReader(hostA: a.scheme.host)
        let (b, _) = await open(sites.appendingPathComponent("site-b/read.html"), .full, scripts: true, onScreen: false)
        let read = await waitOut(b)
        say("   reader: " + ((read?["reads"] as? [String: Any]).map { d in d.keys.sorted().map { "\($0)=\(d[$0]!)" }.joined(separator: "; ") } ?? "NO REPORT"))
        let box = boxes[ObjectIdentifier(b)]!
        say("   reader's handler: " + box.events.filter { $0.hasPrefix("REFUSED") }.map { String($0.prefix(120)) }.joined(separator: " | "))
        if let wa = a.web, let wb = b.web, wa.responds(to: Selector(("_webProcessIdentifier"))) {
            say("   web content pids: writer \(wa.value(forKey: "_webProcessIdentifier") ?? "?"), reader \(wb.value(forKey: "_webProcessIdentifier") ?? "?")")
        }
        keep.contentViewController = nil
        keep.orderOut(nil)
        window.contentViewController = nil
        window.orderOut(nil)
    }

    func unitChecks() {
        say("")
        say("== handler units")
        let home = FileManager.default.homeDirectoryForCurrentUser
        for (name, u) in [("home", home), ("Desktop", home.appendingPathComponent("Desktop")), ("Documents", home.appendingPathComponent("Documents")),
                          ("Downloads", home.appendingPathComponent("Downloads")), ("/", URL(fileURLWithPath: "/")), ("/Volumes/X", URL(fileURLWithPath: "/Volumes/X")),
                          ("Desktop/project", home.appendingPathComponent("Desktop/project")), ("site-a", sites.appendingPathComponent("site-a"))] {
            say("   broad root \(name): \(PageScheme.isBroadRoot(u))")
        }
        let s = PageScheme(page: sites.appendingPathComponent("site-a/page.html"), scripts: true)
        for path in ["data.json", "sub/inner.html", "sub/../data.json", "%2e%2e/site-b/data.json", "sub%2F..%2F..%2Fsite-b%2Fdata.json", ".hidden.json", "sub/.git/config", "a%00b"] {
            let u = URL(string: "\(s.origin)/\(path)")!
            let r = s.relativePath(of: u)
            say("   path \(path) -> \(r.path ?? "refused (\(r.reason))")  [URL path \(u.path)]")
        }
        let other = URL(string: "linen-page://p0000/data.json")!
        say("   other host -> \(s.relativePath(of: other).path ?? "refused (\(s.relativePath(of: other).reason))")")
        say("   CSP scripts on: \(PageSeal.csp(scripts: true))")
        say("   CSP scripts off: \(PageSeal.csp(scripts: false))")
        for (path, _) in [("page.html", 0), ("worker.js", 0), ("shared.js", 0), ("audio.js", 0), ("paint.js", 0), ("svgdoc.svg", 0), ("frame.html", 0), ("sibling.png", 0)] {
            let h = s.responseHeaders(for: path)
            say("   headers \(path): CSP \(h["Content-Security-Policy"] != nil ? "yes" : "NO"), nosniff \(h["X-Content-Type-Options"] ?? "NO"), type \(h["Content-Type"] ?? "?")")
        }
    }

    // MARK: Site files

    func put(_ rel: String, _ text: String) {
        let u = sites.appendingPathComponent(rel)
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: u, atomically: true, encoding: .utf8)
    }

    func writeSites() {
        let probe = probeJS
            .replacingOccurrences(of: "__H__", with: "\(httpPort)").replacingOccurrences(of: "__L__", with: lan)
            .replacingOccurrences(of: "__BASE__", with: "\(base)")
        put("site-a/probe.js", probe)
        put("site-a/data.json", "{\"ok\": \"own origin\"}")
        put("site-a/secret.json", "{\"secret\": \"site-a\"}")
        put("site-a/.hidden.json", "{\"hidden\": true}")
        put("site-a/notes.md", "# A sibling note\n")
        put("site-a/sub/inner.html", "<!doctype html><title>inner</title><p>inner page</p>")
        put("site-a/sibling.js", "window.SIB_JS = 'ran';")
        put("site-a/sibling.css", "#sib { width: 123px; }")
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
        try? png.write(to: sites.appendingPathComponent("site-a/sibling.png"))
        put("site-a/worker.js", "importScripts('probe.js'); onmessage = (e) => pcProbe(e.data.realm, e.data.v, e.data.vi, e.data.ri, (r) => postMessage(r));")
        // The shared worker carries the probe inline: importScripts from a shared worker did not load (see README).
        put("site-a/shared.js", probe + "\nonconnect = (e) => { const port = e.ports[0]; port.onmessage = (m) => pcProbe('shared', m.data.v, m.data.vi, 5, (r) => port.postMessage(r)); };")
        put("site-a/shared-import.js", "importScripts('probe.js'); onconnect = (e) => { e.ports[0].postMessage({imported: typeof pcProbe}); };")
        put("site-a/frame.html", "<!doctype html><script src=\"probe.js\"></script><script>addEventListener('message', (e) => { if (e.data && e.data.go) pcProbe('frame', e.data.v, e.data.vi, 1, (r) => parent.postMessage({pc: 'frame', res: r}, '*')); });</script>")
        put("site-a/svgdoc.svg", "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"><script href=\"probe.js\"/><script>addEventListener('message', (e) => { if (e.data &amp;&amp; e.data.go) pcProbe('svg', e.data.v, e.data.vi, 8, (r) => parent.postMessage({pc: 'svg', res: r}, '*')); });</script></svg>")
        put("site-a/audio.js", """
        const t = (n) => typeof globalThis[n];
        registerProcessor('pc', class extends AudioWorkletProcessor {
          constructor(o) { super();
            const R = {fetch: t('fetch'), WebSocket: t('WebSocket'), WebTransport: t('WebTransport'), RTCPeerConnection: t('RTCPeerConnection'),
              XMLHttpRequest: t('XMLHttpRequest'), importScripts: t('importScripts'), EventSource: t('EventSource')};
            const p = o.processorOptions || {};
            if (typeof WebSocket === 'function') { try { new WebSocket('ws://127.0.0.1:' + p.H + '/' + p.tag + '/ws-audio'); R.ws = 'made'; } catch (e) { R.ws = 'threw ' + e.name; } }
            if (typeof fetch === 'function') { try { fetch('http://127.0.0.1:' + p.H + '/' + p.tag + '/fetch-audio'); R.fetchTried = 'yes'; } catch (e) {} }
            this.port.postMessage(R); }
          process() { return false; }
        });
        """)
        put("site-a/paint.js", "registerPaint('pc', class { paint(ctx, size) { const bad = ['fetch','WebSocket','WebTransport','RTCPeerConnection','XMLHttpRequest','importScripts','EventSource'].filter((n) => typeof globalThis[n] !== 'undefined'); ctx.fillStyle = bad.length ? '#ff0000' : '#00ff00'; ctx.fillRect(0, 0, size.width, size.height); } });")
        // The writer and the reader for the two-page check.
        put("site-c/secret.json", "{\"secret\": \"site-c\"}")
        put("site-c/store.html", """
        <!doctype html><meta charset="utf-8"><title>writer</title><pre id="out"></pre><script>
        (async () => {
          const r = {};
          try { localStorage.setItem('secret', 'C'); r.local = 'set'; } catch (e) { r.local = 'threw ' + e.name; }
          try { sessionStorage.setItem('secret', 'C'); r.session = 'set'; } catch (e) { r.session = 'threw ' + e.name; }
          try { document.cookie = 'secret=C; path=/'; r.cookie = document.cookie || 'none kept'; } catch (e) { r.cookie = 'threw ' + e.name; }
          try { await new Promise((ok, no) => { const q = indexedDB.open('pc', 1); q.onupgradeneeded = () => q.result.createObjectStore('s'); q.onsuccess = () => { const tx = q.result.transaction('s', 'readwrite'); tx.objectStore('s').put('C', 'secret'); tx.oncomplete = ok; tx.onerror = no; }; q.onerror = no; }); r.idb = 'set'; } catch (e) { r.idb = 'threw ' + (e && e.name); }
          try { const bc = new BroadcastChannel('pc'); setInterval(() => bc.postMessage('C'), 150); r.bc = 'posting'; } catch (e) { r.bc = 'threw ' + e.name; }
          document.getElementById('out').textContent = JSON.stringify({done: true, writes: r});
        })();
        </script>
        """)
        put("site-b/data.json", "{\"ok\": \"site-b\"}")
        try? FileManager.default.createSymbolicLink(atPath: sites.appendingPathComponent("site-b/link-out.json").path, withDestinationPath: "../site-c/secret.json")
        try? FileManager.default.createSymbolicLink(atPath: sites.appendingPathComponent("site-b/link-in.json").path, withDestinationPath: "data.json")
    }

    func writeReader(hostA: String) {
        put("site-b/read.html", """
        <!doctype html><meta charset="utf-8"><title>reader</title><pre id="out"></pre><script>
        (async () => {
          const r = {};
          const f = async (k, u) => { try { const x = await fetch(u); r[k] = 'REACHED ' + x.status + ' ' + (await x.text()).slice(0, 30); } catch (e) { r[k] = 'refused ' + e.name; } };
          try { r.local = String(localStorage.getItem('secret')); } catch (e) { r.local = 'threw ' + e.name; }
          try { r.session = String(sessionStorage.getItem('secret')); } catch (e) { r.session = 'threw ' + e.name; }
          r.cookie = document.cookie || 'none';
          try { r.idbNames = JSON.stringify((await indexedDB.databases()).map((d) => d.name)); } catch (e) { r.idbNames = 'threw ' + e.name; }
          try { r.idb = await new Promise((ok) => { const q = indexedDB.open('pc', 1); q.onupgradeneeded = () => { q.result.createObjectStore('s'); }; q.onsuccess = () => { try { const g = q.result.transaction('s').objectStore('s').get('secret'); g.onsuccess = () => ok(String(g.result)); g.onerror = () => ok('error'); } catch (e) { ok('no store ' + e.name); } }; q.onerror = () => ok('open error'); }); } catch (e) { r.idb = 'threw ' + e.name; }
          let heard = 'nothing'; try { const bc = new BroadcastChannel('pc'); bc.onmessage = (m) => { heard = 'HEARD ' + m.data; }; } catch (e) { heard = 'threw ' + e.name; }
          await f('own', 'data.json');
          await f('writerOrigin', 'linen-page://\(hostA)/secret.json');
          await f('dotdot', '../site-c/secret.json');
          await f('encodedDotdot', '%2e%2e/site-c/secret.json');
          await f('encodedSep', '..%2Fsite-c%2Fsecret.json');
          await f('symlinkOut', 'link-out.json');
          await f('symlinkIn', 'link-in.json');
          await f('fileScheme', 'file:///etc/hosts');
          const fr = document.createElement('iframe'); fr.src = 'linen-page://\(hostA)/store.html'; document.body.append(fr);
          await new Promise((ok) => setTimeout(ok, 1500));
          try { r.frameRead = fr.contentDocument ? 'frame is ' + fr.contentWindow.location.href + ' titled "' + fr.contentDocument.title + '"' : 'no access'; } catch (e) { r.frameRead = 'threw ' + e.name; }
          r.broadcast = heard;
          document.getElementById('out').textContent = JSON.stringify({done: true, reads: r});
        })();
        </script>
        """)
    }

    func writePage(_ v: Variant) {
        put("site-a/page.html", """
        <!doctype html><html><head><meta charset="utf-8"><title>P(c) probe page</title>
        <link rel="stylesheet" href="sibling.css">
        <link rel="stylesheet" href="linen-kit://kit/loom.css">
        <link rel="stylesheet" href="linen-kit://kit/unlisted.css" id="kitUnlisted">
        <script src="sibling.js"></script>
        <script src="probe.js"></script>
        <style> .lnk { display: inline-block; padding: 8px 12px; margin: 4px; border: 1px solid #999; } #painted { width: 40px; height: 40px; display: inline-block; } </style>
        </head><body>
        <div id="sib">x</div><img id="sibimg" src="sibling.png" width="4" height="4"><img id="otherimg" src="linen-page://p0000/sibling.png">
        <span id="kitfont" style="font: 40px 'Linen Sans', monospace">Linen kit</span> <span id="mono" style="font: 40px monospace">Linen kit</span>
        <p><span id="noted" class="lnk" data-note="A note card from the kit">noted term</span> <span id="painted"></span></p>
        <p><a class="lnk" id="l-mailto" href="mailto:x@example.com">mailto</a><a class="lnk" id="l-obsidian" href="obsidian://open?vault=probe">obsidian</a><a class="lnk" id="l-app" href="file:///System/Applications/Calculator.app">app</a><a class="lnk" id="l-outside" href="file:///etc/hosts">outside</a><a class="lnk" id="l-https" href="https://example.com/linen/full-address?q=1#frag">https</a><a class="lnk" id="l-sibling" href="sub/inner.html">sibling page</a><a class="lnk" id="l-note" href="notes.md">sibling note</a><a class="lnk" id="l-frag" href="#out">fragment</a><a class="lnk" id="l-download" href="data.json" download>download</a><button class="lnk" id="l-winopen">window.open</button><input class="lnk" id="l-file" type="file"></p>
        <a id="s-https" href="https://example.com/script-click">s</a> <a id="s-mailto" href="mailto:script@example.com">s</a> <a id="s-winopen" href="#">w</a>
        <pre id="out"></pre>
        <script>document.documentElement.dataset.inline = 'yes';</script>
        <script>
        const V = '\(v.name)', VI = \(v.index), GATE = \(v.options.gate);
        const R = {}, realms = {};
        let pending = new Set(['page', 'frame', 'srcdoc', 'worker', 'blobworker', 'shared', 'audio', 'svg']);
        const got = (name, res) => { realms[name] = res; pending.delete(name); };
        addEventListener('message', (e) => { if (e.data && e.data.pc) got(e.data.pc, e.data.res); });
        document.addEventListener('linen:theme', (e) => { const r = document.documentElement; r.dataset.pcThemeEvents = (r.dataset.pcThemeEvents || '') + String(e.detail) + ','; });
        new MutationObserver(() => { const h = document.querySelector('linen-note'); if (h) document.documentElement.dataset.pcNoteSeen = 'host ' + (h.shadowRoot ? 'readable: ' + h.shadowRoot.textContent : 'closed') + ', text ' + (h.textContent || 'none'); }).observe(document.documentElement, {childList: true, subtree: true});
        document.getElementById('l-winopen').addEventListener('click', () => { const w = window.open('https://example.com/popup'); document.documentElement.dataset.winopen = String(w); });
        document.getElementById('s-winopen').addEventListener('click', () => { window.open('https://example.com/script-popup'); });
        const wait = (ms) => new Promise((r) => setTimeout(r, ms));
        (async () => {
          const sib = {};
          await new Promise((ok) => addEventListener('load', ok));
          sib.script = String(window.SIB_JS);
          sib.style = getComputedStyle(document.getElementById('sib')).width;
          sib.image = document.getElementById('sibimg').naturalWidth ? 'loaded' : 'not loaded';
          sib.otherHostImage = document.getElementById('otherimg').naturalWidth ? 'LOADED' : 'refused';
          try { sib.json = (await (await fetch('data.json')).json()).ok; } catch (e) { sib.json = 'err ' + e.name; }
          try { sib.relDotdot = 'REACHED ' + (await (await fetch('sub/../../site-c/secret.json')).text()).slice(0, 20); } catch (e) { sib.relDotdot = 'refused'; }
          sib.origin = location.origin; sib.secure = String(window.isSecureContext);
          R.siblings = sib;
          const kit = {};
          kit.css = getComputedStyle(document.documentElement).getPropertyValue('--paper').trim() || 'not applied';
          try { await document.fonts.load('40px "Linen Sans"'); } catch (e) {}
          kit.font = document.getElementById('kitfont').offsetWidth + ' px vs ' + document.getElementById('mono').offsetWidth + ' px fallback';
          kit.fontsLoaded = [...document.fonts].filter((f) => f.status === 'loaded').map((f) => f.family + ' ' + f.weight).join(', ');
          kit.unlistedCss = document.getElementById('kitUnlisted').sheet ? 'LOADED' : 'refused';
          try { await fetch('linen-kit://kit/fonts/thmanyahsans-Regular.otf'); kit.fontFetch = 'readable (CORS)'; } catch (e) { kit.fontFetch = 'err ' + e.name; }
          try { await fetch('linen-kit://kit/../Info.plist'); kit.escape = 'REACHED'; } catch (e) { kit.escape = 'refused'; }
          R.kit = kit;
          const iso = {};
          iso.kitGlobal = typeof window.__linenKit;
          iso.webkit = typeof window.webkit;
          try { webkit.messageHandlers.linenKit.postMessage({type: 'click', href: 'https://example.com/forged'}); iso.forge = 'POSTED'; } catch (e) { iso.forge = 'threw ' + e.name; }
          iso.themeAttr = document.documentElement.getAttribute('data-linen-theme');
          iso.rtc = typeof RTCPeerConnection; iso.webTransport = typeof WebTransport;
          R.isolation = iso;
          // Realms.
          pcProbe('page', V, VI, 0, (r) => got('page', r));
          const fr = document.createElement('iframe'); fr.src = 'frame.html'; fr.onload = () => fr.contentWindow.postMessage({go: 1, v: V, vi: VI}, '*'); document.body.append(fr);
          const sv = document.createElement('iframe'); sv.src = 'svgdoc.svg'; sv.onload = () => sv.contentWindow.postMessage({go: 1, v: V, vi: VI}, '*'); document.body.append(sv);
          const sd = document.createElement('iframe');
          sd.srcdoc = '<scr' + 'ipt>' + pcProbe.toString() + ';pcProbe("srcdoc", ' + JSON.stringify(V) + ', ' + VI + ', 2, (r) => parent.postMessage({pc: "srcdoc", res: r}, "*"));</scr' + 'ipt>';
          document.body.append(sd);
          try { const w = new Worker('worker.js'); w.onmessage = (e) => got('worker', e.data); w.onerror = (e) => got('worker', {error: 'worker error ' + (e.message || '')}); w.postMessage({realm: 'worker', v: V, vi: VI, ri: 3}); } catch (e) { got('worker', {error: 'threw ' + e.name}); }
          try { const b = new Blob([pcProbe.toString() + ';onmessage = (e) => pcProbe("blobworker", e.data.v, e.data.vi, 4, (r) => postMessage(r));'], {type: 'text/javascript'});
                const w = new Worker(URL.createObjectURL(b)); w.onmessage = (e) => got('blobworker', e.data); w.onerror = (e) => got('blobworker', {error: 'worker error ' + (e.message || '')}); w.postMessage({v: V, vi: VI}); } catch (e) { got('blobworker', {error: 'threw ' + e.name}); }
          try { const si = new SharedWorker('shared-import.js'); si.port.onmessage = (e) => { R.sharedImport = JSON.stringify(e.data); }; si.onerror = (e) => { R.sharedImport = 'error ' + (e && e.message || ''); }; si.port.start(); } catch (e) { R.sharedImport = 'threw ' + e.name; }
          try { if (typeof SharedWorker !== 'function') throw {name: 'absent'}; const s = new SharedWorker('shared.js'); s.port.onmessage = (e) => got('shared', e.data); s.onerror = (e) => got('shared', {error: 'shared error ' + (e && e.message || '')}); s.port.start(); s.port.postMessage({v: V, vi: VI}); } catch (e) { got('shared', {error: 'threw ' + e.name}); }
          try { const ac = new AudioContext(); await ac.audioWorklet.addModule('audio.js'); const n = new AudioWorkletNode(ac, 'pc', {processorOptions: {H: \(httpPort), tag: V + '-audio'}}); n.port.onmessage = (e) => got('audio', e.data); } catch (e) { got('audio', {error: 'threw ' + (e && e.name)}); }
          try { if (typeof CSS === 'undefined' || !CSS.paintWorklet) throw {name: 'absent'}; await CSS.paintWorklet.addModule('paint.js'); document.getElementById('painted').style.backgroundImage = 'paint(pc)'; realms.paint = {present: 'yes, see pixel'}; } catch (e) { realms.paint = {error: 'paint worklet ' + e.name}; }
          // Capability probes and script-made clicks (only with the gate on, so the control run never leaves the page).
          if (GATE) {
            const cap = {};
            const t0 = performance.now(); try { alert('x'); cap.alert = 'returned'; } catch (e) { cap.alert = 'threw'; }
            try { cap.confirm = String(confirm('y')); } catch (e) { cap.confirm = 'threw'; }
            try { cap.prompt = String(prompt('z')); } catch (e) { cap.prompt = 'threw'; }
            cap.dialogMs = Math.round(performance.now() - t0);
            try { const i = document.createElement('input'); i.type = 'file'; document.body.append(i); i.click(); cap.filePicker = 'clicked'; } catch (e) { cap.filePicker = 'threw'; }
            cap.showOpenFilePicker = typeof window.showOpenFilePicker;
            cap.mediaDevices = typeof navigator.mediaDevices;
            try { await navigator.mediaDevices.getUserMedia({video: true, audio: true}); cap.getUserMedia = 'GRANTED'; } catch (e) { cap.getUserMedia = 'refused ' + e.name; }
            try { await navigator.mediaDevices.getDisplayMedia({video: true}); cap.getDisplayMedia = 'GRANTED'; } catch (e) { cap.getDisplayMedia = 'refused ' + e.name; }
            cap.geolocation = typeof navigator.geolocation;
            try { await new Promise((ok, no) => navigator.geolocation.getCurrentPosition(ok, no, {timeout: 2000})); cap.position = 'GRANTED'; } catch (e) { cap.position = 'refused ' + (e.name || e.code); }
            cap.Notification = typeof Notification;
            try { cap.notificationPermission = await Notification.requestPermission(); } catch (e) { cap.notificationPermission = 'refused ' + e.name; }
            try { cap.clipboardRead = 'READ ' + (await navigator.clipboard.readText()).length; } catch (e) { cap.clipboardRead = 'refused ' + e.name; }
            cap.share = typeof navigator.share;
            cap.credentials = typeof navigator.credentials;
            cap.registerProtocolHandler = typeof navigator.registerProtocolHandler;
            try { await document.documentElement.requestFullscreen(); cap.fullscreen = 'ENTERED'; } catch (e) { cap.fullscreen = 'refused ' + (e && e.name); }
            const w = window.open('https://example.com/open'); cap.windowOpen = String(w);
            const cf = document.createElement('iframe'); cf.src = 'mailto:frame@example.com'; document.body.append(cf);
            const of = document.createElement('iframe'); of.src = 'obsidian://open?vault=frame'; document.body.append(of);
            try { const dl = document.createElement('a'); dl.download = 'x.txt'; dl.href = URL.createObjectURL(new Blob(['x'])); document.body.append(dl); dl.click(); cap.download = 'clicked'; } catch (e) { cap.download = 'threw'; }
            R.capabilities = cap;
            const sc = {};
            document.getElementById('s-https').click(); sc.https = 'clicked';
            document.getElementById('s-mailto').click(); sc.mailto = 'clicked';
            document.getElementById('s-winopen').click(); sc.winopen = 'clicked';
            await wait(300);
            try { location.href = 'obsidian://open?vault=script'; } catch (e) {}
            await wait(300);
            sc.stillHere = location.pathname;
            R.scriptClicks = sc;
          }
          const end = Date.now() + 9000;
          while (pending.size && Date.now() < end) await wait(200);
          for (const p of pending) realms[p] = {error: 'no report'};
          R.realms = realms; R.done = true;
          document.getElementById('out').textContent = JSON.stringify(R);
        })();
        </script>
        </body></html>
        """)
    }

    let probeJS = """
    async function pcProbe(realm, v, vi, ri, done) {
      const H = __H__, L = '__L__', BASE = __BASE__;
      const tag = v + '-' + realm;
      const port = BASE + vi * 16 + ri, wtPort = BASE + 120 + vi * 16 + ri;
      const res = {};
      const T = (k, p) => Promise.resolve().then(p).then((x) => { res[k] = x; }, (e) => { res[k] = 'blocked ' + (e && (e.name || e.message) || e); });
      const wait = (ms) => new Promise((r) => setTimeout(r, ms));
      const jobs = [];
      const href = (typeof location !== 'undefined') ? String(location.href) : '';
      const own = (href.startsWith('blob:') ? href.slice(5).split('/').slice(0, 3).join('/') + '/' : '') + 'data.json';
      if (typeof fetch === 'function') {
        jobs.push(T('control', () => fetch(own).then((r) => r.json()).then((j) => 'ok: ' + j.ok)));
        jobs.push(T('fetchV6', () => fetch('http://[::1]:' + H + '/' + tag + '/fetch-v6').then((r) => 'REACHED ' + r.status)));
        jobs.push(T('fetchLoopback', () => fetch('http://127.0.0.1:' + H + '/' + tag + '/fetch-lo').then((r) => 'REACHED ' + r.status)));
        jobs.push(T('fetchLan', () => fetch('http://' + L + ':' + H + '/' + tag + '/fetch-lan').then((r) => 'REACHED ' + r.status)));
        jobs.push(T('fetchNoCors', () => fetch('http://127.0.0.1:' + H + '/' + tag + '/nocors', {mode: 'no-cors'}).then((r) => 'REACHED ' + r.type)));
        jobs.push(T('fetchLocalName', () => fetch('http://linenprobe-' + tag + '-fetch.local/x').then((r) => 'REACHED ' + r.status)));
        jobs.push(T('otherHost', () => fetch('linen-page://p00000000000000000000000000000000/data.json').then((r) => 'REACHED ' + r.status)));
        jobs.push(T('kitUnlisted', () => fetch('linen-kit://kit/secret.txt').then((r) => 'REACHED ' + r.status)));
      } else res.fetch = 'absent';
      if (typeof XMLHttpRequest === 'function') {
        jobs.push(T('xhr', () => new Promise((ok, no) => { const x = new XMLHttpRequest(); x.open('GET', 'http://127.0.0.1:' + H + '/' + tag + '/xhr'); x.onload = () => ok('REACHED ' + x.status); x.onerror = () => no({name: 'error'}); x.send(); })));
      }
      if (typeof WebSocket === 'function') {
        const ws = (k, url) => jobs.push(T(k, () => new Promise((ok) => { try { const s = new WebSocket(url); s.onopen = () => ok('REACHED open'); s.onerror = () => ok('blocked'); setTimeout(() => ok('no answer'), 2500); } catch (e) { ok('threw ' + e.name); } })));
        ws('wsLoopback', 'ws://127.0.0.1:' + H + '/' + tag + '/ws-lo');
        ws('wsLan', 'ws://' + L + ':' + H + '/' + tag + '/ws-lan');
        ws('wsV6', 'ws://[::1]:' + H + '/' + tag + '/ws-v6');
      } else res.websocket = 'absent';
      if (typeof EventSource === 'function') {
        jobs.push(T('eventSource', () => new Promise((ok) => { try { const e = new EventSource('http://127.0.0.1:' + H + '/' + tag + '/es'); e.onopen = () => ok('REACHED'); e.onerror = () => { ok('blocked'); e.close(); }; setTimeout(() => ok('no answer'), 2500); } catch (x) { ok('threw ' + x.name); } })));
      }
      if (typeof WebTransport === 'function') {
        try { const w = new WebTransport('https://' + L + ':' + wtPort + '/'); res.webTransport = 'made'; w.ready.then(() => { res.webTransport = 'REACHED'; }, (e) => { res.webTransport = 'rejected ' + e.name; }); } catch (e) { res.webTransport = 'threw ' + e.name; }
      } else res.webTransport = 'absent (' + typeof WebTransport + ')';
      const RTC = globalThis.RTCPeerConnection;
      if (typeof RTC === 'function') {
        try { const pc = new RTC({iceServers: [{urls: 'stun:' + L + ':' + port}, {urls: 'stun:127.0.0.1:' + port}, {urls: 'stun:[::1]:' + port}, {urls: 'turn:' + L + ':' + port + '?transport=tcp', username: 'u', credential: 'p'}]});
              pc.createDataChannel('x'); pc.createOffer().then((o) => pc.setLocalDescription(o)); globalThis.__pc = pc; res.rtc = 'made'; } catch (e) { res.rtc = 'threw ' + e.name; }
      } else res.rtc = 'absent (' + typeof RTC + ')';
      if (typeof importScripts === 'function') {
        try { importScripts('http://127.0.0.1:' + H + '/' + tag + '/import.js'); res.importScripts = 'REACHED'; } catch (e) { res.importScripts = 'blocked ' + e.name; }
      }
      if (typeof navigator !== 'undefined' && typeof navigator.sendBeacon === 'function') {
        try { res.beacon = 'queued ' + navigator.sendBeacon('http://127.0.0.1:' + H + '/' + tag + '/beacon', 'x'); } catch (e) { res.beacon = 'threw ' + e.name; }
      }
      if (typeof document !== 'undefined' && typeof Image === 'function') {
        const a = new Image(); a.src = 'http://127.0.0.1:' + H + '/' + tag + '/img';
        const b = new Image(); b.src = 'http://linenprobe-' + tag + '-img.local/x';
      }
      await Promise.race([Promise.all(jobs), wait(4500)]);
      done(res);
    }
    """
}

final class EventBox {
    var events: [String] = []
}
