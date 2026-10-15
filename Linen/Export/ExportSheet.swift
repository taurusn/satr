import SwiftUI

/// What the reader chose in the export sheet.
struct ExportChoice: Sendable, Equatable {
    enum Format: String, Sendable, CaseIterable { case pdf, png, html }
    var format: Format = .pdf
    /// Boards: one vector page, or each section on paper.
    var sections = false
    var paper: PaperSize = .a4
    var pngScale = 2
    var pngRegion: BoardPNG.Region = .whole
    /// Notes: paper behind the page instead of white.
    var paperBackground = false

    var fileExtension: String { format.rawValue }
}

/// The export sheet (PRD-2 screen 10): PDF whole or sections for a board, PNG at 1x, 2x or 4x, and for a note PDF or
/// HTML. Choices it cannot honour are shown disabled with the reason, never offered and then refused.
struct ExportSheet: View {
    enum Subject {
        /// `boardSize` in board pixels; `view` the part of the board on screen; sections by id and title.
        case board(title: String, boardSize: CGSize, view: CGRect, sections: [(id: String, title: String, rect: CGRect)], notes: Int)
        case note(title: String)
    }

    let subject: Subject
    var onExport: (ExportChoice) -> Void
    var onCancel: () -> Void
    @State private var choice: ExportChoice
    @State private var sectionID = ""
    @Environment(\.palette) private var palette

    /// `initial` is the last choice (the app remembers it per kind of file); a format the subject lacks falls back to PDF.
    init(subject: Subject, initial: ExportChoice = ExportChoice(), onExport: @escaping (ExportChoice) -> Void, onCancel: @escaping () -> Void) {
        self.subject = subject
        self.onExport = onExport
        self.onCancel = onCancel
        var c = initial
        let board: Bool
        if case .board = subject { board = true } else { board = false }
        if (board && c.format == .html) || (!board && c.format == .png) { c.format = .pdf }
        _choice = State(initialValue: c)
    }

