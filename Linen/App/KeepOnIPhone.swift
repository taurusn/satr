import AppKit
import LinenKit
import SwiftUI

/// Keep on iPhone (SYNC-3), from the document window: the front file alone by default, its folder only by its own
/// command. Hatim, 2026-10-31, after keeping one board brought its whole folder: "i did share only [one board] why did
/// all come? doesnt make sense, and i didnt choose an option says share the whole folder". The toolbar's iPhone
/// button, the File menu and the popover all come here.
@MainActor
final class KeepOnIPhone: NSObject, NSMenuItemValidation {
    static let shared = KeepOnIPhone()

    /// Whether a file is on the iPhone.
    enum Kept: Equatable {
        case no
        /// Kept as its own single-file pin.
        case file(id: String)
        /// Kept because a folder holding it is kept.
        case folder(id: String, path: String)
    }

    private var front: URL? { (NSApp.delegate as? AppDelegate)?.activeDocument?.url }

    func kept(_ url: URL) -> Kept {
        let p = url.resolvingSymlinksInPath().path
        let pins = HelperClient.shared.state?.pins ?? []
        if let f = pins.first(where: { $0.kind == "file" && $0.path == p }) { return .file(id: f.id) }
        if let d = pins.filter({ $0.kind == "folder" && p.hasPrefix($0.path + "/") }).max(by: { $0.path.count < $1.path.count }) {
            return .folder(id: d.id, path: d.path)
        }
        return .no
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let f = front else { return false }
        switch item.action {
        case #selector(keepOnIPhone(_:)): return kept(f) == .no
        case #selector(removeFromIPhone(_:)): if case .file = kept(f) { return true } else { return false }
        default: return true
        }
    }

    // MARK: Commands

    @objc func keepOnIPhone(_ sender: Any?) {
        guard let f = front else { return }
        keepFile(f, from: NSApp.keyWindow)
    }

    @objc func keepFolderOnIPhone(_ sender: Any?) {
        guard let f = front else { return }
        keepFolder(f.deletingLastPathComponent(), from: NSApp.keyWindow)
    }

    @objc func removeFromIPhone(_ sender: Any?) {
        guard let f = front, case let .file(id) = kept(f) else { return }
        HelperClient.shared.unpin(id)
    }

    /// The helper must be running before anything can be kept; otherwise Settings › iPhone sets it up.
    private func ready() -> Bool {
        guard HelperClient.shared.enabled else {
            IPhoneSettingsWindow.show()
            return false
        }
        return true
    }

    /// The one-file sheet: the file, its size, and the files it references, each unticked.
    func keepFile(_ url: URL, from window: NSWindow?) {
        guard ready() else { return }
        let file = url.resolvingSymlinksInPath()
        let refs = Self.references(of: file).filter { kept($0) == .no }
        present(KeepFileSheet(file: file, size: Self.size(file), references: refs.map { ($0, Self.size($0)) }) { chosen in
            HelperClient.shared.pin(file, kind: .file)
            for r in chosen { HelperClient.shared.pin(r, kind: .file) }
        }, on: window)
    }

    /// The folder sheet: the folder, its files and subfolders, and their size.
    func keepFolder(_ url: URL, from window: NSWindow?) {
        guard ready() else { return }
        let folder = url.resolvingSymlinksInPath()
        let scan = PinFiles.scan(root: folder, kind: .folder)
        let subfolders = Set(scan.files.compactMap { f -> String? in
            let parts = f.path.split(separator: "/")
            return parts.count > 1 ? parts.dropLast().joined(separator: "/") : nil
        }).count
        present(KeepFolderSheet(folder: folder, files: scan.files.count, subfolders: subfolders,
                                size: scan.files.reduce(Int64(0)) { $0 + $1.stamp.size }, leftOut: scan.problems) {
            HelperClient.shared.pin(folder, kind: .folder)
        }, on: window)
    }

    private func present<V: View>(_ view: V, on window: NSWindow?) {
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: LinenScreen { view.environment(\.dismissSheet, { [weak sheet] in
            guard let sheet else { return }
            sheet.sheetParent?.endSheet(sheet)
            sheet.orderOut(nil)
        }) })
        host.sizingOptions = [.preferredContentSize]
        sheet.contentView = host
        sheet.setContentSize(host.fittingSize)
        if let window { window.beginSheet(sheet) } else { sheet.center(); sheet.makeKeyAndOrderFront(nil) }
    }

    // MARK: What a file references (SYNC-3)

    static func size(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    /// Files a note, board or page points at that exist on this Mac: wiki links and embeds as the vault's index
    /// resolves them, Markdown links and images, a board's file cards, a page's `src` and `href`. Web addresses,
    /// the file itself and its notes sidecar (which travels with it) are left out.
    static func references(of file: URL) -> [URL] {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe), data.count < 8 << 20 else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        let dir = file.deletingLastPathComponent()
        let vault = VaultLocator.vault(for: file)
        var out: [URL] = []
        func add(_ u: URL?) {
            guard let u = u?.standardizedFileURL.resolvingSymlinksInPath() else { return }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue,
                  u != file, u.lastPathComponent != PinFiles.sidecarName(file.lastPathComponent), !out.contains(u) else { return }
            out.append(u)
        }
        func relative(_ raw: String) -> URL? {
            var r = raw.trimmingCharacters(in: .whitespaces)
            if let i = r.firstIndex(where: { $0 == "#" || $0 == "?" }) { r = String(r[..<i]) }
            guard !r.isEmpty, !r.contains(":") else { return nil }
            r = r.removingPercentEncoding ?? r
            return r.hasPrefix("/") ? vault.root.appendingPathComponent(String(r.dropFirst())) : dir.appendingPathComponent(r)
        }
        switch DocumentKind(fileName: file.lastPathComponent) {
        case .note?:
            let index = Library.shared.index(for: vault)
            for m in matches(#"!?\[\[([^\]\|#]+)"#, text) {
                if case let .note(u, _, _) = index.resolve(m, from: file) { add(u) }
            }
            for m in matches(#"\]\(<?([^)\s>]+)"#, text) { add(relative(m)) }
        case .board?:
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let nodes = obj["nodes"] as? [[String: Any]] {
                for n in nodes where (n["type"] as? String) == "file" {
                    guard let f = n["file"] as? String else { continue }
                    let inVault = vault.root.appendingPathComponent(f)
                    add(FileManager.default.fileExists(atPath: inVault.path) ? inVault : dir.appendingPathComponent(f))
                }
            }
        case .page?:
            for m in matches(#"(?:src|href)\s*=\s*["']([^"']+)["']"#, text) { add(relative(m)) }
        case nil:
            break
        }
        return Array(out.prefix(50))
    }

    private static func matches(_ pattern: String, _ text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            m.numberOfRanges > 1 && m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)) : nil
        }
    }
}

