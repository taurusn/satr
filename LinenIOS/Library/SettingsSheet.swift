import AVFoundation
import LinenKit
import SwiftUI

/// The phone's own settings (IOS-10, sketch screen 11): the paired Mac with Forget, what is kept per pin, when this
/// copy stops opening, local network and camera, and the look (IOS-5).
struct SettingsSheet: View {
    let pair: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance") private var appearance = "system"
    @State private var confirmForget = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow("Linen on this iPhone").padding(.top, 22)
                Text("Settings").font(Tok.serif(30, relativeTo: .title)).foregroundStyle(palette.head)
                    .padding(.top, 2).padding(.bottom, 14)
                    .accessibilityAddTraits(.isHeader)
                macRows
                Row(key: "Kept here") { Text(verbatim: model.keptBytes.formatted(.byteCount(style: .file))) }
                ForEach(model.groups) { g in
                    Row(verbatimKey: g.pin.name, small: true) { Text(verbatim: g.pin.size.formatted(.byteCount(style: .file))) }
                }
                Row(key: "This copy") {
                    if let e = model.expiry {
                        Text("Stops opening on \(e.formatted(.dateTime.day().month(.abbreviated).year()))")
                        LinkLabel(text: Text("Reinstall from your Mac"))
                    } else {
                        Text("Installed from Xcode")
                    }
                }
                Row(key: "Local network") { Text(model.pairedMac == nil ? "Asked when you pair" : "On") }
                Row(key: "Camera") { Text(cameraText) }
                Row(key: "Look") {
                    Picker(selection: $appearance) {
                        Text("System").tag("system")
                        Text("Paper").tag("paper")
                        Text("Night").tag("night")
                    } label: { Text("Look") }
                    .pickerStyle(.segmented).frame(maxWidth: 230)
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 30)
        }
        .background(palette.ground.ignoresSafeArea())
        .confirmationDialog(Text("Forget this Mac?"), isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget this Mac", role: .destructive) { Task { await model.link.forgetMac(); await model.refresh() } }
        } message: {
            Text("Everything kept on this iPhone from it is removed. Pair again to bring it back.")
        }
    }

    @ViewBuilder private var macRows: some View {
        if let mac = model.pairedMac {
            Row(key: "Mac") {
                Text(verbatim: mac.name)
                Button { confirmForget = true } label: { LinkLabel(text: Text("Forget this Mac")) }.buttonStyle(.plain)
            }
            Row(key: "Paired") {
                Text("\(mac.pairedAt.formatted(.dateTime.day().month(.abbreviated))), named “\(mac.phoneName)”")
            }
        } else {
            Row(key: "Mac") {
                Text("Not paired")
                Button { pair() } label: { LinkLabel(text: Text("Pair with a Mac")) }.buttonStyle(.plain)
                    .accessibilityIdentifier("pair")
            }
        }
    }

    private var cameraText: LocalizedStringKey {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: "On, for pairing only"
        case .denied, .restricted: "Off"
        default: "Asked when you pair"
        }
    }
}

/// One settings row: the key on the leading side, the value and its action on the trailing side, a rule under.
private struct Row<Value: View>: View {
    var key: Text
    var small = false
    @ViewBuilder var value: () -> Value
    @Environment(\.palette) private var palette

    init(key: LocalizedStringKey, small: Bool = false, @ViewBuilder value: @escaping () -> Value) {
        self.key = Text(key)
        self.small = small
        self.value = value
    }

    init(verbatimKey: String, small: Bool = false, @ViewBuilder value: @escaping () -> Value) {
        key = Text(verbatim: verbatimKey)
        self.small = small
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            key.font(Tok.sans(small ? 14 : 15.5)).foregroundStyle(small ? palette.quiet : palette.text)
                .padding(.leading, small ? 14 : 0)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) { value() }
                .font(Tok.sans(small ? 14 : 15)).foregroundStyle(palette.text)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, small ? 8 : 11)
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
    }
}
