import LinenKit
import LinkPresentation
import SwiftUI
import WebKit

/// A note, board or page (sketch screens 12, 13, 14): the renderer or the sealed page full width, under the phone's
/// own bar. Boards get the glass band with the Canvas / List switch; notes and pages a plain bar with their title.
struct DocumentScreen: View {
    let source: DocumentSource
    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette
    @Environment(\.layoutDirection) private var direction
    @Environment(\.dismiss) private var dismiss
    @State private var doc: DocumentModel?

    var body: some View {
        VStack(spacing: 0) {
            if let doc {
                if doc.findShown {
                    FindBar(doc: doc)
                } else if doc.document?.kind == .board {
                    BoardBand(doc: doc, back: back)
                } else {
                    DocumentBar(title: Text(verbatim: doc.title), back: back) {
                        if doc.document?.kind == .note {
                            GlyphButton(glyph: .outline, label: "Outline") { Task { await doc.loadOutline(); doc.outlineShown = true } }
                                .accessibilityIdentifier("outline")
                        }
                        GlyphButton(glyph: .find, label: "Find") { doc.findShown = true }
                            .accessibilityIdentifier("find")
                        GlyphButton(glyph: .share, label: "Share") { doc.shareShown = true }
                            .accessibilityIdentifier("share")
                    }
                }
                if let line = doc.pageLine {
                    PageStateLine(text: line)
                }
            } else {
                DocumentBar(title: Text(verbatim: ""), back: back) { EmptyView() }
            }
            ZStack(alignment: .bottom) {
                palette.ground
                if let doc {
                    if let failure = doc.failure {
                        Text(verbatim: failure).font(Tok.sans(15.5)).foregroundStyle(palette.text).padding(28)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    } else if let host = doc.host {
                        HostedView(view: host.web)
                    } else if let page = doc.page {
                        HostedView(view: page.view)
                    }
                    if doc.document?.kind == .note && doc.noteChanges > 0 && !doc.findShown {
                        ChangeChip(count: doc.noteChanges) { Task { await doc.nextChange() } }
                            .padding(.bottom, 18)
                    }
                    if let t = doc.toast {
                        Text(verbatim: t).font(Tok.sans(13.5)).foregroundStyle(palette.text)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: Tok.corner).fill(palette.ground))
                            .overlay(RoundedRectangle(cornerRadius: Tok.corner).stroke(palette.line, lineWidth: 1))
                            .shadow(color: Tok.ink.opacity(0.14), radius: 12, y: 8)
                            .padding(.bottom, 70)
                            .transition(.opacity)
                    }
                }
            }
        }
        .background(palette.ground.ignoresSafeArea())
        #if DEBUG
        .overlay(alignment: .topLeading) {
            if Launch.has("-LinenProbe"), let doc {
                Text(verbatim: doc.probe).font(.system(size: 2)).opacity(0.05).frame(width: 4, height: 4).accessibilityIdentifier("probe")
            }
        }
        #endif
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden()
        .task {
            guard doc == nil else { return }
            let d = DocumentModel(source: source, app: app)
            doc = d
            await d.open(palette: palette, arabic: direction == .rightToLeft)
        }
        .onDisappear { doc?.close() }
        .onChange(of: palette) { _, p in doc?.applyLook(p, arabic: direction == .rightToLeft) }
        .sheet(isPresented: Binding(get: { doc?.outlineShown ?? false }, set: { doc?.outlineShown = $0 })) {
            if let doc { OutlineSheet(doc: doc).environment(\.palette, palette).presentationDetents([.medium, .large]).presentationDragIndicator(.visible) }
        }
        .sheet(isPresented: Binding(get: { doc?.shareShown ?? false }, set: { doc?.shareShown = $0 })) {
            if let url = doc?.shareURL, let d = doc?.document { ShareSheet(url: url, kind: d.kind).ignoresSafeArea().presentationDetents([.medium, .large]) }
        }
        .confirmationDialog(Text("Open this address?"), isPresented: Binding(get: { doc?.external != nil }, set: { if !$0 { doc?.external = nil } }),
                            titleVisibility: .visible, presenting: doc?.external) { u in
            Button("Open") { UIApplication.shared.open(u) }
            Button("Cancel", role: .cancel) {}
        } message: { u in
            Text(verbatim: u.absoluteString)
        }
    }

    private func back() {
        doc?.close()
        if !app.path.isEmpty { app.path.removeLast() } else { dismiss() }
    }
}

