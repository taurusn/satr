// Renders the export sheet (PRD-2 screen 10) offscreen to PNGs, in Paper and Night, for a board and a note.
//   swiftc -O -swift-version 6 -parse-as-library -o build/sheet docs/spikes/export/sheet.swift Linen/Export/*.swift \
//     Linen/Design/Tokens.swift Linen/Design/Components.swift -framework AppKit -framework SwiftUI -framework WebKit
import AppKit
import SwiftUI

@main
struct SheetShots {
    @MainActor static func main() {
        let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/export-out")
        _ = NSApplication.shared
        let board = ExportSheet.Subject.board(title: "Requests readiness", boardSize: CGSize(width: 2922, height: 11622), view: CGRect(x: 0, y: 0, width: 1176, height: 760),
                                              sections: [("s0", "Gateway readiness map", CGRect(x: 0, y: 60, width: 1352, height: 2700)), ("s1", "Identity and access", CGRect(x: 1532, y: 60, width: 1352, height: 2600))], notes: 125)
        for (name, subject, png) in [("board-pdf", board, false), ("board-png", board, true), ("note", ExportSheet.Subject.note(title: "Linen export test"), false)] {
            for night in [false, true] {
                var initial = ExportChoice()
                if png { initial.format = .png } else if name == "board-pdf" { initial.sections = true }
                let view = ExportSheet(subject: subject, initial: initial, onExport: { _ in }, onCancel: {}).environment(\.palette, night ? .night : .paper)
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                win.appearance = NSAppearance(named: night ? .darkAqua : .aqua)
                win.contentView = host
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("sheet-\(name)-\(night ? "night" : "paper").png"))
            }
        }
        print("written to \(out.path)")
    }
}

