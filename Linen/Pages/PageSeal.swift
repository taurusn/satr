import Foundation
import WebKit

/// The walls around a sealed page (PRD-2 PAGE-1, section 9.2): a content rule list, the CSP header on every response,
/// the navigation gate, and a document-start script in every frame that removes WebRTC, WebTransport and the
/// capability APIs PAGE-11 denies. The app always uses `.full`; spike P(c) and the self-test's control run use the
/// others to prove each wall does its part.
struct SealOptions: Sendable, Equatable {
    var rules = true
    var csp = true
    var removal = true
    var gate = true
    /// CSP `sandbox allow-scripts` (spike P(c) measured it; not adopted, see docs/spikes/pages/README.md).
    var sandbox = false
    /// Turns WebTransport, WebRTC and service workers off in WebKit itself for the page's configuration, through
    /// WebKit's feature flags (an SPI; skipped when absent). Spike P(c) found WebTransport inside a dedicated worker
    /// stopped by the CSP alone (the rule list does not cover it and the removal script cannot reach workers), so
    /// this gives that path a second wall.
    var engineFlags = true

    static let full = SealOptions()
    /// The self-test's control run: no walls, so its witness must see the probes.
    static let open = SealOptions(rules: false, csp: false, removal: false, gate: false, engineFlags: false)
}

/// WebKit's own switches for the APIs a sealed page must never have (SealOptions.engineFlags).
enum EngineFlags {
    static let off: Set<String> = ["WebTransportEnabled", "PeerConnectionEnabled", "ServiceWorkersEnabled"]

    /// Turns the flags off on `prefs`; returns the ones it found and turned off (empty when the SPI is missing).
    @MainActor
    @discardableResult
    static func apply(to prefs: WKPreferences) -> [String] {
        // The SPI is only called on a WebKit build Linen has reviewed (its inventory ships), whose feature objects
        // and setter are known; on any other build page scripts are off anyway (PAGE-10), so nothing needs it.
        guard PageSelfTest.inventoryURL() != nil || PageSelfTest.generatingInventory else { return [] }
        let list = NSSelectorFromString("_features"), set = NSSelectorFromString("_setEnabled:forFeature:")
        guard (WKPreferences.self as AnyObject).responds(to: list), prefs.responds(to: set),
              let features = (WKPreferences.self as AnyObject).perform(list)?.takeUnretainedValue() as? [NSObject] else { return [] }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
        let imp = unsafeBitCast(prefs.method(for: set), to: Setter.self)
        var done: [String] = []
        for f in features {
            guard f.responds(to: NSSelectorFromString("key")), let key = f.value(forKey: "key") as? String, off.contains(key) else { continue }
            imp(prefs, set, false, f)
            done.append(key)
        }
        return done.sorted()
    }
}

enum PageSeal {
    static let pageScheme = "linen-page"
    static let kitScheme = "linen-kit"
    static let kitHost = "kit"
    static let kitWorldName = "linen-kit"

    /// The CSP response header (PRD 9.2, literally), with `script-src 'none'` when PAGE-7 turns scripts off.
    static func csp(scripts: Bool, sandbox: Bool = false) -> String {
        let script = scripts ? "'self' 'unsafe-inline' 'unsafe-eval' blob:" : "'none'"
        let worker = scripts ? "'self' blob:" : "'none'"
        var p = "default-src 'none'; script-src \(script); style-src 'self' 'unsafe-inline' linen-kit:; img-src 'self' data: blob:; "
            + "font-src 'self' data: linen-kit:; media-src 'self' data: blob:; worker-src \(worker); connect-src 'self'; "
            + "frame-src 'self'; child-src 'self' blob:; object-src 'none'; form-action 'none'; base-uri 'none'; manifest-src 'none'"
        if sandbox { p += "; sandbox allow-scripts" }
        return p
    }

    /// Blocks every load, then lets the page's own scheme (whose hosts the handler polices), the kit, about:, blob:
    /// and data: through (spike P(a)).
    static let rulesJSON = """
    [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^linen-page:"},"action":{"type":"ignore-previous-rules"}},
     {"trigger":{"url-filter":"^linen-page://[^/]+/__linen_rule_canary__"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^linen-kit:"},"action":{"type":"ignore-previous-rules"}},
     {"trigger":{"url-filter":"^about:"},"action":{"type":"ignore-previous-rules"}},
     {"trigger":{"url-filter":"^blob:"},"action":{"type":"ignore-previous-rules"}},
     {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}}]
    """
    static let rulesIdentifier = "linen-page-seal-2"
    /// The preflight page each tab loads before the author's page, and the one path the rule list blocks on the
    /// page's own origin, so the preflight can see the rule list working in this very web view (review 2, item 14).
    static let preflightPath = "__linen_preflight__.html"
    static let ruleCanaryPath = "__linen_rule_canary__"

