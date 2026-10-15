// Linen 2 blocks host (Lane F): hosts Renderer/page.html in an offscreen WKWebView the way the app does, and checks
// Loom blocks, words and notes in notes (PRD-2 BLK, WORDS, NOTE) on Tests/Fixtures/blocks.
//
//   blocks-host checks                 structure, note cards, the line command, check(), Arabic, layouts, Night
//   blocks-host shots <out-dir>        every fixture at 1176 and 390 px in Paper and Night, full height
//
// Build: swiftc -swift-version 5 -O -o build/blocks-host Tests/Harness/blocks-host.swift -framework AppKit -framework WebKit
import AppKit
import UniformTypeIdentifiers
import WebKit

let args = Array(CommandLine.arguments.dropFirst())
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let rendererDir = root.appendingPathComponent("Renderer")
let fixtures = root.appendingPathComponent("Tests/Fixtures/blocks")

final class AppScheme: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let rel = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        var file = rendererDir.appendingPathComponent(rel).standardizedFileURL
        // Fonts live in ~/Library/Fonts in development (copy-renderer.sh copies them into the app).
        if rel.hasPrefix("fonts/") { file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Fonts").appendingPathComponent(String(rel.dropFirst(6))) }
        guard let data = try? Data(contentsOf: file) else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)"])!)
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

@MainActor
final class Host: NSObject, WKScriptMessageHandler {
    let web: WKWebView
    let window: NSWindow
    var messages: [[String: Any]] = []
    var consoleErrors: [String] = []
    var waiters: [(String, CheckedContinuation<[String: Any], Never>)] = []

