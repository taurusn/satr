// Linen's renderer harness: hosts Renderer/page.html in an offscreen WKWebView the way the app does (served from
// linen-app://renderer), and either renders one file to a PNG or runs the structural checks over a corpus.
//
//   harness shot <file.md> <out.png> [--night] [--width 1180] [--height 900] [--outline] [--rtl] [--full]
//   harness corpus <folder>...            prints counts and paths only, never note text
//   harness reload <file.md>              rewrites a temp copy and checks the reading line holds (LIVE-4)
//   harness checks [group] [--compare-old] bounded work, marks, holds, places, find and announcements (SAFE-5,
//                                         LIVE-3 to LIVE-5, OPEN-3, READ-3, LOOK-4, SAFE-2), on generated text
//                                         and Tests/Fixtures; --compare-old also measures the old diff's memory
import AppKit
import Darwin
import UniformTypeIdentifiers
import WebKit

let args = Array(CommandLine.arguments.dropFirst())
let rendererDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Renderer")

func flag(_ name: String) -> Bool { args.contains(name) }
func value(_ name: String, _ fallback: Double) -> Double {
    if let i = args.firstIndex(of: name), i + 1 < args.count, let v = Double(args[i + 1]) { return v }
    return fallback
}

final class AppScheme: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let rel = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        let file = rendererDir.appendingPathComponent(rel).standardizedFileURL
        guard file.path.hasPrefix(rendererDir.standardizedFileURL.path), let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)"])!)
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

final class LocalScheme: NSObject, WKURLSchemeHandler {
    var base = URL(fileURLWithPath: "/")
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let rel = comps.path.removingPercentEncoding.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 } ?? ""
        let file = base.appendingPathComponent(rel)
        guard let data = try? Data(contentsOf: file) else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime])!)
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

