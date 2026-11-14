import LinenKit
import SwiftUI

/// The file a document screen shows, whichever way it came.
struct OpenDocument {
    var name: String
    var kind: DocumentKind
    var url: URL
    var modified: Date?
    /// The pinned file, or nil for a file opened from elsewhere.
    var ref: PinFileRef?
    /// Where references resolve: the pin's root in the document's generation; nil for a file opened from elsewhere,
    /// which arrives without its folder (IOS-6).
    var root: URL?
    /// The path Copy Reference writes, as the Mac names the file (`projects/requests/map.canvas`).
    var referencePath: String
    var storeKey: String
    var scripts: PageScriptPolicy
    /// Holds the generation while the document is open (SYNC-4).
    var lease: PinnedDocument?

    var plain: Bool { url.pathExtension.lowercased() == "txt" }
    var displayPath: String { referencePath }
}

/// One outline row: a note's heading or a board's section or box, with what the renderer marks on it.
struct OutlineItem: Identifiable, Equatable {
    var id: Int
    var text: String
    var level: Int
    var changed: Bool
    var current: Bool
}

/// Everything one document screen knows: the open file and its generation, the renderer or sealed page showing it,
/// and the phone's own chrome around it (the band, find, outline, Next Change, sharing).
@MainActor
@Observable
final class DocumentModel {
    let source: DocumentSource
    @ObservationIgnored weak var app: AppModel?
    private(set) var document: OpenDocument?
    private(set) var host: RendererHost?
    private(set) var page: SealedPage?
    var title = ""
    /// A board's view: "canvas" or "list" (BRD-23).
    private(set) var mode = "canvas"
    /// A note's change marks still on the page (Next Change).
    private(set) var noteChanges = 0
    var findShown = false
    var findQuery = ""
    private(set) var findCount = 0
    private(set) var findCurrent = 0
    var outlineShown = false
    private(set) var outline: [OutlineItem] = []
    var shareShown = false
    var external: URL?
    var toast: String?
    /// A sealed page's one state line (PAGE-7).
    private(set) var pageLine: String?
    private(set) var failure: String?
    private(set) var pageErrors: [String] = []
    private(set) var zoom: Double = 1
    @ObservationIgnored private var palette: Palette = .paper
    @ObservationIgnored private var arabic = false
    @ObservationIgnored private var text = ""
    @ObservationIgnored private var sidecar: String?
    @ObservationIgnored private var watch: Task<Void, Never>?
    @ObservationIgnored private var assetLeases: [PinnedDocument] = []

    init(source: DocumentSource, app: AppModel) {
        self.source = source
        self.app = app
    }

    // MARK: Opening and closing

    func open(palette: Palette, arabic: Bool) async {
        self.palette = palette
        self.arabic = arabic
        guard document == nil, let app else { return }
        do {
            let d = try await Self.resolve(source, app: app)
            document = d
            title = (d.name as NSString).deletingPathExtension
            if let ref = d.ref { await app.library.markRead(ref) }
            if d.kind == .page {
                let p = SealedPage(document: d, theme: palette.theme)
                p.onTitle = { [weak self] t in self?.title = t }
                p.onOpenInLinen = { [weak self] rel in self?.openLocal(rel) }
                p.onAsk = { [weak self] u in self?.external = u }
                p.onToast = { [weak self] t in self?.showToast(t) }
                p.onStateLine = { [weak self] l in self?.pageLine = l }
                page = p
            } else {
                readFile(d)
                if let place = app.places.place(forKey: d.storeKey) { zoom = place.zoom > 0 ? place.zoom : 1 }
                let h = RendererHost(doc: self)
                h.web.pageZoom = d.kind == .note ? zoom : 1
                host = h
            }
            if d.ref != nil { watchGenerations() }
            #if DEBUG
            if Launch.has("-LinenEval") { startEval() }
            #endif
        } catch {
            failure = String(localized: "This file is no longer on this iPhone.")
        }
    }