    init(width: Double, height: Double) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(AppScheme(), forURLScheme: "linen-app")
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
        MainActor.assumeIsolated {
            if m.name == "console" { consoleErrors.append("\(m.body)"); return }
            guard let msg = m.body as? [String: Any], let type = msg["type"] as? String else { return }
            if type == "imageInfo" || type == "resolveLinks" { return }
            if let i = waiters.firstIndex(where: { $0.0 == type }) { waiters.remove(at: i).1.resume(returning: msg); return }
            messages.append(msg)
        }
    }

    func wait(for type: String, timeout: Double = 15) async -> [String: Any] {
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

    @discardableResult
    func send(_ msg: [String: Any]) async -> Any? {
        try? await web.callAsyncJavaScript("return await window.linen.receive(msg)", arguments: ["msg": msg], contentWorld: .page)
    }

    func js(_ code: String) async -> Any? {
        do { return try await web.callAsyncJavaScript(code, arguments: [:], contentWorld: .page) } catch { return "JSERR \(error)" }
    }

    func settings(theme: String, lang: String = "en") async {
        await send(["type": "settings", "theme": theme, "face": "sans", "uiDir": lang == "ar" ? "rtl" : "ltr", "lang": lang, "contrast": false, "foldArabic": true])
    }

    func load(_ name: String) async {
        let file = fixtures.appendingPathComponent(name)
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let sidecar = try? String(contentsOf: URL(fileURLWithPath: file.path + ".notes.json"), encoding: .utf8)
        messages.removeAll()
        Task { await self.send(["type": "load", "docId": name, "name": name, "path": file.path, "text": text, "plain": false, "version": 1, "meta": ["modified": "14:02"], "sidecar": sidecar ?? NSNull()]) }
        _ = await wait(for: "rendered")
        try? await Task.sleep(for: .milliseconds(250))
    }

    func resize(_ width: Double, _ height: Double) async {
        window.setContentSize(NSSize(width: width, height: height))
        web.frame = NSRect(x: 0, y: 0, width: width, height: height)
        try? await Task.sleep(for: .milliseconds(250))
    }

    func snapshot(to path: String) async {
        if let h = await js("return document.documentElement.scrollHeight") as? Double {
            let w = web.frame.width
            web.frame.size.height = min(h + 40, 9000)
            window.setContentSize(NSSize(width: w, height: web.frame.size.height))
            try? await Task.sleep(for: .milliseconds(500))
        }
        let img = try? await web.takeSnapshot(configuration: WKSnapshotConfiguration())
        if let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}

@MainActor
final class Checks {
    let host: Host
    var passed = 0, failed = 0
    init(_ host: Host) { self.host = host }
    func check(_ name: String, _ pass: Bool, _ detail: Any = "") {
        if pass { passed += 1 } else { failed += 1 }
        let d = "\(detail)"
        print("\(pass ? "PASS" : "FAIL")  \(name)\(d.isEmpty ? "" : ": \(d)")")
    }
    func num(_ code: String) async -> Double { (await host.js(code) as? NSNumber)?.doubleValue ?? -1 }
    func str(_ code: String) async -> String { "\(await host.js(code) ?? "nil")" }

    func run() async {
        await host.settings(theme: "paper")
        for f in ["blocks.md", "arabic.md", "wide.md", "sheet.md", "broken.md"] {
            host.consoleErrors.removeAll()
            await host.load(f)
            check("\(f) renders with no console errors", host.consoleErrors.isEmpty, host.consoleErrors.prefix(3).joined(separator: " | "))
        }

        await host.load("blocks.md")
        check("two tiles blocks, seven tiles", await str("return [document.querySelectorAll('.lb-tiles').length, document.querySelectorAll('.lt').length].join()") == "2,7")
        check("tiles take four columns at 1176", await num("return getComputedStyle(document.querySelector('.lb-tiles')).gridTemplateColumns.split(' ').length") == 4)
        check("bar has five segments, rust for Broken", await str("return [document.querySelectorAll('.lb-bar .bs').length, document.querySelectorAll('.lb-bar .bs.s-rust').length].join()") == "5,1")
        let hiddenText = await num("return [...document.querySelectorAll('.lb-bar .bs-t')].filter(t => t.hidden).length")
        let keyShown = await num("return [...document.querySelectorAll('.lb-bar .bk')].filter(k => !k.hidden).length")
        check("bar: words that do not fit move to the key, and only those", hiddenText == keyShown, "hidden in bar \(Int(hiddenText)), in key \(Int(keyShown))")
        check("steps: four chevrons, the second current", await str("return [...document.querySelectorAll('.lb-steps .ls')].map(l => l.className.split(' ')[1]).join(',')") == "past,cur,todo,todo")
        check("level: 3 of 6 threads in ink", await str("return [document.querySelectorAll('.lb-level .th.done').length, document.querySelectorAll('.lb-level .th').length].join()") == "3,6")
        check("count: 12 of 37", await str("return document.querySelector('.lb-count .lv-n').textContent") == "12 of 37")
        check("cards: six, every tone", await str("return [...document.querySelectorAll('.lc')].map(c => c.className.match(/tone-(\\w+)/)[1]).join(',')") == "paper,tint,ink,dashed,sticky,paper")
        check("cards: three across goes wide", await num("return document.querySelector('[data-lblk=cards]').classList.contains('wide') ? 1 : 0") == 1)
        check("cards: the link renders as a wiki link", await num("return document.querySelectorAll('.lc-link a.wl').length") == 1)
        check("table: rows anchored by {#id}", await str("return [document.querySelectorAll('tr#r-form, tr#r-approve').length, document.querySelector('tr#r-form td').textContent.trim()].join()") == "2,Request form")
        check("table: verdict marks, braces gone", await str("return [document.querySelectorAll('.lb-v.v-good').length, document.querySelectorAll('.lb-v.v-bad').length, document.querySelector('#doc table').textContent.includes('{')].join()") == "1,1,false")
        check("words: pills with shapes; the quiet word plain", await str("return document.querySelectorAll('.lw.s-rust').length >= 2 && document.querySelectorAll('.lw.quiet').length >= 2") == "1")
        check("words: the Broken tile shows its swatch with the label", await num("return document.querySelectorAll('.lt .lb-sw.s-rust').length") == 1)
        check("header: eyebrow and lead from linen:", await str("return document.getElementById('eyebrow').textContent + '|' + document.getElementById('note-lead').textContent.slice(0, 18)") == "ReadinessOctober|Where the requests")
        check("blocks follow their text's direction (ltr)", await str("return document.querySelector('[data-lblk=tiles]').getAttribute('dir')") == "ltr")

        // Note cards (BLK-1, NOTE-1): beside or below the block holding the mark, never over it.
        func hover(_ selector: String) async -> String {
            await host.js("LinenBlocks.close(); const t = document.querySelector(\"\(selector)\"); t.scrollIntoView({block:'center'}); t.dispatchEvent(new MouseEvent('mouseover', {bubbles: true})); return true")
            try? await Task.sleep(for: .milliseconds(420))
            return await str("""
              const c = document.querySelector('.lnote-card'); if (!c || c.hidden) return 'closed';
              const t = document.querySelector("\(selector)"); const b = t.closest('.blk').getBoundingClientRect(), r = c.getBoundingClientRect();
              const over = !(r.right <= b.left + 1 || r.left >= b.right - 1 || r.bottom <= b.top + 1 || r.top >= b.bottom - 1);
              return (over ? 'OVER ' : 'clear ') + (r.left >= b.right ? 'beside ' : r.top >= b.bottom ? 'below ' : 'other ') + c.textContent.slice(0, 300);
            """)
        }
        let fn = await hover("sup.fnref a")
        check("footnote card opens after 300 ms, beside the block, not over it", fn.hasPrefix("clear beside") && fn.contains("403"), fn)
        let nt = await hover(".lnote[data-note=n-approve]")
        check("note term opens its sidecar note with title, state and sources", nt.hasPrefix("clear") && nt.contains("Every decision is refused") && nt.contains("server/approvals.py:118"), nt)
        let tl = await hover("[data-lnote=n-broken]")
        check("noted tile opens its note", tl.hasPrefix("clear") && tl.contains("Ten broken boxes"), tl)
        await host.js("document.dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape'})); return true")
        check("Esc closes the card", await str("const c = document.querySelector('.lnote-card'); return c && !c.hidden ? 'open' : 'closed'") == "closed")
        check("noted items are marked", await num("return document.querySelectorAll('.noted[data-lnote]').length") == 2)
        check("print sources: one list with the sidecar notes, numbered after the footnotes", await str("return [...document.querySelectorAll('.lnotes-blk li')].map(l => l.value).join(',')") == "3,4,5")

        // The line command (CLI-6).
        let line = await num("""
          const src = document.querySelector('[data-lblk=bar]'); const l = Number(src.dataset.l.split('-')[0]) + 2;
          await window.linen.receive({type: 'command', name: 'line', line: l});
          return Math.round(src.getBoundingClientRect().top);
        """)
        check("line command puts the block holding that line on the reading line", abs(line - 64) <= 2, "top \(Int(line))")

        // Phone width: tiles two across, the card a sheet.
        await host.resize(390, 844)
        check("390 px: four tiles wrap to two across", await num("return getComputedStyle(document.querySelector('.lb-tiles')).gridTemplateColumns.split(' ').length") == 2)
        check("390 px: cards wrap to at most two across", await num("return getComputedStyle(document.querySelector('.lb-cards')).gridTemplateColumns.split(' ').length") <= 2)
        // R5: on a phone the card goes below the block holding the mark, never over it, with the mark still in view.
        let narrow = await str("""
          LinenBlocks.close(); const t = document.querySelector('sup.fnref a'); t.scrollIntoView({block: 'end'}); scrollBy(0, 0);
          t.dispatchEvent(new MouseEvent('mouseover', {bubbles: true})); await new Promise(r => setTimeout(r, 420));
          const c = document.querySelector('.lnote-card'); if (!c || c.hidden) return 'closed';
          const b = t.closest('.blk').getBoundingClientRect(), r = c.getBoundingClientRect(), m = t.getBoundingClientRect();
          const over = !(r.bottom <= b.top + 1 || r.top >= b.bottom - 1);
          return [over ? 'OVER' : 'clear', getComputedStyle(c).position, m.top >= 0 && m.bottom <= innerHeight ? 'mark-visible' : 'mark-hidden', Math.round(r.width) <= Math.round(b.width) ? 'fits' : 'wider'].join(',');
        """)
        check("R5 390 px: the note opens below its block, not over it, the mark in view", narrow == "clear,absolute,mark-visible,fits", narrow)
        await host.resize(1176, 900)

        // Broken blocks (principle 6): the source and the problem in place; check() lists everything.
        await host.load("broken.md")
        check("broken YAML shows its source and the problem in place", await str("return document.querySelectorAll('.lb-failed').length + '|' + document.querySelector('.lb-failed').textContent.includes('line 20')") == "3|true", await str("return [...document.querySelectorAll('.lb-failed b')].map(b => b.textContent).join(' / ')"))
        check("R8 a card with an unknown tone fails in place, as check() reports it", await str("return [...document.querySelectorAll('.lb-failed b')].some(b => b.textContent.includes('tone must be one of'))") == "1")
        let checked = await str("""
          const text = `\((try? String(contentsOf: fixtures.appendingPathComponent("broken.md"), encoding: .utf8))?.replacingOccurrences(of: "`", with: "\\`") ?? "")`;
          return JSON.stringify(LinenBlocks.check(text).map(p => p.severity[0] + p.line + ' ' + p.message.slice(0, 40)));
        """)
        check("check() finds the bad layout, seven words, the YAML line, unknown keys, a bad tone and count", ["layout must be", "7 words", "tiles:", "colour", "tone must", "number count", "Eight"].allSatisfy { checked.contains($0) }, checked)

        // Arabic (ARB-1, BRD-27 for blocks): right to left, Arabic pills, the interface's digits.
        await host.load("arabic.md")
        // R11: the steps strip itself runs right to left (its chevrons point left), not only its block.
        check("R11 Arabic chevrons point left", await str("return getComputedStyle(document.querySelector('.lb-steps .ls:first-child')).clipPath").contains("11px 0px, 100% 0px, 100% 100%"), await str("return getComputedStyle(document.querySelector('.lb-steps .ls:first-child')).clipPath"))
        // R12: a table row anchored by an Arabic id.
        check("R12 an Arabic {#id} anchors its row and leaves the cell", await str("return [document.getElementById('مرحلة') ? 'row' : 'none', document.querySelector('#doc table').textContent.includes('{#') ? 'braces' : 'clean'].join()") == "row,clean")
        check("Arabic blocks run right to left", await str("return [...document.querySelectorAll('[data-lblk]')].map(b => b.getAttribute('dir')).join(',')") == "rtl,rtl,rtl,rtl")
        check("Arabic pills drop letter spacing", await num("return document.querySelectorAll('.lw.ar').length") >= 1)
        check("Arabic words keep their shapes", await num("return document.querySelectorAll('.lb-bar .bs.s-rust, .lb-bar .bs.s-threads').length") == 2)
        await host.settings(theme: "paper", lang: "ar")
        await host.load("blocks.md")
        let arCount = await str("return document.querySelector('.lb-count .lv-n').textContent")
        check("Arabic interface: counts in Arabic digits", arCount == "١٢ من ٣٧", arCount)
        await host.settings(theme: "paper", lang: "en")

        // Layouts (BLK-0).
        await host.resize(1440, 900)
        await host.load("wide.md")
        let wideCards = await num("return document.querySelector('[data-lblk=cards]').getBoundingClientRect().width")
        let prose = await num("return document.querySelector('#doc > .blk p').getBoundingClientRect().width")
        check("wide: blocks take the page, prose keeps its measure", wideCards > 1000 && prose <= 580, "cards \(Int(wideCards)), prose \(Int(prose))")
        await host.load("sheet.md")
        let side = await str("""
          const s = document.querySelector('.blk.side').getBoundingClientRect(); const p = document.querySelector('#doc > .blk:not(.side) p').getBoundingClientRect();
          return [getComputedStyle(document.querySelector('.blk.side')).float, Math.round(s.left - p.right), Math.round(s.width)].join(',');
        """)
        check("sheet: side blocks float into the side column beside the prose", (side.hasPrefix("right,") || side.hasPrefix("inline-end,")) && (Int(side.split(separator: ",")[1]) ?? -1) >= 40 && side.hasSuffix(",320"), side)
        await host.resize(800, 900)
        check("sheet on a narrow window: side blocks fall into the column", await str("return getComputedStyle(document.querySelector('.blk.side')).float") == "none")
        await host.resize(1176, 900)

        // Night: shapes in ink, rust with an ink hairline (WORDS-2).
        await host.settings(theme: "night")
        await host.load("blocks.md")
        check("Night: rust pill gains the ink (light) hairline", await str("return getComputedStyle(document.querySelector('.lw.s-rust')).borderTopColor") == "rgb(246, 243, 235)")
        check("Night: Partial threads draw in light ink", await str("return getComputedStyle(document.querySelector('.bs.s-threads')).backgroundImage").contains("246, 243, 235"))
        await host.settings(theme: "paper")

        // A reload keeps blocks and re-dresses words when the vocabulary changes.
        let text = (try? String(contentsOf: fixtures.appendingPathComponent("blocks.md"), encoding: .utf8)) ?? ""
        let changed = text.replacingOccurrences(of: "linen:\n", with: "linen:\n  words:\n    - {word: Broken, shape: solid}\n    - {word: Works, shape: outline, quiet: true}\n")
        await host.send(["type": "update", "text": changed, "inBurst": false, "version": 2, "sidecar": (try? String(contentsOf: fixtures.appendingPathComponent("blocks.md.notes.json"), encoding: .utf8)) ?? NSNull()])
        _ = await host.wait(for: "reloaded")
        check("reload: a changed vocabulary re-dresses kept blocks", await str("return document.querySelectorAll('.lw.s-solid').length >= 2 && document.querySelectorAll('.lw.s-rust').length === 0") == "1")
        // R1: kept blocks follow the document: swatches after a word changes shape, width after the layout changes,
        // footnote numbers after a reference is inserted before them.
        check("R1 kept tiles redraw their swatches for the new word", await str("return [document.querySelectorAll('.lt .lb-sw.s-solid').length, document.querySelectorAll('.lb-sw.s-rust').length].join()") == "1,0", await str("return [...document.querySelectorAll('.lb-sw')].map(s => s.className).join(' | ')"))
        check("R3 the legend lists the words in use, with the new shape", await str("return [...document.querySelectorAll('#note-legend .lg')].map(g => g.textContent + ':' + g.querySelector('.lb-sw').className.split(' ')[1]).join(',')").contains("Broken:s-solid"), await str("return document.getElementById('note-legend') ? document.getElementById('note-legend').textContent : 'none'"))
        let wideText = changed.replacingOccurrences(of: "linen:\n", with: "linen:\n  layout: wide\n")
        await host.send(["type": "update", "text": wideText, "inBurst": false, "version": 3, "sidecar": NSNull()])
        _ = await host.wait(for: "reloaded")
        check("R1 a layout change to wide widens kept blocks", await str("return [...document.querySelectorAll('[data-lblk]')].every(b => b.classList.contains('wide')) && document.getElementById('pane').classList.contains('lb-wide')") == "1")
        let fnText = wideText.replacingOccurrences(of: "The service takes a request", with: "First a new reference[^0] appears. The service takes a request").replacingOccurrences(of: "[^1]: Approve", with: "[^0]: A note added before the others.\n[^1]: Approve")
        await host.send(["type": "update", "text": fnText, "inBurst": false, "version": 4, "sidecar": NSNull()])
        _ = await host.wait(for: "reloaded")
        check("R1 footnote numbers follow an inserted reference", await str("return [...document.querySelectorAll('sup.fnref a')].map(a => a.dataset.fn + '=' + a.textContent).join(',')") == "0=1,1=2,2=3,1=2", await str("return [...document.querySelectorAll('sup.fnref a')].map(a => a.dataset.fn + '=' + a.textContent).join(',')"))
        check("R1 the footnotes list numbers match the references", await str("return [...document.querySelectorAll('.footnotes li')].map(l => l.id + '=' + l.value).join(',')") == "fn-0=1,fn-1=2,fn-2=3")
        // R2: the footnotes are a source-backed block: an edit to a definition alone is a changed block, and the line
        // command reaches a definition.
        let before = await str("return document.querySelector('.footnotes-blk').dataset.h")
        let defEdit = fnText.replacingOccurrences(of: "Both read `role`", with: "Both still read `role`")
        await host.send(["type": "update", "text": defEdit, "inBurst": false, "version": 5, "sidecar": NSNull()])
        let rl = await host.wait(for: "reloaded")
        let after = await str("return document.querySelector('.footnotes-blk').dataset.h")
        check("R2 editing only a footnote definition changes a block", before != after && ((rl["changed"] as? NSNumber)?.intValue ?? 0) >= 1, "changed \(rl["changed"] ?? "?")")
        let defLine = (defEdit.components(separatedBy: "\n").firstIndex { $0.hasPrefix("[^2]:") } ?? 0) + 1
        let lineTop = await num("await window.linen.receive({type: 'command', name: 'line', line: \(defLine)}); return Math.round(document.querySelector('.footnotes-blk').getBoundingClientRect().top)")
        let atEnd = await str("return Math.abs(scrollY - (document.documentElement.scrollHeight - innerHeight)) <= 2 && document.querySelector('.footnotes-blk').getBoundingClientRect().top < innerHeight")
        check("R2 the line command reaches a footnote definition (on the reading line, or the page scrolled to its end with the list in view)", abs(lineTop - 64) <= 2 || atEnd == "1", "top \(Int(lineTop)), at end \(atEnd)")
        check("Lane D: an Arabic item in an English list reads right to left", await str("return [...document.querySelectorAll('#doc li')].filter(l => /[\\u0600-\\u06FF]/.test(l.textContent) && l.closest('ul')).map(l => l.getAttribute('dir') + '/' + l.closest('ul').getAttribute('dir')).join()") == "rtl/ltr")

        print("blocks checks: \(passed) passed, \(failed) failed")
    }
}

@MainActor
func main() async {
    let mode = args.first ?? "checks"
    let host = Host(width: 1176, height: 900)
    await host.open()
    switch mode {
    case "probe":
        // The harness's own flow: settings without lang or face, a load without a sidecar; reports what arrives.
        let file = URL(fileURLWithPath: args[1])
        await host.send(["type": "settings", "theme": "paper", "uiDir": "ltr"])
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        Task { await host.send(["type": "load", "docId": "p", "name": file.lastPathComponent, "path": file.path, "text": text, "plain": false, "version": 1, "meta": ["modified": "14:02"]]) }
        let fp = await host.wait(for: "firstPaint", timeout: 10)
        let rd = await host.wait(for: "rendered", timeout: 10)
        print("firstPaint: \(fp["type"] ?? "?"), rendered: \(rd["type"] ?? "?"), blocks: \(await host.js("return document.querySelectorAll('#doc > .blk').length") ?? "?")")
        print("other messages: \(host.messages.map { $0["type"] ?? "?" })")
        print("console: \(host.consoleErrors)")
    case "shots":
        let out = args.count > 1 ? args[1] : "build/blocks-shots"
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        for f in ["blocks.md", "arabic.md", "wide.md", "sheet.md", "broken.md"] {
            for (w, h) in [(1176.0, 900.0), (390.0, 844.0)] {
                for theme in ["paper", "night"] {
                    await host.resize(w, h)
                    await host.settings(theme: theme)
                    await host.load(f)
                    let name = "\(out)/\(f.replacingOccurrences(of: ".md", with: ""))-\(Int(w))-\(theme).png"
                    await host.snapshot(to: name)
                    print(name)
                }
            }
        }
        // Note cards open: a sidecar note beside its term at 1176, a footnote as a sheet at 390, in both looks.
        for (w, h) in [(1176.0, 900.0), (390.0, 844.0)] {
            for theme in ["paper", "night"] {
                await host.resize(w, h)
                await host.settings(theme: theme)
                await host.load("blocks.md")
                let sel = w > 500 ? ".lnote[data-note=n-approve]" : "sup.fnref a"
                _ = await host.js("const t = document.querySelector('\(sel)'); t.scrollIntoView({block: 'center'}); t.dispatchEvent(new MouseEvent('mouseover', {bubbles: true})); await new Promise(r => setTimeout(r, 450)); return true")
                let img = try? await host.web.takeSnapshot(configuration: WKSnapshotConfiguration())
                let name = "\(out)/card-\(Int(w))-\(theme).png"
                if let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: name)) }
                print(name)
            }
        }
        if !host.consoleErrors.isEmpty { print("console: \(host.consoleErrors.prefix(5))") }
    default:
        let c = Checks(host)
        await c.run()
        exit(c.failed == 0 ? 0 : 1)
    }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in await main() }
app.run()
