// pagehost: drives Linen/Pages' SealedPageController outside the app, the way a tab hosts it.
//
//   pagehost inventory <out.txt>                 the PAGE-10 inventory for this Mac's WebKit build (walked twice, compared)
//   pagehost selftest <inventory.txt>            the full self-test against that inventory, timed
//   pagehost shot <page.html> <out.png> [--width 1176] [--height 900] [--night] [--unsealed] [--full]
//                                                sealed with scripts on (or plain WebKit from file: with --unsealed)
//   pagehost stress                               PAGE-12: an endless loop and an endless allocation beside a live page
//   pagehost reload <page.html>                  PAGE-5: scroll, rewrite the file, reload, report where the view landed
//
//   swiftc -swift-version 6 -parse-as-library -o build/pagehost docs/spikes/pages/pagehost.swift Linen/Pages/*.swift \
//     Linen/Document/Schemes.swift Linen/Document/SafeOpen.swift Linen/System/Log.swift Linen/App/TrustedFolders.swift Linen/Design/Tokens.swift \
//     -framework AppKit -framework WebKit
import AppKit
import WebKit

@main
struct PageHost {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            let code = await Host().run(Array(CommandLine.arguments.dropFirst()))
            exit(code)
        }
        app.run()
    }
}

@MainActor
final class Host {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    lazy var kit = KitScheme(css: repo.appendingPathComponent("Linen/Pages/Kit/loom.css"),
                             fonts: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Fonts"))

    func run(_ a: [String]) async -> Int32 {
        PageSelfTest.inventoryOverride = repo.appendingPathComponent("Linen/Pages/Inventory")
        guard let cmd = a.first else { print("usage: pagehost inventory|selftest|shot|stress|reload ..."); return 2 }
        switch cmd {
        case "inventory": return await inventory(a)
        case "selftest": return await selftest(a)
        case "selftest-negative": return await negative(a)
        case "preflight-negative": return await preflightNegative(a)
        case "shot": return await shot(a)
        case "stress": return await stress()
        case "reload": return await reload(a)
        default: print("unknown command"); return 2
        }
    }

    func value(_ a: [String], _ name: String, _ d: Double) -> Double {
        if let i = a.firstIndex(of: name), i + 1 < a.count, let v = Double(a[i + 1]) { return v }
        return d
    }

    // MARK: inventory, selftest

    func inventory(_ a: [String]) async -> Int32 {
        guard a.count >= 2 else { return 2 }
        let t0 = Date()
        guard let one = await PageSelfTest.shared.inventoryText(), let two = await PageSelfTest.shared.inventoryText() else { print("walk failed"); return 3 }
        let body = { (s: String) in s.split(separator: "\n").filter { !$0.hasPrefix("#") } }
        print("walked twice in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s; identical: \(body(one) == body(two))")
        let parsed = PageSelfTest.parse(one)
        for r in PageSelfTest.realms { print("  \(r): \(parsed[r]?.count ?? 0) lines\(parsed[r]?.first.map { $0.hasPrefix("!") || $0 == "absent" ? " (\($0))" : "" } ?? "")") }
        try? one.write(toFile: a[1], atomically: true, encoding: .utf8)
        return body(one) == body(two) ? 0 : 1
    }

    func selftest(_ a: [String]) async -> Int32 {
        let inv = a.count >= 2 ? URL(fileURLWithPath: a[1]) : nil
        let t0 = Date()
        let s = await PageSelfTest.shared.run(inventory: inv)
        print("self-test: \(s) in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s; block reason now: \(PageSelfTest.shared.blockReason ?? "none")")
        return s == .passed ? 0 : 1
    }

    /// PRD-2 section 13's self-test cases: each must turn scripts off with the line saying why.
    func negative(_ a: [String]) async -> Int32 {
        guard a.count >= 2 else { return 2 }
        let inv = URL(fileURLWithPath: a[1])
        let t = PageSelfTest.shared
        var code: Int32 = 0
        let cases: [(String, PageSelfTest.TestHooks, URL?)] = [
            ("unknown WebKit build", .init(), URL(fileURLWithPath: "/var/empty/webkit-0.0.txt")),
            ("an innocently named global", .init(injection: "window.linenHelper = function () {};"), inv),
            ("an extra prototype method", .init(injection: "Element.prototype.sendHome = function () {};"), inv),
            ("an accessor", .init(injection: "Object.defineProperty(Document.prototype, 'homeAddress', {get() { return 1; }, configurable: true});"), inv),
            ("an instance-owned property on navigator", .init(injection: "Object.defineProperty(navigator, 'phoneHome', {value: () => 1});"), inv),
            ("one escape at the witness", .init(sealedOptions: .open), inv),
            ("a capability granted (confirm says yes), with the inventory unchanged", .init(injection: "window.confirm = () => true;"), inv),
            ("a realm that cannot start (Worker throws)", .init(injection: "window.Worker = function () { throw new Error('no'); };"), inv),
            ("a witness that is down", .init(deadWitness: true), inv),
            ("a probe that times out", .init(hang: true), inv),
        ]
        for (name, hooks, file) in cases {
            t.hooks = hooks
            let t0 = Date()
            let s = await t.run(inventory: file)
            let off = t.blockReason != nil
            if s == .passed || !off { code = 1 }
            print("\(s == .passed || !off ? "FAIL" : "ok  ") \(name): \(t.blockReason ?? "no line") (\(String(format: "%.1f", Date().timeIntervalSince(t0))) s)")
        }
        // A method on the prototype of an interface that is not a global, reached only through an instance: the
        // reference inventory comes from a build where StorageManager is not a global; the test build adds a method.
        let hide = "delete window.StorageManager;"
        t.hooks = .init(injection: hide)
        if let base = await t.inventoryText() {
            let f = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("inventory-hidden.txt")
            try? base.write(to: f, atomically: true, encoding: .utf8)
            t.hooks = .init(injection: hide)
            let same = await t.run(inventory: f)
            t.hooks = .init(injection: hide + " Object.getPrototypeOf(navigator.storage).leak = function () {};")
            let s = await t.run(inventory: f)
            let ok = same == .passed && s != .passed
            if !ok { code = 1 }
            print("\(ok ? "ok  " : "FAIL") a method on a prototype not exposed as a global: control \(same), with the method: \(t.blockReason ?? "no line")")
        } else { code = 1; print("FAIL could not build the hidden-global inventory") }
        t.hooks = .init()
        let clean = await t.run(inventory: inv)
        print("\(clean == .passed ? "ok  " : "FAIL") the reviewed build passes cleanly afterwards")
        return clean == .passed ? code : 1
    }

    /// A tab whose rule list or removal script did not install must show its source, never run the page.
    func preflightNegative(_ a: [String]) async -> Int32 {
        guard a.count >= 2 else { return 2 }
        let page = URL(fileURLWithPath: a[1]).standardizedFileURL
        PagePolicy.setPerFile(page, true)
        var code: Int32 = 0
        for wall in ["none", "rules", "removal"] {
            let c = SealedPageController(url: page, theme: "paper", kit: kit)
            if wall != "none" { c.testDropWall = wall }
            var events: [String] = []
            var line: String?
            c.onEvent = { events.append($0) }
            c.onStateLine = { line = $0 }
            var served: [String] = []
            let win = window(900, 600, onScreen: false)
            win.contentViewController = c
            c.scheme.onRequest = { u, ok, why in if ok { served.append(String(u.split(separator: "/").last ?? "")) } }
            try? await Task.sleep(for: .seconds(4))
            let authorServed = served.contains(page.lastPathComponent)
            let ok = wall == "none" ? authorServed : (!authorServed && events.contains { $0.hasPrefix("preflight failed") })
            if !ok { code = 1 }
            print("\(ok ? "ok  " : "FAIL") wall left out: \(wall); author page served: \(authorServed); \(events.filter { $0.hasPrefix("preflight") }.joined(separator: ", ")); line: \(line ?? "-")")
            c.close()
            win.contentViewController = nil
            win.orderOut(nil)
        }
        return code
    }

    // MARK: shot

    func window(_ w: Double, _ h: Double, onScreen: Bool) -> NSWindow {
        let win = NSWindow(contentRect: NSRect(x: onScreen ? 60 : -30000, y: onScreen ? 60 : -30000, width: w, height: h), styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.orderFrontRegardless()
        return win
    }

    func shot(_ a: [String]) async -> Int32 {
        guard a.count >= 3 else { return 2 }
        let page = URL(fileURLWithPath: a[1]).standardizedFileURL, out = URL(fileURLWithPath: a[2])
        let w = value(a, "--width", 1176), h = value(a, "--height", 900)
        let win = window(w, h, onScreen: false)
        let web: WKWebView
        var events: [String] = []
        var controller: SealedPageController?
        if a.contains("--unsealed") {
            let v = WKWebView(frame: NSRect(x: 0, y: 0, width: w, height: h))
            win.contentView = v
            v.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
            web = v
        } else {
            PagePolicy.setPerFile(page, true)
            let c = SealedPageController(url: page, theme: a.contains("--night") ? "night" : "paper", kit: kit)
            c.onEvent = { events.append($0) }
            c.scheme.onRequest = { u, served, why in if !served { events.append("refused \(u.suffix(60)) \(why)") } }
            win.contentViewController = c
            win.setContentSize(NSSize(width: w, height: h))
            controller = c
            var waited = 0
            while c.web == nil && waited < 50 { try? await Task.sleep(for: .milliseconds(100)); waited += 1 }
            guard let v = c.web else { print("no web view"); return 3 }
            web = v
        }
        try? await Task.sleep(for: .seconds(4))
        let conf = WKSnapshotConfiguration()
        if a.contains("--full"), let hgt = try? await web.evaluateJavaScript("document.documentElement.scrollHeight") as? Double {
            let full = min(hgt, 12000) + (controller != nil && web.frame.minY > 0 ? 0 : 0)
            win.setContentSize(NSSize(width: w, height: full + (controller == nil ? 0 : (win.contentView!.bounds.height - web.bounds.height))))
            try? await Task.sleep(for: .seconds(1.5))
            conf.rect = CGRect(x: 0, y: 0, width: w, height: full)
        }
        guard let img = try? await web.takeSnapshot(configuration: conf), let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { print("snapshot failed"); return 3 }
        try? png.write(to: out)
        let errs = (try? await web.evaluateJavaScript("document.title")) as? String ?? "?"
        print("shot \(out.lastPathComponent) title \"\(errs)\" scripts \(controller?.scriptsOn.description ?? "unsealed") events \(events.joined(separator: " | "))")
        return 0
    }

    // MARK: stress (PAGE-12)

    func stress() async -> Int32 {
        let dir = repo.appendingPathComponent("build/pagehost-stress")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pages = [
            "live.html": "<!doctype html><title>live</title><pre id=t>0</pre><script>let n = 0; setInterval(() => { document.getElementById('t').textContent = ++n; }, 100);</script>",
            "loop.html": "<!doctype html><title>loop</title><p>looping</p><script>setTimeout(() => { for (;;) {} }, 500);</script>",
            "alloc.html": "<!doctype html><title>alloc</title><p id=p>allocating</p><script>const keep = []; setTimeout(function grow() { try { for (let i = 0; i < 16; i++) keep.push(new Float64Array(1 << 20).fill(i)); document.getElementById('p').textContent = (keep.length * 8) + ' MB'; setTimeout(grow, 0); } catch (e) { document.getElementById('p').textContent = 'stopped at ' + (keep.length * 8) + ' MB: ' + e.name; } }, 500);</script>",
        ]
        for (name, text) in pages { try? text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let live = SealedPageController(url: dir.appendingPathComponent("live.html"), theme: "paper", kit: kit)
        PagePolicy.setPerFile(dir.appendingPathComponent("live.html"), true)
        let lw = window(500, 300, onScreen: false)
        lw.contentViewController = live
        var code: Int32 = 0
        for bad in ["loop.html", "alloc.html"] {
            let url = dir.appendingPathComponent(bad)
            PagePolicy.setPerFile(url, true)
            let c = SealedPageController(url: url, theme: "paper", kit: kit)
            var log: [(Date, String)] = []
            var line: String?
            c.onEvent = { log.append((Date(), $0)) }
            c.onStateLine = { line = $0; if let l = $0 { log.append((Date(), "line: \(l)")) } }
            var loaded: Date?
            c.onFinish = { if loaded == nil { loaded = Date() } }
            let bw = window(500, 300, onScreen: false)
            bw.contentViewController = c
            let t0 = Date()
            var oldPID: Int32?
            var stalledAt: Double?, recoveredAt: Double?, liveMax = 0.0
            var stopped = false
            while Date().timeIntervalSince(t0) < 25 {
                let p0 = Date()
                _ = await live.evaluateInKit("return 1")
                liveMax = max(liveMax, Date().timeIntervalSince(p0))
                // Time from when the page started misbehaving (500 ms after it loaded).
                let t = Date().timeIntervalSince(loaded.map { $0.addingTimeInterval(0.5) } ?? t0)
                if oldPID == nil, let w = c.web, w.responds(to: Selector(("_webProcessIdentifier"))) { let n = (w.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value ?? 0; if n > 0 { oldPID = n } }
                if stalledAt == nil, log.contains(where: { $0.1 == "stalled" || $0.1.hasPrefix("web content ended") || $0.1.hasPrefix("over memory") }) {
                    stalledAt = t
                    if log.contains(where: { $0.1 == "stalled" }) { c.stopPage(); stopped = true }
                }
                if stalledAt != nil, recoveredAt == nil, !c.scriptsOn, c.web != nil {
                    if (await c.evaluateInKit("return 1")) as? Int == 1 { recoveredAt = t }
                }
                if recoveredAt != nil { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
            let alive = oldPID.map { kill($0, 0) == 0 }
            print("  \(bad) first web content process \(oldPID.map(String.init) ?? "?") still running after recovery: \(alive.map(String.init) ?? "?")")
            let progress = await c.evaluateInKit("const p = document.getElementById('p'); return p ? p.textContent : ''") as? String ?? "?"
            print("  \(bad) page says: \(progress); pid \(c.web.map { $0.responds(to: Selector(("_webProcessIdentifier"))) ? "\($0.value(forKey: "_webProcessIdentifier") ?? "?")" : "?" } ?? "gone")")
            let ok = (stalledAt.map { $0 <= 6 } ?? false) && (recoveredAt.map { $0 <= 10 } ?? false)
                && oldPID != nil && kill(oldPID ?? 0, 0) != 0 && liveMax < 0.1
            if !ok { code = 1 }
            print("\(bad): first sign \(stalledAt.map { String(format: "%.1f s", $0) } ?? "never") (\(log.first(where: { $0.1 == "stalled" || $0.1.hasPrefix("web content ended") || $0.1.hasPrefix("over memory") })?.1 ?? "-")), stopped \(stopped), scripts-off page answering at \(recoveredAt.map { String(format: "%.1f s", $0) } ?? "never"), live tab slowest answer \(String(format: "%.0f ms", liveMax * 1000)), line \(line ?? "-") \(ok ? "PASS" : "FAIL")")
            bw.contentViewController = nil
            bw.orderOut(nil)
        }
        return code
    }

    // MARK: reload (PAGE-5)

    func reload(_ a: [String]) async -> Int32 {
        guard a.count >= 2 else { return 2 }
        let src = URL(fileURLWithPath: a[1])
        let dir = repo.appendingPathComponent("build/pagehost-reload")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let page = dir.appendingPathComponent("page.html")
        var sections = (1...60).map { "<h2 id=\"s\($0)\">Section \($0)</h2><p>" + String(repeating: "Body text. ", count: 40) + "</p>" }
        try? ("<!doctype html><title>reload</title>" + sections.joined()).write(to: page, atomically: true, encoding: .utf8)
        _ = src
        PagePolicy.setPerFile(page, true)
        let c = SealedPageController(url: page, theme: "paper", kit: kit)
        let win = window(900, 700, onScreen: false)
        win.contentViewController = c
        try? await Task.sleep(for: .seconds(2))
        _ = await c.evaluateInKit("document.getElementById('s30').scrollIntoView(); return 1")
        let before = await c.evaluateInKit("const r = document.getElementById('s30').getBoundingClientRect(); return r.top")
        // An agent adds text above the reading point.
        sections.insert("<h2 id=\"new\">Inserted</h2><p>" + String(repeating: "New text. ", count: 200) + "</p>", at: 5)
        try? ("<!doctype html><title>reload</title>" + sections.joined()).write(to: page, atomically: true, encoding: .utf8)
        c.reload()
        try? await Task.sleep(for: .seconds(2))
        let after = await c.evaluateInKit("const r = document.getElementById('s30').getBoundingClientRect(); return r.top")
        print("section 30 top before \(String(describing: before)) after \(String(describing: after)) (holding by the nearest element with an id)")
        return 0
    }
}
