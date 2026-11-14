import LinenKit
import SwiftUI
import WebKit

/// A note, board or page (sketch screens 12, 13, 14): the renderer or the sealed page full width, under the phone's
/// own bar. Boards get the glass band with the Canvas / List switch; notes and pages a plain bar with their title.
struct DocumentScreen: View {
    let source: DocumentSource
    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette
    @Environment(\.layoutDirection) private var direction
    @State private var doc: DocumentModel?

    // iOS's own controls (Hatim, 2026-11-14): the navigation bar with its back button and title, toolbar buttons, a
    // segmented picker for Canvas and List, the system search field for find with its matches in the bottom toolbar,
    // the share sheet through ShareLink. Linen's own, with the reason in PRD-2's build log: where the change chip sits
    // over the text (BRD-13; the button is the system's glass button), the toast and the page line (status, not
    // controls).
    var body: some View {
        VStack(spacing: 0) {
            if let line = doc?.pageLine {
                PageStateLine(text: line)
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
        .navigationTitle(Text(verbatim: doc?.title ?? ""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .modifier(FindField(doc: doc))
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
        .confirmationDialog(Text("Open this address?"), isPresented: Binding(get: { doc?.external != nil }, set: { if !$0 { doc?.external = nil } }),
                            titleVisibility: .visible, presenting: doc?.external) { u in
            Button("Open") { UIApplication.shared.open(u) }
            Button("Cancel", role: .cancel) {}
        } message: { u in
            Text(verbatim: u.absoluteString)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if let doc, !doc.findShown {
            if doc.document?.kind == .board {
                ToolbarItem(placement: .principal) {
                    Picker(selection: Binding(get: { doc.mode }, set: { m in Task { await doc.setMode(m) } })) {
                        Text("Canvas").tag("canvas")
                        Text("List").tag("list")
                    } label: { Text("View") }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .accessibilityIdentifier("mode")
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if doc.document?.kind != .page {
                    Button { Task { await doc.loadOutline(); doc.outlineShown = true } } label: { Label("Outline", systemImage: "list.bullet") }
                        .accessibilityIdentifier("outline")
                }
                Button { doc.findShown = true } label: { Label("Find", systemImage: "magnifyingglass") }
                    .accessibilityIdentifier("find")
                if let url = doc.shareURL {
                    ShareLink(item: url, preview: SharePreview(Text(verbatim: url.lastPathComponent))) { Label("Share", systemImage: "square.and.arrow.up") }
                        .accessibilityIdentifier("share")
                }
            }
        }
    }
}

/// Find in a document (IOS-2, IOS-3) through iOS's own search field in the navigation bar, with the count and the
/// previous and next buttons in the bottom toolbar, as Safari's find does. Linen's renderer does the finding (it
/// reaches blocks not drawn yet and folds Arabic), so the system's find panel for web views is not used.
private struct FindField: ViewModifier {
    let doc: DocumentModel?

    func body(content: Content) -> some View {
        if let doc, doc.findShown {
            content
                // Closing the field also empties it: that empty query must not start a new find after the end.
                .searchable(text: Binding(get: { doc.findQuery }, set: { q in if doc.findShown { Task { await doc.find(q) } } }),
                            isPresented: Binding(get: { doc.findShown }, set: { if !$0 { doc.findShown = false; Task { await doc.endFind() } } }),
                            placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Find"))
                .onSubmit(of: .search) { Task { await doc.findStep(1) } }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .toolbar {
                    ToolbarItemGroup(placement: .bottomBar) {
                        if !doc.findQuery.isEmpty {
                            Text(doc.findCount == 0 ? "Not found" : "\(doc.findCurrent) of \(doc.findCount)")
                                .font(Tok.sans(13, relativeTo: .footnote))
                        }
                        Spacer()
                        Button { Task { await doc.findStep(-1) } } label: { Label("Previous match", systemImage: "chevron.up") }
                            .disabled(doc.findCount == 0)
                        Button { Task { await doc.findStep(1) } } label: { Label("Next match", systemImage: "chevron.down") }
                            .disabled(doc.findCount == 0)
                    }
                }
        } else {
            content
        }
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

/// "3 changed since you read it · Next" for a note (BRD-13's chip, on a note).
struct ChangeChip: View {
    let count: Int
    let next: () -> Void
    @Environment(\.palette) private var palette
    var body: some View {
        let label = HStack(spacing: 6) {
            Text("\(count) changed since you read it").foregroundStyle(palette.text)
            Text(verbatim: "·").foregroundStyle(palette.quiet)
            Text("Next").fontWeight(.semibold).foregroundStyle(palette.head)
        }
        .font(Tok.sans(13.5, medium: true, relativeTo: .subheadline))
        .frame(minHeight: 30)
        if #available(iOS 26, *) {
            Button(action: next) { label }.buttonStyle(.glass).controlSize(.large).accessibilityIdentifier("nextChange")
        } else {
            Button(action: next) { label }.buttonStyle(.bordered).controlSize(.large).accessibilityIdentifier("nextChange")
        }
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
/// ink, a dot on what changed; a note's text size above it. iOS's own list, stepper and Done button.
struct OutlineSheet: View {
    let doc: DocumentModel
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if doc.document?.kind == .note {
                    Section {
                        Stepper(value: Binding(get: { doc.zoom }, set: { doc.setZoom($0) }), in: 0.7...2.0, step: 0.1) {
                            HStack {
                                Text("Text size").font(Tok.sans(15)).foregroundStyle(palette.text)
                                Spacer()
                                Text(verbatim: doc.zoom.formatted(.percent.precision(.fractionLength(0)))).font(Tok.sans(14)).foregroundStyle(palette.quiet)
                            }
                        }
                        .listRowBackground(palette.raised)
                    }
                }
                Section {
                    if doc.outline.isEmpty {
                        Text("No headings").font(Tok.sans(15)).foregroundStyle(palette.quiet).listRowBackground(palette.raised)
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
                        }
                        .listRowBackground(palette.raised)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(palette.ground.ignoresSafeArea())
            .navigationTitle(Text(verbatim: doc.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
