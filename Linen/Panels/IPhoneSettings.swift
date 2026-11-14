import AppKit
import CoreImage.CIFilterBuiltins
import LinenKit
import ServiceManagement
import SwiftUI

/// The app's side of the helper (SYNC-2): registers the login item, talks to it over XPC with its code signature
/// checked, and keeps it told of the page trust (PAGE-7) while Linen runs.
@MainActor
final class HelperClient: ObservableObject {
    static let shared = HelperClient()
    /// Posted when what the helper keeps or knows changed, so every window's iPhone mark follows.
    static let changed = Notification.Name("LinenHelperStateChanged")

    @Published private(set) var state: HelperState?
    @Published private(set) var status: SMAppService.Status
    @Published var lastError: String?
    private var connection: NSXPCConnection?
    private var poll: Timer?
    private var defaultsObserver: (any NSObjectProtocol)?
    private var lastTrust: PageTrust?

    private var service: SMAppService { .loginItem(identifier: LinenHelperXPC.serviceName) }

    private init() {
        status = SMAppService.loginItem(identifier: LinenHelperXPC.serviceName).status
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HelperClient.shared.pushTrust() }
        }
        if status == .enabled { pushTrust() }
    }

    var enabled: Bool { status == .enabled }

    #if DEBUG
    /// Shows a given state without a helper, for rendering the pane offscreen.
    func preview(_ s: HelperState?, status: SMAppService.Status) {
        state = s
        self.status = status
        previewing = true
    }

    private var previewing = false
    #endif

    /// "Start at login" and the helper's first launch, in one step; macOS then asks for local network access when the
    /// helper announces itself.
    func enable() {
        do {
            try service.register()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        status = service.status
        pushTrust()
        refresh()
    }

    func disable() {
        try? service.unregister()
        status = service.status
        connection?.invalidate()
        connection = nil
        state = nil
    }

    private func proxy() -> (any LinenHelperProtocol)? {
        guard enabled else { return nil }
        if connection == nil {
            let c = NSXPCConnection(machServiceName: LinenHelperXPC.serviceName)
            c.remoteObjectInterface = LinenHelperXPC.interface()
            c.setCodeSigningRequirement(LinenHelperXPC.requirement(identifier: LinenHelperXPC.serviceName))
            c.invalidationHandler = { Task { @MainActor in HelperClient.shared.connection = nil } }
            c.resume()
            connection = c
        }
        return connection?.remoteObjectProxyWithErrorHandler { e in
            Task { @MainActor in HelperClient.shared.lastError = e.localizedDescription }
        } as? any LinenHelperProtocol
    }

    func refresh() {
        #if DEBUG
        if previewing { return }
        #endif
        status = service.status
        proxy()?.state { data in
            let s = try? JSONDecoder().decode(HelperState.self, from: data)
            Task { @MainActor in
                let c = HelperClient.shared
                if c.state != s {
                    c.state = s
                    NotificationCenter.default.post(name: HelperClient.changed, object: nil)
                }
                if s != nil { c.lastError = nil }
            }
        }
    }

    /// Polls twice a second while the pane is open: pairing and transfers change fast.
    func watch(_ on: Bool) {
        poll?.invalidate()
        poll = nil
        guard on else { return }
        refresh()
        poll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in MainActor.assumeIsolated { HelperClient.shared.refresh() } }
    }

    func beginPairing() { proxy()?.beginPairing { _ in Task { @MainActor in HelperClient.shared.refresh() } } }
    func cancelPairing() { proxy()?.cancelPairing(); refresh() }
    func answer(_ allow: Bool) { proxy()?.answerPairing(allow); refresh() }
    func forget(_ phone: HelperState.Phone) { proxy()?.forgetPhone(phone.certHash); refresh() }
    func unpin(_ id: String) { proxy()?.unpin(id); refresh() }
    func setLimit(_ bytes: Int64) { proxy()?.setLimit(bytes); refresh() }

    func pin(_ url: URL, kind: Pin.Kind) {
        pushTrust()
        proxy()?.pin(url.path, kind: kind.rawValue) { _ in Task { @MainActor in HelperClient.shared.refresh() } }
    }

    /// The page trust as the app keeps it: trusted folders and per-file choices (PAGE-7).
    func pushTrust() {
        guard enabled else { return }
        let t = PageTrust(revision: 0, folders: TrustedFolders.all,
                          perFile: (UserDefaults.standard.dictionary(forKey: PagePolicy.perFileKey) as? [String: Bool]) ?? [:])
        guard t != lastTrust, let data = try? JSONEncoder().encode(t) else { return }
        lastTrust = t
        proxy()?.setTrust(data)
    }
}

