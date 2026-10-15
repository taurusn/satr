// Spike P(b): what escapes the P(a) seal (rule list + CSP header + navigation gate), and what closes it.
//
// The research lane's leak test found WebRTC STUN packets leaving a sealed page; P(a) never probed UDP or name
// lookups. This page tries WebRTC (STUN, TURN over TCP, a .local STUN host) from the page and from every kind of
// frame a page can make (about:blank, document.open, srcdoc, sandboxed srcdoc, nested srcdoc, data:, blob:),
// WebTransport (on its own port, base + 5 + seal), and lookups of .local names from images, prefetch hints, fetch and WebSocket. It also reports what
// still works for a kit page (fonts from the page scheme, WebAssembly, script speed).
//
//   swiftc -O -o build/webrtc docs/spikes/pages/webrtc.swift -framework AppKit -framework WebKit
//   python3 -I docs/spikes/pages/witness2.py <http-port> <lan-ip> <udp-base> <log> &
//   ./build/webrtc <http-port> <lan-ip> <udp-base> <log> <font.ttf>
import AppKit
import WebKit

let args = CommandLine.arguments
if args.count < 6 { print("usage: webrtc <http-port> <lan-ip> <udp-base> <log> <font.ttf>"); exit(2) }
let udpBase = Int(args[3]) ?? 0
let lan = args[2], logPath = args[4]
let font = FileManager.default.contents(atPath: args[5]) ?? Data()

struct Seal {
    let name: String
    let rules: Bool, csp: Bool, killScript: Bool, lockdown: Bool, gateAllowsDataBlob: Bool
}
let seals = [
    Seal(name: "none", rules: false, csp: false, killScript: false, lockdown: false, gateAllowsDataBlob: false),
    Seal(name: "sealed", rules: true, csp: true, killScript: false, lockdown: false, gateAllowsDataBlob: false),
    Seal(name: "script", rules: true, csp: true, killScript: true, lockdown: false, gateAllowsDataBlob: false),
    Seal(name: "lockdown", rules: true, csp: true, killScript: false, lockdown: true, gateAllowsDataBlob: false),
    Seal(name: "gateopen", rules: true, csp: false, killScript: true, lockdown: false, gateAllowsDataBlob: true),
]

