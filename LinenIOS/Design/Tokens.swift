import CoreText
import SwiftUI
import UIKit

/// Loom's tokens (PRD section 8), the only colours Linen's native screens use, as on the Mac (Linen/Design/Tokens.swift).
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

    static let corner: CGFloat = 2
    static let brandCurve = Animation.timingCurve(0.22, 0.8, 0.2, 1, duration: 0.34)

    /// Thmanyah Serif Display Light, following Dynamic Type from `size` at the default text size (IOS-5).
    static func serif(_ size: CGFloat, relativeTo style: Font.TextStyle = .largeTitle) -> Font {
        .custom("thmanyahserifdisplay-Light", size: size, relativeTo: style)
    }

    static func sans(_ size: CGFloat, medium: Bool = false, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(medium ? "thmanyahsans-Medium" : "thmanyahsans-Regular", size: size, relativeTo: style)
    }

    /// The faces the renderer ships (copied in by Scripts/copy-renderer.sh), registered for the native screens too.
    static func registerFaces() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("renderer/fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "otf" {
            CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

extension UIColor {
    static let linenPaper = UIColor(red: 0xF6 / 255, green: 0xF3 / 255, blue: 0xEB / 255, alpha: 1)
    static let linenInk2 = UIColor(red: 0x1F / 255, green: 0x33 / 255, blue: 0x28 / 255, alpha: 1)
}

/// Paper or Night: the suite's Night, as on the Mac (PRD 8.1).
struct Palette: Equatable {
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
    var night: Bool

    static let paper = Palette(ground: Tok.paper, raised: Tok.paper2, text: Tok.ink2, head: Tok.ink, quiet: Tok.ink2,
                               line: Tok.rule, accent: Tok.ink, onAccent: Tok.paper, weave: Tok.ink, weaveOpacity: 0.13, night: false)
    static let night = Palette(ground: Tok.ink2, raised: Tok.ink, text: Tok.paper, head: Tok.paper, quiet: Tok.sage,
                               line: Tok.paper.opacity(0.14), accent: Tok.paper, onAccent: Tok.ink2, weave: Tok.paper, weaveOpacity: 0.09, night: true)

    /// The renderer's name for this look.
    var theme: String { night ? "night" : "paper" }
    var groundUIColor: UIColor { night ? .linenInk2 : .linenPaper }
}

private struct PaletteKey: EnvironmentKey { static let defaultValue = Palette.paper }
extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}