/// Settings > iPhone (SYS-2), as sketched: pairing with the QR and the six digits, paired phones, what is kept on the
/// iPhone with sizes, the size limit and the helper's state. One window, opened from Settings and from Keep on iPhone.
@MainActor
enum IPhoneSettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 720), styleMask: [.titled, .closable, .fullSizeContentView, .resizable], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.title = String(localized: "iPhone")
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 560, height: 520)
        w.contentView = NSHostingView(rootView: LinenScreen { IPhoneSettingsView() })
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
    }
}

struct IPhoneSettingsView: View {
    @ObservedObject private var helper = HelperClient.shared
    @Environment(\.palette) private var palette
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private static let brain = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Loom/brain")

    var body: some View {
        ZStack(alignment: .topLeading) {
            WeaveBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Eyebrow(text: "Linen")
                    Text("iPhone").font(Tok.serif(34)).foregroundStyle(palette.head).padding(.top, 4).padding(.bottom, 16)
                    if !helper.enabled {
                        setup
                    } else {
                        pairing
                        phones
                        pins
                        limit
                        helperLine
                    }
                    if let e = helper.lastError {
                        Text(e).font(Tok.sans(13)).foregroundStyle(Tok.rust).padding(.top, 10)
                    }
                }
                .padding(.horizontal, 40).padding(.top, 44).padding(.bottom, 30)
                .frame(maxWidth: 680, alignment: .leading)
            }
        }
        .onAppear { helper.watch(true) }
        .onDisappear { helper.watch(false) }
        .onReceive(tick) { now = $0 }
    }

    // MARK: Setup (SYNC-2)

    private var setup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keep folders on your iPhone").font(Tok.serif(24)).foregroundStyle(palette.head)
            Text("A small helper inside Linen keeps the folders you pin ready for your iPhone, even when Linen is closed. It starts at login and has no Dock icon. macOS will ask whether Linen may find devices on your local network: allow it, since that is how your iPhone reaches this Mac.")
                .font(Tok.sans(14)).foregroundStyle(palette.text).fixedSize(horizontal: false, vertical: true)
            if helper.status == .requiresApproval {
                Text("Turn on Linen in System Settings › General › Login Items to finish.").font(Tok.sans(13.5)).foregroundStyle(palette.text)
                Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }.buttonStyle(LoomButtonStyle(kind: .line))
            } else {
                Button("Start the Helper at Login") { helper.enable() }.buttonStyle(LoomButtonStyle())
            }
        }
        .padding(.bottom, 16)
    }

    // MARK: Pairing (SYNC-1)

    @ViewBuilder private var pairing: some View {
        let p = helper.state?.pairing
        HStack(alignment: .center, spacing: 22) {
            if let qr = p?.qr, p?.digits == nil {
                QRImage(text: qr).frame(width: 150, height: 150)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pairing with a phone").font(Tok.serif(24)).foregroundStyle(palette.head)
                    Text("In Linen on your iPhone, tap Pair with a Mac and point the camera at this code. Your iPhone will ask to find devices on your local network: allow it.")
                        .font(Tok.sans(14)).foregroundStyle(palette.text).fixedSize(horizontal: false, vertical: true)
                    if let e = p?.expires {
                        let left = max(0, Int(e.timeIntervalSince(now)))
                        Text("Code valid for \(left / 60):\(String(format: "%02d", left % 60)) · one pairing at a time").font(Tok.sans(12.5)).foregroundStyle(palette.quiet)
                    }
                    Button("Cancel") { helper.cancelPairing() }.buttonStyle(LoomButtonStyle(kind: .line))
                }
            } else if let digits = p?.digits {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pairing with \(p?.phoneName ?? "an iPhone")").font(Tok.serif(24)).foregroundStyle(palette.head)
                    Text("Check that the iPhone shows the same six digits, then Allow.").font(Tok.sans(14)).foregroundStyle(palette.text)
                    Text(PairingDigits.spaced(digits)).font(Tok.serif(40)).tracking(2).foregroundStyle(palette.head).padding(.vertical, 4)
                        .accessibilityLabel(digits.map(String.init).joined(separator: " "))
                    HStack(spacing: 10) {
                        Button("Allow") { helper.answer(true) }.buttonStyle(LoomButtonStyle()).keyboardShortcut(.defaultAction)
                        Button("Refuse") { helper.answer(false) }.buttonStyle(LoomButtonStyle(kind: .line))
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if let ended = p?.ended { Text(ended).font(Tok.sans(13.5)).foregroundStyle(palette.text) }
                    Button("Pair an iPhone…") { helper.beginPairing() }.buttonStyle(LoomButtonStyle())
                }
            }
        }
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
    }

    // MARK: Phones

    @ViewBuilder private var phones: some View {
        let list = helper.state?.phones ?? []
        Eyebrow(text: "Paired").padding(.top, 20).padding(.bottom, 4)
        if list.isEmpty {
            Text("No iPhone paired yet.").font(Tok.sans(13.5)).foregroundStyle(palette.quiet).padding(.vertical, 8)
        }
        ForEach(list, id: \.certHash) { phone in
            row {
                Text(phone.name).font(Tok.sans(14.5, medium: true)).foregroundStyle(palette.text)
                Text(seen(phone)).font(Tok.sans(13)).foregroundStyle(palette.quiet)
            } trailing: {
                Button("Forget") { helper.forget(phone) }.buttonStyle(.plain).font(Tok.sans(13)).foregroundStyle(palette.quiet)
            }
        }
    }

    private func seen(_ p: HelperState.Phone) -> String {
        if p.connected { return String(localized: "connected now") }
        guard let d = p.lastSeen else { return String(localized: "not seen since pairing") }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return String(localized: "last seen \(f.localizedString(for: d, relativeTo: now))")
    }

    // MARK: Pins (SYNC-3, SYNC-8, IOS-11)

    @ViewBuilder private var pins: some View {
        let list = helper.state?.pins ?? []
        let used = list.reduce(Int64(0)) { $0 + $1.size }
        let limit = helper.state?.limit ?? LinkBounds.defaultTotalLimit
        Eyebrow(text: "Kept on iPhone · \(bytes(used)) of \(bytes(limit))").padding(.top, 22).padding(.bottom, 4)
        if Self.brainOffer(list) {
            row {
                Text("Loom brain").font(Tok.sans(14.5, medium: true)).foregroundStyle(palette.text)
                Text("~/Loom/brain, suggested first").font(Tok.sans(13)).foregroundStyle(palette.quiet)
            } trailing: {
                Button("Keep on iPhone") { helper.pin(Self.brain, kind: .folder) }.buttonStyle(.plain).font(Tok.sans(13, medium: true)).foregroundStyle(palette.accent)
            }
        }
        if list.isEmpty {
            Text("Nothing yet. In any note, board or page, click the iPhone button in the toolbar to keep it on your iPhone.")
                .font(Tok.sans(13.5)).foregroundStyle(palette.quiet).padding(.vertical, 8).fixedSize(horizontal: false, vertical: true)
        }
        ForEach(list, id: \.id) { pin in
            row {
                Text(pin.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(Tok.sans(14.5)).foregroundStyle(palette.text).lineLimit(1).truncationMode(.middle)
                Text(pin.kind == "file" ? String(localized: "file · \(bytes(pin.size))") : String(localized: "folder · \(pin.files) files · \(bytes(pin.size))"))
                    .font(Tok.sans(13)).foregroundStyle(palette.quiet)
                if let first = pin.problems.first {
                    Text(pin.problems.count > 1 ? "\(first) (and \(pin.problems.count - 1) more)" : first).font(Tok.sans(12.5)).foregroundStyle(palette.quiet).lineLimit(2)
                }
            } trailing: {
                Button("Unpin") { helper.unpin(pin.id) }.buttonStyle(.plain).font(Tok.sans(13)).foregroundStyle(palette.quiet)
            }
        }
    }

    static func brainOffer(_ pins: [HelperState.PinRow]) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: brain.path, isDirectory: &dir) && dir.boolValue
            && !pins.contains { $0.path == brain.resolvingSymlinksInPath().path }
    }

    private var limit: some View {
        let options: [(Int64, String)] = [(1 << 30, "1 GB"), (2 << 30, "2 GB"), (5 << 30, "5 GB"), (10 << 30, "10 GB")]
        let current = helper.state?.limit ?? LinkBounds.defaultTotalLimit
        return HStack {
            Text("Size limit").font(Tok.sans(14.5)).foregroundStyle(palette.text)
            Spacer()
            HStack(spacing: 0) {
                ForEach(options, id: \.0) { o in
                    Button { helper.setLimit(o.0) } label: {
                        Text(o.1).font(Tok.sans(13, medium: current == o.0)).padding(.horizontal, 12).frame(height: 28)
                            .foregroundStyle(current == o.0 ? palette.onAccent : palette.text)
                            .background(current == o.0 ? palette.accent : .clear).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: Tok.corner).stroke(palette.line))
        }
        .padding(.vertical, 12).padding(.top, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
    }

    private var helperLine: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Helper").font(Tok.sans(13, medium: true)).foregroundStyle(palette.text)
            Spacer()
            Text(helperText).font(Tok.sans(13)).foregroundStyle(palette.quiet).multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12)
    }

    private var helperText: String {
        guard let s = helper.state else { return String(localized: "Starting…") }
        if !s.listening {
            return String(localized: "Your iPhone cannot reach this Mac. Check that Linen may use the local network (System Settings › Privacy & Security › Local Network) and that the firewall lets LinenHelper accept connections.")
        }
        return String(localized: "Running · starts at login · announced as “\(s.serviceName ?? "this Mac")”")
    }

    private func bytes(_ n: Int64) -> String { IPhoneSettingsView.bytes(n) }

    /// Sizes in binary units, so the 2 GB limit reads "2 GB" and nothing reads "0 bytes".
    static func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: n)
    }

    private func row<L: View, T: View>(@ViewBuilder _ leading: () -> L, @ViewBuilder trailing: () -> T) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) { leading() }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
    }
}

/// The pairing QR, drawn sharp in ink on paper whatever the look, so every camera reads it.
struct QRImage: View {
    let text: String

    var body: some View {
        if let img = Self.render(text) {
            Image(nsImage: img).interpolation(.none).resizable().aspectRatio(1, contentMode: .fit)
                .padding(8).background(Tok.paper2)
                .accessibilityLabel("Pairing code")
        }
    }

    /// Rasterised at a whole-number scale with no smoothing: a blurred module edge can defeat a camera.
    static func render(_ text: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage else { return nil }
        let colored = out.applyingFilter("CIFalseColor", parameters: [
            "inputColor0": CIColor(red: 0x28 / 255, green: 0x47 / 255, blue: 0x34 / 255),
            "inputColor1": CIColor(red: 0xFB / 255, green: 0xF9 / 255, blue: 0xF4 / 255),
        ]).samplingNearest().transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cg = CIContext().createCGImage(colored, from: colored.extent.integral) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