func page(_ seal: String, _ index: Int) -> String {
    let port = udpBase + index
    let host = { (probe: String) in "linenprobe-\(seal)-\(probe).local" }
    return """
    <!doctype html><html><head><meta charset="utf-8">
    <style>
      @font-face { font-family: KC; src: url(linen-page://doc/font.ttf); }
      .kc { font: 40px KC, monospace; } .mono { font: 40px monospace; }
    </style>
    <link rel="dns-prefetch" href="//\(host("dnsprefetch"))">
    <link rel="preconnect" href="http://\(host("preconnect"))">
    <link rel="prefetch" href="http://\(host("prefetch"))/x">
    </head><body>
    <span class="kc" id="kc">Linen kit</span> <span class="mono" id="mono">Linen kit</span>
    <img src="http://\(host("img"))/x">
    <script>
    const R = [];
    const note = (k, v) => R.push(k + ': ' + v);
    const stun = 'stun:\(lan):\(port)';
    const ice = [{urls: stun}, {urls: 'stun:\(host("stun")):\(port)'}, {urls: 'turn:\(lan):\(port)?transport=tcp', username: 'u', credential: 'p'}];
    window.addEventListener('message', e => { const [k, v] = String(e.data).split('|'); note(k, v); });
    function rtc(C, tag) {
      try {
        const pc = new C({iceServers: ice}); pc.createDataChannel('x');
        pc.createOffer().then(o => pc.setLocalDescription(o)).catch(e => note(tag, 'offer failed ' + e.name));
        window['_pc_' + tag] = pc; note(tag, 'made');
      } catch (e) { note(tag, 'threw ' + e.name); }
    }
    note('typeof RTCPeerConnection', typeof RTCPeerConnection);
    note('typeof webkitRTCPeerConnection', typeof webkitRTCPeerConnection);
    note('typeof WebTransport', typeof WebTransport);
    note('typeof WebAssembly', typeof WebAssembly);
    note('typeof WebGLRenderingContext', typeof WebGLRenderingContext);
    note('typeof navigator.serviceWorker', typeof navigator.serviceWorker);
    rtc(window.RTCPeerConnection, 'rtc-page');
    const f1 = document.createElement('iframe'); document.body.append(f1);
    rtc(f1.contentWindow.RTCPeerConnection, 'rtc-blank-iframe');
    const f2 = document.createElement('iframe'); document.body.append(f2);
    try { const d = f2.contentDocument; d.open(); d.write('<script>parent._docR = window.RTCPeerConnection<\\/script>'); d.close(); } catch (e) { note('docwrite', 'threw ' + e.name); }
    rtc(window._docR, 'rtc-docwrite-iframe');
    const inner = tag => `<script>try{const pc=new RTCPeerConnection({iceServers:[{urls:'${stun}'}]});pc.createDataChannel('x');pc.createOffer().then(o=>pc.setLocalDescription(o));top.postMessage('${tag}|made','*')}catch(e){top.postMessage('${tag}|threw '+e.name,'*')}<\\/script>`;
    const frame = (attrs, set) => { const f = document.createElement('iframe'); for (const k in attrs) f.setAttribute(k, attrs[k]); set(f); document.body.append(f); };
    frame({}, f => f.srcdoc = inner('rtc-srcdoc'));
    frame({sandbox: 'allow-scripts'}, f => f.srcdoc = inner('rtc-sandboxed-srcdoc'));
    frame({}, f => f.srcdoc = '<iframe srcdoc="' + inner('rtc-nested-srcdoc').replace(/"/g, '&quot;') + '"></iframe>');
    frame({}, f => f.src = 'data:text/html,' + encodeURIComponent(inner('rtc-data-iframe')));
    frame({}, f => f.src = URL.createObjectURL(new Blob([inner('rtc-blob-iframe')], {type: 'text/html'})));
    if (typeof WebTransport === 'function') {
      try { const wt = new WebTransport('https://\(lan):\(port + 5)/'); wt.ready.catch(e => note('webtransport', 'rejected ' + e.name)); note('webtransport', 'made'); }
      catch (e) { note('webtransport', 'threw ' + e.name); }
    }
    fetch('http://\(host("fetch"))/x').catch(() => {});
    try { new WebSocket('ws://\(host("ws"))/x'); } catch (e) {}
    const ff = new FontFace('K', 'url(linen-page://doc/font.ttf)');
    ff.load().then(() => { document.fonts.add(ff); const c = document.createElement('canvas').getContext('2d');
      c.font = '40px K, monospace'; const a = c.measureText('Linen kit').width; c.font = '40px monospace'; const b = c.measureText('Linen kit').width;
      note('font-js', 'loaded, ' + a.toFixed(0) + ' px vs ' + b.toFixed(0) + ' px fallback'); }).catch(e => note('font-js', 'failed ' + e.name));
    document.fonts.ready.then(() => note('font-css', document.getElementById('kc').offsetWidth + ' px vs ' + document.getElementById('mono').offsetWidth + ' px fallback'));
    let t = performance.now(), s = 0; for (let i = 0; i < 3e7; i++) s += i % 7; note('loop 30M', (performance.now() - t).toFixed(0) + ' ms');
    setTimeout(() => webkit.messageHandlers.probe.postMessage(R), 4000);
    </script></body></html>
    """
}

final class PageScheme: NSObject, WKURLSchemeHandler {
    var csp: String?
    var seal = "", index = 0
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let isFont = url.path.hasSuffix(".ttf")
        var headers = ["Content-Type": isFont ? "font/ttf" : "text/html; charset=utf-8"]
        if let csp, !isFont { headers["Content-Security-Policy"] = csp }
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
        task.didReceive(isFont ? font : Data(page(seal, index).utf8))
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

@MainActor
final class Run: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
    var navs: [String] = []
    var notes: [String] = []
    var allowDataBlob = false
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        let s = action.request.url?.absoluteString ?? "?"
        let scheme = action.request.url?.scheme ?? ""
        if scheme == "linen-page" || s == "about:blank" || s == "about:srcdoc" { return .allow }
        if allowDataBlob && (scheme == "data" || scheme == "blob") { return .allow }
        navs.append((action.targetFrame?.isMainFrame ?? false ? "main " : "sub ") + String(s.prefix(40)))
        return .cancel
    }
    func webView(_ webView: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        navs.append("popup"); return nil
    }
    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
        notes = (m.body as? [String]) ?? []
    }

    func run(_ seal: Seal, _ index: Int, rules: WKContentRuleList) async {
        navs = []; notes = []; allowDataBlob = seal.gateAllowsDataBlob
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let scheme = PageScheme(); scheme.csp = seal.csp ? cspHeader : nil; scheme.seal = seal.name; scheme.index = index
        config.setURLSchemeHandler(scheme, forURLScheme: "linen-page")
        config.userContentController.add(self, name: "probe")
        if seal.rules { config.userContentController.add(rules) }
        if seal.killScript { config.userContentController.addUserScript(WKUserScript(source: killRTC, injectionTime: .atDocumentStart, forMainFrameOnly: false)) }
        if seal.lockdown { config.defaultWebpagePreferences.isLockdownModeEnabled = true }
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        window.contentView = web
        window.orderFrontRegardless()
        web.load(URLRequest(url: URL(string: "linen-page://doc/\(seal.name)/page.html")!))
        try? await Task.sleep(for: .seconds(9))
        web.loadHTMLString("", baseURL: nil)  // tear the page down so its peer connections close
        try? await Task.sleep(for: .seconds(1))
        window.orderOut(nil)
        config.userContentController.removeScriptMessageHandler(forName: "probe")
    }
}

