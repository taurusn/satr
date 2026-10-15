// Spike X(a): a 500-node board exported to a vector PDF by Linen's own drawing (Linen/Export): Thmanyah as glyph
// outlines, an invisible Geeza Pro / Helvetica layer for search, selection and copy. Builds a synthetic display list
// shaped like an agent's readiness map (the renderer's `displayList` hands over the same shape), writes the whole
// board and the Sections PDF, and checks the EXP-5 gate: time, size, PDFKit text and search (Arabic included,
// ligature words too), selection boxes against the visible glyphs, no Thmanyah font data, mixed lines in order.
//
//   swiftc -O -parse-as-library -o build/xa docs/spikes/export/xa.swift Linen/Export/DisplayList.swift \
//     Linen/Export/OutlineText.swift Linen/Export/BoardPDF.swift -framework AppKit -framework PDFKit
//   ./build/xa build/export-out [nodes]
import AppKit
import CoreText
import PDFKit

let english = [
    "Gateway readiness map", "Identity and access", "Request intake", "Status recording", "Audit ledger", "Storage bucket",
    "Single sign-on", "Event ledger", "Outcome recording", "Linen reads board.canvas files", "Partial rollout in staging",
    "Approvals routed by amount", "Owner sign-off", "Sandbox per user", "Pinned folders sync", "Export to PDF",
]
let englishBodies = [
    "The service answers on staging but the ledger write fails under load; retry is not idempotent yet.",
    "Seen working end to end with real SSO on the dev cluster. Owner confirmed the flow on 12 October.",
    "Exists in code, not seen working: the job never ran because the queue binding is missing.",
    "Planned for the next milestone; depends on the storage bucket and the per-bucket keys.",
    "Linen keeps your place while an agent rewrites the file, and marks what changed since you looked.",
]
let arabic = [
    "يقرأ لينن ما يكتبه الوكلاء", "مزامنة الملفات بلا سحابة", "لا سحابة ولا حساب", "تسجيل الدخول الموحد", "سجل الأحداث والتدقيق",
    "الماك والآيفون معا", "حالة الجاهزية للبوابة",
]
let arabicBodies = [
    "يقرأ لينن ما يكتبه الوكلاء على الماك والآيفون، ويحفظ مكانك حين يعيد الوكيل كتابة الملف.",
    "تمت مزامنة ١٢ ملفا في ٣ ثوان عبر الشبكة المحلية، بلا سحابة ولا حساب.",
    "افتح ملف board.canvas في Linen ثم اضغط Present لعرض الأقسام بالترتيب.",
    "الخدمة تعمل على بيئة الاختبار لكن الكتابة في السجل تفشل تحت الضغط.",
]
let words: [(String, String)] = [("WORKS", "outline"), ("PARTIAL", "threads"), ("BROKEN", "rust"), ("MISSING", "dashed"), ("PLANNED", "dotted")]
let testWords = ["Gateway", "readiness", "board.canvas", "Linen", "staging", "idempotent", "لينن", "الوكلاء", "سحابة", "مزامنة", "الماك", "حساب", "الجاهزية", "Present"]

func hex(_ s: String) -> String { s }
let ink = "#284734", ink2 = "#1F3328", rule = "#DAD5C8", paper2 = "#FBF9F4", rust = "#9C4A2E", wash = "rgba(227,231,223,0.55)"

struct Gen {
    var items: [[String: Any]] = []
    var sections: [[String: Any]] = []
    var notes: [[String: Any]] = []
    var lines: [(text: String, face: Face, size: CGFloat, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, rtl: Bool)] = []

    func font(_ f: Face, _ s: CGFloat) -> CTFont { CTFontCreateWithName(f.postScriptName as CFString, s, nil) }