@MainActor
final class Host: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let web: WKWebView
    let window: NSWindow
    let local = LocalScheme()
    var messages: [[String: Any]] = []
    var answerOutside = false // checks mode: image requests naming "outside" come back as outside the vault
    var lastSplit = ""
    var consoleErrors: [String] = []
    var waiters: [(String, CheckedContinuation<[String: Any], Never>)] = []

    init(width: Double, height: Double) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(AppScheme(), forURLScheme: "linen-app")
        config.setURLSchemeHandler(local, forURLScheme: "linen-local")
        window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: config)
        super.init()
        config.userContentController.add(self, name: "linen")
        config.userContentController.add(self, name: "console")
        config.userContentController.addUserScript(WKUserScript(source: """
          window.addEventListener('error', e => webkit.messageHandlers.console.postMessage('error: ' + e.message + ' @' + (e.filename||'') + ':' + (e.lineno||'')));
          window.addEventListener('securitypolicyviolation', e => webkit.messageHandlers.console.postMessage('csp: ' + e.violatedDirective + ' ' + e.blockedURI));
          const ce = console.error; console.error = (...a) => { webkit.messageHandlers.console.postMessage('console: ' + a.map(String).join(' ').slice(0, 300)); ce(...a); };
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        window.contentView = web
        window.orderBack(nil)
    }

    nonisolated func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        let name = m.name
        let body = m.body
        MainActor.assumeIsolated {
            if name == "console" { consoleErrors.append("\(body)"); return }
            guard let msg = body as? [String: Any], let type = msg["type"] as? String else { return }
            messages.append(msg)
            if type == "imageInfo", let reqs = msg["requests"] as? [String] {
                var map: [String: Any] = [:]
                for r in reqs where r.hasPrefix("path:") { map[r] = ["status": "ok", "url": "linen-local://asset/" + (String(r.dropFirst(5)).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")] }
                for r in reqs where answerOutside && r.contains("outside") { map[r] = ["status": "outside", "label": "outside.png"] }
                Task { _ = try? await self.send(["type": "imageInfo", "map": map]) }
            }
            // A message goes to a waiter or stays queued, never both, so a later wait cannot see a stale one.
            if let i = waiters.firstIndex(where: { $0.0 == type }) { messages.removeLast(); waiters.remove(at: i).1.resume(returning: msg) }
        }
    }

    func wait(for type: String, timeout: Double = 20) async -> [String: Any] {
        if let i = messages.firstIndex(where: { $0["type"] as? String == type }) { return messages.remove(at: i) }
        return await withCheckedContinuation { cont in
            waiters.append((type, cont))
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                MainActor.assumeIsolated {
                    if let i = self.waiters.firstIndex(where: { $0.0 == type }) { self.waiters.remove(at: i).1.resume(returning: ["type": "timeout"]) }
                }
            }
        }
    }

    func open() async {
        web.load(URLRequest(url: URL(string: "linen-app://renderer/page.html")!))
        _ = await wait(for: "ready")
    }

    /// Lets the page and its WebContent process go (checks mode starts each group in a fresh one).
    func retire() {
        window.orderOut(nil)
        web.configuration.userContentController.removeAllScriptMessageHandlers()
        window.contentView = nil
    }

    @discardableResult
    func send(_ msg: [String: Any]) async throws -> Any? {
        try await web.callAsyncJavaScript("return await window.linen.receive(msg)", arguments: ["msg": msg], contentWorld: .page)
    }

    func js(_ code: String) async -> Any? { try? await web.callAsyncJavaScript(code, arguments: [:], contentWorld: .page) }

    func load(_ file: URL, version: Int = 1, place: [String: Any]? = nil) async throws -> Double {
        let data = try Data(contentsOf: file)
        let text = String(decoding: data, as: UTF8.self)
        local.base = file.deletingLastPathComponent()
        messages.removeAll { ($0["type"] as? String) == "rendered" || ($0["type"] as? String) == "firstPaint" }
        var msg: [String: Any] = ["type": "load", "docId": "t\(version)", "name": file.lastPathComponent, "path": file.path, "text": text,
                                  "plain": file.pathExtension.lowercased() == "txt", "version": version, "meta": ["modified": "14:02"]]
        if let place { msg["place"] = place }
        let t0 = CFAbsoluteTimeGetCurrent()
        Task { _ = try? await self.send(msg) }
        let fp = await wait(for: "firstPaint", timeout: 8)
        let first = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        lastSplit = "lex \(fp["lexMs"] ?? "?") ms, paint \(fp["paintMs"] ?? "?") ms"
        _ = await wait(for: "rendered", timeout: 8)
        return first
    }

    func snapshot(to path: String, full: Bool) async {
        if full, let h = await js("return document.documentElement.scrollHeight") as? Double {
            web.frame.size.height = min(h, 16000)
            try? await Task.sleep(for: .milliseconds(400))
        }
        try? await Task.sleep(for: .milliseconds(300))
        let cfg = WKSnapshotConfiguration()
        let img = try? await web.takeSnapshot(configuration: cfg)
        if let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}

let structuralChecks = """
const doc = document.getElementById('doc');
const out = { raw: [], overflow: 0, mathPrices: 0, blocks: doc.children.length };
const walker = document.createTreeWalker(doc, NodeFilter.SHOW_TEXT, { acceptNode(n) { return n.parentElement.closest('pre, code, .katex, .render-failed, [hidden], .blk.pre') ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT; } });
let text = ''; while (walker.nextNode()) text += walker.currentNode.nodeValue + '\\n';
for (const [name, re] of [['wikilink', /\\[\\[[^\\]\\n]+\\]\\]/], ['highlight', /==\\S[^=\\n]*\\S==/], ['callout', /^\\s*\\[![A-Za-z]+\\]/m], ['blockmath', /\\$\\$/], ['comment', /%%[^%\\n]+%%/]]) if (re.test(text)) out.raw.push(name);
const colRight = doc.getBoundingClientRect().right + 2;
out.what = [];
doc.querySelectorAll(':scope > .blk:not(.wide) *').forEach(n => { const r = n.getBoundingClientRect(); if (r.width && r.right > colRight + 40 && !n.closest('.table-wrap, pre, .katex-display')) { out.overflow++; if (out.what.length < 2) out.what.push(n.tagName + '.' + n.className + ' w=' + Math.round(r.width)); } });
doc.querySelectorAll('.katex').forEach(k => { const p = k.closest('p, li, td'); if (p && /\\$\\s?\\d/.test(p.textContent)) out.mathPrices++; });
return out;
"""

// MARK: checks

/// The WebContent process's memory footprint now and its peak so far, in MB.
func footprint(_ web: WKWebView) -> (now: Double, peak: Double) {
    guard let pid = (web.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, pid > 0 else { return (-1, -1) }
    var info = rusage_info_v4()
    let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) } }
    return r == 0 ? (Double(info.ri_phys_footprint) / 1e6, Double(info.ri_lifetime_max_phys_footprint) / 1e6) : (-1, -1)
}

@MainActor
final class Checks {
    var host: Host
    var passed = 0, failed = 0
    init(_ host: Host) { self.host = host }

    func check(_ name: String, _ pass: Bool, _ detail: String = "") {
        if pass { passed += 1 } else { failed += 1 }
        print("\(pass ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : ": \(detail)")")
    }
    func js(_ code: String) async -> Any? { await host.js(code) }
    func num(_ code: String) async -> Double { (await js(code) as? NSNumber)?.doubleValue ?? -1 }
    func str(_ code: String) async -> String { await js(code) as? String ?? "" }
    func sleep(_ s: Double) async { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }

    @discardableResult
    func load(_ text: String, _ extra: [String: Any] = [:]) async -> (ms: Double, lex: Double) {
        host.messages.removeAll()
        var msg: [String: Any] = ["type": "load", "docId": "check", "name": "check.md", "path": "/tmp/check.md", "text": text, "plain": false, "version": 1, "meta": [:]]
        for (k, v) in extra { msg[k] = v }
        let t0 = CFAbsoluteTimeGetCurrent()
        Task { _ = try? await host.send(msg) }
        let fp = await host.wait(for: "firstPaint", timeout: 120)
        _ = await host.wait(for: "rendered", timeout: 120)
        return ((CFAbsoluteTimeGetCurrent() - t0) * 1000, (fp["lexMs"] as? NSNumber)?.doubleValue ?? -1)
    }
    @discardableResult
    func update(_ text: String, inBurst: Bool = false, wait: Bool = true) async -> Double {
        let t0 = CFAbsoluteTimeGetCurrent()
        Task { _ = try? await host.send(["type": "update", "text": text, "inBurst": inBurst, "version": 2]) }
        if wait { _ = await host.wait(for: "reloaded", timeout: 120) } else { await sleep(0.05) }
        return (CFAbsoluteTimeGetCurrent() - t0) * 1000
    }
    func send(_ msg: [String: Any]) async { _ = try? await host.send(msg) }
    var lastBaseline: [String]? { host.messages.last { $0["type"] as? String == "baseline" }?["hashes"] as? [String] }
    func blockCount() async -> Int { Int(await num("return document.querySelectorAll('#doc > .blk[data-h]').length")) }
    func hashes() async -> [String] { await js("return [...document.querySelectorAll('#doc > .blk[data-h]')].map(e => e.dataset.h)") as? [String] ?? [] }
    func paragraphs(_ n: Int, _ word: String) -> String { (0..<n).map { "\(word) paragraph number \($0) with a few words." }.joined(separator: "\n\n") }

    func run(compareOld: Bool, only: String?) async {
        // Each group runs in a fresh page, so one group's memory and late messages never reach the next.
        func want(_ group: String) async -> Bool {
            guard only == nil || group.contains(only!) else { return false }
            host.retire()
            host = Host(width: 1180, height: 900)
            await host.open()
            return true
        }
        var r = (ms: 0.0, lex: 0.0), plain = 0.0, note = "", n = 0
        if await want("SAFE-5 size") {
            // SAFE-5: over 20 MB opens as plain text, decided before anything is posted to the worker.
            let unit = "# Heading\n\nA paragraph with **bold** and a [[wiki link]], repeated to make a large file.\n\n"
            let big = String(repeating: unit, count: 21 * 1024 * 1024 / unit.utf8.count + 1)
            r = await load(big)
            plain = await num("return document.querySelectorAll('#doc pre.plain').length")
            let heads = await num("return document.querySelectorAll('#doc h1, #doc h2').length")
            note = await str("return document.getElementById('banner').hidden ? '' : document.getElementById('banner').textContent")
            check("21 MB ASCII document opens as plain text", plain > 0 && heads == 0 && note.contains("too large"), String(format: "%.1f MB, %d plain blocks, first paint %.0f ms (parse %.0f ms)", Double(big.utf8.count) / 1048576, Int(plain), r.ms, r.lex))
            let arabic = String(repeating: "سطر ", count: 3_000_000) // 12M UTF-16 units, 21 MB of UTF-8
            r = await load(arabic)
            plain = await num("return document.querySelectorAll('#doc pre.plain').length")
            note = await str("return document.getElementById('banner').textContent")
            check("21 MB of Arabic (12M characters) is counted in bytes and opens as plain", plain > 0 && note.contains("too large"), String(format: "%.1f MB, first paint %.0f ms (parse %.0f ms)", Double(arabic.utf8.count) / 1048576, r.ms, r.lex))
            let under = String(repeating: "سطر ", count: 2_000_000) // 14 MB of UTF-8: stays Markdown (one giant paragraph, shown as 16 KB pieces)
            r = await load(under)
            note = await str("return document.getElementById('banner').hidden ? '' : document.getElementById('banner').textContent")
            check("14 MB of Arabic stays under the limit", !note.contains("too large"), String(format: "first paint %.0f ms (parse %.0f ms)", r.ms, r.lex))

        }
        if await want("SAFE-5 tokens") {
            // SAFE-5: the token cap is checked while lexing.
            // Long paragraphs dense with emphasis (about 900 tokens each): 300 of them pass the cap, and 600 must stop at
            // the same point rather than lex to the end.
            let para = (0..<300).map { "w\($0) *e\($0)*" }.joined(separator: " ")
            let t300 = Array(repeating: para, count: 300).joined(separator: "\n\n"), t600 = Array(repeating: para, count: 600).joined(separator: "\n\n")
            let r300 = await load(t300)
            let r600 = await load(t600)
            plain = await num("return document.querySelectorAll('#doc pre.plain').length")
            note = await str("return document.getElementById('banner').textContent")
            check("over 200,000 tokens fails to plain text, stopping where the cap is crossed", plain > 0 && note.contains("too large") && r600.lex < r300.lex * 1.5, String(format: "1 MB parse %.0f ms, 2 MB parse %.0f ms (a full parse would take about twice as long), first paint %.0f ms", r300.lex, r600.lex, r600.ms))

        }
        if await want("SAFE-5 caps") {
            // SAFE-5: at most 10,000 blocks and 200,000 elements.
            r = await load(paragraphs(12000, "Block"))
            n = await blockCount()
            note = await str("const n = document.getElementById('notice'); return n.hidden ? '' : n.textContent")
            check("12,000 blocks stop at 10,000 with a notice", n == 10000 && note.contains("10,000"), String(format: "%d blocks, rendered in %.0f ms", n, r.ms))
            let html = (0..<40).map { _ in "<div>" + String(repeating: "<i>x</i>", count: 6000) + "</div>" }.joined(separator: "\n\n")
            r = await load(html)
            n = await blockCount()
            let elements = Int(await num("return document.querySelectorAll('#doc *').length"))
            note = await str("const n = document.getElementById('notice'); return n.hidden ? '' : n.textContent")
            check("240,000 elements stop under 200,000 with a notice", elements <= 200_000 && n < 40 && note.contains("first \(n) blocks"), "\(n) of 40 blocks, \(elements) elements")

        }
        if await want("SAFE-5 nesting") {
            // SAFE-5: nesting past 100 levels is flattened (Tests/Fixtures/Deep Nesting.md).
            let deepURL = rendererDir.deletingLastPathComponent().appendingPathComponent("Tests/Fixtures/Deep Nesting.md")
            host.consoleErrors.removeAll()
            r = await load((try? String(contentsOf: deepURL, encoding: .utf8)) ?? "")
            let depth = Int(await num("let max = 0; const walk = (n, d) => { if (d > max) max = d; for (const c of n.children) walk(c, d + 1); }; walk(document.getElementById('doc'), 0); return max"))
            let texts = await num("const t = document.getElementById('doc').textContent; return ['Quote at level 150', 'List level 150', 'Mixed at level 240', 'Five thousand quotes deep', 'Emphasis at the centre', 'The end of the fixture'].filter(s => t.includes(s)).length")
            check("150-level nesting renders flattened, without hanging", r.ms < 3000 && depth <= 220 && texts == 6 && host.consoleErrors.isEmpty, String(format: "first paint %.0f ms, deepest element %d levels under the page, %d of 6 texts kept, console %@", r.ms, depth, Int(texts), host.consoleErrors.isEmpty ? "clean" : host.consoleErrors.prefix(2).joined(separator: " | ")))

        }
        if await want("LIVE-4 diff memory") {
            // LIVE-4: the diff stays linear in memory for 10,000 replaced blocks, measured in a fresh WebContent process
            // so the peak is the diff's own.
            let inputs = "window.__a = Array.from({length: 10000}, (_, i) => 'a' + i); window.__b = Array.from({length: 10000}, (_, i) => 'b' + i); return 0"
            let freshPage = Host(width: 1180, height: 900)
            await freshPage.open()
            _ = await freshPage.js(inputs)
            await sleep(1)
            let before = footprint(freshPage.web)
            let diffMs = (await freshPage.js("const t0 = performance.now(); window.__keep = LinenDiff.diff(window.__a, window.__b); return performance.now() - t0") as? NSNumber)?.doubleValue ?? -1
            let after = footprint(freshPage.web)
            freshPage.retire()
            check("10,000 replaced hashes diff in bounded memory", diffMs >= 0 && diffMs < 500 && after.peak - before.peak < 20, String(format: "%.0f ms; peak footprint %.0f MB to %.0f MB (+%.1f MB)", diffMs, before.peak, after.peak, after.peak - before.peak))
            if compareOld {
                // The replaced trace-of-vectors Myers, once, in its own fresh process.
                let oldPage = Host(width: 1180, height: 900)
                await oldPage.open()
                _ = await oldPage.js(inputs)
                await sleep(1)
                let o0 = footprint(oldPage.web)
                let oldMs = (await oldPage.js("""
                  function myers(A, B, maxD) { const N = A.length, M = B.length; const max = N + M, off = max; const V = new Int32Array(2 * max + 2); const trace = [];
                    for (let d = 0; d <= Math.min(max, maxD); d++) { trace.push(V.slice()); for (let k = -d; k <= d; k += 2) { let x = (k === -d || (k !== d && V[off + k - 1] < V[off + k + 1])) ? V[off + k + 1] : V[off + k - 1] + 1; let y = x - k; while (x < N && y < M && A[x] === B[y]) { x++; y++; } V[off + k] = x; if (x >= N && y >= M) return trace; } } return trace; }
                  const t0 = performance.now(); window.__keep = myers(window.__a, window.__b, 4000); return performance.now() - t0
                """) as? NSNumber)?.doubleValue ?? -1
                let o1 = footprint(oldPage.web)
                oldPage.retire()
                print(String(format: "      for comparison, the old diff on the same input: %.0f ms; peak footprint %.0f MB to %.0f MB (+%.0f MB)", oldMs, o0.peak, o1.peak, o1.peak - o0.peak))
            }
            await load(paragraphs(10000, "Old"))
            let replaceMs = await update(paragraphs(10000, "Fresh"))
            n = await blockCount()
            let fresh = await num("return document.querySelector('#doc > .blk p') && document.querySelector('#doc > .blk p').textContent.startsWith('Fresh') ? 1 : 0")
            check("a reload replacing 10,000 blocks completes", n == 10000 && fresh == 1, String(format: "%.0f ms, most of it lexing 10,000 short paragraphs", replaceMs))
        }
        if await want("LIVE-4 pairing") {
            // LIVE-4: edited pairing uses word multisets and half of both blocks.
            let pairing = await js("""
              const blk = (raw) => ({ kind: 'md', token: { type: 'paragraph', raw } });
              const words = (n) => Array.from({ length: n }, (_, i) => 'w' + i).join(' ');
              const p = (a, b) => LinenDiff.pairEdited([blk(a)], [blk(b)], []).size;
              return [p('alpha', 'alpha ' + words(99)), p(words(10), words(8) + ' extra more fresh words'), p('a a a a b', 'a c d e f'), p('a a b c', 'a a b d')];
            """) as? [Int] ?? []
            check("edited pairing: one word inside a 100-word block is not an edit; 8 of 10 and 8 of 12 is; repeats count once each", pairing == [0, 1, 0, 1], "\(pairing), expected [0, 1, 0, 1]")
            // A block inserted before an edit does not hide the edit (Codex verification, new defect 2).
            let shifted = await js("""
              const blk = (raw) => ({ kind: 'md', token: { type: 'paragraph', raw } });
              const words = (n) => Array.from({ length: n }, (_, i) => 'w' + i).join(' ');
              const m = LinenDiff.pairEdited([blk(words(10))], [blk('a different inserted paragraph'), blk(words(9) + ' changed')], []);
              return m.has(0) ? m.get(0) : -1;
            """) as? Int ?? -2
            check("edited pairing looks past an inserted block: old A pairs with A' after a new X", shifted == 1, "paired with \(shifted), expected 1")

        }
        if await want("LIVE-5 marks") {
            // LIVE-5: no baseline (Quick Look) shows no marks and no notice.
            let v0 = ["# Marks", "Alpha paragraph.", "Same words here.", "Removed paragraph X.", "Beta paragraph.", "Gamma paragraph.", "Delta paragraph."]
            await load((v0 + (0..<60).map { "Filler paragraph \($0) to push the end below the window." } + ["Tail paragraph Y.", "Last paragraph Z."]).joined(separator: "\n\n"))
            var marks = await num("return document.querySelectorAll('#doc > .blk.chg, #doc > .gap').length")
            let bannerHidden = await num("return document.getElementById('banner').hidden ? 1 : 0")
            check("no baseline: no marks, no notice", marks == 0 && bannerHidden == 1)
            let base0 = lastBaseline ?? []
            check("first sight posts the whole sequence as the baseline", base0.count == 69, "\(base0.count) hashes")
            // v1 repeats "Same words here." (one new occurrence) and drops X near the top and Y near the end.
            let v1 = ["# Marks", "Alpha paragraph.", "Same words here.", "Same words here.", "Beta paragraph.", "Gamma paragraph.", "Delta paragraph."] + (0..<60).map { "Filler paragraph \($0) to push the end below the window." } + ["Last paragraph Z."]
            let v1Text = v1.joined(separator: "\n\n")
            host.messages.removeAll()
            await load(v1Text, ["baseline": base0])
            marks = await num("return document.querySelectorAll('#doc > .blk.chg').length")
            let gaps = await js("return [...document.querySelectorAll('#doc > .gap')].map(g => [g.previousElementSibling ? g.previousElementSibling.textContent.trim() : '', g.dataset.removed.split(',').length])") as? [[Any]] ?? []
            let gapAfter = gaps.map { ($0.first as? String) ?? "" }
            check("a repeated block is marked once, and gaps sit where the removed blocks were", marks == 1 && gapAfter.count == 2 && gapAfter[0].hasPrefix("Same words") && gapAfter[1].hasPrefix("Filler paragraph 59"), "\(Int(marks)) marked, gaps after \(gapAfter.map { String($0.prefix(22)) })")
            await sleep(3.8)
            let acked = lastBaseline ?? []
            let cur = await hashes()
            marks = await num("return document.querySelectorAll('#doc > .blk.chg').length")
            let idxY = base0.firstIndex(of: base0[base0.count - 2]) ?? -1
            let yHash = base0[base0.count - 2], xHash = base0[3]
            let yAt = acked.firstIndex(of: yHash) ?? -1
            check("after 3 s on screen: the visible mark and gap are read, repeats kept, the unseen gap keeps its place", marks == 0 && acked.count == cur.count + 1 && !acked.contains(xHash) && yAt == acked.count - 2 && acked.filter { $0 == base0[2] }.count == 2, "posted \(acked.count) hashes for \(cur.count) blocks, removed Y at \(yAt) of \(acked.count) (was \(idxY) of \(base0.count))")
            await update(v1Text)
            marks = await num("return document.querySelectorAll('#doc > .blk.chg').length")
            let gapsLeft = await num("return document.querySelectorAll('#doc > .gap').length")
            await update(v1Text + "\n\nAppended after the read.")
            let marked2 = await js("return [...document.querySelectorAll('#doc > .blk.chg')].map(e => e.textContent.trim())") as? [String] ?? []
            check("reloads after the acknowledgement bring no marks back", marks == 0 && gapsLeft == 1 && marked2 == ["Appended after the read."], "first reload \(Int(marks)) marks and \(Int(gapsLeft)) gap; second reload marks \(marked2)")
            host.messages.removeAll()
            let rewritten = (0..<12).map { "Entirely new paragraph \($0)." }.joined(separator: "\n\n")
            await load(rewritten, ["baseline": cur, "baselineDate": "3 October"])
            let saidRewritten = await str("return document.getElementById('banner').textContent")
            let early = lastBaseline
            await sleep(3.8)
            check("the rewritten line waits 3 s on screen before it counts as read", saidRewritten.contains("3 October") && early == nil && lastBaseline?.count == 12, "baseline posted at once: \(early != nil), after 3 s: \(lastBaseline?.count ?? 0) hashes")

        }
        if await want("LIVE-5 tall") {
            // LIVE-5: a block taller than twice the window is acknowledged.
            let tall = (0..<400).map { "Line \($0) of one very tall paragraph" }.joined(separator: " ")
            await load(["# Tall", "Short opener.", tall, "After."].joined(separator: "\n\n"))
            let tallBase = lastBaseline ?? []
            host.messages.removeAll()
            await load(["# Tall", "Short opener.", tall + " changed", "After."].joined(separator: "\n\n"), ["baseline": tallBase])
            let tallH = await num("const e = document.querySelector('#doc > .blk.chg'); return e ? e.getBoundingClientRect().height / innerHeight : 0")
            _ = await js("const e = document.querySelector('#doc > .blk.chg'); window.scrollTo(0, e.getBoundingClientRect().top + scrollY + 200); return 0")
            await send(["type": "focus", "key": true])
            await sleep(3.8)
            let tallLeft = await num("return document.querySelectorAll('#doc > .blk.chg').length")
            check("a block over twice the window's height is acknowledged", tallH > 2 && tallLeft == 0, String(format: "block %.1f windows tall", tallH))

        }
        if await want("LIVE-3 hold") {
            // LIVE-3: degraded reads wait for their quiet, in or out of a burst.
            await load(paragraphs(10, "Kept"))
            await update("", inBurst: false, wait: false)
            await sleep(0.4)
            let heldCount = await blockCount()
            await send(["type": "quiet"])
            await sleep(0.2)
            let afterQuiet = await blockCount()
            await load(paragraphs(10, "Kept"))
            await update("", inBurst: false, wait: false)
            await sleep(0.2)
            await update(paragraphs(11, "Kept"))
            await send(["type": "quiet"])
            await sleep(0.2)
            let replaced = await blockCount()
            check("an empty read outside a burst waits for quiet; a later good read replaces it", heldCount == 10 && afterQuiet == 0 && replaced == 11, "held \(heldCount), after quiet \(afterQuiet), replaced \(replaced)")
            // Small files are held too: four blocks truncated to one wait for quiet (Codex verification, finding 13).
            await load(paragraphs(4, "Small"))
            await update(paragraphs(1, "Small"), inBurst: false, wait: false)
            await sleep(0.4)
            let smallHeld = await blockCount()
            await send(["type": "quiet"])
            await sleep(0.2)
            let smallAfter = await blockCount()
            check("a four-block file cut to one block waits for quiet", smallHeld == 4 && smallAfter == 1, "held \(smallHeld), after quiet \(smallAfter)")
            // A live rewrite of most of the page shows the one rewritten line, not a wall of marks (finding f).
            await load(paragraphs(10, "Original"))
            await sleep(0.2)
            await update(paragraphs(10, "Rewritten"))
            await sleep(0.2)
            let liveMarks = await num("return document.querySelectorAll('#doc > .blk.chg, #doc > .gap').length")
            let liveLine = await num("return document.querySelector('#banner [data-k=\"rewritten\"]') ? 1 : 0")
            check("a live update that changes over half the page shows the rewritten line instead of marks", liveMarks == 0 && liveLine == 1, "\(Int(liveMarks)) marks, rewritten line \(Int(liveLine))")

        }
        if await want("SAFE-5 cancel") {
            // SAFE-5: a load while a long parse runs ends that parse.
            let slow = String(repeating: "## Section\n\nSome *emphasis*, a [link](https://example.com) and `code` in a paragraph.\n\n- item one\n- item two\n\n", count: 30000)
            host.messages.removeAll()
            Task { _ = try? await host.send(["type": "load", "docId": "slow", "name": "slow.md", "path": "/tmp/slow.md", "text": slow, "plain": false, "version": 1, "meta": [:]]) }
            await sleep(0.15)
            let t0 = CFAbsoluteTimeGetCurrent()
            Task { _ = try? await host.send(["type": "load", "docId": "small", "name": "small.md", "path": "/tmp/small.md", "text": "# Small\n\nThe newer document.", "plain": false, "version": 2, "meta": [:]]) }
            _ = await host.wait(for: "rendered", timeout: 60)
            let smallMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            await sleep(4)
            let shown = await str("return document.getElementById('note-title').textContent")
            let renderTitles = host.messages.filter { $0["type"] as? String == "rendered" }.map { "\($0["title"] ?? "")" }
            let renders = renderTitles.count
            check("a newer load cancels the running parse", smallMs < 800 && shown == "Small" && renders == 0, String(format: "%.1f MB parse superseded; newer document rendered in %.0f ms; title %@; other renders %@", Double(slow.utf8.count) / 1048576, smallMs, shown, renderTitles.joined(separator: ", ")))

        }
        if await want("OPEN-3 places") {
            // OPEN-3, LIVE-4: places return to the nearest repeat, render through a missing index, and use qoff.
            let repeated = (0..<300).map { $0 % 3 == 0 ? "Repeated paragraph." : "Paragraph \($0) with its own words." }.joined(separator: "\n\n")
            await load(repeated)
            let rep = await js("return [...document.querySelectorAll('#doc > .blk')].map(e => e.dataset.h)") as? [String] ?? []
            await load(repeated, ["place": ["hash": rep.count > 150 ? rep[150] : "", "index": 151, "offset": 0, "quote": "Repeated"]])
            var at = (try? await host.web.callAsyncJavaScript("return await window.linen.receive({type:'command', name:'place'})", arguments: [:], contentWorld: .page)) as? [String: Any]
            check("a repeated hash returns to the occurrence nearest the stored index", (at?["index"] as? NSNumber)?.intValue == 150, "index \(at?["index"] ?? "none"), wanted 150")
            let shortParas = (0..<300).map { "Short paragraph \($0)." }.joined(separator: "\n\n")
            await load(shortParas)
            let sp = await hashes()
            // In a window 1,800 px tall, the 20 blocks rendered past the place cannot fill the screen below it.
            let tallWindow = Host(width: 1180, height: 1800)
            await tallWindow.open()
            Task { _ = try? await tallWindow.send(["type": "load", "docId": "tall", "name": "tall.md", "path": "/tmp/tall.md", "text": shortParas, "plain": false, "version": 1, "meta": [:],
                                                    "place": ["hash": sp.count > 120 ? sp[120] : "", "index": 120, "offset": 0, "quote": "Short paragraph 120."]]) }
            let firstY = await tallWindow.wait(for: "firstPaint", timeout: 30)
            _ = await tallWindow.wait(for: "rendered", timeout: 30)
            _ = firstY
            at = (try? await tallWindow.web.callAsyncJavaScript("return await window.linen.receive({type:'command', name:'place'})", arguments: [:], contentWorld: .page)) as? [String: Any]
            let clampedFirst = (await tallWindow.js("return document.documentElement.scrollHeight") as? NSNumber)?.doubleValue ?? 0
            tallWindow.retire()
            check("a place the first screen cannot reach is restored as the rest arrives", (at?["index"] as? NSNumber)?.intValue == 120, "index \(at?["index"] ?? "none"), wanted 120; page \(Int(clampedFirst)) px tall")
            host.consoleErrors.removeAll()
            await load(repeated, ["place": ["hash": "gone", "index": 200, "offset": 4, "quote": "nothing like this"]])
            at = (try? await host.web.callAsyncJavaScript("return await window.linen.receive({type:'command', name:'place'})", arguments: [:], contentWorld: .page)) as? [String: Any]
            check("a missing hash renders through its stored index", host.consoleErrors.isEmpty && (at?["index"] as? NSNumber)?.intValue == 200, "index \(at?["index"] ?? "none"), console \(host.consoleErrors.isEmpty ? "clean" : host.consoleErrors[0])")
            let phrase = "the phrase that appears twice in this block"
            let long = "Opening words. " + phrase + ". " + String(repeating: "Middle sentence that fills the block with text. ", count: 80) + phrase + ". Closing words."
            let filler = (0..<40).map { "Filler \($0) after the long block." }
            await load((["# Quote", "Intro.", long, "After."] + filler).joined(separator: "\n\n"))
            let qoff = long.distance(from: long.startIndex, to: long.range(of: phrase, options: .backwards)!.lowerBound)
            await load((["# Quote", "Intro.", long + " Edited.", "After."] + filler).joined(separator: "\n\n"), ["place": ["hash": "edited", "index": 2, "offset": 10, "quote": String(phrase.prefix(40)), "qoff": qoff]])
            at = (try? await host.web.callAsyncJavaScript("return await window.linen.receive({type:'command', name:'place'})", arguments: [:], contentWorld: .page)) as? [String: Any]
            let gotOff = (at?["qoff"] as? NSNumber)?.intValue ?? -1
            check("a repeated quote is told apart by its saved offset", abs(gotOff - qoff) < 120, "reading line at character \(gotOff), the second phrase starts at \(qoff)")

        }
        if await want("LOOK-4 announce") {
            // LOOK-4: one announcement per settled reload.
            await load(paragraphs(8, "Said"))
            await update(paragraphs(8, "Said").replacingOccurrences(of: "number 2 ", with: "number two ").replacingOccurrences(of: "number 5 ", with: "number five ") + "\n\nOne more at the end.")
            await sleep(0.3)
            let said = await str("return document.getElementById('status').textContent")
            let settled = paragraphs(8, "Said").replacingOccurrences(of: "number 2 ", with: "number two ").replacingOccurrences(of: "number 5 ", with: "number five ") + "\n\nOne more at the end."
            await update(settled + "\n\nBurst one.", inBurst: true)
            await update(settled + "\n\nBurst one.\n\nBurst two.", inBurst: true)
            await sleep(0.3)
            let duringBurst = await str("return document.getElementById('status').textContent")
            await send(["type": "quiet"])
            await sleep(0.3)
            let afterBurst = await str("return document.getElementById('status').textContent")
            await update(settled + "\n\nBurst one.\n\nBurst two.\n\nA single addition.")
            await sleep(0.3)
            let single = await str("return document.getElementById('status').textContent")
            let regions = await num("return document.querySelectorAll('#doc[aria-live], #pane[aria-live], #shell[aria-live], article[aria-live]').length")
            check("a settled reload is announced once, in a hidden status line", said == "Updated, 3 changes" && duringBurst == said && afterBurst == "Updated, 2 changes" && single == "Updated, 1 change" && regions == 0, "\(said) / during the burst: \(duringBurst) / at quiet: \(afterBurst) / then: \(single)")

        }
        if await want("SAFE-2 outside") {
            // SAFE-2: allowing an outside image names that image.
            host.answerOutside = true
            await load("# Images\n\n![one](../outside/one.png)\n\n![two](../elsewhere/outside-two.png)")
            await sleep(0.3)
            host.messages.removeAll()
            _ = await js("document.querySelectorAll('#doc .blocked button')[1].click(); return 0")
            await sleep(0.2)
            let allow = host.messages.first { $0["type"] as? String == "allowOutside" }
            host.answerOutside = false
            check("Allow this file posts that image's request", allow?["request"] as? String == "path:../elsewhere/outside-two.png", "\(allow ?? [:])")

        }
        if await want("READ-3 fold") {
            // READ-3: Arabic folding follows the setting and the find bar's option.
            await load("# بحث\n\nكتب مُحَمَّد رسالة إلى أحمد، ثم قرأها محمد مرة أخرى.")
            let count = { () async -> Int in Int(await self.num("return document.querySelectorAll('mark.find.cur').length ? document.querySelectorAll('mark.find').length : 0")) }
            _ = await js("document.getElementById('find-input').value = 'محمد'; return window.linen.receive({type:'command', name:'find'})")
            await sleep(0.1)
            let folded = await count()
            await send(["type": "settings", "foldArabic": false])
            let exact = await count()
            host.messages.removeAll()
            _ = await js("document.getElementById('find-fold').click(); return 0")
            let toggled = await count()
            let setting = host.messages.first { $0["type"] as? String == "setting" }
            let visible = await num("return document.getElementById('find-fold').hidden ? 0 : 1")
            check("Arabic folding: on by default, off by setting, back on from the find bar", folded == 2 && exact == 1 && toggled == 2 && setting?["key"] as? String == "foldArabic" && setting?["value"] as? Bool == true && visible == 1, "matches \(folded), \(exact), \(toggled); posted \(setting ?? [:])")
            _ = await js("return window.linen.receive({type:'command', name:'find'}).then(() => document.getElementById('find-done').click())")


        }
        print("checks \(passed + failed), passed \(passed), failed \(failed); console: \(host.consoleErrors.isEmpty ? "clean" : host.consoleErrors.prefix(3).joined(separator: " | "))")
    }
}

@MainActor
func main() async {
    guard let mode = args.first else { print("usage: harness shot|corpus|reload|checks ..."); exit(2) }
    let host = Host(width: value("--width", 1180), height: value("--height", 900))
    await host.open()
    switch mode {
    case "shot":
        let file = URL(fileURLWithPath: args[1])
        try? await host.send(["type": "settings", "theme": flag("--night") ? "night" : "paper", "uiDir": flag("--rtl") ? "rtl" : "ltr"])
        let first = (try? await host.load(file)) ?? -1
        if flag("--outline") { try? await host.send(["type": "command", "name": "outline", "show": true]) }
        if let q = args.firstIndex(of: "--find"), q + 1 < args.count { _ = await host.js("document.getElementById('find-input').value = \(String(reflecting: args[q + 1])); return window.linen.receive({type:'command', name:'find'})") }
        await host.snapshot(to: args[2], full: flag("--full"))
        print(String(format: "first paint %.0f ms (%@); console: %@", first, host.lastSplit, host.consoleErrors.isEmpty ? "clean" : host.consoleErrors.joined(separator: " | ")))
    case "corpus":
        var files: [URL] = []
        for root in args.dropFirst() {
            let e = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            while let u = e?.nextObject() as? URL {
                if u.path.contains("/node_modules/") || u.path.contains("/build/") || u.path.contains("/.build/") { continue }
                if ["md", "markdown"].contains(u.pathExtension.lowercased()) { files.append(u) }
            }
        }
        var times: [Double] = [], problems: [String] = []
        for f in files {
            host.consoleErrors.removeAll()
            let tf = CFAbsoluteTimeGetCurrent()
            guard let first = try? await host.load(f) else { problems.append("unreadable \(f.path)"); continue }
            let total = (CFAbsoluteTimeGetCurrent() - tf) * 1000
            FileHandle.standardError.write(Data(String(format: "%6.0f %6.0f %@\n", first, total, f.path).utf8))
            times.append(first)
            let r = await host.js(structuralChecks) as? [String: Any] ?? [:]
            let raw = r["raw"] as? [String] ?? []
            let overflow = r["overflow"] as? Int ?? 0
            let prices = r["mathPrices"] as? Int ?? 0
            if !raw.isEmpty || overflow > 0 || prices > 0 || !host.consoleErrors.isEmpty {
                problems.append("\(f.path): raw=\(raw) overflow=\(overflow) \(r["what"] ?? "") mathOnPrices=\(prices) console=\(host.consoleErrors.prefix(2))")
            }
        }
        times.sort()
        func p(_ q: Double) -> Double { times.isEmpty ? 0 : times[min(times.count - 1, Int(Double(times.count) * q))] }
        print("files \(files.count)  with problems \(problems.count)")
        print(String(format: "first paint ms  p50 %.0f  p95 %.0f  max %.0f", p(0.5), p(0.95), times.last ?? 0))
        for pr in problems.prefix(40) { print("  " + pr) }
    case "reload":
        let src = URL(fileURLWithPath: args[1])
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("linen-reload-\(UUID().uuidString).md")
        try? FileManager.default.copyItem(at: src, to: tmp)
        _ = try? await host.load(tmp)
        _ = await host.js("window.scrollTo(0, document.documentElement.scrollHeight * 0.45); return 0")
        try? await Task.sleep(for: .milliseconds(300))
        var text = (try? String(contentsOf: tmp, encoding: .utf8)) ?? ""
        var worst = 0.0, failures = 0
        for i in 0..<30 {
            let place = (try? await host.web.callAsyncJavaScript("return await window.linen.receive({type:'command', name:'place'})", arguments: [:], contentWorld: .page)) as? [String: Any]
            let anchorHash = place?["hash"] as? String ?? ""
            let anchorTop = place?["top"] as? Double ?? 0
            let before = await host.js("const b = document.elementFromPoint(innerWidth/2, 64); const r = document.caretRangeFromPoint(innerWidth/2, 64); return r ? [r.startContainer.nodeValue ? r.startContainer.nodeValue.slice(r.startOffset, r.startOffset + 30) : '', r.getBoundingClientRect().top] : ['', 0]") as? [Any]
            var lines = text.components(separatedBy: "\n")
            // Insert above and below the reading point, and edit far away.
            lines.insert("Inserted paragraph \(i) above the reader, with a few words to give it height.", at: min(lines.count, 4 + i % 7))
            lines.insert("", at: min(lines.count, 5 + i % 7))
            lines.append("Appended line \(i).")
            text = lines.joined(separator: "\n")
            try? text.write(to: tmp, atomically: true, encoding: .utf8)
            host.messages.removeAll()
            Task { _ = try? await host.send(["type": "update", "text": text, "inBurst": false, "version": i + 2]) }
            let t0 = CFAbsoluteTimeGetCurrent(); let r = await host.wait(for: "reloaded", timeout: 15); let dt = (CFAbsoluteTimeGetCurrent() - t0) * 1000; if dt > 400 { print("  step \(i): reload took \(Int(dt)) ms") }
            if (r["type"] as? String) == "timeout" { print("  step \(i): no reload; console: \(host.consoleErrors.suffix(3))"); if i > 2 { break } }
            let after = await host.js("const r = document.caretRangeFromPoint(innerWidth/2, 64); return r ? [r.startContainer.nodeValue ? r.startContainer.nodeValue.slice(r.startOffset, r.startOffset + 30) : '', r.getBoundingClientRect().top] : ['', 0]") as? [Any]
            let newTop = await host.js("const e = document.querySelector('[data-h=\"\(anchorHash)\"]'); return e ? e.getBoundingClientRect().top : -99999") as? Double ?? -99999
            if abs(newTop - anchorTop) > 1 { print("  step \(i): anchor block moved \(Int(newTop - anchorTop)) px (\(newTop == -99999 ? "gone" : "kept"))") }
            let q0 = before?.first as? String ?? "", q1 = after?.first as? String ?? ""
            let y0 = before?.last as? Double ?? 0, y1 = after?.last as? Double ?? 0
            worst = max(worst, abs(y1 - y0))
            if q0 != q1 { failures += 1; print("  step \(i): line moved from \(String(reflecting: String(q0.prefix(20)))) to \(String(reflecting: String(q1.prefix(20))))") }
        }
        print("reload steps 30, line changed \(failures) times, worst vertical drift \(Int(worst)) px; console: \(host.consoleErrors.isEmpty ? "clean" : host.consoleErrors.prefix(3).joined(separator: " | "))")
        try? FileManager.default.removeItem(at: tmp)
    case "checks":
        await Checks(host).run(compareOld: flag("--compare-old"), only: args.count > 1 && !args[1].hasPrefix("--") ? args[1] : nil)
    default:
        print("unknown mode")
    }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in await main() }
app.run()