/// A UIKit view (the web view or the sealed page) inside SwiftUI, filling its space.
struct HostedView: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView {
        let box = UIView()
        box.backgroundColor = .clear
        view.translatesAutoresizingMaskIntoConstraints = false
        view.removeFromSuperview()
        box.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: box.leadingAnchor), view.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            view.topAnchor.constraint(equalTo: box.topAnchor), view.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        return box
    }

    func updateUIView(_ box: UIView, context: Context) {}
}

/// The plain bar of a note, a page or pairing (sketch `.pnav`): back, the title, the actions; a rule under it.
struct DocumentBar<Actions: View>: View {
    let title: Text
    let back: () -> Void
    @ViewBuilder var actions: () -> Actions
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            GlyphButton(glyph: .chevron, label: "Back", action: back).accessibilityIdentifier("back")
            title.font(.system(size: 15, weight: .semibold)).foregroundStyle(palette.head)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 0) { actions() }.frame(minWidth: 44, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .frame(minHeight: 48)
        .background(palette.ground)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
    }
}

/// A board's band (sketch screen 13): glass, with back, the Canvas / List switch, the outline and find; every target
/// 44 points.
struct BoardBand: View {
    let doc: DocumentModel
    let back: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            GlyphButton(glyph: .chevron, label: "Back", action: back).accessibilityIdentifier("back")
            Spacer(minLength: 4)
            HStack(spacing: 0) {
                segment("Canvas", value: "canvas")
                segment("List", value: "list")
            }
            .overlay(RoundedRectangle(cornerRadius: Tok.corner).stroke(palette.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Tok.corner))
            Spacer(minLength: 4)
            GlyphButton(glyph: .outline, label: "Outline") { Task { await doc.loadOutline(); doc.outlineShown = true } }
                .accessibilityIdentifier("outline")
            GlyphButton(glyph: .find, label: "Find") { doc.findShown = true }
                .accessibilityIdentifier("find")
            GlyphButton(glyph: .share, label: "Share") { doc.shareShown = true }
                .accessibilityIdentifier("share")
        }
        .padding(.horizontal, 2).padding(.vertical, 2)
        .glass()
        .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 6)
        .background(palette.ground)
    }

    private func segment(_ label: LocalizedStringKey, value: String) -> some View {
        let on = doc.mode == value
        return Button { Task { await doc.setMode(value) } } label: {
            Text(label).font(Tok.sans(13.5, medium: true, relativeTo: .subheadline))
                .foregroundStyle(on ? palette.onAccent : palette.text)
                .padding(.horizontal, 15).frame(minHeight: 44)
                .background(on ? palette.accent : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("mode:\(value)")
    }
}

/// "3 changed since you read it · Next" for a note (BRD-13's chip, on a note).
struct ChangeChip: View {
    let count: Int
    let next: () -> Void
    @Environment(\.palette) private var palette
    var body: some View {
        Button(action: next) {
            HStack(spacing: 6) {
                Text("\(count) changed since you read it").foregroundStyle(palette.text)
                Text(verbatim: "·").foregroundStyle(palette.quiet)
                Text("Next").fontWeight(.semibold).foregroundStyle(palette.head)
            }
            .font(Tok.sans(13.5, medium: true, relativeTo: .subheadline))
            .padding(.horizontal, 14).frame(minHeight: 44)
            .glass()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("nextChange")
    }
}

/// The phone's find bar, over the document: the field, the count, previous and next, Done.
struct FindBar: View {
    let doc: DocumentModel
    @FocusState private var focused: Bool
    @State private var query = ""
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 4) {
            TextField(text: $query) { Text("Find").foregroundStyle(palette.quiet.opacity(0.7)) }
                .font(Tok.sans(16)).foregroundStyle(palette.text)
                .focused($focused)
                .submitLabel(.search)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(.horizontal, 10).frame(minHeight: 40)
                .background(RoundedRectangle(cornerRadius: Tok.corner).fill(palette.raised))
                .overlay(RoundedRectangle(cornerRadius: Tok.corner).stroke(palette.line, lineWidth: 1))
                .onSubmit { Task { await doc.findStep(1) } }
                .onChange(of: query) { _, q in Task { await doc.find(q) } }
                .accessibilityIdentifier("findField")
            if !query.isEmpty {
                Text(doc.findCount == 0 ? "Not found" : "\(doc.findCurrent) of \(doc.findCount)")
                    .font(Tok.sans(13, relativeTo: .footnote)).foregroundStyle(palette.quiet).lineLimit(1).fixedSize()
            }
            Button { Task { await doc.findStep(-1) } } label: { Glyph(.chevron, size: 18).rotationEffect(.degrees(90)).frame(width: 40, height: 44) }
                .buttonStyle(.plain).accessibilityLabel(Text("Previous match"))
            Button { Task { await doc.findStep(1) } } label: { Glyph(.chevron, size: 18).rotationEffect(.degrees(-90)).frame(width: 40, height: 44) }
                .buttonStyle(.plain).accessibilityLabel(Text("Next match"))
            Button { Task { await doc.endFind() } } label: {
                Text("Done").font(Tok.sans(15, medium: true)).foregroundStyle(palette.head).frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(palette.ground)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
        .onAppear { query = doc.findQuery; focused = true }
    }
}

/// A sealed page's one honest line (PAGE-7): scripts are off on the phone until the Mac's trust decisions arrive.
struct PageStateLine: View {
    let text: String
    @Environment(\.palette) private var palette
    var body: some View {
        Text(verbatim: text).font(Tok.sans(13.5, relativeTo: .footnote)).foregroundStyle(palette.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(palette.raised)
            .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
            .accessibilityIdentifier("pageStateLine")
    }
}

/// The outline as a sheet (IOS-2, IOS-3): a note's headings or a board's sections and boxes, the current one in
/// ink, a dot on what changed; a note's text size above it.
struct OutlineSheet: View {
    let doc: DocumentModel
    @Environment(\.palette) private var palette

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow("Outline").padding(.top, 22)
                Text(verbatim: doc.title).font(Tok.serif(26, relativeTo: .title2)).foregroundStyle(palette.head)
                    .padding(.top, 2).padding(.bottom, 10)
                if doc.document?.kind == .note {
                    HStack {
                        Text("Text size").font(Tok.sans(15)).foregroundStyle(palette.text)
                        Spacer()
                        Button { doc.setZoom(doc.zoom - 0.1) } label: { Text(verbatim: "A").font(Tok.sans(14)).frame(width: 44, height: 44) }
                            .accessibilityLabel(Text("Smaller text"))
                        Text(verbatim: (doc.zoom).formatted(.percent.precision(.fractionLength(0)))).font(Tok.sans(14)).foregroundStyle(palette.quiet)
                            .frame(minWidth: 52)
                        Button { doc.setZoom(doc.zoom + 0.1) } label: { Text(verbatim: "A").font(Tok.sans(20)).frame(width: 44, height: 44) }
                            .accessibilityLabel(Text("Larger text"))
                    }
                    .buttonStyle(.plain).foregroundStyle(palette.head)
                    .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
                }
                if doc.outline.isEmpty {
                    Text("No headings").font(Tok.sans(15)).foregroundStyle(palette.quiet).padding(.top, 14)
                }
                ForEach(doc.outline) { item in
                    Button { Task { await doc.goOutline(item) } } label: {
                        HStack(spacing: 8) {
                            Text(verbatim: item.text)
                                .font(item.level == 0 ? Tok.sans(15.5, medium: true) : Tok.sans(15))
                                .foregroundStyle(item.current ? palette.head : palette.text)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if item.changed {
                                Circle().fill(palette.head).frame(width: 6, height: 6).accessibilityLabel(Text("Changed"))
                            }
                        }
                        .padding(.leading, CGFloat(item.level) * 16)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 30)
        }
        .background(palette.ground.ignoresSafeArea())
    }
}

/// Shares the original file (IOS-7) through iOS's share sheet: AirDrop, Mail, Save to Files and the rest.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    let kind: DocumentKind

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [FileItem(url: url, kind: kind)], applicationActivities: nil)
    }

    func updateUIViewController(_ c: UIActivityViewController, context: Context) {}

    /// The file, with a header naming it as the original (PDF and PNG exports from the phone are 2.x).
    final class FileItem: NSObject, UIActivityItemSource {
        let url: URL
        let kind: DocumentKind
        init(url: URL, kind: DocumentKind) {
            self.url = url
            self.kind = kind
        }

        func activityViewControllerPlaceholderItem(_ c: UIActivityViewController) -> Any { url }
        func activityViewController(_ c: UIActivityViewController, itemForActivityType t: UIActivity.ActivityType?) -> Any? { url }
        func activityViewControllerLinkMetadata(_ c: UIActivityViewController) -> LPLinkMetadata? {
            let m = LPLinkMetadata()
            let size = ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize).map { Int64($0).formatted(.byteCount(style: .file)) } ?? ""
            let what: String
            switch kind {
            case .note: what = String(localized: "Note")
            case .board: what = String(localized: "JSON Canvas")
            case .page: what = String(localized: "Page")
            }
            m.title = url.lastPathComponent
            m.originalURL = URL(fileURLWithPath: "\(what) · \(size) · " + String(localized: "the original file"))
            return m
        }
    }
}
