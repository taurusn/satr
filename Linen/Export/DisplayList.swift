import CoreGraphics
import Foundation
import ImageIO

/// A board as a list of marks, the hand-over from the renderer to export (PRD-2 EXP-5). The renderer's
/// `displayList` command (`Renderer/board.js`) returns it as JSON in board pixels, items in paint order; `origin` is
/// the board point at the export's top left, so every coordinate here is moved by it. Linen draws it natively, so
/// no text in an export comes from WebKit.
///
///     { "size": {"w", "h"}, "origin": {"x", "y"}, "dir": "ltr"|"rtl", "title": str,
///       "items": [
///         {"t": "rect", "x", "y", "w", "h", "fill", "stroke", "lw", "r", "dash": [on, off]|null, "shadow": bool,
///          "role": "section"|"node"|"pill", "shape": "outline"|"threads"|"solid"|"dashed"|"dotted"|"rust", "id"},
///         {"t": "path", "d": "M 0 0 C ...", "fill", "stroke", "lw", "dash", "cap", "role", "id"},
///         {"t": "text", "text", "font": "sans"|"serif-display"|"serif-text"|"mono", "weight", "size", "x", "y", "w", "h",
///          "dir", "color", "upper": bool, "tracking": px, "anchor": "middle", "chip": bool, "role", "id"},
///         {"t": "image", "src": "data:..." | a file path the caller resolves, "x", "y", "w", "h", "id"},
///         {"t": "clip", "x", "y", "w", "h"}, {"t": "unclip"} ],
///       "sections": [{"id", "name", "x", "y", "w", "h", "depth"}],
///       "notes": [{"id", "title", "area", "body", "refs": [str]}] }
///
/// A text item is one line as WebKit laid it out: `y` and `h` its text box (a centred label: `x` its middle, `w` 0),
/// `text` its characters in logical order before `upper`. Colours are CSS strings. Notes are numbered in their order
/// and each number sits on the box with the note's `id`.
struct DisplayList: Sendable {
    var size: CGSize
    var rtl: Bool
    var title: String
    var items: [Item]
    var sections: [Section]
    var notes: [Note]

    enum Item: Sendable {
        case rect(Box)
        case path(Shape)
        case text(Line)
        case image(Picture)
        case clip(CGRect)
        case unclip
    }

    struct Box: Sendable {
        var rect: CGRect
        var fill: RGBA?
        var stroke: RGBA?
        var lineWidth: CGFloat
        var radius: CGFloat
        var dash: [CGFloat]
        var shadow: Bool
        var hatch: Hatch?
        var node: String?
        var role: String? = nil
    }

    struct Hatch: Sendable {
        var color: RGBA
        var gap: CGFloat
        var lineWidth: CGFloat
    }

    /// `@unchecked`: the path is an immutable copy made once by `SVGPath.parse`, never mutated after.
    struct Shape: @unchecked Sendable {
        let path: CGPath
        var fill: RGBA?
        var stroke: RGBA?
        var lineWidth: CGFloat
        var dash: [CGFloat]
        var roundCap: Bool
    }

    struct Line: Sendable {
        var text: String
        var face: Face
        var size: CGFloat
        var rect: CGRect
        var baseline: CGFloat?
        var rtl: Bool
        var color: RGBA
        /// Letter spacing in pixels (eyebrows).
        var tracking: CGFloat = 0
        /// `rect.minX` is the line's middle (connector labels).
        var centered = false
        /// Drawn on a paper chip (connector labels, BRD-4).
        var chip = false
        /// The renderer's role ("section-name", "edge-label"); nil for a box's own text.
        var role: String? = nil
        /// The box this text belongs to: it is clipped to it, as the reader clips a card (`.b-node` overflow).
        var node: String? = nil
    }

    struct Picture: Sendable {
        var data: Data
        var rect: CGRect
    }

    struct Section: Sendable {
        var id: String
        var title: String
        var rect: CGRect
        /// 0 for a top-level section; nested sections print inside their parent.
        var depth: Int = 0
    }

    struct Note: Sendable {
        var number: Int
        var title: String
        var area: String
        var body: String
        var refs: [String]
        var anchor: CGPoint?
    }

