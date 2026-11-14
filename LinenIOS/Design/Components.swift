import LinenKit
import SwiftUI

/// Linen's mark on Loom's grid, as on the Mac (Linen/Design/Components.swift).
struct LinenMark: Shape {
    static let lines: [(CGPoint, CGPoint)] = {
        let ltr: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (15, 24, 33, 24), (48, 15, 48, 33), (24, 39, 24, 57), (39, 48, 57, 48),
            (81, 24, 153, 24), (81, 48, 141, 48), (15, 72, 117, 72),
        ]
        let axis: CGFloat = 84
        return ltr.map { (CGPoint(x: 2 * axis - $0.2, y: $0.3), CGPoint(x: 2 * axis - $0.0, y: $0.1)) }
    }()
    static let box = CGRect(x: 12, y: 12, width: 144, height: 63)
    var only: Int?

    func path(in rect: CGRect) -> Path {
        let b = Self.box
        let s = min(rect.width / b.width, rect.height / b.height)
        let ox = rect.midX - b.midX * s, oy = rect.midY - b.midY * s
        var p = Path()
        for (i, (a, c)) in Self.lines.enumerated() where only == nil || only == i {
            p.move(to: CGPoint(x: ox + a.x * s, y: oy + a.y * s))
            p.addLine(to: CGPoint(x: ox + c.x * s, y: oy + c.y * s))
        }
        return p
    }
}

/// The mark drawing itself: Linen's only working indicator. Whole under Reduce Motion.
struct WeaveIndicator: View {
    var lineWidth: CGFloat = 2.2
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSince(start)
            ZStack {
                ForEach(0..<LinenMark.lines.count, id: \.self) { i in
                    let (from, to) = reduceMotion ? (CGFloat(0), CGFloat(1)) : Self.trim(t - Double(i) * 0.1)
                    LinenMark(only: i).trim(from: from, to: to)
                        .stroke(palette.head, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                }
            }
            .aspectRatio(LinenMark.box.width / LinenMark.box.height, contentMode: .fit)
        }
        .accessibilityHidden(true)
    }

    static func trim(_ t: Double) -> (CGFloat, CGFloat) {
        guard t > 0 else { return (0, 0) }
        let p = t.truncatingRemainder(dividingBy: 2.2) / 2.2
        let ease = { (x: Double) -> Double in x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2 }
        if p < 0.38 { return (0, CGFloat(ease(p / 0.38))) }
        if p < 0.58 { return (0, 1) }
        if p < 0.96 { return (CGFloat(ease((p - 0.58) / 0.38)), 1) }
        return (1, 1)
    }
}

/// The sketch's line glyphs (docs/design/build_screens2.py), drawn on a 16-point grid with a 1.4 stroke.
struct Glyph: View {
    enum Name {
        case note, board, page, gear, chevron, outline, find, share, airdrop, mail, files, camera
    }

    var name: Name
    var size: CGFloat = 20
    /// Mirrors with the interface where the glyph points (the back chevron).
    @Environment(\.layoutDirection) private var direction
    @Environment(\.palette) private var palette

    init(_ name: Name, size: CGFloat = 20) {
        self.name = name
        self.size = size
    }

    var body: some View {
        GlyphShape(name: name)
            .stroke(palette.head, style: StrokeStyle(lineWidth: 1.4 * size / 16, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .scaleEffect(x: name == .chevron && direction == .rightToLeft ? -1 : 1, y: 1)
            .accessibilityHidden(true)
    }

    static func name(for kind: DocumentKind) -> Name {
        switch kind {
        case .note: .note
        case .board: .board
        case .page: .page
        }
    }
}

struct GlyphShape: Shape {
    var name: Glyph.Name

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 16
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var p = Path()
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) { p.addRect(CGRect(origin: pt(x, y), size: CGSize(width: w * s, height: h * s))) }
        func line(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) { p.move(to: pt(a, b)); p.addLine(to: pt(c, d)) }
        func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) { p.addEllipse(in: CGRect(x: rect.minX + (cx - r) * s, y: rect.minY + (cy - r) * s, width: 2 * r * s, height: 2 * r * s)) }
        switch name {
        case .note:
            box(3.5, 2.5, 9, 11); line(5.5, 5.5, 10.5, 5.5); line(5.5, 8, 10.5, 8); line(5.5, 10.5, 8.5, 10.5)
        case .board:
            box(2.5, 2.5, 4.5, 4.5); box(9, 2.5, 4.5, 3); box(9, 7.5, 4.5, 6); box(2.5, 9, 4.5, 4.5)
        case .page:
            box(2.5, 3, 11, 10); line(2.5, 5.5, 13.5, 5.5); line(4, 4.2, 4.01, 4.2); line(5.5, 4.2, 5.51, 4.2)
        case .gear:
            circle(8, 8, 2.2)
            line(8, 2.5, 8, 4.1); line(8, 11.9, 8, 13.5); line(2.5, 8, 4.1, 8); line(11.9, 8, 13.5, 8)
            line(4.1, 4.1, 5.2, 5.2); line(10.8, 10.8, 11.9, 11.9); line(4.1, 11.9, 5.2, 10.8); line(10.8, 5.2, 11.9, 4.1)
        case .chevron:
            p.move(to: pt(10, 3.5)); p.addLine(to: pt(5.5, 8)); p.addLine(to: pt(10, 12.5))
        case .outline:
            line(3, 4.5, 5, 4.5); line(3, 8, 5, 8); line(3, 11.5, 5, 11.5); line(7.5, 4.5, 13.5, 4.5); line(7.5, 8, 13.5, 8); line(7.5, 11.5, 11.5, 11.5)
        case .find:
            circle(7, 7, 4.2); line(10.2, 10.2, 13.5, 13.5)
        case .share:
            line(8, 2.5, 8, 10.5); p.move(to: pt(5, 5.5)); p.addLine(to: pt(8, 2.5)); p.addLine(to: pt(11, 5.5))
            p.move(to: pt(4, 8.5)); p.addLine(to: pt(4, 13.5)); p.addLine(to: pt(12, 13.5)); p.addLine(to: pt(12, 8.5))
        case .airdrop:
            circle(8, 8, 1.5)
            p.addArc(center: pt(8, 8), radius: 4.2 * s, startAngle: .degrees(135), endAngle: .degrees(45), clockwise: false)
            p.move(to: pt(3, 13)); p.addArc(center: pt(8, 8), radius: 7 * s, startAngle: .degrees(135), endAngle: .degrees(45), clockwise: false)
        case .mail:
            box(2.5, 4, 11, 8); p.move(to: pt(2.5, 4.5)); p.addLine(to: pt(8, 9)); p.addLine(to: pt(13.5, 4.5))
        case .files:
            p.move(to: pt(2.5, 4.5)); p.addLine(to: pt(6.5, 4.5)); p.addLine(to: pt(7.7, 6)); p.addLine(to: pt(13.5, 6))
            p.addLine(to: pt(13.5, 13)); p.addLine(to: pt(2.5, 13)); p.closeSubpath()
        case .camera:
            box(2.5, 4.5, 11, 8.5); circle(8, 8.7, 2.4); line(6, 4.5, 6.8, 3); line(6.8, 3, 9.2, 3); line(9.2, 3, 10, 4.5)
        }
        return p
    }
}

