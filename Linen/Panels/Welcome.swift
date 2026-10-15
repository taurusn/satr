import SwiftUI
import UniformTypeIdentifiers

/// The empty state (LOOK-3): the mark on the weave, the question, a drop zone, Open, the last files.
struct WelcomeView: View {
    let open: () -> Void
    let openURL: (URL) -> Void
    @Environment(\.palette) private var palette
    @State private var dropping = false
    @State private var recent: [URL] = []

    var body: some View {
        ZStack {
            WeaveBackground()
            VStack(spacing: 14) {
                LinenMark().stroke(palette.head, style: StrokeStyle(lineWidth: 2.6, lineCap: .round)).frame(width: 84, height: 37)
                Eyebrow(text: "Linen").padding(.top, 2)
                Text("What are we reading?").font(Tok.serif(40)).foregroundStyle(palette.head)
                Text("Drop a note, a board or a page here")
                    .font(Tok.sans(14)).foregroundStyle(palette.text)
                    .frame(maxWidth: .infinity).frame(height: 76)
                    .background(palette.raised.opacity(0.7))
                    .overlay(RoundedRectangle(cornerRadius: Tok.corner).strokeBorder(dropping ? palette.head : Tok.tint3, style: StrokeStyle(lineWidth: 1, dash: dropping ? [] : [4, 3])))
                    .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                        for p in providers {
                            _ = p.loadObject(ofClass: URL.self) { url, _ in
                                if let url { DispatchQueue.main.async { openURL(url) } }
                            }
                        }
                        return true
                    }
                    .padding(.top, 6)
                Button("Open…", action: open).buttonStyle(LoomButtonStyle(kind: .fill)).keyboardShortcut(.defaultAction)
                if !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Eyebrow(text: "Recent").padding(.bottom, 6)
                        ScrollView {
                        VStack(spacing: 0) {
                        ForEach(recent.prefix(12), id: \.self) { u in
                            Button { openURL(u) } label: {
                                HStack {
                                    Text(u.deletingPathExtension().lastPathComponent).font(Tok.sans(14, medium: true)).foregroundStyle(palette.head)
                                    Spacer()
                                    Text(u.deletingLastPathComponent().path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                                        .font(Tok.sans(12.5)).foregroundStyle(palette.text).lineLimit(1).truncationMode(.head)
                                }
                                .padding(.vertical, 7)
                                .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        }
                        }
                        .frame(maxHeight: 186)
                        .scrollIndicators(.automatic)
                    }
                    .padding(.top, 14)
                }
            }
            .frame(width: 440)
            .padding(40)
        }
        .onAppear { recent = Library.shared.recent }
    }
}
