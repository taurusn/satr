import AppKit
import SwiftUI

/// Loom's tokens (PRD section 8), the only colours Linen's native screens use. `Scripts/lint-tokens.py` checks
/// them against Loom's DESIGN.md and Ferry's tokens, and against Renderer/page.css.
enum Tok {
    static let paper = Color(hex: 0xF6F3EB)
    static let paper2 = Color(hex: 0xFBF9F4)
    static let ink = Color(hex: 0x284734)
    static let ink2 = Color(hex: 0x1F3328)
    static let sage = Color(hex: 0x8FA394)
    static let rule = Color(hex: 0xDAD5C8)
    static let tint1 = Color(hex: 0xE3E7DF)
    static let tint2 = Color(hex: 0xC9D3CA)
    static let tint3 = Color(hex: 0xA9B8AC)
    static let rust = Color(hex: 0x9C4A2E)
    static let inkPressed = Color(hex: 0x1F3A2A)

    static let corner: CGFloat = 2
    static let brandCurve = Animation.timingCurve(0.22, 0.8, 0.2, 1, duration: 0.34)
    static let feedback = Animation.easeInOut(duration: 0.15)

    static func serif(_ size: CGFloat) -> Font { .custom("thmanyahserifdisplay-Light", fixedSize: size) }
    static func sans(_ size: CGFloat, medium: Bool = false) -> Font {
        .custom(medium ? "thmanyahsans-Medium" : "thmanyahsans-Regular", fixedSize: size)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

extension NSColor {
    static let linenPaper = NSColor(srgbRed: 0xF6 / 255, green: 0xF3 / 255, blue: 0xEB / 255, alpha: 1)
    static let linenInk2 = NSColor(srgbRed: 0x1F / 255, green: 0x33 / 255, blue: 0x28 / 255, alpha: 1)
    static let linenInk = NSColor(srgbRed: 0x28 / 255, green: 0x47 / 255, blue: 0x34 / 255, alpha: 1)
}

/// Paper or Night: the suite's Night, defined once from Ferry's values (PRD 8.1).
struct Palette {
    var ground: Color
    var raised: Color
    var text: Color
    var head: Color
    var quiet: Color
    var line: Color
    var accent: Color
    var onAccent: Color
    var weave: Color
    var weaveOpacity: Double

    static let paper = Palette(ground: Tok.paper, raised: Tok.paper2, text: Tok.ink2, head: Tok.ink, quiet: Tok.ink2,
                               line: Tok.rule, accent: Tok.ink, onAccent: Tok.paper, weave: Tok.ink, weaveOpacity: 0.13)
    static let night = Palette(ground: Tok.ink2, raised: Tok.ink, text: Tok.paper, head: Tok.paper, quiet: Tok.sage,
                               line: Tok.paper.opacity(0.14), accent: Tok.paper, onAccent: Tok.ink2, weave: Tok.paper, weaveOpacity: 0.09)
}

private struct PaletteKey: EnvironmentKey { static let defaultValue = Palette.paper }
extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}
