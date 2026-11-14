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

    // iOS's own controls (Hatim, 2026-11-14): a form in a navigation stack with Done, labelled rows, the segmented
    // picker, the system's buttons and a destructive confirmation.
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    macRows
                }
                Section {
                    LabeledContent { Text(verbatim: model.keptBytes.formatted(.byteCount(style: .file))) } label: { Text("Kept here") }
                    ForEach(model.groups) { g in
                        LabeledContent { Text(verbatim: g.pin.size.formatted(.byteCount(style: .file))) } label: { Text(verbatim: g.pin.name).foregroundStyle(palette.quiet) }
                    }
                }
                .listRowBackground(palette.raised)
                Section {
                    LabeledContent {
                        if let e = model.expiry {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("Stops opening on \(e.formatted(.dateTime.day().month(.abbreviated).year()))")
                                Text("Reinstall from your Mac").foregroundStyle(palette.quiet)
                            }
                        } else {
                            Text("Installed from Xcode")
                        }
                    } label: { Text("This copy") }
                    LabeledContent { Text(model.pairedMac == nil ? "Asked when you pair" : "On") } label: { Text("Local network") }
                    LabeledContent { Text(cameraText) } label: { Text("Camera") }
                }
                .listRowBackground(palette.raised)
                Section {
                    Picker(selection: $appearance) {
                        Text("System").tag("system")
                        Text("Paper").tag("paper")
                        Text("Night").tag("night")
                    } label: { Text("Look") }
                    .pickerStyle(.segmented)
                } header: { Text("Look") }
                .listRowBackground(palette.raised)
            }
            .font(Tok.sans(15.5))
            .foregroundStyle(palette.text)
            .scrollContentBackground(.hidden)
            .background(palette.ground.ignoresSafeArea())
            .navigationTitle(Text("Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .confirmationDialog(Text("Forget this Mac?"), isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget this Mac", role: .destructive) { Task { await model.link.forgetMac(); await model.refresh() } }
        } message: {
            Text("Everything kept on this iPhone from it is removed. Pair again to bring it back.")
        }
    }

    @ViewBuilder private var macRows: some View {
        if let mac = model.pairedMac {
            LabeledContent { Text(verbatim: mac.name) } label: { Text("Mac") }
                .listRowBackground(palette.raised)
            LabeledContent { Text("\(mac.pairedAt.formatted(.dateTime.day().month(.abbreviated))), named “\(mac.phoneName)”") } label: { Text("Paired") }
                .listRowBackground(palette.raised)
            Button("Forget this Mac", role: .destructive) { confirmForget = true }
                .listRowBackground(palette.raised)
        } else {
            LabeledContent { Text("Not paired") } label: { Text("Mac") }
                .listRowBackground(palette.raised)
            Button("Pair with a Mac") { pair() }
                .accessibilityIdentifier("pair")
                .listRowBackground(palette.raised)
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
