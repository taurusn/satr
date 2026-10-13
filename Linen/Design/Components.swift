import SwiftUI

/// Linen's mark on Loom's grid: the woven square as a drop cap, with the lines of a page, right to left
/// (docs/design/make_mark.py builds the same geometry).
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
        let ox = rect.midX - (b.midX) * s, oy = rect.midY - (b.midY) * s
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

/// The woven dots behind empty and setup screens (never behind body text, PRD section 8).
struct WeaveBackground: View {
    @Environment(\.palette) private var palette
    var body: some View {
        Canvas { ctx, size in
            let tile: CGFloat = 44
            var p = Path()
            var y: CGFloat = 0
            while y < size.height + tile {
                var x: CGFloat = 0
                while x < size.width + tile {
                    p.move(to: CGPoint(x: x + 8.5, y: y + 11)); p.addLine(to: CGPoint(x: x + 13.5, y: y + 11))
                    p.move(to: CGPoint(x: x + 33, y: y + 8.5)); p.addLine(to: CGPoint(x: x + 33, y: y + 13.5))
                    p.move(to: CGPoint(x: x + 11, y: y + 30.5)); p.addLine(to: CGPoint(x: x + 11, y: y + 35.5))
                    p.move(to: CGPoint(x: x + 30.5, y: y + 33)); p.addLine(to: CGPoint(x: x + 35.5, y: y + 33))
                    x += tile
                }
                y += tile
            }
            ctx.stroke(p, with: .color(palette.weave.opacity(palette.weaveOpacity)), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
        }
        .background(palette.ground)
        .allowsHitTesting(false)
    }
}

/// The small uppercase label above titles, in ink-2 (sage fails contrast as text on paper).
struct Eyebrow: View {
    let text: LocalizedStringKey
    @Environment(\.palette) private var palette
    @Environment(\.layoutDirection) private var direction
    var body: some View {
        Text(text).textCase(.uppercase).font(Tok.sans(11, medium: true))
            .tracking(direction == .rightToLeft ? 0 : 1.5).foregroundStyle(palette.quiet)
    }
}

/// Loom buttons: ink fill or ink line, 2-point corners, the action as the label.
struct LoomButtonStyle: ButtonStyle {
    enum Kind { case fill, line }
    var kind: Kind = .fill
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Tok.sans(13.5, medium: true))
            .padding(.horizontal, 16).frame(height: 34)
            .foregroundStyle(kind == .fill ? palette.onAccent : palette.head)
            .background(RoundedRectangle(cornerRadius: Tok.corner).fill(kind == .fill ? palette.accent.opacity(configuration.isPressed ? 0.85 : 1) : .clear))
            .overlay(RoundedRectangle(cornerRadius: Tok.corner).stroke(kind == .line ? palette.head : .clear, lineWidth: 1))
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .animation(Tok.feedback, value: configuration.isPressed)
    }
}

/// Paper or Night for native screens, following the app's appearance setting.
struct LinenScreen<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @AppStorage("appearance") private var appearance = "system"
    @ViewBuilder var content: () -> Content
    var body: some View {
        let night = appearance == "night" || (appearance == "system" && scheme == .dark)
        content().environment(\.palette, night ? .night : .paper)
    }
}