    /// Breaks text the way a browser would at this width (Core Text with the same faces), one line per item.
    mutating func text(_ s: String, face: Face, size: CGFloat, lh: CGFloat, x: CGFloat, y: CGFloat, width: CGFloat, color: String, maxLines: Int = 6) -> CGFloat {
        let rtl = OutlineText.isRTL(s)
        let attr = NSAttributedString(string: s, attributes: [.font: font(face, size)])
        let ts = CTTypesetterCreateWithAttributedString(attr)
        let ns = s as NSString
        var start = 0, top = y, n = 0
        while start < ns.length, n < maxLines {
            let len = CTTypesetterSuggestLineBreak(ts, start, Double(width))
            if len <= 0 { break }
            let piece = ns.substring(with: NSRange(location: start, length: len)).trimmingCharacters(in: .whitespaces)
            start += len
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: piece, attributes: [.font: font(face, size)]))
            let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let lx = rtl ? x + width - w : x
            items.append(["t": "text", "text": piece, "font": face.rawValue, "size": size, "x": lx, "y": top, "w": w, "h": lh, "dir": rtl ? "rtl" : "ltr", "color": color])
            lines.append((piece, face, size, lx, top, w, lh, rtl))
            top += lh
            n += 1
        }
        return top - y
    }

    mutating func build(nodes: Int) -> [String: Any] {
        let perSection = max(1, nodes / 10)
        let cols = 5, cardW: CGFloat = 240, gap: CGFloat = 28, pad: CGFloat = 24
        var sx: CGFloat = 0, sy: CGFloat = 0, rowH: CGFloat = 0
        var made = 0, noteN = 0
        var prevCard: CGRect?
        for s in 0..<10 {
            let secW = pad * 2 + CGFloat(cols) * cardW + CGFloat(cols - 1) * gap
            // lay out cards first to know the section's height
            var cards: [[String: Any]] = []
            var colY = [CGFloat](repeating: pad + 30, count: cols)
            let sectionItemsStart = items.count
            items.append([:]) // placeholder for the section rect
            let title = s % 5 == 2 ? arabic[s % arabic.count] : english[s % english.count]
            for k in 0..<perSection where made < nodes {
                let c = k % cols
                let ar = (made % 5) == 3
                let x = sx + pad + CGFloat(c) * (cardW + gap), y = sy + colY[c]
                let cardIndex = items.count
                items.append([:])
                var h: CGFloat = 14
                let word = words[made % words.count]
                // pill
                let pill = word.0
                let pillW = CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: pill, attributes: [.font: font(.sans500, 10), .kern: 1.4])), nil, nil, nil)) + 14
                let px = ar ? x + cardW - 14 - pillW : x + 14
                items.append(["t": "rect", "x": px, "y": y + h, "w": pillW, "h": 18, "fill": word.1 == "rust" ? rust : nil as Any?, "stroke": ink, "lw": 1, "r": 9,
                              "dash": word.1 == "dashed" ? [3, 2] : (word.1 == "dotted" ? [1, 2] : []), "hatch": word.1 == "threads" ? ["color": ink, "gap": 4, "lw": 0.75] : nil as Any?].compactMapValues { $0 })
                items.append(["t": "text", "text": pill, "font": "sans-500", "size": 10, "x": px + 7, "y": y + h, "w": pillW - 14, "h": 18, "dir": "ltr", "color": word.1 == "rust" ? "#F6F3EB" : ink])
                h += 26
                let t = ar ? arabic[(made / 5) % arabic.count] : english[made % english.count] + " \(made)"
                h += text(t, face: .serif, size: 19, lh: 24, x: x + 14, y: y + h, width: cardW - 28, color: ink, maxLines: 2) + 4
                let b = ar ? arabicBodies[made % arabicBodies.count] : englishBodies[made % englishBodies.count]
                h += text(b, face: .sans, size: 15, lh: 22, x: x + 14, y: y + h, width: cardW - 28, color: ink2, maxLines: 4)
                h += 14
                let card = CGRect(x: x, y: y, width: cardW, height: h)
                items[cardIndex] = ["t": "rect", "x": x, "y": y, "w": cardW, "h": h, "fill": paper2, "stroke": rule, "lw": 1, "r": 2, "shadow": true, "node": "n\(made)"]
                if made % 4 == 1 {
                    noteN += 1
                    notes.append(["n": noteN, "title": ar ? "مصدر \(noteN)" : "Evidence for card \(made)", "area": title, "x": ar ? x : x + cardW, "y": y,
                                  "body": ar ? arabicBodies[(made + 1) % arabicBodies.count] : englishBodies[(made + 2) % englishBodies.count],
                                  "refs": ["src/service/ledger.ts:\(40 + made)-\(52 + made)"]])
                }
                // a connector to the previous card in the section, every other card
                if let p = prevCard, k % 2 == 1 {
                    let a = CGPoint(x: p.midX, y: p.maxY), e = CGPoint(x: card.midX, y: card.minY)
                    let d = "M \(a.x) \(a.y) C \(a.x) \(a.y + 40) \(e.x) \(e.y - 40) \(e.x) \(e.y)"
                    cards.append(["t": "path", "d": d, "stroke": made % 7 == 0 ? rust : ink2, "lw": 1.5, "dash": made % 3 == 0 ? [5, 4] : [], "cap": "round"])
                    if made % 6 == 1 {
                        let mid = CGPoint(x: (a.x + e.x) / 2, y: (a.y + e.y) / 2)
                        let label = ar ? "يرسل إلى" : "sends to"
                        let lw = CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: [.font: font(.sans, 12.5)])), nil, nil, nil))
                        cards.append(["t": "rect", "x": mid.x - lw / 2 - 6, "y": mid.y - 10, "w": lw + 12, "h": 20, "fill": "#F6F3EB", "stroke": rule, "lw": 1, "r": 2])
                        cards.append(["t": "text", "text": label, "font": "sans", "size": 12.5, "x": mid.x - lw / 2, "y": mid.y - 10, "w": lw, "h": 20, "dir": ar ? "rtl" : "ltr", "color": ink2])
                        lines.append((label, .sans, 12.5, mid.x - lw / 2, mid.y - 10, lw, 20, ar))
                    }
                }
                prevCard = card
                colY[c] += h + gap
                made += 1
            }
            let secH = (colY.max() ?? 100) + pad - gap
            items[sectionItemsStart] = ["t": "rect", "x": sx, "y": sy, "w": secW, "h": secH, "fill": wash, "stroke": rule, "lw": 1, "r": 2]
            // section name above the section, eyebrow and serif title
            items.append(["t": "text", "text": "SECTION \(s + 1)", "font": "sans-500", "size": 11, "x": sx + 2, "y": sy - 40, "w": 80, "h": 14, "dir": "ltr", "color": ink2])
            _ = text(title, face: .serif, size: 24, lh: 28, x: sx + 2, y: sy - 28, width: secW, color: ink, maxLines: 1)
            items.append(contentsOf: cards)
            sections.append(["id": "s\(s)", "title": title, "x": sx, "y": sy, "w": secW, "h": secH])
            rowH = max(rowH, secH)
            if s % 2 == 0 { sx += secW + 180 } else { sx = 0; sy += rowH + 180; rowH = 0 }
            prevCard = nil
        }
        let maxX = items.compactMap { d -> CGFloat? in guard let x = d["x"] as? CGFloat, let w = d["w"] as? CGFloat else { return nil }; return x + w }.max() ?? 0
        let maxY = items.compactMap { d -> CGFloat? in guard let y = d["y"] as? CGFloat, let h = d["h"] as? CGFloat else { return nil }; return y + h }.max() ?? 0
        // shift everything down so the section names above the first row are inside the board
        let shift: CGFloat = 60
        items = items.map { var d = $0; if let y = d["y"] as? CGFloat { d["y"] = y + shift }; if var p = d["d"] as? String, d["t"] as? String == "path" { p = shiftPath(p, shift); d["d"] = p }; return d }
        sections = sections.map { var d = $0; d["y"] = (d["y"] as! CGFloat) + shift; return d }
        notes = notes.map { var d = $0; d["y"] = (d["y"] as! CGFloat) + shift; return d }
        lines = lines.map { var l = $0; l.y += shift; return l }
        return ["size": ["w": maxX + 20, "h": maxY + shift + 20], "dir": "ltr", "title": "Readiness map", "items": items, "sections": sections, "notes": notes]
    }

    func shiftPath(_ d: String, _ dy: CGFloat) -> String {
        let parts = d.split(separator: " ")
        var out: [String] = []
        var i = 0
        var isY = false
        while i < parts.count {
            let p = parts[i]
            if let v = Double(p) { out.append(isY ? String(Double(v) + Double(dy)) : String(p)); isY.toggle() } else { out.append(String(p)); isY = false }
            i += 1
        }
        return out.joined(separator: " ")
    }
}

