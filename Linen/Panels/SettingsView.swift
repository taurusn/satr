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
                pages
                Spacer()
            }
            .padding(.horizontal, 40).padding(.top, 44)
        }
        .onAppear { editors = Editors.available(); trusted = TrustedFolders.all }
    }

    // MARK: Pages (PAGE-7, SYS-2)

    @State private var trusted: [String] = []

    /// Page scripts run by default only in these folders and their subfolders; everywhere else a page opens with
    /// scripts off and one click to run it.
    private var pages: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: "Pages").padding(.top, 22).padding(.bottom, 6)
            Text("Scripts run in pages from these folders and the folders inside them. Pages from anywhere else open with scripts off.")
                .font(Tok.sans(13)).foregroundStyle(palette.quiet).fixedSize(horizontal: false, vertical: true).padding(.bottom, 6)
            ForEach(trusted, id: \.self) { path in
                HStack {
                    Text(path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                        .font(Tok.sans(13.5)).foregroundStyle(palette.text).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Remove") { TrustedFolders.remove(path); trusted = TrustedFolders.all }
                        .buttonStyle(.plain).font(Tok.sans(13)).foregroundStyle(palette.quiet)
                }
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
            }
            if trusted.isEmpty {
                Text("No trusted folders yet.").font(Tok.sans(13.5)).foregroundStyle(palette.quiet).padding(.vertical, 8)
            }
            Button("Add Folder…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let u = panel.url { TrustedFolders.add(u.path); trusted = TrustedFolders.all }
            }
            .buttonStyle(.plain).font(Tok.sans(13, medium: true)).foregroundStyle(palette.accent).padding(.top, 8)
            // The seal's self-test (PAGE-10): one line, the one place its state shows.
            HStack {
                Text(sealLine).font(Tok.sans(13)).foregroundStyle(palette.quiet).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Check Now") { Task { @MainActor in _ = await PageSelfTest.shared.run(); sealLine = Self.describe() } }
                    .buttonStyle(.plain).font(Tok.sans(13, medium: true)).foregroundStyle(palette.accent)
            }
            .padding(.top, 10)
            .onAppear { sealLine = Self.describe() }
            .onReceive(NotificationCenter.default.publisher(for: PageSelfTest.changed)) { _ in sealLine = Self.describe() }
        }
    }

    @State private var sealLine = ""

    static func describe() -> String {
        let t = PageSelfTest.shared
        switch t.state {
        case .running: return String(localized: "Checking the page seal…")
        case .failed(let why): return why.hasPrefix("Page scripts are off") ? why : String(localized: "Page scripts are off: \(why)")
        case .passed, .idle:
            if let why = t.blockReason { return String(localized: "Page scripts are off: \(why)") }
            if let d = t.lastRun { return String(localized: "The page seal passed its check on \(d.formatted(date: .abbreviated, time: .shortened)).") }
            return String(localized: "The page seal has not been checked yet.")
        }
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
