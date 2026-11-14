import AppKit
import SwiftUI

// Buttons and checkboxes with real accessibility titles. On macOS a SwiftUI button or toggle reports its label only as
// an accessibility description, never as a title (checked 2026-11-14 with plain, bordered, default and custom styles),
// so a script, VoiceOver's item chooser or Ferry driving the Mac finds no "Cancel" by name: on 2026-11-11 the Keep on
// iPhone sheet's checkboxes could be ticked only by position. These wrap AppKit's own controls, which carry the title,
// and draw the push button as `LoomButtonStyle` does.

/// A push button drawn as `LoomButtonStyle`, with its title as its accessibility title.
struct TitledButton: NSViewRepresentable {
    enum Key { case none, defaultAction, cancelAction }

    let title: String
    var kind: LoomButtonStyle.Kind = .fill
    var key: Key = .none
    /// A stable name for scripts and tests (AXIdentifier).
    var identifier: String?
    let action: () -> Void
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var enabled

    init(_ title: String, kind: LoomButtonStyle.Kind = .fill, key: Key = .none, identifier: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.kind = kind
        self.key = key
        self.identifier = identifier
        self.action = action
    }

    func makeNSView(context: Context) -> LoomNSButton {
        let b = LoomNSButton()
        b.target = context.coordinator
        b.action = #selector(Coordinator.press)
        return b
    }

    func updateNSView(_ b: LoomNSButton, context: Context) {
        context.coordinator.action = action
        b.title = title
        b.kind = kind
        b.fill = NSColor(palette.accent)
        b.ink = NSColor(kind == .fill ? palette.onAccent : palette.head)
        b.isEnabled = enabled
        b.keyEquivalent = switch key {
        case .none: ""
        case .defaultAction: "\r"
        case .cancelAction: "\u{1b}"
        }
        if let identifier { b.setAccessibilityIdentifier(identifier) }
        b.invalidateIntrinsicContentSize()
        b.needsDisplay = true
    }

    /// Its own size, as a SwiftUI button with `LoomButtonStyle` takes: it never stretches across a row.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LoomNSButton, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator: NSObject {
        var action: () -> Void = {}
        @objc func press() { action() }
    }
}

/// The push button behind `TitledButton`: Loom's 34-point button, 2-point corners, Thmanyah Sans Medium 13.5.
final class LoomNSButton: NSButton {
    var kind: LoomButtonStyle.Kind = .fill
    var fill: NSColor = .linenInk
    var ink: NSColor = .linenPaper

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        setButtonType(.momentaryPushIn)
        focusRingType = .default
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    static let font = NSFont(name: "thmanyahsans-Medium", size: 13.5) ?? .systemFont(ofSize: 13.5, weight: .medium)

    private var label: NSAttributedString {
        NSAttributedString(string: title, attributes: [.font: Self.font, .foregroundColor: ink])
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(label.size().width) + 32, height: 34)
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Tok.corner, yRadius: Tok.corner)
        NSGraphicsContext.saveGraphicsState()
        if !isEnabled { NSGraphicsContext.current?.cgContext.setAlpha(0.4) }
        switch kind {
        case .fill:
            fill.withAlphaComponent(isHighlighted ? 0.85 : 1).setFill()
            box.fill()
        case .line:
            // Pressed, the line and its label dim as the fill does (review P3-7).
            if isHighlighted { NSGraphicsContext.current?.cgContext.setAlpha(isEnabled ? 0.6 : 0.24) }
            ink.setStroke()
            box.lineWidth = 1
            box.stroke()
        }
        let s = label.size()
        label.draw(at: NSPoint(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A checkbox whose title (a file name, say) is its accessibility title. Long titles shorten in the middle.
struct TitledCheckbox: NSViewRepresentable {
    let title: String
    @Binding var isOn: Bool
    var identifier: String?
    @Environment(\.palette) private var palette

    func makeNSView(context: Context) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: context.coordinator, action: #selector(Coordinator.toggled(_:)))
        b.lineBreakMode = .byTruncatingMiddle
        b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return b
    }

    func updateNSView(_ b: NSButton, context: Context) {
        context.coordinator.set = { isOn = $0 }
        b.title = title
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont(name: "thmanyahsans-Regular", size: 13.5) ?? .systemFont(ofSize: 13.5),
            .foregroundColor: NSColor(palette.text),
            .paragraphStyle: { let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingMiddle; return p }(),
        ])
        b.state = isOn ? .on : .off
        // The box is drawn by AppKit in the view's appearance; Paper fixed while macOS is dark drew a dark box on paper.
        b.appearance = NSAppearance(named: palette.ground == Palette.night.ground ? .darkAqua : .aqua)
        if let identifier { b.setAccessibilityIdentifier(identifier) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        let natural = nsView.intrinsicContentSize
        return CGSize(width: min(natural.width, proposal.width ?? natural.width), height: natural.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator: NSObject {
        var set: (Bool) -> Void = { _ in }
        @objc func toggled(_ b: NSButton) { set(b.state == .on) }
    }
}
