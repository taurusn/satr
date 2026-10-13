import AppKit
import SwiftUI

/// Settings (SYS-1), in Ferry Host's pattern: eyebrow, serif title, ruled rows.
struct SettingsView: View {
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("bodyFace") private var face = "sans"
    @AppStorage("defaultZoom") private var zoom = 1.0
    @AppStorage("editorBundleID") private var editor = ""
    @AppStorage("remoteImagesAlways") private var remoteAlways = false
    @Environment(\.palette) private var palette
    @State private var editors: [(String, String)] = []

    var body: some View {
        ZStack(alignment: .topLeading) {
            WeaveBackground()
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow(text: "Linen")
                Text("Settings").font(Tok.serif(34)).foregroundStyle(palette.head).padding(.top, 4).padding(.bottom, 16)
                row("Appearance") { segmented($appearance, [("paper", "Paper"), ("night", "Night"), ("system", "Follow system")]) }
                row("Body face") { segmented($face, [("sans", "Thmanyah Sans"), ("serif", "Serif Text")]) }
                row("Text size") {
                    HStack(spacing: 0) {
                        cell("−", selected: false) { zoom = max(0.7, zoom - 0.1) }
                        cell("\(Int((zoom * 100).rounded()))%", selected: true) { zoom = 1 }
                        cell("+", selected: false) { zoom = min(2, zoom + 0.1) }
                    }
                    .overlay(RoundedRectangle(cornerRadius: Tok.corner).stroke(palette.line))
                }
                row("Open in Editor") {
                    Picker("", selection: $editor) {
                        Text("Obsidian for vault notes").tag("")
                        ForEach(editors, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .labelsHidden().frame(width: 220)
                }
                row("Remote images") { segmented(Binding(get: { remoteAlways ? "always" : "ask" }, set: { remoteAlways = $0 == "always" }), [("ask", "Ask per file"), ("always", "Always load")]) }
                Spacer()
            }
            .padding(.horizontal, 40).padding(.top, 44)
        }
        .onAppear { editors = Editors.available() }
    }

    private func row<C: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> C) -> some View {
        HStack {
            Text(title).font(Tok.sans(14.5)).foregroundStyle(palette.text)
            Spacer()
            content()
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
    }

    private func segmented(_ value: Binding<String>, _ options: [(String, LocalizedStringKey)]) -> some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { opt in cell(opt.1, selected: value.wrappedValue == opt.0) { value.wrappedValue = opt.0 } }
        }
        .overlay(RoundedRectangle(cornerRadius: Tok.corner).stroke(palette.line))
    }

    private func cell(_ title: LocalizedStringKey, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Tok.sans(13, medium: selected)).padding(.horizontal, 12).frame(height: 28)
                .foregroundStyle(selected ? palette.onAccent : palette.text)
                .background(selected ? palette.accent : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