    enum Problem: Error, CustomStringConvertible {
        case notAnObject, badSize, tooLarge(Int)
        var description: String {
            switch self {
            case .notAnObject: "The display list is not an object"
            case .badSize: "The display list has no size"
            case let .tooLarge(n): "The display list has \(n) items, more than export draws"
            }
        }
    }

    /// The most items one export draws (a 2,000-node board with its connectors and text lines fits well under it).
    static let maxItems = 400_000

    /// Images one export carries: each at most 25 MB of file and 50 megapixels, 150 MB in all.
    static let maxImageBytes = 25_000_000, maxImagePixels = 50_000_000, maxImageTotal = 150_000_000

    /// Reads the JSON the page returns (a dictionary from `callAsyncJavaScript` or `JSONSerialization`). `image`
    /// gives the bytes for a picture the board names by path (the caller reads it through the vault gate, SAFE-2);
    /// a picture it cannot give is drawn as a frame with its name.
    static func parse(_ any: Any, image: ((String) -> Data?)? = nil) throws -> DisplayList {
        guard let o = any as? [String: Any] else { throw Problem.notAnObject }
        guard let s = o["size"] as? [String: Any], let w = num(s["w"]), let h = num(s["h"]), w > 0, h > 0, w.isFinite, h.isFinite else {
            throw Problem.badSize
        }
        let origin = (o["origin"] as? [String: Any]).map { CGPoint(x: num($0["x"]) ?? 0, y: num($0["y"]) ?? 0) } ?? .zero
        let raw = o["items"] as? [Any] ?? []
        if raw.count > maxItems { throw Problem.tooLarge(raw.count) }
        var items: [Item] = []
        items.reserveCapacity(raw.count)
        var budget = maxImageTotal
        var imagesLeft = 500
        var anchors: [String: CGRect] = [:]
        for case let it as [String: Any] in raw {
            let isImage = (it["t"] as? String) == "image"
            if isImage { imagesLeft -= 1 }
            for item in Self.items(it, origin: origin, image: image, allowImages: imagesLeft >= 0, budget: &budget) {
                if case let .rect(b) = item, let id = b.node, b.role != "pill" { anchors[id] = anchors[id] ?? b.rect }
                items.append(item)
            }
        }
        let rtl = (o["dir"] as? String) == "rtl"
        let sections: [Section] = (o["sections"] as? [Any] ?? []).compactMap {
            guard let d = $0 as? [String: Any], let r = rect(d, origin: origin) else { return nil }
            return Section(id: d["id"] as? String ?? "", title: d["title"] as? String ?? d["name"] as? String ?? "", rect: r,
                           depth: int(d["depth"], in: 0...1000) ?? 0)
        }
        let notes: [Note] = (o["notes"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }.enumerated().map { i, d in
            // explicit anchor (x, y) or the top trailing corner of the box the note belongs to
            var anchor: CGPoint?
            if let x = num(d["x"]), let y = num(d["y"]) { anchor = CGPoint(x: x - origin.x, y: y - origin.y) }
            else if let id = d["id"] as? String, let r = anchors[id] { anchor = CGPoint(x: rtl ? r.minX : r.maxX, y: r.minY) }
            return Note(number: int(d["n"], in: 1...1_000_000) ?? i + 1, title: d["title"] as? String ?? "",
                        area: d["area"] as? String ?? "", body: d["body"] as? String ?? "",
                        refs: (d["refs"] as? [Any] ?? []).compactMap { $0 as? String }, anchor: anchor)
        }.sorted { $0.number < $1.number }
        return DisplayList(size: CGSize(width: w, height: h), rtl: rtl,
                           title: o["title"] as? String ?? "", items: items, sections: sections, notes: notes)
    }

    private static func items(_ d: [String: Any], origin: CGPoint, image: ((String) -> Data?)?, allowImages: Bool, budget: inout Int) -> [Item] {
        switch d["t"] as? String {
        case "rect":
            guard let r = rect(d, origin: origin) else { return [] }
            let role = d["role"] as? String
            var hatch: Hatch?
            if let h = d["hatch"] as? [String: Any], let c = RGBA.parse(h["color"]) {
                hatch = Hatch(color: c, gap: max(2, num(h["gap"]) ?? 6), lineWidth: max(0.25, num(h["lw"]) ?? 1))
            } else if role == "pill", (d["shape"] as? String) == "threads" {
                // Partial's ink threads (WORDS-2), which the renderer draws with a CSS gradient.
                hatch = Hatch(color: RGBA.parse(d["stroke"]) ?? .ink, gap: 4, lineWidth: 0.75)
            }
            return [.rect(Box(rect: r, fill: RGBA.parse(d["fill"]), stroke: RGBA.parse(d["stroke"]), lineWidth: num(d["lw"]) ?? 1,
                              radius: max(0, num(d["r"]) ?? 0), dash: dash(d["dash"]), shadow: (d["shadow"] as? Bool) ?? (role == "node" && (d["kind"] as? String) == "card"),
                              hatch: hatch, node: d["node"] as? String ?? d["id"] as? String, role: role))]
        case "path":
            guard let s = d["d"] as? String, var p = SVGPath.parse(s) else { return [] }
            if origin != .zero {
                var t = CGAffineTransform(translationX: -origin.x, y: -origin.y)
                guard let moved = p.copy(using: &t) else { return [] }
                p = moved
            }
            return [.path(Shape(path: p, fill: RGBA.parse(d["fill"]), stroke: RGBA.parse(d["stroke"]), lineWidth: num(d["lw"]) ?? 1,
                                dash: dash(d["dash"]), roundCap: (d["cap"] as? String) == "round"))]
        case "text":
            guard var t = d["text"] as? String, !t.isEmpty, let r = rect(d, origin: origin, allowZeroHeight: true), let size = num(d["size"]), size > 0, size < 2000 else { return [] }
            if (d["upper"] as? Bool) == true { t = t.uppercased() }
            return [.text(Line(text: t, face: face(d["font"] as? String, weight: int(d["weight"], in: 1...1000) ?? 400), size: size, rect: r,
                               baseline: num(d["baseline"]).map { $0 - origin.y }, rtl: (d["dir"] as? String) == "rtl",
                               color: RGBA.parse(d["color"]) ?? .ink2, tracking: num(d["tracking"]) ?? 0,
                               centered: (d["anchor"] as? String) == "middle", chip: (d["chip"] as? Bool) ?? false, role: d["role"] as? String,
                               node: d["role"] == nil ? d["id"] as? String : nil))]
        case "image":
            guard let r = rect(d, origin: origin), let src = d["src"] as? String else { return [] }
            if allowImages, let data = (src.hasPrefix("data:") ? dataURL(src) : image?(src)), data.count <= maxImageBytes, data.count <= budget,
               let isrc = CGImageSourceCreateWithData(data as CFData, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(isrc, 0, nil) as? [CFString: Any],
               let pw = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, let ph = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
               pw > 0, ph > 0, Double(pw) * Double(ph) <= Double(maxImagePixels) {
                budget -= data.count
                return [.image(Picture(data: data, rect: r))]
            }
            // A picture that cannot travel: its frame and its name, so nothing silently disappears.
            let name = (src.hasPrefix("data:") ? "" : (src as NSString).lastPathComponent)
            var out: [Item] = [.rect(Box(rect: r, fill: nil, stroke: .rule, lineWidth: 1, radius: 2, dash: [3, 2], shadow: false, hatch: nil, node: nil, role: "missing-image"))]
            if !name.isEmpty {
                out.append(.text(Line(text: name, face: .sans, size: 12, rect: CGRect(x: r.minX + 8, y: r.minY + 8, width: max(0, r.width - 16), height: 16),
                                      baseline: nil, rtl: OutlineText.isRTL(name), color: .ink2)))
            }
            return out
        case "clip":
            return rect(d, origin: origin).map { [.clip($0)] } ?? []
        case "unclip":
            return [.unclip]
        default:
            return []
        }
    }

    /// The renderer names a role and a weight; export draws one of Linen's faces.
    static func face(_ name: String?, weight: Int) -> Face {
        switch name {
        case "serif", "serif-display": return .serif
        case "serif-text", "serif-text-500": return weight >= 500 || name == "serif-text-500" ? .serifText500 : .serifText
        case "mono": return .mono
        case "sans-500": return .sans500
        case "sans-700": return .sans700
        default: return weight >= 600 ? .sans700 : weight >= 500 ? .sans500 : .sans
        }
    }

    /// A whole number in a sane range, or nil (never traps on 1e100 or NaN).
    static func int(_ v: Any?, in range: ClosedRange<Int> = -1_000_000...1_000_000) -> Int? {
        guard let d = num(v), let i = Int(exactly: d.rounded()), range.contains(i) else { return nil }
        return i
    }

    static func num(_ v: Any?) -> CGFloat? {
        if let n = v as? NSNumber { let d = n.doubleValue; return d.isFinite ? CGFloat(d) : nil }
        if let d = v as? Double { return d.isFinite ? CGFloat(d) : nil }
        if let i = v as? Int { return CGFloat(i) }
        return nil
    }

    private static func rect(_ d: [String: Any], origin: CGPoint = .zero, allowZeroHeight: Bool = false) -> CGRect? {
        guard let x = num(d["x"]), let y = num(d["y"]), let w = num(d["w"]) else { return nil }
        let h = num(d["h"]) ?? 0
        guard w >= 0, h >= 0, w < 1e7, h < 1e7, allowZeroHeight || h > 0 || w > 0 else { return nil }
        return CGRect(x: x - origin.x, y: y - origin.y, width: w, height: h)
    }

    private static func dash(_ v: Any?) -> [CGFloat] {
        (v as? [Any] ?? []).compactMap { num($0) }.filter { $0 > 0 }
    }

    /// Only `data:` images: export never reads the disk or the network for a picture.
    private static func dataURL(_ s: String) -> Data? {
        // a payload past the image limit is refused before it is decoded
        guard s.hasPrefix("data:"), s.utf8.count <= maxImageBytes / 3 * 4 + 1024, let comma = s.firstIndex(of: ",") else { return nil }
        let head = s[s.index(s.startIndex, offsetBy: 5)..<comma]
        guard head.hasSuffix(";base64") else { return nil }
        return Data(base64Encoded: String(s[s.index(after: comma)...]), options: .ignoreUnknownCharacters)
    }
}

/// Linen's faces by role. Export draws them as Thmanyah outlines; `mono` is the system's monospaced face.
enum Face: String, Sendable, CaseIterable {
    case sans, sans500 = "sans-500", sans700 = "sans-700", serif, serifText = "serif-text", serifText500 = "serif-text-500", mono

    var postScriptName: String {
        switch self {
        case .sans: "thmanyahsans-Regular"
        case .sans500: "thmanyahsans-Medium"
        case .sans700: "thmanyahsans-Bold"
        case .serif: "thmanyahserifdisplay-Light"
        case .serifText: "thmanyahseriftext-Regular"
        case .serifText500: "thmanyahseriftext-Medium"
        case .mono: "Menlo-Regular"
        }
    }
}

/// A colour in sRGB. Loom's tokens are the only colours the renderer sends; this parses what CSS prints.
struct RGBA: Sendable, Hashable {
    var r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat

    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var key: String { String(format: "%02x%02x%02x%02x", Int(r * 255), Int(g * 255), Int(b * 255), Int(a * 255)) }

    static let paper = RGBA(hex: 0xF6F3EB)
    static let paper2 = RGBA(hex: 0xFBF9F4)
    static let ink = RGBA(hex: 0x284734)
    static let ink2 = RGBA(hex: 0x1F3328)
    static let rule = RGBA(hex: 0xDAD5C8)
    static let tint1 = RGBA(hex: 0xE3E7DF)
    static let rust = RGBA(hex: 0x9C4A2E)

    init(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    init(hex: UInt32, a: CGFloat = 1) {
        self.init(r: CGFloat((hex >> 16) & 0xFF) / 255, g: CGFloat((hex >> 8) & 0xFF) / 255, b: CGFloat(hex & 0xFF) / 255, a: a)
    }

    static func parse(_ v: Any?) -> RGBA? {
        guard let s0 = v as? String else { return nil }
        let s = s0.trimmingCharacters(in: .whitespaces).lowercased()
        if s.isEmpty || s == "none" || s == "transparent" { return nil }
        if s.hasPrefix("#") {
            let hex = String(s.dropFirst())
            if hex.count == 3, let v = UInt32(hex, radix: 16) {
                let r = (v >> 8) & 0xF, g = (v >> 4) & 0xF, b = v & 0xF
                return RGBA(hex: (r * 17) << 16 | (g * 17) << 8 | b * 17)
            }
            if hex.count == 6, let v = UInt32(hex, radix: 16) { return RGBA(hex: v) }
            if hex.count == 8, let v = UInt32(hex, radix: 16) { return RGBA(hex: v >> 8, a: CGFloat(v & 0xFF) / 255) }
            return nil
        }
        if s.hasPrefix("rgb"), let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")") {
            let parts = s[s.index(after: open)..<close].split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")) }
            guard parts.count >= 3 else { return nil }
            let c = RGBA(r: CGFloat(parts[0]) / 255, g: CGFloat(parts[1]) / 255, b: CGFloat(parts[2]) / 255, a: parts.count > 3 ? CGFloat(parts[3]) : 1)
            return c.a <= 0 ? nil : c
        }
        return nil
    }
}

/// SVG path data (`M L H V C S Q T A Z`, absolute and relative) into a CGPath in the same coordinates.
enum SVGPath {
    static func parse(_ d: String) -> CGPath? {
        var tokens: [Substring] = []
        var i = d.startIndex
        while i < d.endIndex {
            let c = d[i]
            if c.isLetter && c != "e" && c != "E" {
                tokens.append(d[i...i]); i = d.index(after: i); continue
            }
            if c == "-" || c == "+" || c == "." || c.isNumber {
                var j = d.index(after: i)
                var seenDot = c == ".", seenExp = false
                while j < d.endIndex {
                    let k = d[j]
                    if k.isNumber { j = d.index(after: j); continue }
                    if k == "." && !seenDot && !seenExp { seenDot = true; j = d.index(after: j); continue }
                    if (k == "e" || k == "E") && !seenExp {
                        seenExp = true; j = d.index(after: j)
                        if j < d.endIndex, d[j] == "-" || d[j] == "+" { j = d.index(after: j) }
                        continue
                    }
                    break
                }
                tokens.append(d[i..<j]); i = j; continue
            }
            i = d.index(after: i)
        }
        let path = CGMutablePath()
        var cmd: Character = "M"
        var t = 0
        var cur = CGPoint.zero, start = CGPoint.zero, lastCtl: CGPoint?, lastQuad: CGPoint?
        func next() -> CGFloat? {
            guard t < tokens.count, let v = Double(tokens[t]) else { return nil }
            t += 1
            return CGFloat(v)
        }
        func hasNumber() -> Bool { t < tokens.count && Double(tokens[t]) != nil }
        while t < tokens.count {
            if let ch = tokens[t].first, tokens[t].count == 1, ch.isLetter { cmd = ch; t += 1 }
            let rel = cmd.isLowercase
            let base = rel ? cur : .zero
            switch cmd.uppercased().first! {
            case "M":
                guard let x = next(), let y = next() else { return path.isEmpty ? nil : path.copy() }
                cur = CGPoint(x: base.x + x, y: base.y + y); start = cur
                path.move(to: cur)
                cmd = rel ? "l" : "L"
                lastCtl = nil; lastQuad = nil
            case "L":
                guard let x = next(), let y = next() else { return path.copy() }
                cur = CGPoint(x: base.x + x, y: base.y + y)
                if path.isEmpty { path.move(to: cur) } else { path.addLine(to: cur) }
                lastCtl = nil; lastQuad = nil
            case "H":
                guard let x = next() else { return path.copy() }
                cur = CGPoint(x: (rel ? cur.x : 0) + x, y: cur.y); path.addLine(to: cur)
                lastCtl = nil; lastQuad = nil
            case "V":
                guard let y = next() else { return path.copy() }
                cur = CGPoint(x: cur.x, y: (rel ? cur.y : 0) + y); path.addLine(to: cur)
                lastCtl = nil; lastQuad = nil
            case "C":
                guard let x1 = next(), let y1 = next(), let x2 = next(), let y2 = next(), let x = next(), let y = next() else { return path.copy() }
                let c1 = CGPoint(x: base.x + x1, y: base.y + y1), c2 = CGPoint(x: base.x + x2, y: base.y + y2)
                cur = CGPoint(x: base.x + x, y: base.y + y)
                path.addCurve(to: cur, control1: c1, control2: c2)
                lastCtl = c2; lastQuad = nil
            case "S":
                guard let x2 = next(), let y2 = next(), let x = next(), let y = next() else { return path.copy() }
                let c1 = lastCtl.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let c2 = CGPoint(x: base.x + x2, y: base.y + y2)
                cur = CGPoint(x: base.x + x, y: base.y + y)
                path.addCurve(to: cur, control1: c1, control2: c2)
                lastCtl = c2; lastQuad = nil
            case "Q":
                guard let x1 = next(), let y1 = next(), let x = next(), let y = next() else { return path.copy() }
                let c = CGPoint(x: base.x + x1, y: base.y + y1)
                cur = CGPoint(x: base.x + x, y: base.y + y)
                path.addQuadCurve(to: cur, control: c)
                lastQuad = c; lastCtl = nil
            case "T":
                guard let x = next(), let y = next() else { return path.copy() }
                let c = lastQuad.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                cur = CGPoint(x: base.x + x, y: base.y + y)
                path.addQuadCurve(to: cur, control: c)
                lastQuad = c; lastCtl = nil
            case "A":
                guard let rx = next(), let ry = next(), let rot = next(), let large = next(), let sweep = next(), let x = next(), let y = next() else { return path.copy() }
                let end = CGPoint(x: base.x + x, y: base.y + y)
                arc(path, from: cur, to: end, rx: rx, ry: ry, rotation: rot, large: large != 0, sweep: sweep != 0)
                cur = end
                lastCtl = nil; lastQuad = nil
            case "Z":
                path.closeSubpath(); cur = start
                lastCtl = nil; lastQuad = nil
                if hasNumber() { cmd = rel ? "l" : "L" }
            default:
                t += 1
            }
        }
        return path.isEmpty ? nil : path.copy()
    }

    /// SVG's endpoint arc as cubic curves (SVG 1.1 appendix F.6).
    private static func arc(_ path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx rx0: CGFloat, ry ry0: CGFloat,
                            rotation: CGFloat, large: Bool, sweep: Bool) {
        var rx = abs(rx0), ry = abs(ry0)
        if rx == 0 || ry == 0 || p0 == p1 { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180, cosP = cos(phi), sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosP * dx + sinP * dy, y1 = -sinP * dx + cosP * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = sqrt(max(0, num / den))
        if large == sweep { coef = -coef }
        let cx1 = coef * rx * y1 / ry, cy1 = -coef * ry * x1 / rx
        let cx = cosP * cx1 - sinP * cy1 + (p0.x + p1.x) / 2
        let cy = sinP * cx1 + cosP * cy1 + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi } else if sweep && delta < 0 { delta += 2 * .pi }
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        func point(_ t: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * cos(t) * cosP - ry * sin(t) * sinP, y: cy + rx * cos(t) * sinP + ry * sin(t) * cosP)
        }
        func deriv(_ t: CGFloat) -> CGPoint {
            CGPoint(x: -rx * sin(t) * cosP - ry * cos(t) * sinP, y: -rx * sin(t) * sinP + ry * cos(t) * cosP)
        }
        let k = 4 / 3 * tan(step / 4)
        var t0 = theta1
        for _ in 0..<segments {
            let t1 = t0 + step
            let a = point(t0), b = point(t1), da = deriv(t0), db = deriv(t1)
            path.addCurve(to: b, control1: CGPoint(x: a.x + k * da.x, y: a.y + k * da.y), control2: CGPoint(x: b.x - k * db.x, y: b.y - k * db.y))
            t0 = t1
        }
    }
}