func strip(_ s: String) -> String {
    let marks = CharacterSet(charactersIn: "\u{064B}\u{064C}\u{064D}\u{064E}\u{064F}\u{0650}\u{0651}\u{0652}\u{0670}\u{200F}\u{200E}\u{061C}")
    let scalars = s.unicodeScalars.filter { !marks.contains($0) }
    return String(String.UnicodeScalarView(scalars)).components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
}

func run(_ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: args[0])
    p.arguments = Array(args.dropFirst())
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try? p.run()
    p.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
}

@main
struct XA {
    static func main() throws {
        let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/export-out")
        let n = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 500 : 500
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var gen = Gen()
        let json = gen.build(nodes: n)
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: out.appendingPathComponent("xa-displaylist-\(n).json"))
        let reparsed = try JSONSerialization.jsonObject(with: data)
        let t0 = Date()
        let list = try DisplayList.parse(reparsed)
        let parseTime = Date().timeIntervalSince(t0)
        print("display list: \(list.items.count) items, \(gen.lines.count) text lines, \(list.sections.count) sections, \(list.notes.count) notes, board \(Int(list.size.width)) x \(Int(list.size.height)) px, JSON \(data.count / 1024) KB, parse \(String(format: "%.3f", parseTime)) s")

        let whole = out.appendingPathComponent("xa-whole-\(n).pdf")
        let w = try BoardPDF.write(list, shape: .whole, to: whole)
        print("WHOLE: \(w.pages) pages, \(w.bytes / 1024) KB, \(String(format: "%.2f", w.seconds)) s, \(w.glyphs) glyphs as \(w.forms) forms, \(w.hiddenWords) hidden words")
        let secs = out.appendingPathComponent("xa-sections-\(n).pdf")
        let s = try BoardPDF.write(list, shape: .sections(.a4), to: secs)
        print("SECTIONS (A4): \(s.pages) pages, \(s.bytes / 1024) KB, \(String(format: "%.2f", s.seconds)) s, split: \(s.splitSections.count)")