/// The woven crosses behind empty and setup screens (never behind body text, PRD section 8).
struct WeaveBackground: View {
    @Environment(\.palette) private var palette
    var body: some View {
        Canvas { ctx, size in
            let tile: CGFloat = 22
            var p = Path()
            var y: CGFloat = 0
            while y < size.height + tile {
                var x: CGFloat = 0
                while x < size.width + tile {
                    p.move(to: CGPoint(x: x + 4.25, y: y + 5.5)); p.addLine(to: CGPoint(x: x + 6.75, y: y + 5.5))
                    p.move(to: CGPoint(x: x + 16.5, y: y + 4.25)); p.addLine(to: CGPoint(x: x + 16.5, y: y + 6.75))
                    p.move(to: CGPoint(x: x + 5.5, y: y + 15.25)); p.addLine(to: CGPoint(x: x + 5.5, y: y + 17.75))
                    p.move(to: CGPoint(x: x + 15.25, y: y + 16.5)); p.addLine(to: CGPoint(x: x + 17.75, y: y + 16.5))
                    x += tile
                }
                y += tile
            }
            ctx.stroke(p, with: .color(palette.weave.opacity(palette.weaveOpacity)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        }
        .background(palette.ground)
        .allowsHitTesting(false)
    }
}

/// The small uppercase label above titles.
struct Eyebrow: View {
    let text: Text
    var paths = false
    @Environment(\.palette) private var palette
    @Environment(\.layoutDirection) private var direction

    init(_ key: LocalizedStringKey) { text = Text(key) }
    /// A folder path: its own case, never set as uppercase (PRD section 8, digits and paths).
    init(path: String) {
        text = Text(verbatim: path)
        paths = true
    }

    var body: some View {
        if paths {
            text.font(Tok.sans(13, medium: true, relativeTo: .footnote)).tracking(0.3).foregroundStyle(palette.quiet)
        } else {
            text.textCase(.uppercase).font(Tok.sans(11.5, medium: true, relativeTo: .caption))
                .tracking(direction == .rightToLeft ? 0 : 1.6).foregroundStyle(palette.quiet)
        }
    }
}

/// A Loom link: ink, medium, a quiet rule under it.
struct LinkLabel: View {
    let text: Text
    @Environment(\.palette) private var palette
    var body: some View {
        text.font(Tok.sans(14, medium: true, relativeTo: .subheadline)).foregroundStyle(palette.head)
            .padding(.bottom, 1)
            .overlay(alignment: .bottom) { Rectangle().fill(palette.night ? Tok.paper.opacity(0.4) : Tok.tint3).frame(height: 1) }
    }
}

/// Floating chrome over a board: glass, as Loom's floating panels (PRD section 8).
struct GlassPanel: ViewModifier {
    @Environment(\.palette) private var palette
    func body(content: Content) -> some View {
        content
            .background(palette.night ? Tok.ink2.opacity(0.9) : Tok.paper.opacity(0.9))
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: Tok.corner))
            .overlay(RoundedRectangle(cornerRadius: Tok.corner).stroke(palette.line, lineWidth: 1))
            .shadow(color: Tok.ink.opacity(0.12), radius: 13, y: 10)
    }
}

extension View {
    func glass() -> some View { modifier(GlassPanel()) }
}

/// A 44-point tap target around a glyph.
struct GlyphButton: View {
    let glyph: Glyph.Name
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Glyph(glyph).frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}