    /// Runs at document start in every frame of the page's own world (spike P(b)). It removes WebRTC and
    /// WebTransport (the ways out the rule list and the CSP do not cover) and the capability APIs PAGE-11 denies, and
    /// pins each to `undefined` so a page cannot put it back. It is a blocklist of today's names; the self-test's
    /// per-build inventory (PAGE-10) is what notices a new one.
    static let removalScript = """
    (() => {
      const pin = (o, n) => { if (!o) return; try { delete o[n]; } catch (e) {}
        try { Object.defineProperty(o, n, {value: undefined, configurable: false, writable: false, enumerable: false}); } catch (e) {} };
      const names = new Set(['RTCPeerConnection','webkitRTCPeerConnection','RTCDataChannel','RTCSessionDescription','RTCIceCandidate',
        'RTCRtpTransceiver','RTCRtpSender','RTCRtpReceiver','RTCDtlsTransport','RTCIceTransport','RTCSctpTransport','RTCCertificate',
        'RTCPeerConnectionIceEvent','RTCDataChannelEvent','RTCTrackEvent','RTCRtpScriptTransform','RTCEncodedAudioFrame',
        'RTCEncodedVideoFrame','RTCDTMFSender','RTCDTMFToneChangeEvent','RTCErrorEvent','RTCError','RTCStatsReport',
        'RTCPeerConnectionIceErrorEvent','RTCTransformEvent','RTCRtpScriptTransformer',
        'WebTransport','WebTransportBidirectionalStream','WebTransportDatagramDuplexStream','WebTransportError',
        'WebTransportReceiveStream','WebTransportSendStream','PaymentRequest','PaymentResponse','PaymentAddress',
        'PaymentMethodChangeEvent','PaymentRequestUpdateEvent','ApplePaySession','ApplePayError','ApplePaySetup',
        'Notification','PushManager','PushSubscription','PushSubscriptionOptions','IdentityCredential',
        'DigitalCredential','PublicKeyCredential']);
      for (const n of Object.getOwnPropertyNames(window)) { if (/^(webkit)?RTC/.test(n) || /^WebTransport/.test(n)) names.add(n); }
      for (const n of names) pin(window, n);
      const P = (C, ms) => { if (!C || !C.prototype) return; for (const m of ms) pin(C.prototype, m); };
      P(window.Clipboard, ['read', 'readText']);
      P(window.Navigator, ['share', 'canShare', 'credentials', 'mediaDevices', 'geolocation', 'serviceWorker',
        'getUserMedia', 'webkitGetUserMedia', 'requestMediaKeySystemAccess', 'registerProtocolHandler']);
      P(window.Geolocation, ['getCurrentPosition', 'watchPosition']);
      P(window.MediaDevices, ['getUserMedia', 'getDisplayMedia', 'enumerateDevices']);
      P(window.CredentialsContainer, ['get', 'create', 'store']);
    })();
    """

    nonisolated(unsafe) private static var compiled: WKContentRuleList?

    /// The compiled rule list, compiled once per launch. A failure is returned to the caller, which opens the page
    /// as its source text with the reason (PAGE-1), never unsealed.
    @MainActor
    static func ruleList() async throws -> WKContentRuleList {
        if let compiled { return compiled }
        guard let store = WKContentRuleListStore.default() else { throw SealError.rulesUnavailable }
        guard let list = try await store.compileContentRuleList(forIdentifier: rulesIdentifier, encodedContentRuleList: rulesJSON) else {
            throw SealError.rulesUnavailable
        }
        compiled = list
        return list
    }

    enum SealError: Error, CustomStringConvertible {
        case rulesUnavailable
        var description: String { "Linen could not build the wall that keeps this page off the network" }
    }

    /// One random host per opened page (PRD 9.2): 128 bits, lower-case hex, so two pages never share an origin.
    static func randomHost() -> String {
        // The system generator (arc4random) is a CSPRNG with no failure path, unlike SecRandomCopyBytes.
        var g = SystemRandomNumberGenerator()
        return "p" + (0..<2).map { _ in String(format: "%016llx", g.next() as UInt64) }.joined()
    }

    /// The WebKit build pages run on, the key of the self-test's inventory (PAGE-10).
    static var webKitBuild: String {
        Bundle(identifier: "com.apple.WebKit")?.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
    }
}
