import AppKit
import LinenKit
import SwiftUI

/// Open Quickly (OPEN-5, ⇧⌘O): note names and aliases in the vault, then recent files.
@MainActor
final class OpenQuicklyPanel: NSPanel {
    init(index: VaultIndex?, open: @escaping (URL, Bool) -> Void) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 540, height: 360), styleMask: [.titled, .fullSizeContentView, .closable],
                   backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        contentView = NSHostingView(rootView: LinenScreen {
            OpenQuicklyView(index: index, open: { [weak self] url, newTab in self?.close(); open(url, newTab) }, cancel: { [weak self] in self?.close() })
        })
    }

    override var canBecomeKey: Bool { true }

    func present(over parent: NSWindow?) {
        if let f = parent?.frame {
            setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.maxY - frame.height - 90))
        } else {
            center()
        }
        makeKeyAndOrderFront(nil)
    }
}

struct OpenQuicklyView: View {
    let index: VaultIndex?
    let open: (URL, Bool) -> Void
    let cancel: () -> Void
    @Environment(\.palette) private var palette
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    private var results: [(url: URL, name: String, path: String)] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var out: [(URL, String, String)] = []
        if let index, !q.isEmpty {
            out = index.search(q, limit: 12).map { ($0.url, $0.name, $0.path) }
        }
        let recent = Library.shared.recent.filter { q.isEmpty || $0.lastPathComponent.localizedCaseInsensitiveContains(q) }
        for u in recent where !out.contains(where: { $0.0 == u }) {
            out.append((u, u.deletingPathExtension().lastPathComponent, u.deletingLastPathComponent().path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")))
        }
        return Array(out.prefix(12)).map { (url: $0.0, name: $0.1, path: $0.2) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Open quickly", text: $query)
                .textFieldStyle(.plain).font(Tok.sans(19)).foregroundStyle(palette.head)
                .focused($focused)
                .padding(.horizontal, 16).padding(.vertical, 14)
                .onSubmit { pick(newTab: NSEvent.modifierFlags.contains(.command)) }
                .onChange(of: query) { selected = 0 }
            Rectangle().fill(palette.line).frame(height: 1)
            let items = results
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { i, r in
                        HStack {
                            Text(r.name).font(Tok.sans(14.5, medium: i == selected)).lineLimit(1)
                            Spacer()
                            Text(r.path).font(Tok.sans(12.5)).lineLimit(1).truncationMode(.head)
                        }
                        .foregroundStyle(i == selected ? palette.onAccent : palette.text)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(i == selected ? palette.accent : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture { open(r.url, false) }
                    }
                }
            }
            Text("↩ open · ⌘↩ new tab").font(Tok.sans(12.5)).foregroundStyle(palette.text).padding(.horizontal, 16).padding(.vertical, 8)
        }
        .background(palette.ground)
        .onAppear { focused = true }
        .onKeyPress(.downArrow) { selected = min(selected + 1, max(0, results.count - 1)); return .handled }
        .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
        .onKeyPress(.escape) { cancel(); return .handled }
    }

    private func pick(newTab: Bool) {
        let items = results
        guard items.indices.contains(selected) else { return }
        open(items[selected].url, newTab)
    }
}
