import AVFoundation
import LinenKit
import SwiftUI

/// Pairing with a Mac (SYNC-1, sketch screen 15): the camera reads the QR code Linen shows in Settings on the Mac,
/// the link dials (iOS asks for local network access at this moment, never at launch), both screens show six digits,
/// and Hatim clicks Allow on the Mac. If camera access is off, the screen says so and where to turn it on.
struct PairingScreen: View {
    enum Stage: Equatable {
        case asking, camera, cameraOff, dialing, match(String, String), paired(String), failed(PairingFailure)
    }

    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var stage: Stage = .asking
    @State private var pairing: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            DocumentBar(title: Text("Pair with a Mac"), back: { pairing?.cancel(); dismiss() }) { EmptyView() }
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
                case let .paired(mac):
                    done(mac)
                case let .failed(reason):
                    failed(reason)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(palette.ground.ignoresSafeArea())
        .task { await start() }
    }

    private func start() async {
        #if DEBUG
        if let s = Launch.value("-LinenPairing") {
            switch s {
            case "match": stage = .match("418 207", "MacBook Air"); return
            case "off": stage = .cameraOff; return
            default: break
            }
        }
        #endif
        if let code = model.pendingPairCode {
            model.pendingPairCode = nil
            stage = .camera
            scanned(code)
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
                    Text("Settings › Linen › Camera").font(Tok.sans(13.5, medium: true)).foregroundStyle(Tok.paper)
                        .padding(.bottom, 1).overlay(alignment: .bottom) { Rectangle().fill(Tok.paper.opacity(0.5)).frame(height: 1) }
                        .frame(minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.plain)
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
                WeaveIndicator(lineWidth: 1.6).frame(width: 30, height: 14)
                Text("Waiting for Allow").font(Tok.sans(14)).foregroundStyle(palette.head)
            }
            .padding(.top, 26)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WeaveBackground())
    }

    private func waiting(_ text: Text) -> some View {
        VStack(spacing: 14) {
            WeaveIndicator(lineWidth: 2).frame(width: 60, height: 28)
            text.font(Tok.sans(15)).foregroundStyle(palette.head)
        }
    }

    private func done(_ mac: String) -> some View {
        VStack(spacing: 12) {
            Text("Paired with \(mac)").font(Tok.serif(28, relativeTo: .title)).foregroundStyle(palette.head)
            Text("Folders you keep on iPhone from your Mac arrive in the Library.").font(Tok.sans(15)).foregroundStyle(palette.text)
                .multilineTextAlignment(.center).frame(maxWidth: 290)
            Button { dismiss() } label: {
                Text("Done").font(Tok.sans(15, medium: true)).foregroundStyle(palette.onAccent).padding(.horizontal, 22).frame(minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: Tok.corner).fill(palette.accent))
            }
            .buttonStyle(.plain).padding(.top, 8)
        }
    }

    private func failed(_ reason: PairingFailure) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Self.title(reason)).font(Tok.serif(26, relativeTo: .title2)).foregroundStyle(palette.head)
            Text(Self.detail(reason)).font(Tok.sans(15)).foregroundStyle(palette.text).fixedSize(horizontal: false, vertical: true)
            Button { stage = .camera } label: {
                Text("Try again").font(Tok.sans(15, medium: true)).foregroundStyle(palette.onAccent).padding(.horizontal, 22).frame(minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: Tok.corner).fill(palette.accent))
            }
            .buttonStyle(.plain).padding(.top, 8)
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
