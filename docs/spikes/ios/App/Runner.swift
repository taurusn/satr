// Spike I(a) runs, chosen by launch arguments. Every run writes Documents/results/<name>.json and progress lines.
//   fixtures   every note and board fixture: console errors, page errors, the renderer's problems, a snapshot each
//   paint      a board's first paint: 20 loads in one page (as board-host bench), 20 cold pages, 20 List first paints
//   bench      the renderer's own B(a) gesture set (board.js bench), 3 runs of 180 frames per gesture
//   touch      a board at the first section at reading zoom with the frame recorder armed, for real touches (XCUITest)
//   loop       the I(a) 10-minute loop, see loop()
//   idle       a board, then nothing (a memory baseline for xctrace)
import UIKit
import WebKit

@MainActor
final class Runner {
    var started = false
    let defaults = UserDefaults.standard
    var mode: String { defaults.string(forKey: "LinenMode") ?? "fixtures" }
    var boardName: String { defaults.string(forKey: "LinenBoard") ?? "big-500" }
    var boardURL: URL { fixturesRoot.appendingPathComponent("boards/\(boardName).canvas") }
    var runs: Int { defaults.integer(forKey: "LinenRuns") > 0 ? defaults.integer(forKey: "LinenRuns") : 20 }

    func run(in host: HostController) async {
        try? FileManager.default.removeItem(at: Out.dir.appendingPathComponent("progress.txt"))
        Out.line("mode \(mode) board \(boardName) device \(UIDevice.current.model) iOS \(UIDevice.current.systemVersion) screen \(UIScreen.main.bounds.size) scale \(UIScreen.main.scale)")
        switch mode {
        case "fixtures": await fixtures(host)
        case "paint": await paint(host)
        case "bench": await bench(host)
        case "touch": await touch(host)
        case "loop": await loop(host)
        case "idle": await idle(host)
        default: Out.line("unknown mode \(mode)")
        }
        Out.line("DONE \(mode)")
        // A finished run gives the phone back: the screen may sleep again and the app quits, so nothing keeps running.
        UIApplication.shared.isIdleTimerDisabled = false
        try? await Task.sleep(for: .seconds(2))
        exit(0)
    }

    // MARK: fixtures

    static let probe = """
      const q = (s) => [...document.querySelectorAll(s)];
      const shown = (el) => el && !el.closest('[hidden]') && el.textContent.trim() ? el.textContent.trim().slice(0, 240) : null;
      const B = window.LinenBoard;
      const out = { failed: q('.render-failed').map((e) => e.textContent.trim().slice(0, 240)),
        notice: shown(document.getElementById('notice')), banner: shown(document.getElementById('banner')), boardActive: !!(B && B.active),
        width: innerWidth, height: innerHeight, dpr: devicePixelRatio };
      if (kind === 'board') {
        let m;
        try { m = window.LinenCanvas.parse(text, { sidecarText: sidecar }); } catch (e) { m = { fatal: { reason: 'threw', problems: [{ path: '$', message: String(e) }] }, problems: [] }; }
        out.modelProblems = (m.problems || []).map((p) => `${p.severity || ''} ${p.path || ''}: ${p.message}`);
        out.modelFatal = m.fatal ? { reason: m.fatal.reason, problems: (m.fatal.problems || []).map((p) => `${p.path || ''}: ${p.message}`) } : null;
        const S = B._state;
        out.boardProblems = S.board ? (S.board.problems || []).map((p) => `${p.severity || ''} ${p.path || ''}: ${p.message}`) : null;
        out.nodes = S.board ? S.board.nodes.length : 0;
        out.edges = S.board ? S.board.edges.length : 0;
        out.mounted = S.mounted ? S.mounted.size : 0;
        out.level = S.level; out.mode = S.mode;
        out.fatalShown = !!document.querySelector('.fatal');
        out.fatalList = q('.b-probs li').map((e) => e.textContent.trim().slice(0, 200));
        out.lines = q('.b-line, .b-probline').map(shown).filter(Boolean);
      } else {
        out.title = (document.getElementById('note-title') || {}).textContent || '';
        out.blocks = document.querySelectorAll('#doc > *').length;
        if (window.LinenBlocks && !plain) { try { out.check = window.LinenBlocks.check(text, sidecar).map((p) => `${p.severity} line ${p.line}: ${p.message}`); } catch (e) { out.check = ['check threw ' + e]; } }
      }
      out.fontsLoaded = [...document.fonts].filter((f) => f.status === 'loaded').map((f) => f.family + ' ' + f.weight);
      out.fontsFailed = [...document.fonts].filter((f) => f.status === 'error').map((f) => f.family + ' ' + f.weight);
      return JSON.stringify(out);
    """

