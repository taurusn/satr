import AVFoundation
import LinenKit
import SwiftUI

/// Pairing with a Mac (SYNC-1, sketch screen 15): the camera reads the QR code Linen shows in Settings on the Mac,
/// the link dials (iOS asks for local network access at this moment, never at launch), both screens show six digits,
/// and Hatim clicks Allow on the Mac. If camera access is off, the screen says so and where to turn it on.
struct PairingScreen: View {
    enum Stage: Equatable {
        case asking, camera, cameraOff, dialing, match(String, String), paired(String), failed(PairingFailure)
        /// Asks before dialing: a code that came by link (never dial on a link alone), or one that would replace the
        /// paired Mac (review P2-6, 2026-11-14).
        case confirm(code: String, mac: String, replaces: String?)
    }

    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var stage: Stage = .asking
    @State private var pairing: Task<Void, Never>?

    // iOS's own controls (Hatim, 2026-11-14): the navigation bar with its title and Cancel, the system's buttons and
    // activity indicator. Linen's own: the viewfinder's corners over the camera (a drawing, not a control).
    var body: some View {
        NavigationStack {
            ZStack {
                switch stage {
                case .asking, .camera:
                    cameraView
                case .cameraOff:
                    cameraOff
                case .dialing:
                    waiting(Text("Finding your Mac"))
                case let .match(digits, mac):
                    matchView(digits: digits, mac: mac)
                case let .confirm(code, mac, replaces):
                    confirmView(code: code, mac: mac, replaces: replaces)
                case let .paired(mac):
                    done(mac)
                case let .failed(reason):
                    failed(reason)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.ground.ignoresSafeArea())
            .navigationTitle(Text("Pair with a Mac"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { pairing?.cancel(); dismiss() }.accessibilityIdentifier("back")
                }
            }
        }
        .task { await start() }
        .task(id: stage) { await watchdog(stage) }
    }

    /// No step spins for ever (threads L1, 2026-11-14: "after the QR scan the iPhone shows loading for hours"). The
    /// link ends each step itself (15 s to find the Mac, 75 s for its answer); this is the screen's own limit on top,
    /// so whatever happens below, a waiting screen becomes a message with Try again.
    private func watchdog(_ s: Stage) async {
        let limit: Duration
        let reason: PairingFailure
        switch s {
        case .dialing: limit = .seconds(Self.findLimit); reason = .unreachable
        case .match: limit = .seconds(Self.answerLimit); reason = .timeout
        default: return
        }
        try? await Task.sleep(for: limit)
        guard !Task.isCancelled, stage == s else { return }
        pairing?.cancel()
        pairing = nil
        stage = .failed(reason)
    }

    static let findLimit: Double = 30
    static let answerLimit: Double = 100

    private func start() async {
        #if DEBUG
        if let s = Launch.value("-LinenPairing") {
            switch s {
            case "match": stage = .match("418 207", "MacBook Air"); return
            case "off": stage = .cameraOff; return
            // A link that never answers: the screen's own limit must end the wait (watchdog).
            case "stall": stage = .dialing; return
            case "confirm": stage = .confirm(code: "", mac: "MacBook Air", replaces: "Mac mini"); return
            default: break
            }
        }
        #endif
        if let code = model.pendingPairCode {
            model.pendingPairCode = nil
            await prepare(code, fromLink: true)
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: stage = .camera
        case .notDetermined: stage = await AVCaptureDevice.requestAccess(for: .video) ? .camera : .cameraOff
        default: stage = .cameraOff
        }
    }

    private func scanned(_ code: String) {
        guard stage == .camera else { return }
        stage = .dialing
        Task { await prepare(code, fromLink: false) }
    }

    /// A code from the camera dials at once, unless it would replace the paired Mac; a code from a link always asks.
    private func prepare(_ code: String, fromLink: Bool) async {
        guard let invite = PairingInvite(text: code) else { stage = .failed(.notALinenCode); return }
        let replaces = await model.link.replacesPairedMac(scannedCode: code)
        if fromLink || replaces != nil {
            stage = .confirm(code: code, mac: invite.macName, replaces: replaces)
        } else {
            dial(code)
        }
    }

    private func dial(_ code: String) {
        stage = .dialing
        let link = model.link
        pairing = Task {
            for await step in link.pair(scannedCode: code, phoneName: UIDevice.current.name) {
                switch step {
                case .dialing: stage = .dialing
                case let .match(digits, mac): stage = .match(PairingDigits.spaced(digits), mac)
                case let .paired(mac): stage = .paired(mac.name); await model.refresh()
                case let .failed(reason): stage = .failed(reason)
                }
            }
        }
    }

    private var cameraView: some View {
        VStack(spacing: 0) {
            ZStack {
                QRCamera(onCode: scanned).background(Color.black)
                Viewfinder().frame(width: 240, height: 240)
            }
            .frame(height: 500)
            .clipped()
            VStack(alignment: .leading, spacing: 4) {
                Text("Point at the code").font(Tok.serif(24, relativeTo: .title2)).foregroundStyle(palette.head)
                Text("In Linen on your Mac: Settings, iPhone, Pair. Linen will ask to find devices on your local network; that is how it reaches the Mac.")
                    .font(Tok.sans(15)).foregroundStyle(palette.text).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24).padding(.top, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
        }
    }

    private var cameraOff: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Camera access is off for Linen").font(Tok.serif(26, relativeTo: .title2)).foregroundStyle(Tok.paper)
                Text("Linen uses the camera only to read the pairing code on your Mac.").font(Tok.sans(15)).foregroundStyle(Tok.paper)
                    .fixedSize(horizontal: false, vertical: true)
                Button { if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) } } label: {
                    Text("Settings › Linen › Camera").font(Tok.sans(14, medium: true))
                }
                .buttonStyle(.bordered).tint(Tok.paper).controlSize(.large)
                .padding(.top, 6)
            }
            .padding(.horizontal, 34)
            .frame(maxWidth: .infinity, maxHeight: 500, alignment: .leading)
            .background(Tok.ink2)
            Spacer()
        }
    }

    private func matchView(digits: String, mac: String) -> some View {
        VStack(spacing: 0) {
            Eyebrow(path: mac).padding(.top, 120)
            Text(verbatim: digits).font(Tok.serif(52, relativeTo: .largeTitle)).tracking(3).foregroundStyle(palette.head)
                .padding(.top, 10).padding(.bottom, 8)
                .accessibilityLabel(Text(verbatim: digits.map(String.init).joined(separator: " ")))
            Text("Check that your Mac shows the same six digits, then click Allow there.")
                .font(Tok.sans(15.5)).foregroundStyle(palette.text).multilineTextAlignment(.center).frame(maxWidth: 280)
            HStack(spacing: 10) {
                ProgressView().tint(palette.head)
                Text("Waiting for Allow").font(Tok.sans(14)).foregroundStyle(palette.head)
            }
            .padding(.top, 26)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WeaveBackground())
    }

    private func confirmView(code: String, mac: String, replaces: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pair with \(mac)?").font(Tok.serif(26, relativeTo: .title2)).foregroundStyle(palette.head)
            Text("Linen will connect to \(mac) and show six digits to check on that Mac.")
                .font(Tok.sans(15)).foregroundStyle(palette.text).fixedSize(horizontal: false, vertical: true)
            if let replaces {
                Text("This replaces \(replaces). Everything kept on this iPhone from it is removed.")
                    .font(Tok.sans(15, medium: true)).foregroundStyle(palette.text).fixedSize(horizontal: false, vertical: true)
            }
            Button { dial(code) } label: { Text("Pair").font(Tok.sans(15, medium: true)) }
                .buttonStyle(.borderedProminent).controlSize(.large).tint(palette.accent).foregroundStyle(palette.onAccent)
                .padding(.top, 8)
                .accessibilityIdentifier("confirmPair")
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func waiting(_ text: Text) -> some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large).tint(palette.head)
            text.font(Tok.sans(15)).foregroundStyle(palette.head)
        }
    }

    private func done(_ mac: String) -> some View {
        VStack(spacing: 12) {
            Text("Paired with \(mac)").font(Tok.serif(28, relativeTo: .title)).foregroundStyle(palette.head)
            Text("Folders you keep on iPhone from your Mac arrive in the Library.").font(Tok.sans(15)).foregroundStyle(palette.text)
                .multilineTextAlignment(.center).frame(maxWidth: 290)
            Button { dismiss() } label: { Text("Done").font(Tok.sans(15, medium: true)) }
                .buttonStyle(.borderedProminent).controlSize(.large).tint(palette.accent).foregroundStyle(palette.onAccent)
                .padding(.top, 8)
        }
    }

    private func failed(_ reason: PairingFailure) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Self.title(reason)).font(Tok.serif(26, relativeTo: .title2)).foregroundStyle(palette.head)
            Text(Self.detail(reason)).font(Tok.sans(15)).foregroundStyle(palette.text).fixedSize(horizontal: false, vertical: true)
            Button { pairing?.cancel(); pairing = nil; stage = .camera } label: { Text("Try again").font(Tok.sans(15, medium: true)) }
                .buttonStyle(.borderedProminent).controlSize(.large).tint(palette.accent).foregroundStyle(palette.onAccent)
                .padding(.top, 8)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func title(_ r: PairingFailure) -> LocalizedStringKey {
        switch r {
        case .code: "The code did not match"
        case .expired: "That code has expired"
        case .refused: "The Mac refused this iPhone"
        case .timeout: "The Mac did not answer"
        case .busy: "The Mac is pairing another phone"
        case .notALinenCode: "That is not a Linen pairing code"
        case .unreachable: "Linen could not reach that Mac"
        case .localNetworkOff: "Local network access is off for Linen"
        }
    }

    static func detail(_ r: PairingFailure) -> LocalizedStringKey {
        switch r {
        case .code, .expired, .timeout, .busy: "On your Mac, open Settings, iPhone, Pair for a new code, then point at it again."
        case .refused: "If that was a mistake, pair again and click Allow on the Mac."
        case .notALinenCode: "Point at the code in Linen's Settings on your Mac, under iPhone."
        case .unreachable: "Keep the iPhone on the same Wi-Fi as the Mac, with the Mac awake, then try again."
        case .localNetworkOff: "Turn it on in Settings › Linen › Local Network, then try again."
        }
    }
}