    func close() {
        watch?.cancel()
        host?.tearDown()
        page?.close()
        document?.lease?.close()
        for l in assetLeases { l.close() }
        assetLeases.removeAll()
        app?.flush()
    }

    private static func resolve(_ source: DocumentSource, app: AppModel) async throws -> OpenDocument {
        switch source {
        case let .pinned(ref):
            let lease = try await app.library.open(ref)
            let pin = await app.library.pins().first { $0.id == ref.pin }
            let mac = pin?.macPath ?? ""
            let refPath = pin?.kind == .file ? mac : (mac.isEmpty ? ref.path : mac + "/" + ref.path)
            let modified = (try? lease.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return OpenDocument(name: lease.url.lastPathComponent, kind: lease.kind, url: lease.url, modified: modified, ref: ref, root: lease.root,
                                referencePath: refPath, storeKey: ref.storeKey, scripts: lease.scripts ?? .off, lease: lease)
        case let .opened(id):
            guard let f = app.opened.first(where: { $0.id == id }) ?? app.openedStore.all().first(where: { $0.id == id }) else {
                throw PinLibraryError.noSuchFile(PinFileRef(pin: "opened", path: id))
            }
            let url = app.openedStore.url(for: f)
            return OpenDocument(name: f.name, kind: f.kind, url: url, modified: f.opened, ref: nil, root: nil, referencePath: f.name,
                                storeKey: "opened:\(id)", scripts: .off, lease: nil)
        }
    }

    private func readFile(_ d: OpenDocument) {
        let data = (try? Data(contentsOf: d.url)) ?? Data()
        text = TextDecoder.decode(data).text
        sidecar = nil
        if d.kind == .board || (d.kind == .note && !d.plain), let s = try? Data(contentsOf: URL(fileURLWithPath: d.url.path + ".notes.json")) {
            sidecar = TextDecoder.decode(s).text
        }
    }

    /// A newer generation of the pin: open the file in it, show it as an outside change (place held, changes marked),
    /// then let the old generation go (SYNC-4).
    private func watchGenerations() {
        guard let app, let ref = document?.ref else { return }
        let library = app.library
        watch = Task { [weak self] in
            for await change in library.changes() {
                guard case let .generation(pin, g) = change, pin == ref.pin else { continue }
                guard let self, let old = self.document, let oldLease = old.lease, g > oldLease.generation else { continue }
                guard let fresh = try? await library.open(ref) else { continue }
                var d = old
                d.url = fresh.url
                d.root = fresh.root
                d.lease = fresh
                d.scripts = fresh.scripts ?? .off
                d.modified = (try? fresh.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                self.document = d
                if d.kind == .page {
                    self.page?.reload(document: d)
                } else {
                    self.readFile(d)
                    self.host?.sendUpdate(d, text: self.text, sidecar: self.sidecar)
                }
                await library.markRead(ref)
                oldLease.close()
            }
        }
    }

    // MARK: The renderer's messages

    func pageReady() {
        guard let host, let d = document else { return }
        host.sendSettings(palette, arabic: arabic)
        var place: [String: Any]?
        let stored = app?.places.place(forKey: d.storeKey)
        if d.kind == .board, let b = stored?.board {
            place = ["kind": "board", "cx": b.cx, "cy": b.cy, "zoom": b.zoom, "node": b.node ?? NSNull(), "mode": b.mode]
        } else if d.kind == .note, let p = stored {
            place = ["hash": p.blockHash, "index": p.blockIndex, "offset": p.offset, "quote": p.quote, "atEnd": p.atEnd]
        }
        let base = app?.baselines.hashes(forKey: d.storeKey)
        host.sendLoad(d, text: text, sidecar: sidecar, place: place, baseline: base, baselineDate: base != nil ? stored?.date : nil)
    }

    func applyLook(_ p: Palette, arabic: Bool) {
        palette = p
        self.arabic = arabic
        host?.sendSettings(p, arabic: arabic)
        page?.setTheme(p.theme)
    }

    func firstPaint(_ msg: [String: Any]) {}

    func rendered(title t: String?) {
        if let t, !t.isEmpty { title = t }
        Task {
            await refreshMode()
            await countNoteChanges()
            #if DEBUG
            if Launch.has("-LinenProbe") { try? await Task.sleep(for: .milliseconds(600)); await updateProbe() }
            #endif
        }
        if let ref = document?.ref, let heading = app?.pendingHeadings.removeValue(forKey: ref) {
            host?.send(["type": "command", "name": "heading", "text": heading])
        }
    }

    func view(_ msg: [String: Any]) {
        if let m = msg["mode"] as? String { mode = m }
        #if DEBUG
        if Launch.has("-LinenProbe") { Task { await updateProbe() } }
        #endif
    }

    #if DEBUG
    /// Development only (`-LinenEval`): runs `Documents/linen-eval.js` in the open document's page when it appears and
    /// writes the result, the page errors and the seal's events to `Documents/linen-eval.out`.
    private func startEval() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let input = docs.appendingPathComponent("linen-eval.js"), output = docs.appendingPathComponent("linen-eval.out")
        Task { [weak self] in
            while let self, !Task.isCancelled, self.document != nil {
                if let js = try? String(contentsOf: input, encoding: .utf8) {
                    try? FileManager.default.removeItem(at: input)
                    var result: Any? = nil
                    if let host = self.host { result = await host.js(js) } else if let page = self.page { result = await page.evaluateInKit(js) }
                    let out: [String: Any] = ["result": result.map { "\($0)" } ?? "nil", "pageErrors": self.pageErrors, "seal": self.page?.events ?? []]
                    if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted]) { try? data.write(to: output) }
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    /// For the UI test: the board's view and the centre of a card really under that point, as JSON.
    private(set) var probe = ""

    func updateProbe() async {
        guard let host else { return }
        let js = """
          const S = window.LinenBoard && LinenBoard._state; if (!S || !S.view) return '';
          const v = S.view, W = innerWidth, H = innerHeight; let card = null;
          for (const el of document.querySelectorAll('.b-node')) {
            const r = el.getBoundingClientRect(), cx = r.left + r.width / 2, cy = r.top + r.height / 2;
            if (r.width < 40 || cx < 60 || cx > W - 60 || cy < 60 || cy > H - 220) continue;
            const hit = document.elementFromPoint(cx, cy);
            if (hit && hit.closest('.b-node') === el) { card = [Math.round(cx), Math.round(cy)]; break; }
          }
          return JSON.stringify({tx: v.tx, ty: v.ty, s: v.s, mode: S.mode, level: S.level, card});
        """
        probe = (await host.js(js) as? String) ?? ""
    }
    #endif

    func storePlace(_ p: [String: Any]) {
        guard let app, let d = document else { return }
        if p["kind"] as? String == "board" {
            guard let cx = p["cx"] as? Double, let cy = p["cy"] as? Double, let z = p["zoom"] as? Double else { return }
            let node = p["node"] as? String
            let view = BoardView(cx: cx, cy: cy, zoom: z, node: node, mode: p["mode"] as? String ?? "canvas")
            app.places.set(Place(blockHash: node ?? "", blockIndex: 0, offset: 0, quote: "", zoom: 1, atEnd: false, date: Date(), board: view), forKey: d.storeKey)
            return
        }
        guard let hash = p["hash"] as? String else { return }
        app.places.set(Place(blockHash: hash, blockIndex: p["index"] as? Int ?? 0, offset: p["offset"] as? Double ?? 0, quote: p["quote"] as? String ?? "",
                             zoom: zoom, atEnd: p["atEnd"] as? Bool ?? false, date: Date()), forKey: d.storeKey)
    }

    func storeBaseline(_ hashes: [String]) {
        guard let app, let d = document else { return }
        app.baselines.set(hashes, forKey: d.storeKey)
        Task { await countNoteChanges() }
    }

    func pageError(_ s: String) {
        pageErrors.append(s)
        #if DEBUG
        print("[linen page] \(s)")
        if let key = document?.storeKey { app?.sweepErrors[key, default: []].append(s) }
        #endif
    }

    // MARK: Links and references

    func resolve(_ target: String) async -> PinReference {
        guard let app, let ref = document?.ref else { return .notOnPhone }
        return await app.library.resolve(target, from: ref)
    }

    func asset(path rel: String) async -> URL? {
        guard let d = document, d.root != nil else { return nil }
        if let u = d.lease?.sibling(rel) { return u }
        return await asset(wiki: rel)
    }

    func asset(wiki target: String) async -> URL? {
        guard let app, let d = document, let ref = d.ref else { return nil }
        guard case let .file(r) = await app.library.resolve(target, from: ref) else { return nil }
        if r.pin == ref.pin, let root = d.root {
            let u = root.appendingPathComponent(r.path)
            return u.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") ? u : nil
        }
        // In another pin: hold that pin's generation while this document is open.
        guard let other = try? await app.library.open(r) else { return nil }
        assetLeases.append(other)
        return other.url
    }

    func openWiki(_ target: String) {
        Task {
            let parts = target.split(separator: "#", maxSplits: 1).map(String.init)
            switch await resolve(target) {
            case let .file(r) where DocumentKind(fileName: r.path) != nil:
                if parts.count > 1, !parts[1].hasPrefix("^") { app?.pendingHeadings[r] = parts[1] }
                app?.path.append(.pinned(r))
            case .file:
                showToast(String(localized: "Linen opens notes, boards and pages only"))
            case .notOnPhone, .missing:
                showToast(document?.ref == nil ? String(localized: "Not on this iPhone") : String(localized: "No note called \(parts.first ?? target)"))
            }
        }
    }

    func openLocal(_ href: String) {
        let raw = href.removingPercentEncoding ?? href
        let pathPart = raw.split(separator: "#", maxSplits: 1).first.map(String.init) ?? raw
        guard document?.ref != nil, !pathPart.hasPrefix("/") else { showToast(String(localized: "Not on this iPhone")); return }
        openWiki(raw.hasSuffix(".md") || DocumentKind(fileName: pathPart) != nil ? raw : pathPart)
    }

    func askExternal(_ u: URL) {
        guard let s = u.scheme?.lowercased(), ["http", "https", "mailto", "tel"].contains(s) else {
            showToast(String(localized: "Linen does not open \(u.scheme ?? "this"): links"))
            return
        }
        external = u
    }

    func showToast(_ t: String) {
        toast = t
        let shown = t
        Task {
            try? await Task.sleep(for: .seconds(2.4))
            if self.toast == shown { self.toast = nil }
        }
    }

    // MARK: The band: Canvas and List, Next Change, text size

    func setMode(_ m: String) async {
        guard let host, m != mode else { return }
        _ = await host.command("toggleList")
        await refreshMode()
        #if DEBUG
        if Launch.has("-LinenProbe") { try? await Task.sleep(for: .milliseconds(900)); await updateProbe() }
        #endif
    }

    func refreshMode() async {
        guard let host, document?.kind == .board else { return }
        if let v = await host.command("view") as? [String: Any], let m = v["mode"] as? String { mode = m }
    }

    func countNoteChanges() async {
        guard let host, document?.kind == .note else { return }
        noteChanges = (await host.js("return document.querySelectorAll('#doc > .blk.chg, #doc > .gap').length") as? Int) ?? 0
    }

    func nextChange() async {
        guard let host else { return }
        if (await host.command("nextChange") as? Bool) != true { showToast(String(localized: "No more changes below")) }
    }

    func setZoom(_ z: Double) {
        guard let host, document?.kind == .note else { return }
        zoom = min(max(z, 0.7), 2)
        host.web.pageZoom = zoom
        Task {
            if let p = await host.command("place") as? [String: Any] { storePlace(p) }
        }
    }

    // MARK: Find (the phone's own bar, driving the renderer's find)

    func find(_ q: String) async {
        findQuery = q
        if let page {
            let found = await page.find(q)
            findCount = found ? 1 : 0
            findCurrent = found ? 1 : 0
            return
        }
        guard let host, let d = document else { return }
        if d.kind == .board {
            _ = await host.command("findText", ["q": q])
            await readBoardFind()
        } else {
            _ = await host.js("""
              if (document.getElementById('findbar').hidden) await window.linen.receive({type: 'command', name: 'find'});
              const i = document.getElementById('find-input'); i.value = q; i.dispatchEvent(new Event('input'));
              i.blur();
              return true;
            """, ["q": q])
        }
    }

    func findStep(_ dir: Int) async {
        if let page { _ = await page.find(findQuery, backwards: dir < 0); return }
        guard let host else { return }
        _ = await host.command(dir > 0 ? "findNext" : "findPrevious")
        if document?.kind == .board { await readBoardFind() }
    }

    func endFind() async {
        findShown = false
        findQuery = ""
        findCount = 0
        guard let host else { return }
        _ = await host.js("""
          const b = document.querySelector('.b-findd'); if (b && !b.closest('[hidden]')) b.click();
          const n = document.getElementById('find-done'); if (n && !document.getElementById('findbar').hidden) n.click();
          return true;
        """)
    }

    private func readBoardFind() async {
        guard let host else { return }
        let r = await host.js("const s = window.LinenBoard && LinenBoard._state; return s ? [s.find.cur + 1, s.find.hits.length] : [0, 0]") as? [Int]
        findCurrent = r?.first ?? 0
        findCount = r?.last ?? 0
    }

    func findState(count: Int, current: Int) {
        findCount = count
        findCurrent = current
    }

    func findClosed() {}

    // MARK: Outline (as a sheet, read from the renderer's own outline)

    func loadOutline() async {
        guard let host, let d = document else { return }
        let js: String
        if d.kind == .board {
            js = """
              const L = document.querySelector('.b-secs'); if (!L) return [];
              return [...L.querySelectorAll('a[data-id], a[data-tour]')].map((a, i) => {
                const m = /d(\\d)/.exec(a.className); const c = a.querySelector('.cnt');
                return [i, (c ? a.textContent.slice(0, a.textContent.length - c.textContent.length) : a.textContent).trim(), m ? Number(m[1]) : 0,
                        a.classList.contains('chgd'), a.classList.contains('cur')];
              });
            """
        } else {
            js = """
              return [...document.querySelectorAll('#outline-list li')].map((li, i) => [i, li.textContent.trim(), Number((li.className.match(/h(\\d)/) || [0, 1])[1]) - 1,
                li.classList.contains('chg') || li.classList.contains('changed'), li.classList.contains('cur')]);
            """
        }
        let rows = (await host.js(js) as? [[Any]]) ?? []
        let items: [OutlineItem] = rows.compactMap { r in
            guard r.count == 5, let i = r[0] as? Int, let t = r[1] as? String else { return nil }
            return OutlineItem(id: i, text: t, level: r[2] as? Int ?? 0, changed: r[3] as? Bool ?? false, current: r[4] as? Bool ?? false)
        }
        let top = items.map(\.level).min() ?? 0
        outline = items.map { var o = $0; o.level -= top; return o }
    }

    func goOutline(_ item: OutlineItem) async {
        guard let host, let d = document else { return }
        outlineShown = false
        if d.kind == .board {
            _ = await host.js("const a = document.querySelectorAll('.b-secs a[data-id], .b-secs a[data-tour]')[i]; if (a) a.click(); return !!a;", ["i": item.id])
        } else {
            _ = await host.js("const a = document.querySelectorAll('#outline-list li a')[i]; if (a) a.click(); return !!a;", ["i": item.id])
        }
    }

    /// The original file, for the share sheet (IOS-7).
    var shareURL: URL? { document?.url }
}