        for (name, url) in [("whole", whole), ("sections", secs)] {
            check(name: name, url: url, gen: gen, list: list, wholeScale: name == "whole")
        }
        // A first-page preview to look at.
        if let doc = PDFDocument(url: whole), let page = doc.page(at: 0) {
            let b = page.bounds(for: .mediaBox)
            let thumb = page.thumbnail(of: NSSize(width: 2400, height: 2400 * b.height / b.width), for: .mediaBox)
            if let tiff = thumb.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: out.appendingPathComponent("xa-whole-\(n)-preview.png"))
            }
            // A crop at print size of the top left, to judge glyph quality.
            let crop = NSImage(size: NSSize(width: 1200, height: 900))
            crop.lockFocus()
            NSColor.white.set()
            NSRect(x: 0, y: 0, width: 1200, height: 900).fill()
            let ctx = NSGraphicsContext.current!.cgContext
            ctx.translateBy(x: 0, y: 900)
            ctx.scaleBy(x: 3, y: 3)
            ctx.translateBy(x: -20, y: -b.height + 10)
            page.draw(with: .mediaBox, to: ctx)
            crop.unlockFocus()
            if let tiff = crop.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: out.appendingPathComponent("xa-whole-\(n)-crop.png"))
            }
        }
        if let doc = PDFDocument(url: secs), let page = doc.page(at: 0) {
            let b = page.bounds(for: .mediaBox)
            let thumb = page.thumbnail(of: NSSize(width: 1600, height: 1600 * b.height / b.width), for: .mediaBox)
            if let tiff = thumb.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: out.appendingPathComponent("xa-sections-\(n)-p1.png"))
            }
            if doc.pageCount > 1, let last = doc.page(at: doc.pageCount - 1) {
                let lb = last.bounds(for: .mediaBox)
                let t2 = last.thumbnail(of: NSSize(width: 1200, height: 1200 * lb.height / lb.width), for: .mediaBox)
                if let tiff = t2.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                    try png.write(to: out.appendingPathComponent("xa-sections-\(n)-last.png"))
                }
            }
        }
    }

    static func check(name: String, url: URL, gen: Gen, list: DisplayList, wholeScale: Bool) {
        guard let doc = PDFDocument(url: url) else { print("\(name): PDFKit cannot open"); return }
        let all = (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined(separator: "\n")
        let normAll = strip(all)
        // every distinct line, logical order, without diacritics
        var linesFound = 0, linesTotal = 0, arabicFound = 0, arabicTotal = 0, mixedFound = 0, mixedTotal = 0
        var missing: [String] = []
        var seen = Set<String>()
        for l in gen.lines where !seen.contains(l.text) {
            seen.insert(l.text)
            linesTotal += 1
            let ok = normAll.contains(strip(l.text))
            if ok { linesFound += 1 } else if missing.count < 5 { missing.append(l.text) }
            if l.rtl {
                arabicTotal += 1; if ok { arabicFound += 1 }
                if l.text.range(of: "[A-Za-z]", options: .regularExpression) != nil { mixedTotal += 1; if ok { mixedFound += 1 } }
            }
        }
        print("[\(name)] PDFKit text: \(linesFound)/\(linesTotal) distinct lines exact (Arabic \(arabicFound)/\(arabicTotal), mixed Arabic+Latin \(mixedFound)/\(mixedTotal))")
        if !missing.isEmpty { print("  missing e.g.: \(missing.map { "«\($0)»" }.joined(separator: " "))") }
        var findLine: [String] = []
        for wd in testWords {
            let expected = gen.lines.reduce(0) { $0 + $1.text.components(separatedBy: wd).count - 1 }
            let found = doc.findString(wd, withOptions: []).count
            findLine.append("\(wd) \(found)/\(expected)")
        }
        print("  findString: " + findLine.joined(separator: ", "))
        // selection boxes against the visible glyphs (whole board only: one page, known transform)
        if wholeScale, let page = doc.page(at: 0) {
            let b = page.bounds(for: .mediaBox)
            var scale = BoardPDF.pointsPerPixel
            let longest = max(list.size.width, list.size.height) * scale + 2 * BoardPDF.margin
            if longest > BoardPDF.maxSide { scale = (BoardPDF.maxSide - 2 * BoardPDF.margin) / max(list.size.width, list.size.height) }
            let text = OutlineText(context: CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!)
            var worstX: CGFloat = 0, worstY: CGFloat = 0, sampled = 0
            var report: [String] = []
            let samples = ["Gateway", "readiness", "staging", "idempotent", "لينن", "الوكلاء", "سحابة", "مزامنة", "board.canvas", "حساب", "الماك", "Present"]
            for wd in samples {
                guard let l = gen.lines.first(where: { $0.text.contains(wd) }) else { continue }
                let line = text.typeset(l.text, face: l.face, size: l.size, rtl: l.rtl)
                let ns = l.text as NSString
                let r = ns.range(of: wd)
                // visible glyph extent of the word
                var lo = CGFloat.infinity, hi = -CGFloat.infinity
                for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                    let c = CTRunGetGlyphCount(run)
                    var idx = [CFIndex](repeating: 0, count: c), pos = [CGPoint](repeating: .zero, count: c), adv = [CGSize](repeating: .zero, count: c)
                    CTRunGetStringIndices(run, CFRange(location: 0, length: c), &idx); CTRunGetPositions(run, CFRange(location: 0, length: c), &pos); CTRunGetAdvances(run, CFRange(location: 0, length: c), &adv)
                    for i in 0..<c where idx[i] >= r.location && idx[i] < r.location + r.length { lo = min(lo, pos[i].x); hi = max(hi, pos[i].x + adv[i].width) }
                }
                let lineW = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                let x0 = l.rtl ? l.x + l.w - lineW : l.x
                let vis = CGRect(x: BoardPDF.margin + (x0 + lo) * scale, y: b.height - BoardPDF.margin - (l.y + l.h) * scale, width: (hi - lo) * scale, height: l.h * scale)
                // the selection PDFKit finds nearest to it
                let sels = doc.findString(wd, withOptions: []).filter { $0.pages.first === page }
                guard let best = sels.map({ $0.bounds(for: page) }).min(by: { abs($0.midX - vis.midX) + abs($0.midY - vis.midY) < abs($1.midX - vis.midX) + abs($1.midY - vis.midY) }) else {
                    report.append("\(wd): no selection"); continue
                }
                let dx = max(abs(best.minX - vis.minX), abs(best.maxX - vis.maxX))
                let dy = abs(best.midY - vis.midY)
                worstX = max(worstX, dx); worstY = max(worstY, dy); sampled += 1
                report.append("\(wd) x±\(String(format: "%.2f", dx)) y±\(String(format: "%.2f", dy))")
            }
            print("  selection boxes vs visible glyphs (\(sampled) words, pt): worst horizontal \(String(format: "%.2f", worstX)), worst vertical centre \(String(format: "%.2f", worstY))")
            print("    " + report.joined(separator: "; "))
            // whole lines selected by their box and copied: Arabic, mixed, English
            var copies: [String] = []
            var exact = 0, tried = 0
            let picks = [gen.lines.first(where: { $0.rtl && $0.text.contains("board.canvas") }), gen.lines.first(where: { $0.rtl && !$0.text.contains("board") && $0.text.count > 20 }),
                         gen.lines.first(where: { !$0.rtl && $0.face == .sans && $0.text.count > 25 }), gen.lines.first(where: { $0.rtl && $0.face == .serif })]
            for case let l? in picks {
                let rect = CGRect(x: BoardPDF.margin + l.x * scale - 1, y: b.height - BoardPDF.margin - (l.y + l.h) * scale + 1, width: l.w * scale + 2, height: l.h * scale - 2)
                let copied = (page.selection(for: rect)?.string ?? "").trimmingCharacters(in: .whitespaces)
                let collapse = { (x: String) in x.replacingOccurrences(of: " +", with: " ", options: .regularExpression) }
                tried += 1
                let ok = collapse(copied) == collapse(l.text) || strip(copied) == strip(l.text) && !copied.contains("\n")
                if ok { exact += 1 } else { copies.append("want «\(l.text)» got «\(copied.debugDescription)»") }
            }
            print("  lines copied by their box: \(exact)/\(tried) in order with spaces" + (copies.isEmpty ? "" : "\n    " + copies.joined(separator: "\n    ")))
        }
        let fonts = run(["/opt/homebrew/bin/pdffonts", url.path])
        let names = fonts.split(separator: "\n").dropFirst(2).map { String($0.split(separator: " ").first ?? "") }
        print("  pdffonts: \(Set(names).sorted().joined(separator: ", ")); Thmanyah present: \(fonts.lowercased().contains("thmanyah"))")
        let images = run(["/opt/homebrew/bin/pdfimages", "-list", url.path]).split(separator: "\n").count - 2
        print("  pdfimages: \(images) images")
        let info = run(["/opt/homebrew/bin/pdfinfo", url.path])
        let errors = info.split(separator: "\n").filter { $0.contains("Error") || $0.contains("error") }
        let pagesLine = info.split(separator: "\n").first { $0.hasPrefix("Pages:") } ?? ""
        print("  pdfinfo: \(pagesLine.replacingOccurrences(of: "  ", with: "")), \(errors.isEmpty ? "no errors" : errors.joined(separator: " | "))")
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/qpdf") { print("  qpdf --check: " + (run(["/opt/homebrew/bin/qpdf", "--check", url.path]).split(separator: "\n").last.map(String.init) ?? "")) }
    }
}