    private var isBoard: Bool { if case .board = subject { return true }; return false }
    private var title: String {
        switch subject {
        case let .board(t, _, _, _, _), let .note(t): t
        }
    }
    private var formats: [ExportChoice.Format] { isBoard ? [.pdf, .png] : [.pdf, .html] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(text: "Export")
                Text(title).font(Tok.serif(24)).foregroundStyle(palette.head).lineLimit(2)
            }
            Picker("", selection: $choice.format) {
                ForEach(formats, id: \.self) { f in Text(label(f)).tag(f) }
            }
            .pickerStyle(.segmented).labelsHidden()
            switch choice.format {
            case .pdf: pdfOptions
            case .png: pngOptions
            case .html: htmlOptions
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(LoomButtonStyle(kind: .line)).keyboardShortcut(.cancelAction)
                Button("Export") { onExport(resolved()) }.buttonStyle(LoomButtonStyle()).keyboardShortcut(.defaultAction).disabled(!canExport)
            }
            .padding(.top, 4)
        }
        .padding(22)
        .frame(width: 440)
        .background(palette.ground)
        .onAppear {
            if case let .board(_, _, _, sections, _) = subject, let first = sections.first { sectionID = first.id }
        }
    }

    private func label(_ f: ExportChoice.Format) -> LocalizedStringKey {
        switch f {
        case .pdf: "PDF"
        case .png: "PNG"
        case .html: "HTML"
        }
    }

    // MARK: PDF

    @ViewBuilder private var pdfOptions: some View {
        if case let .board(_, size, _, sections, notes) = subject {
            option(on: !choice.sections, title: "Whole board",
                   detail: "1 page · \(Int(size.width * BoardPDF.pointsPerPixel)) × \(Int(size.height * BoardPDF.pointsPerPixel)) pt · vector") { choice.sections = false }
            option(on: choice.sections, title: "Sections",
                   detail: sections.isEmpty ? "The board as one section on paper; body never under 9 pt"
                       : "\(sections.count) sections · the orientation follows each section's shape · body never under 9 pt; a section taller than a page splits between rows") { choice.sections = true }
            if choice.sections { paperRow }
            if notes > 0 { line("Notes are numbered on their boxes and follow as sources (\(notes))") }
        } else {
            paperRow
            Toggle(isOn: $choice.paperBackground) { Text("Paper background").font(Tok.sans(13)).foregroundStyle(palette.text) }
                .toggleStyle(.checkbox)
        }
        line("Text stays searchable, Arabic included; Thmanyah is drawn as outlines, so none of its font data goes in.")
    }

    private var paperRow: some View {
        HStack {
            Text("Paper").font(Tok.sans(13)).foregroundStyle(palette.text)
            Spacer()
            Picker("", selection: $choice.paper) {
                ForEach(PaperSize.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden().frame(width: 120)
        }
    }

    // MARK: PNG

    @ViewBuilder private var pngOptions: some View {
        if case let .board(_, size, view, sections, _) = subject {
            option(on: choice.pngRegion == .whole, title: "Whole board", detail: pixels(CGRect(origin: .zero, size: size).insetBy(dx: -24, dy: -24))) { choice.pngRegion = .whole }
            if !sections.isEmpty {
                option(on: isSection, title: "One section", detail: sectionRect.map(pixels) ?? "") { choice.pngRegion = .section(sectionID) }
                if isSection {
                    Picker("", selection: $sectionID) {
                        ForEach(sections, id: \.id) { s in Text(s.title.isEmpty ? String(localized: "Untitled section") : s.title).tag(s.id) }
                    }
                    .labelsHidden()
                    .onChange(of: sectionID) { _, id in choice.pngRegion = .section(id) }
                }
            }
            option(on: isView, title: "What is on screen", detail: pixels(view)) { choice.pngRegion = .rect(view) }
            HStack {
                Text("Scale").font(Tok.sans(13)).foregroundStyle(palette.text)
                Spacer()
                Picker("", selection: $choice.pngScale) {
                    ForEach([1, 2, 4], id: \.self) { s in Text("\(s)x").tag(s).disabled(!fits(scale: s)) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 150)
            }
            if !fits(scale: choice.pngScale) {
                line(fits(scale: 1) ? "Past the PNG limit (16,384 px a side, 128 megapixels) at this scale; choose a smaller one."
                                    : "Past the PNG limit even at 1x; export one section per file.")
            }
        }
    }

    private var isSection: Bool { if case .section = choice.pngRegion { return true }; return false }
    private var isView: Bool { if case .rect = choice.pngRegion { return true }; return false }

    private var sectionRect: CGRect? {
        guard case let .board(_, _, _, sections, _) = subject, let s = sections.first(where: { $0.id == sectionID }) else { return nil }
        return s.rect.insetBy(dx: -16, dy: 0).union(CGRect(x: s.rect.minX, y: s.rect.minY - 44, width: 1, height: 1))
    }

    private var regionRect: CGRect? {
        guard case let .board(_, size, view, _, _) = subject else { return nil }
        switch choice.pngRegion {
        case .whole: return CGRect(origin: .zero, size: size).insetBy(dx: -24, dy: -24)
        case .section: return sectionRect
        case let .rect(r): return r.width > 0 ? r : view
        }
    }

    private func fits(scale: Int) -> Bool { regionRect.map { BoardPNG.fits($0, scale: scale) } ?? false }

    private func pixels(_ r: CGRect) -> String {
        let (w, h) = BoardPNG.size(of: r, scale: choice.pngScale)
        return "\(w) × \(h) px at \(choice.pngScale)x"
    }

    // MARK: HTML

    @ViewBuilder private var htmlOptions: some View {
        line("One file that opens offline in any browser, with the notes and the Paper and Night switch. Images travel inside it.")
        line("Thmanyah is named, not included: where it is installed the page shows it, elsewhere the system's faces.")
    }

    // MARK: Parts

    private var canExport: Bool { choice.format != .png || fits(scale: choice.pngScale) }

    private func resolved() -> ExportChoice {
        var c = choice
        if case .section = c.pngRegion { c.pngRegion = .section(sectionID) }
        return c
    }

    private func option(on: Bool, title: LocalizedStringKey, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Circle().strokeBorder(palette.head, lineWidth: 1)
                    .background(Circle().fill(on ? palette.head : .clear).padding(3))
                    .frame(width: 14, height: 14).padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Tok.sans(13.5, medium: true)).foregroundStyle(palette.head)
                    Text(detail).font(Tok.sans(12)).foregroundStyle(palette.quiet).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func line(_ s: LocalizedStringKey) -> some View {
        Text(s).font(Tok.sans(12)).foregroundStyle(palette.quiet).fixedSize(horizontal: false, vertical: true)
    }
}