/// The viewfinder's four corners, in paper over the camera.
private struct Viewfinder: View {
    var body: some View {
        Canvas { ctx, size in
            let l: CGFloat = 34
            var p = Path()
            p.move(to: CGPoint(x: 0, y: l)); p.addLine(to: .zero); p.addLine(to: CGPoint(x: l, y: 0))
            p.move(to: CGPoint(x: size.width - l, y: 0)); p.addLine(to: CGPoint(x: size.width, y: 0)); p.addLine(to: CGPoint(x: size.width, y: l))
            p.move(to: CGPoint(x: 0, y: size.height - l)); p.addLine(to: CGPoint(x: 0, y: size.height)); p.addLine(to: CGPoint(x: l, y: size.height))
            p.move(to: CGPoint(x: size.width - l, y: size.height)); p.addLine(to: CGPoint(x: size.width, y: size.height)); p.addLine(to: CGPoint(x: size.width, y: size.height - l))
            ctx.stroke(p, with: .color(Tok.paper), lineWidth: 3)
        }
        .accessibilityHidden(true)
    }
}

/// The camera, reading QR codes only, running only while the view is on screen.
private struct QRCamera: UIViewRepresentable {
    let onCode: @MainActor (String) -> Void

    func makeUIView(context: Context) -> CameraView {
        let v = CameraView()
        v.onCode = onCode
        v.start()
        return v
    }

    func updateUIView(_ v: CameraView, context: Context) { v.onCode = onCode }

    static func dismantleUIView(_ v: CameraView, coordinator: ()) { v.stop() }
}

final class CameraView: UIView, AVCaptureMetadataOutputObjectsDelegate {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var onCode: (@MainActor (String) -> Void)?
    private let runner = SessionRunner()

    func start() {
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device) else { return }
        let session = AVCaptureSession()
        let output = AVCaptureMetadataOutput()
        guard session.canAddInput(input), session.canAddOutput(output) else { return }
        session.addInput(input)
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let preview = layer as? AVCaptureVideoPreviewLayer
        preview?.session = session
        preview?.videoGravity = .resizeAspectFill
        runner.run(session)
    }

    func stop() { runner.stop() }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        let code = objects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }.first
        MainActor.assumeIsolated {
            if let code { onCode?(code) }
        }
    }
}

/// Starts and stops the capture session off the main thread, as AVFoundation asks.
private final class SessionRunner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "linen.camera")
    private var session: AVCaptureSession?

    func run(_ s: AVCaptureSession) {
        queue.async {
            self.session = s
            s.startRunning()
        }
    }

    func stop() {
        queue.async {
            self.session?.stopRunning()
            self.session = nil
        }
    }
}
