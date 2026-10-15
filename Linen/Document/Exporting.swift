import AppKit
import LinenKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// File > Export… (PRD-2 screen 10): a board as a vector PDF (whole or by sections) or a PNG, drawn by Linen from the
/// renderer's display list (EXP-5, EXP-6); a note as a PDF with searchable Arabic (EXP-8) or one self-contained HTML
/// file (EXP-3). Pages export with sealed pages.
@MainActor
extension DocumentWindow {
    private static var lastChoice: [String: ExportChoice] = [:]

    @objc func exportDocument(_ sender: Any?) {
        // A page exports as WebKit prints it (EXP-7), from its own sealed view.
        if kind == .page, let pageController {
            savePanel(ExportChoice(format: .pdf)) { dest in
                let data = try await pageController.pdfData()
                try data.write(to: dest, options: .atomic)
                return "\(data.count) bytes"
            }
            return
        }
        guard let window, web != nil else { NSSound.beep(); return }
        Task { @MainActor in
            switch kind {
            case .board:
                guard let list = await boardDisplayList() else { alert(String(localized: "This board has nothing to export yet.")); return }
                let view = (await command("place") as? [String: Any]).flatMap { p -> CGRect? in
                    guard let cx = p["cx"] as? Double, let cy = p["cy"] as? Double, let z = p["zoom"] as? Double, z > 0 else { return nil }
                    let size = window.contentView?.bounds.size ?? .zero
                    return CGRect(x: cx - size.width / z / 2, y: cy - size.height / z / 2, width: size.width / z, height: size.height / z)
                } ?? CGRect(origin: .zero, size: list.size)
                let subject = ExportSheet.Subject.board(title: list.title.isEmpty ? window.title : list.title, boardSize: list.size, view: view,
                                                        sections: list.sections.filter { $0.depth == 0 }.map { (id: $0.id, title: $0.title, rect: $0.rect) },
                                                        notes: list.notes.count)
                present(subject) { choice in self.exportBoard(list, choice: choice, view: view) }
            case .note:
                present(.note(title: window.title)) { choice in self.exportNote(choice) }
            case .page:
                break
            }
        }
    }

    private func present(_ subject: ExportSheet.Subject, perform: @escaping (ExportChoice) -> Void) {
        guard let window else { return }
        let key = "\(kind)"
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 360), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        let sheet = ExportSheet(subject: subject, initial: Self.lastChoice[key] ?? ExportChoice(), onExport: { [weak window] choice in
            Self.lastChoice[key] = choice
            window?.endSheet(panel)
            perform(choice)
        }, onCancel: { [weak window] in window?.endSheet(panel) })
        panel.contentView = NSHostingView(rootView: LinenScreen { sheet })
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 440, height: 360))
        window.beginSheet(panel)
    }

    /// The board as Linen draws it, with images read through the vault gate from the board's own folder.
    private func boardDisplayList() async -> DisplayList? {
        guard let raw = await command("displayList") else { return nil }
        let folder = url.deletingLastPathComponent()
        return try? DisplayList.parse(raw, image: { rel in
            SafeOpen.open(root: folder, relative: rel).flatMap { SafeOpen.read($0) }
        })
    }

    private func savePanel(_ choice: ExportChoice, then write: @escaping (URL) async throws -> String) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + "." + choice.fileExtension
        if let t = UTType(filenameExtension: choice.fileExtension) { panel.allowedContentTypes = [t] }
        panel.directoryURL = url.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let dest = panel.url else { return }
            Task { @MainActor in
                do {
                    let summary = try await write(dest)
                    Log.write("exported \(dest.lastPathComponent): \(summary)")
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                } catch {
                    self.alert(String(describing: error))
                }
            }
        }
    }

    private func exportBoard(_ list: DisplayList, choice: ExportChoice, view: CGRect) {
        savePanel(choice) { dest in
            switch choice.format {
            case .png:
                let region: BoardPNG.Region = {
                    if case .rect = choice.pngRegion { return .rect(view) }
                    return choice.pngRegion
                }()
                let out = try BoardPNG.write(list, region: region, scale: choice.pngScale, to: dest)
                return "\(out.width)x\(out.height) px"
            default:
                let out = try BoardPDF.write(list, shape: choice.sections ? .sections(choice.paper) : .whole, sourcesPaper: choice.paper,
                                             title: list.title, to: dest)
                return "\(out.pages) pages, \(out.bytes) bytes"
            }
        }
    }

    private func exportNote(_ choice: ExportChoice) {
        savePanel(choice) { dest in
            switch choice.format {
            case .html:
                guard let web = self.web else { throw CocoaError(.fileWriteUnknown) }
                let dir = Bundle.main.resourceURL!.appendingPathComponent("renderer")
                let folder = self.url.deletingLastPathComponent()
                let out = try await NoteHTML.write(from: web, title: self.window?.title ?? "", rendererDirectory: dir, image: { rel in
                    guard let d = SafeOpen.open(root: folder, relative: rel).flatMap({ SafeOpen.read($0) }) else { return nil }
                    return (d, UTType(filenameExtension: (rel as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream")
                }, to: dest)
                return "\(out)"
            default:
                // A dedicated offscreen renderer at the paper's width: the tab on screen is never changed by an export.
                let config = WKWebViewConfiguration()
                config.websiteDataStore = .nonPersistent()
                config.setURLSchemeHandler(AppScheme(root: Bundle.main.resourceURL!.appendingPathComponent("renderer")), forURLScheme: "linen-app")
                let host = NotePDF.Host(configuration: config, paper: choice.paper)
                defer { host.close() }
                let load: [String: Any] = ["docId": UUID().uuidString, "name": self.url.lastPathComponent, "path": self.url.path, "text": self.text,
                                           "plain": self.url.pathExtension.lowercased() == "txt", "version": 1, "meta": [:],
                                           "sidecar": self.sidecarText ?? NSNull()]
                guard await host.open(settings: ["face": Settings.face, "uiDir": "ltr", "lang": "en"], load: load) else {
                    throw NotePDF.Failure.layout(String(localized: "the note did not render"))
                }
                let out = try await NotePDF.write(from: host.web, options: NotePDF.Options(paper: choice.paper, title: self.window?.title ?? "",
                                                                                          paperBackground: choice.paperBackground), to: dest)
                return "\(out.pages) pages, \(out.bytes) bytes"
            }
        }
    }

    private func alert(_ text: String) {
        guard let window else { return }
        let a = NSAlert()
        a.messageText = String(localized: "Export")
        a.informativeText = text
        a.beginSheetModal(for: window)
    }
}
