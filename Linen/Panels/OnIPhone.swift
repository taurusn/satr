import AppKit
import LinenKit
import SwiftUI

/// The document window's iPhone button and its popover (SYNC-3, principle 11): whether this file is on the iPhone,
/// keep or remove it, everything kept with Remove on each row, and the sync line. Hatim, 2026-10-31: "also make sure
/// in the ui somewhere please instead of system settings". Settings › iPhone keeps pairing and the size limit.
@MainActor
enum OnIPhone {
    /// The toolbar's mark for a file: not kept, kept, or kept with its folder.
    static func mark(for url: URL) -> (image: NSImage?, tip: String) {
        switch KeepOnIPhone.shared.kept(url) {
        case .no:
            return (NSImage(systemSymbolName: "iphone", accessibilityDescription: String(localized: "Not on iPhone")), String(localized: "Not on iPhone"))
        case .file:
            return (NSImage(systemSymbolName: "iphone.badge.checkmark", accessibilityDescription: String(localized: "On iPhone")), String(localized: "On iPhone"))
        case let .folder(_, path):
            let name = (path as NSString).lastPathComponent
            return (folderMark(), String(localized: "On iPhone with its folder “\(name)”"))
        }
    }

    /// The iPhone with a small folder at its foot, drawn as a template so it takes the toolbar's colour.
    private static func folderMark() -> NSImage? {
        guard let phone = NSImage(systemSymbolName: "iphone", accessibilityDescription: nil),
              let folder = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 7, weight: .bold)) else { return nil }
        let size = NSSize(width: phone.size.width + 6, height: phone.size.height)
        let img = NSImage(size: size, flipped: false) { _ in
            phone.draw(in: NSRect(origin: .zero, size: phone.size))
            let f = NSRect(x: size.width - folder.size.width, y: 0, width: folder.size.width, height: folder.size.height)
            NSColor.clear.setFill()
            folder.draw(in: f)
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = String(localized: "On iPhone with its folder")
        return img
    }

    static func popover(for url: URL, window: NSWindow?) -> NSPopover {
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = NSHostingController(rootView: LinenScreen {
            OnIPhonePopover(file: url) { [weak p] action in
                p?.performClose(nil)
                switch action {
                case .keepFile: KeepOnIPhone.shared.keepFile(url, from: window)
                case .keepFolder: KeepOnIPhone.shared.keepFolder(url.deletingLastPathComponent(), from: window)
                case .settings: IPhoneSettingsWindow.show()
                }
            }
        })
        HelperClient.shared.refresh()
        return p
    }
}

struct OnIPhonePopover: View {
    enum Action { case keepFile, keepFolder, settings }

    let file: URL
    let act: (Action) -> Void
    @ObservedObject private var helper = HelperClient.shared
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: "On iPhone")
            if !helper.enabled {
                Text("Linen is not set up for your iPhone yet.").font(Tok.sans(13.5)).foregroundStyle(palette.text).padding(.top, 8)
                Button("Set Up in Settings…") { act(.settings) }.buttonStyle(LoomButtonStyle()).padding(.top, 10)
            } else {
                thisFile
                kept
                syncLine
            }
        }
        .padding(18)
        .frame(width: 360, alignment: .leading)
        .background(palette.ground)
    }

    // MARK: This file

    @ViewBuilder private var thisFile: some View {
        let state = KeepOnIPhone.shared.kept(file)
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.lastPathComponent).font(Tok.sans(14.5, medium: true)).foregroundStyle(palette.text).lineLimit(1).truncationMode(.middle)
                Text(line(state)).font(Tok.sans(12.5)).foregroundStyle(palette.quiet).lineLimit(2)
            }
            Spacer(minLength: 8)
            switch state {
            case .no:
                Button("Keep…") { act(.keepFile) }.buttonStyle(LoomButtonStyle())
            case let .file(id):
                Button("Remove") { helper.unpin(id) }.buttonStyle(LoomButtonStyle(kind: .line))
            case .folder:
                EmptyView()
            }
        }
        .padding(.top, 10).padding(.bottom, 12)
        if state == .no {
            Button("Keep its folder instead…") { act(.keepFolder) }
                .buttonStyle(.plain).font(Tok.sans(12.5, medium: true)).foregroundStyle(palette.accent).padding(.bottom, 12)
        }
        Rectangle().fill(palette.line).frame(height: 1)
    }

    private func line(_ s: KeepOnIPhone.Kept) -> String {
        switch s {
        case .no: String(localized: "Not on your iPhone")
        case .file: String(localized: "On your iPhone, kept up to date")
        case let .folder(_, path): String(localized: "On your iPhone with its folder “\((path as NSString).lastPathComponent)”")
        }
    }

    // MARK: Everything kept

    @ViewBuilder private var kept: some View {
        let pins = helper.state?.pins ?? []
        let used = pins.reduce(Int64(0)) { $0 + $1.size }
        Eyebrow(text: "Kept · \(IPhoneSettingsView.bytes(used)) of \(IPhoneSettingsView.bytes(helper.state?.limit ?? LinkBounds.defaultTotalLimit))")
            .padding(.top, 12).padding(.bottom, 2)
        if pins.isEmpty {
            Text("Nothing kept yet.").font(Tok.sans(13)).foregroundStyle(palette.quiet).padding(.vertical, 6)
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(pins, id: \.id) { pin in
                    HStack(spacing: 8) {
                        Image(systemName: pin.kind == "file" ? "doc" : "folder").font(.system(size: 12)).foregroundStyle(palette.quiet).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(pin.name).font(Tok.sans(13.5)).foregroundStyle(palette.text).lineLimit(1).truncationMode(.middle)
                            Text(pin.kind == "file" ? String(localized: "file · \(IPhoneSettingsView.bytes(pin.size))")
                                 : String(localized: "folder · \(pin.files) files · \(IPhoneSettingsView.bytes(pin.size))"))
                                .font(Tok.sans(12)).foregroundStyle(palette.quiet)
                        }
                        Spacer(minLength: 8)
                        Button("Remove") { helper.unpin(pin.id) }.buttonStyle(.plain).font(Tok.sans(12.5)).foregroundStyle(palette.quiet)
                    }
                    .padding(.vertical, 7)
                    .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
                }
            }
        }
        .frame(maxHeight: 220)
        .fixedSize(horizontal: false, vertical: pins.count <= 5)
    }

    // MARK: Sync line

    @ViewBuilder private var syncLine: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(phoneLine).font(Tok.sans(12.5)).foregroundStyle(palette.quiet).lineLimit(2)
            Spacer(minLength: 8)
            Button("iPhone Settings…") { act(.settings) }.buttonStyle(.plain).font(Tok.sans(12.5, medium: true)).foregroundStyle(palette.accent)
        }
        .padding(.top, 12)
    }

    private var phoneLine: String {
        guard let p = helper.state?.phones.first else { return String(localized: "No iPhone paired") }
        if p.connected { return String(localized: "\(p.name) · connected now") }
        guard let d = p.lastSeen else { return String(localized: "\(p.name) · not seen since pairing") }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return String(localized: "\(p.name) · last seen \(f.localizedString(for: d, relativeTo: Date()))")
    }
}