    func fixtureList() -> [URL] {
        let fm = FileManager.default
        func files(_ dir: URL, _ exts: [String]) -> [URL] {
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { exts.contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        return files(fixturesRoot, ["md", "txt"]) + files(fixturesRoot.appendingPathComponent("blocks"), ["md"])
            + files(fixturesRoot.appendingPathComponent("boards"), ["canvas"])
    }

    func fixtures(_ host: HostController) async {
        let p = host.newPage()
        guard await p.open() else { Out.line("page never said ready"); return }
        await p.settings()
        let shots = documents.appendingPathComponent("shots")
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        var out: [[String: Any]] = []
        for (i, file) in fixtureList().enumerated() {
            let board = file.pathExtension == "canvas"
            let rel = file.path.replacingOccurrences(of: fixturesRoot.path + "/", with: "")
            p.consoleErrors.removeAll(); p.consoleWarnings.removeAll(); p.pageErrors.removeAll()
            var ms = 0.0
            var reply: [String: Any] = [:]
            if board {
                (ms, reply) = await p.loadBoard(file, docId: "f\(i)")
                await p.settle()
            } else {
                (ms, reply) = await p.loadNote(file, docId: "f\(i)")
            }
            try? await Task.sleep(for: .milliseconds(900)) // KaTeX, Mermaid, images and faces finish
            let text = String(decoding: (try? Data(contentsOf: file)) ?? Data(), as: UTF8.self)
            let side: Any = (try? String(contentsOf: URL(fileURLWithPath: file.path + ".notes.json"), encoding: .utf8)) ?? NSNull()
            let raw = try? await p.web.callAsyncJavaScript(Self.probe, arguments: ["kind": board ? "board" : "note", "text": text, "sidecar": side, "plain": file.pathExtension == "txt"], contentWorld: .page)
            let probe = (raw as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } ?? ["probe": "failed: \(String(describing: raw))"]
            await p.snapshot(to: shots.appendingPathComponent(rel.replacingOccurrences(of: "/", with: "_") + ".png"))
            out.append(["file": rel, "kind": board ? "board" : "note", "ms": Int(ms), "reply": reply["type"] ?? "?", "console": p.consoleErrors,
                        "warnings": p.consoleWarnings, "pageErrors": p.pageErrors, "probe": probe])
            Out.line("\(rel): \(reply["type"] ?? "?") in \(Int(ms)) ms, console \(p.consoleErrors.count), page errors \(p.pageErrors.count)")
        }
        // Positive control, after the counts: one console.log, one console.error and one uncaught throw must reach the
        // app's capture and the system log (the outside read), or a zero above proves nothing.
        p.consoleErrors.removeAll(); p.pageErrors.removeAll()
        _ = await p.js("console.log('SPIKE-CONTROL log'); console.error('SPIKE-CONTROL error'); setTimeout(() => { throw new Error('SPIKE-CONTROL throw'); }, 0); return true")
        try? await Task.sleep(for: .milliseconds(500))
        let control: [String: Any] = ["console": p.consoleErrors, "pageErrors": p.pageErrors]
        Out.line("page messages to the system console: \(Page.systemConsole)")
        Out.line("control: console \(p.consoleErrors), page errors \(p.pageErrors)")
        Out.write("fixtures", ["runAt": Stamp.now(), "results": out, "terminations": p.terminations, "control": control])
    }

    // MARK: boards

    /// The first section at reading zoom in Canvas, as PRD-2 section 4's benchmark asks ("switches to Canvas and opens
    /// the first section at reading zoom ... even where BRD-24 would open List view first"). The phone opens a wide first
    /// section as a List (BRD-24); switching to Canvas keeps the section view the opening computed.
    func readingPlace(_ p: Page) async -> [String: Any]? {
        _ = await p.loadBoard(boardURL, docId: "probe")
        var v = (await p.command("view")) as? [String: Any] ?? [:]
        let openedAs = v["mode"] as? String ?? "?"
        if openedAs == "list" { _ = await p.command("toggleList") }
        await p.settle()
        v = (await p.command("view")) as? [String: Any] ?? [:]
        guard let s = v["s"] as? Double, let tx = v["tx"] as? Double, let ty = v["ty"] as? Double, let w = v["W"] as? Double, let h = v["H"] as? Double else { return nil }
        Out.line("opening: BRD-24 opened \(openedAs); reading view s=\(s) level=\(v["level"] ?? "?") mounted=\(v["mounted"] ?? "?") view \(Int(w))x\(Int(h))")
        return ["kind": "board", "cx": (w / 2 - tx) / s, "cy": (h / 2 - ty) / s, "zoom": s, "node": NSNull(), "mode": "canvas"]
    }

    func paint(_ host: HostController) async {
        var p = host.newPage()
        guard await p.open() else { Out.line("page never said ready"); return }
        await p.settings()
        guard let place = await readingPlace(p) else { Out.line("no reading place"); return }
        var warm: [[String: Any]] = []
        for i in 0..<runs {
            let (ms, fp) = await p.loadBoard(boardURL, docId: "w\(i)", place: place)
            warm.append(["hostMs": ms, "pageMs": fp["paintMs"] ?? -1, "mounted": fp["mounted"] ?? -1, "reply": fp["type"] ?? "?"])
            try? await Task.sleep(for: .milliseconds(150))
        }
        let view = (await p.command("view")) as? [String: Any] ?? [:]
        Out.line("warm first paints: \(warm.map { Int(($0["hostMs"] as? Double) ?? -1) })")
        var list: [[String: Any]] = []
        var listPlace = place
        listPlace["mode"] = "list"
        for i in 0..<runs {
            let (ms, fp) = await p.loadBoard(boardURL, docId: "l\(i)", place: listPlace)
            list.append(["hostMs": ms, "pageMs": fp["paintMs"] ?? -1, "reply": fp["type"] ?? "?"])
            try? await Task.sleep(for: .milliseconds(150))
        }
        let listView = (await p.command("view")) as? [String: Any] ?? [:]
        Out.line("list first paints: \(list.map { Int(($0["hostMs"] as? Double) ?? -1) })")
        var errors = p.consoleErrors + p.pageErrors
        var cold: [[String: Any]] = []
        for i in 0..<runs {
            let t0 = CFAbsoluteTimeGetCurrent()
            p = host.newPage()
            let ready = await p.open()
            let tReady = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            await p.settings()
            let (ms, fp) = await p.loadBoard(boardURL, docId: "c\(i)", place: place)
            let total = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            cold.append(["ready": ready, "pageReadyMs": tReady, "hostMs": ms, "pageMs": fp["paintMs"] ?? -1, "mounted": fp["mounted"] ?? -1, "totalMs": total, "reply": fp["type"] ?? "?"])
            errors += p.consoleErrors + p.pageErrors
            try? await Task.sleep(for: .milliseconds(300))
        }
        Out.line("cold first paints (load to paint): \(cold.map { Int(($0["hostMs"] as? Double) ?? -1) })")
        Out.write("paint-\(boardName)", ["runAt": Stamp.now(), "board": boardName, "place": place, "openingView": view, "listView": listView,
                                         "warm": warm, "list": list, "cold": cold, "errors": errors, "terminations": p.terminations])
    }

    func bench(_ host: HostController) async {
        let p = host.newPage()
        guard await p.open() else { Out.line("page never said ready"); return }
        await p.settings()
        guard let place = await readingPlace(p) else { return }
        _ = await p.loadBoard(boardURL, docId: "bench", place: place)
        await p.settle()
        try? await Task.sleep(for: .seconds(1))
        var all: [[String: Any]] = []
        let gestureRuns = defaults.integer(forKey: "LinenGestureRuns") > 0 ? defaults.integer(forKey: "LinenGestureRuns") : 3
        for r in 0..<gestureRuns {
            Out.line("bench run \(r + 1) of \(gestureRuns) starts")
            if let out = await p.command("bench", ["frames": 180, "exp": [String: Any]()]) as? [String: Any] { all.append(out) } else { Out.line("bench failed") }
            try? await Task.sleep(for: .seconds(1))
        }
        Out.write("bench-\(boardName)", ["runAt": Stamp.now(), "board": boardName, "runs": all, "errors": p.consoleErrors + p.pageErrors, "terminations": p.terminations])
    }

    /// Real touches come from the UI test; this keeps the recorder armed and writes what it saw every 2 s.
    func touch(_ host: HostController) async {
        let p = host.newPage()
        guard await p.open() else { Out.line("page never said ready"); return }
        await p.settings()
        guard let place = await readingPlace(p) else { return }
        _ = await p.loadBoard(boardURL, docId: "touch", place: place)
        await p.settle()
        _ = await p.js("window.__spike.arm(true); return true")
        // Where pans start: a point on the ground, off the cards (a drag that starts on a card does not pan; see README).
        let gp = (await p.js("return window.__spike.groundPoint()")) as? [String: Any]
        let frame = p.web.frame
        let label = UILabel(frame: CGRect(x: 0, y: 0, width: 4, height: 4))
        label.accessibilityIdentifier = "groundPoint"
        label.text = gp.map { "\(Double(truncating: $0["x"] as! NSNumber) + frame.minX),\(Double(truncating: $0["y"] as! NSNumber) + frame.minY)" } ?? "none"
        label.alpha = 0.02
        host.view.addSubview(label)
        Out.line("TOUCH READY ground point \(label.text ?? "none") (web view at \(frame))")
        var lastCount = -1
        var quietSince = Date()
        let began = Date()
        // Ends 30 s after the last gesture once gestures have come, or after 6 minutes with none.
        while Date().timeIntervalSince(began) < 360 && !(lastCount > 0 && Date().timeIntervalSince(quietSince) > 30) {
            try? await Task.sleep(for: .seconds(2))
            let n = (await p.js("return window.__spike.gestures.length")) as? Int ?? 0
            if n != lastCount {
                lastCount = n
                quietSince = Date()
                let raw = (await p.js("return JSON.stringify(window.__spike.gestures)")) as? String ?? "[]"
                let g = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) ?? []
                let v = (await p.command("view")) as? [String: Any] ?? [:]
                Out.write("touch-\(boardName)", ["at": Stamp.now(), "board": boardName, "place": place, "view": v, "gestures": g,
                                                 "errors": p.consoleErrors + p.pageErrors, "terminations": p.terminations])
            }
        }
    }

    func idle(_ host: HostController) async {
        let p = host.newPage()
        guard await p.open() else { return }
        await p.settings()
        guard let place = await readingPlace(p) else { return }
        _ = await p.loadBoard(boardURL, docId: "idle", place: place)
        Out.line("IDLE READY")
        try? await Task.sleep(for: .seconds(defaults.double(forKey: "LinenMinutes") > 0 ? defaults.double(forKey: "LinenMinutes") * 60 : 120))
    }

    // MARK: the 10-minute loop

    static let gestures = """
      window.__loop = {
        raf: () => new Promise((r) => requestAnimationFrame(r)),
        canvas: () => document.querySelector('.b-canvas'),
        at() { const r = this.canvas().getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; },
        // A pan: wheel deltas through the renderer's own wheel handler (the mid-gesture path: gesture(), then rest()).
        async pan(dx, dy, frames) { const C = this.canvas(), p = this.at(); const t0 = performance.now(), d = [];
          for (let i = 0; i < frames; i++) { const a = performance.now(); C.dispatchEvent(new WheelEvent('wheel', { deltaX: -dx, deltaY: -dy, clientX: p.x, clientY: p.y, bubbles: true, cancelable: true })); await this.raf(); d.push(performance.now() - a); }
          return d; },
        // A pinch: ctrl-wheel steps, the renderer's trackpad pinch path, factor spread over the frames.
        async pinch(factor, frames) { const C = this.canvas(), p = this.at(); const dy = -Math.log(factor) / frames / 0.01, d = [];
          for (let i = 0; i < frames; i++) { const a = performance.now(); C.dispatchEvent(new WheelEvent('wheel', { deltaY: dy, ctrlKey: true, clientX: p.x, clientY: p.y, bubbles: true, cancelable: true })); await this.raf(); d.push(performance.now() - a); }
          return d; },
        async rest(ms) { await new Promise((r) => setTimeout(r, ms)); const S = window.LinenBoard._state; for (let i = 0; i < 120 && S.pumping; i++) await this.raf(); },
        centre() { const S = window.LinenBoard._state, b = S.board; if (!b) return null; const { s, tx, ty } = S.view; const cx = (S.W / 2 - tx) / s, cy = (S.H / 2 - ty) / s;
          let best = null, bd = Infinity; for (const n of b.nodes) { if (n.kind === 'section' || !n.placed) continue; const d = Math.hypot(n.x + n.w / 2 - cx, n.y + n.h / 2 - cy); if (d < bd) { bd = d; best = n; } }
          return best && { id: best.id, sx: (best.x + best.w / 2) * s + tx, sy: (best.y + best.h / 2) * s + ty }; },
        at2(id) { const S = window.LinenBoard._state, n = S.board && S.board.byId.get(id); if (!n) return null; const { s, tx, ty } = S.view; return { sx: (n.x + n.w / 2) * s + tx, sy: (n.y + n.h / 2) * s + ty }; },
        noted(k) { const S = window.LinenBoard._state; return [...S.mounted.keys()].filter((id) => { const n = S.board.byId.get(id); return n && n.note; }).slice(0, k); },
      };
      return true;
    """

    /// One iteration: open the board (first section at reading zoom in Canvas), 20 pans, 10 pinches in and out,
    /// Canvas to List and back, open 5 notes (5 node notes on the board, then 5 note files in the same page), and
    /// between them a reload after an outside change (the board file rewritten atomically in Documents, seen by a
    /// directory watcher, sent as `update` like DocumentWindow.sendUpdate). Repeats until the minutes are up.
    func loop(_ host: HostController) async {
        let minutes = defaults.double(forKey: "LinenMinutes") > 0 ? defaults.double(forKey: "LinenMinutes") : 10
        let fm = FileManager.default
        let dir = documents.appendingPathComponent("loop")
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let board = dir.appendingPathComponent("\(boardName).canvas")
        try? fm.copyItem(at: boardURL, to: board)
        try? fm.copyItem(at: URL(fileURLWithPath: boardURL.path + ".notes.json"), to: URL(fileURLWithPath: board.path + ".notes.json"))
        let original = (try? Data(contentsOf: board)) ?? Data()
        let notes = ["Complete.md", "Tables and Code.md", "Deep Nesting.md", "blocks/arabic.md", "blocks/blocks.md"].map { fixturesRoot.appendingPathComponent($0) }

        let p = host.newPage()
        guard await p.open() else { Out.line("page never said ready"); return }
        await p.settings()
        guard let place = await readingPlace(p) else { return }
        let watcher = DirWatcher(dir)
        let t0 = Date()
        var iterations: [[String: Any]] = []
        var i = 0
        var version = 1
        Out.line("LOOP START \(minutes) min")
        while Date().timeIntervalSince(t0) < minutes * 60 {
            i += 1
            var it: [String: Any] = ["i": i, "start": Stamp.now(), "t": Date().timeIntervalSince(t0)]
            let docId = "loop\(i)"
            version += 1
            let (fpMs, fp) = await p.loadBoard(board, docId: docId, place: place, version: version)
            it["firstPaintMs"] = fpMs
            it["firstPaintReply"] = fp["type"] ?? "?"
            await p.settle()
            _ = await p.js(Self.gestures)
            var panMax = 0.0, pinchMax = 0.0
            for k in 0..<20 {
                let dirs: [(Double, Double)] = [(-14, 0), (14, 0), (0, -12), (0, 12)]
                let d = dirs[k % 4]
                if let f = await p.js("return await window.__loop.pan(\(d.0), \(d.1), 24)") as? [Double] { panMax = max(panMax, f.max() ?? 0) }
                _ = await p.js("await window.__loop.rest(260); return true")
            }
            for _ in 0..<10 {
                if let f = await p.js("return await window.__loop.pinch(2.2, 30)") as? [Double] { pinchMax = max(pinchMax, f.max() ?? 0) }
                _ = await p.js("await window.__loop.rest(260); return true")
                if let f = await p.js("return await window.__loop.pinch(1 / 2.2, 30)") as? [Double] { pinchMax = max(pinchMax, f.max() ?? 0) }
                _ = await p.js("await window.__loop.rest(260); return true")
            }
            it["panLongestFrameMs"] = panMax
            it["pinchLongestFrameMs"] = pinchMax
            _ = await p.command("toggleList")
            try? await Task.sleep(for: .milliseconds(600))
            it["listMode"] = ((await p.command("view")) as? [String: Any])?["mode"] ?? "?"
            _ = await p.command("toggleList")
            await p.settle()
            let ids = (await p.js("return window.__loop.noted(5)")) as? [String] ?? []
            var opened = 0
            for id in ids {
                if (await p.command("openNote", ["id": id])) as? Bool == true { opened += 1 }
                try? await Task.sleep(for: .milliseconds(500))
            }
            it["nodeNotesOpened"] = opened
            _ = await p.command("toggleList"); _ = await p.command("toggleList") // closes the note card (setMode closes it)
            await p.settle()
            // The outside change: one card's text changes, the file is replaced atomically.
            let before = (await p.js("return window.__loop.centre()")) as? [String: Any]
            var json = (try? JSONSerialization.jsonObject(with: original)) as? [String: Any] ?? [:]
            if var nodes = json["nodes"] as? [[String: Any]] {
                let k = (i * 7) % nodes.count
                nodes[k]["text"] = ((nodes[k]["text"] as? String) ?? "") + "\n\nChanged outside, round \(i)."
                json["nodes"] = nodes
            }
            let newData = (try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])) ?? original
            watcher.reset()
            let tw = CFAbsoluteTimeGetCurrent()
            try? newData.write(to: board, options: .atomic)
            let seen = await watcher.next(timeout: 5)
            let text = String(decoding: (try? Data(contentsOf: board)) ?? Data(), as: UTF8.self)
            let sidecar: Any = (try? String(contentsOf: URL(fileURLWithPath: board.path + ".notes.json"), encoding: .utf8)) ?? NSNull()
            version += 1
            await p.send(["type": "update", "kind": "board", "docId": docId, "text": text, "sidecar": sidecar, "inBurst": false, "version": version, "meta": [:]])
            _ = await p.js("await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))); return true")
            it["reloadMs"] = (CFAbsoluteTimeGetCurrent() - tw) * 1000
            it["watcherSaw"] = seen
            if let b = before, let id = b["id"] as? String, let after = (await p.js("return window.__loop.at2('\(id)')")) as? [String: Any],
               let bx = b["sx"] as? Double, let by = b["sy"] as? Double, let ax = after["sx"] as? Double, let ay = after["sy"] as? Double {
                it["centreDriftPx"] = hypot(ax - bx, ay - by)
            }
            await p.settle()
            for (k, n) in notes.enumerated() {
                let (ms, r) = await p.loadNote(n, docId: "loop\(i)n\(k)")
                if r["type"] as? String != "rendered" { it["noteFail"] = n.lastPathComponent }
                it["note\(k)Ms"] = ms
                try? await Task.sleep(for: .milliseconds(400))
            }
            it["end"] = Stamp.now()
            it["consoleErrors"] = p.consoleErrors.count
            it["pageErrors"] = p.pageErrors.count
            it["terminations"] = p.terminations.count
            iterations.append(it)
            Out.line("loop \(i) at \(Int(Date().timeIntervalSince(t0))) s: first paint \(Int(fpMs)) ms, reload \(Int((it["reloadMs"] as? Double) ?? -1)) ms, drift \(String(format: "%.1f", (it["centreDriftPx"] as? Double) ?? -1)) px, longest pan frame \(Int(panMax)), pinch \(Int(pinchMax)), errors \(p.consoleErrors.count + p.pageErrors.count), terminations \(p.terminations.count)")
            Out.write("loop-\(boardName)", ["runAt": Stamp.now(), "minutes": minutes, "board": boardName, "iterations": iterations,
                                            "errors": Array((p.consoleErrors + p.pageErrors).prefix(40)), "terminations": p.terminations])
        }
        Out.line("LOOP END after \(i) iterations, \(Int(Date().timeIntervalSince(t0))) s")
    }
}

/// Watches a folder for writes, as Linen's file watcher would see the link's replace-by-rename.
@MainActor
final class DirWatcher {
    private let source: DispatchSourceFileSystemObject
    private var pending = 0
    private var waiter: CheckedContinuation<Bool, Never>?
    init(_ dir: URL) {
        let fd = open(dir.path, O_EVTONLY)
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .extend], queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.fire() } }
        source.setCancelHandler { close(fd) }
        source.resume()
    }
    private func fire() {
        if let w = waiter { waiter = nil; w.resume(returning: true) } else { pending += 1 }
    }
    func reset() { pending = 0 }
    func next(timeout: Double) async -> Bool {
        if pending > 0 { pending = 0; return true }
        return await withCheckedContinuation { c in
            waiter = c
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { MainActor.assumeIsolated { if let w = self.waiter { self.waiter = nil; w.resume(returning: false) } } }
        }
    }
}
