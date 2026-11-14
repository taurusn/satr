import LinenKit
import SwiftUI

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