// Removes every WebRTC and WebTransport constructor before any page script runs, in every frame.
let killRTC = """
(() => { for (const n of ['RTCPeerConnection','webkitRTCPeerConnection','RTCDataChannel','RTCSessionDescription','RTCIceCandidate','RTCRtpTransceiver','RTCRtpSender','RTCRtpReceiver','RTCDtlsTransport','RTCIceTransport','RTCSctpTransport','RTCCertificate','RTCPeerConnectionIceEvent','RTCDataChannelEvent','RTCTrackEvent','WebTransport']) {
  try { delete window[n]; Object.defineProperty(window, n, {value: undefined, configurable: false, writable: false}); } catch (e) {} } })();
"""
let rulesJSON = """
[{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
 {"trigger":{"url-filter":"^linen-page:"},"action":{"type":"ignore-previous-rules"}},
 {"trigger":{"url-filter":"^about:"},"action":{"type":"ignore-previous-rules"}},
 {"trigger":{"url-filter":"^blob:"},"action":{"type":"ignore-previous-rules"}},
 {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}}]
"""
let cspHeader = "default-src 'none'; script-src linen-page: 'unsafe-inline' 'unsafe-eval' blob:; style-src linen-page: 'unsafe-inline'; img-src linen-page: data: blob:; font-src linen-page: data:; media-src linen-page: data: blob:; worker-src blob: linen-page:; connect-src 'none'; frame-src 'none'; child-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'; manifest-src 'none'"

func hits(_ seal: Seal, _ index: Int) -> [String] {
    let text = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
    var out = Set<String>()
    for line in text.split(separator: "\n") {
        if line.contains(" seal=\(index) ") { out.insert(line.contains(" UDP ") ? "UDP to its STUN port" : "TCP to its TURN port") }
        if line.contains(" seal=\(index + 5) ") { out.insert((line.contains(" UDP ") ? "UDP" : "TCP") + " to its WebTransport port") }
        if line.contains("linenprobe-\(seal.name)-"), let r = line.range(of: "linenprobe-\(seal.name)-") {
            out.insert("lookup " + line[r.upperBound...].prefix { $0 != "." && $0 != " " })
        }
        if line.contains("HTTP ") && line.contains("/\(seal.name)/") { out.insert("HTTP " + line.split(separator: " ").suffix(1).joined()) }
    }
    return out.sorted()
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    let rules = try! await WKContentRuleListStore.default()!.compileContentRuleList(forIdentifier: "webrtc-spike", encodedContentRuleList: rulesJSON)!
    let run = Run()
    for (i, seal) in seals.enumerated() {
        await run.run(seal, i, rules: rules)
        try? await Task.sleep(for: .seconds(2))
        print("== \(seal.name)  [rules \(seal.rules), csp \(seal.csp), kill script \(seal.killScript), lockdown \(seal.lockdown), gate lets data:/blob: frames \(seal.gateAllowsDataBlob)]")
        print("   page: " + (run.notes.isEmpty ? "NO REPORT" : run.notes.joined(separator: " ; ")))
        print("   navigations cancelled: \(run.navs.count) " + run.navs.joined(separator: " | "))
        let h = hits(seal, i)
        print("   witness (\(h.count)): " + h.joined(separator: ", "))
    }
    exit(0)
}
app.run()