private struct DismissSheetKey: EnvironmentKey {
    static let defaultValue: @MainActor () -> Void = {}
}

extension EnvironmentValues {
    var dismissSheet: @MainActor () -> Void {
        get { self[DismissSheetKey.self] }
        set { self[DismissSheetKey.self] = newValue }
    }
}

/// Keep one file: it alone, its size, and "Also keep these N files" with each reference unticked.
struct KeepFileSheet: View {
    let file: URL
    let size: Int64
    let references: [(URL, Int64)]
    let keep: ([URL]) -> Void
    @State private var chosen: Set<URL> = []
    @Environment(\.palette) private var palette
    @Environment(\.dismissSheet) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: "Keep on iPhone")
            Text(file.lastPathComponent).font(Tok.serif(24)).foregroundStyle(palette.head).padding(.top, 4)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Text("This file only, \(IPhoneSettingsView.bytes(size)). Linen keeps it up to date on your iPhone whenever Linen is open there near this Mac.")
                .font(Tok.sans(13.5)).foregroundStyle(palette.text).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            if !references.isEmpty {
                Eyebrow(text: "Also keep these \(references.count) files").padding(.top, 16).padding(.bottom, 4)
                Text("It points at them. Each one you tick is kept as its own file.")
                    .font(Tok.sans(12.5)).foregroundStyle(palette.quiet).padding(.bottom, 4)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(references, id: \.0) { r in
                            Toggle(isOn: Binding(get: { chosen.contains(r.0) }, set: { on in if on { chosen.insert(r.0) } else { chosen.remove(r.0) } })) {
                                HStack {
                                    Text(r.0.lastPathComponent).font(Tok.sans(13.5)).foregroundStyle(palette.text).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(IPhoneSettingsView.bytes(r.1)).font(Tok.sans(12.5)).foregroundStyle(palette.quiet)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .padding(.vertical, 5)
                            .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(LoomButtonStyle(kind: .line)).keyboardShortcut(.cancelAction)
                Button(chosen.isEmpty ? "Keep on iPhone" : "Keep \(chosen.count + 1) Files on iPhone") {
                    keep(references.map(\.0).filter(chosen.contains))
                    dismiss()
                }
                .buttonStyle(LoomButtonStyle()).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 18)
        }
        .padding(24)
        .frame(width: 460)
        .background(palette.ground)
    }
}

/// Keep a whole folder: named, with its files and subfolders counted, as its own command.
struct KeepFolderSheet: View {
    let folder: URL
    let files: Int
    let subfolders: Int
    let size: Int64
    let leftOut: [String]
    let keep: () -> Void
    @Environment(\.palette) private var palette
    @Environment(\.dismissSheet) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: "Keep folder on iPhone")
            Text(folder.lastPathComponent).font(Tok.serif(24)).foregroundStyle(palette.head).padding(.top, 4)
            Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(Tok.sans(12.5)).foregroundStyle(palette.quiet)
                .lineLimit(1).truncationMode(.middle).padding(.top, 2)
            Text(summary).font(Tok.sans(13.5)).foregroundStyle(palette.text).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
            if !leftOut.isEmpty {
                Text("Left out: \(leftOut.prefix(3).joined(separator: "; "))").font(Tok.sans(12.5)).foregroundStyle(palette.quiet)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            }
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(LoomButtonStyle(kind: .line)).keyboardShortcut(.cancelAction)
                Button("Keep Folder on iPhone") { keep(); dismiss() }.buttonStyle(LoomButtonStyle()).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 18)
        }
        .padding(24)
        .frame(width: 460)
        .background(palette.ground)
    }

    private var summary: String {
        let files = String(localized: "\(files) files")
        let sub = subfolders == 0 ? "" : String(localized: " in \(subfolders) subfolders")
        return String(localized: "Everything in it: \(files)\(sub), \(IPhoneSettingsView.bytes(size)). Files added to it later go to your iPhone too.")
    }
}
