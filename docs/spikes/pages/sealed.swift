// Spike P(a): can a WKWebView run an HTML page's own scripts while nothing it does reaches the network or the disk?
//
// A witness HTTP server on 127.0.0.1 logs every request it receives. A test page served from linen-page:// tries
// every way a page can reach out (fetch, XHR, WebSocket, EventSource, beacon, images, CSS, fonts, prefetch,
// iframes, scripts, module imports, workers, media, forms, navigations, popups, file: URLs). Each probe runs under
// four seals: none (proves the witness sees traffic), a content rule list, a CSP response header, and both.
//
//   swiftc -O -o build/sealed docs/spikes/pages/sealed.swift -framework AppKit -framework WebKit
//   ./build/sealed <witness-port> <witness-log>
import AppKit
import WebKit

let args = CommandLine.arguments
let port = args.count >= 3 ? Int(args[1]) ?? 0 : 0
let logPath = args.count >= 3 ? args[2] : ""
let origin = "http://127.0.0.1:\(port)"

func page(_ seal: String) -> String {
    // Every probe names itself in the URL so the witness log says which one got out.
    let u = { (probe: String) in "\(origin)/\(seal)/\(probe)" }
    return """
    <!doctype html><html><head><meta charset="utf-8">
    <style>
      @font-face { font-family: X; src: url(\(u("css-font"))); }
      .bg { background-image: url(\(u("css-bg"))); font-family: X; }
      @import url(\(u("css-import")));
    </style>
    <link rel="stylesheet" href="\(u("link-css"))">
    <link rel="prefetch" href="\(u("prefetch"))">
    <link rel="preload" as="image" href="\(u("preload"))">
    <link rel="dns-prefetch" href="\(origin)">
    <link rel="preconnect" href="\(origin)">
    <link rel="icon" href="\(u("favicon"))">
    <script src="\(u("script-src"))"></script>
    </head><body>
    <div class="bg">probe</div>
    <img src="\(u("img"))">
    <img srcset="\(u("img-srcset")) 2x">
    <picture><source srcset="\(u("picture"))"><img></picture>
    <video src="\(u("video"))" preload="auto"></video>
    <audio src="\(u("audio"))" preload="auto"></audio>
    <object data="\(u("object"))"></object>
    <embed src="\(u("embed"))">
    <iframe src="\(u("iframe"))"></iframe>
    <iframe srcdoc="<img src='\(u("srcdoc-img"))'><script>fetch('\(u("srcdoc-fetch"))')</script>"></iframe>
    <svg><image href="\(u("svg-image"))"/></svg>
    <form id="f" action="\(u("form"))" method="post" target="sink"><input name="a" value="b"></form>
    <iframe name="sink"></iframe>
    <a id="ping" href="#x" ping="\(u("a-ping"))">ping</a>
    <script>
      const ok = [];
      const tryit = (name, f) => { try { f(); ok.push(name); } catch (e) { ok.push(name + ' threw ' + e.name); } };
      tryit('fetch', () => fetch('\(u("fetch"))').catch(() => {}));
      tryit('fetch-nocors', () => fetch('\(u("fetch-nocors"))', { mode: 'no-cors' }).catch(() => {}));
      tryit('xhr', () => { const x = new XMLHttpRequest(); x.open('GET', '\(u("xhr"))'); x.send(); });
      tryit('websocket', () => new WebSocket('ws://127.0.0.1:\(port)/\(seal)/websocket'));
      tryit('eventsource', () => new EventSource('\(u("eventsource"))'));
      tryit('beacon', () => navigator.sendBeacon('\(u("beacon"))', 'x'));
      tryit('image-js', () => { new Image().src = '\(u("image-js"))'; });
      tryit('import', () => import('\(u("import"))').catch(() => {}));
      tryit('worker-blob', () => new Worker(URL.createObjectURL(new Blob(["fetch('\(u("worker-fetch"))').catch(()=>{}); try { importScripts('\(u("worker-import"))') } catch(e) {}"], { type: 'text/javascript' }))));
      tryit('font-js', () => new FontFace('Y', 'url(\(u("font-js")))').load().catch(() => {}));
      tryit('css-js', () => { const s = document.createElement('style'); s.textContent = '.z{background:url(\(u("css-js")))}'; document.head.append(s); const d = document.createElement('div'); d.className = 'z'; document.body.append(d); });
      tryit('form', () => document.getElementById('f').submit());
      tryit('ping', () => document.getElementById('ping').click());
      tryit('open', () => window.open('\(u("window-open"))'));
      tryit('file-fetch', () => fetch('file:///etc/hosts').then(r => r.text()).then(t => fetch('\(u("file-leak"))?' + t.length)).catch(() => {}));
      tryit('file-img', () => { const i = new Image(); i.onload = () => fetch('\(u("file-img-loaded"))').catch(()=>{}); i.src = 'file:///System/Library/Desktop%20Pictures/.thumbnails/Sequoia.heic'; });
      tryit('storage', () => { localStorage.setItem('k', 'v'); });
      setTimeout(() => { tryit('navigate', () => { location.href = '\(u("navigate"))'; }); }, 1200);
      webkit.messageHandlers.probe.postMessage({ ran: ok });
    </script></body></html>
    """
}

final class PageScheme: NSObject, WKURLSchemeHandler {
    var csp: String?
    var seal = ""
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        var headers = ["Content-Type": "text/html; charset=utf-8"]
        if let csp { headers["Content-Security-Policy"] = csp }
        let data = Data(page(seal).utf8)
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

@MainActor
final class Run: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
    var navs: [String] = []
    var ran: [String] = []
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        let s = action.request.url?.absoluteString ?? "?"
        if action.request.url?.scheme == "linen-page" || s == "about:blank" || s == "about:srcdoc" { return .allow }
        navs.append((action.targetFrame?.isMainFrame ?? false ? "main " : "sub ") + s)
        return .cancel
    }
    func webView(_ webView: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        navs.append("popup " + (a.request.url?.absoluteString ?? "?")); return nil
    }
    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
        if let d = m.body as? [String: Any], let r = d["ran"] as? [String] { ran = r }
    }

    func seal(_ name: String, rules: WKContentRuleList?, csp: String?) async -> (navs: [String], ran: [String]) {
        navs = []; ran = []
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let scheme = PageScheme(); scheme.csp = csp; scheme.seal = name
        config.setURLSchemeHandler(scheme, forURLScheme: "linen-page")
        config.userContentController.add(self, name: "probe")
        if let rules { config.userContentController.add(rules) }
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        window.contentView = web
        window.orderFrontRegardless()
        web.load(URLRequest(url: URL(string: "linen-page://doc/\(name)/page.html")!))
        try? await Task.sleep(for: .seconds(4))
        window.orderOut(nil)
        config.userContentController.removeScriptMessageHandler(forName: "probe")
        return (navs, ran)
    }
}

// Block everything, then let linen-page: through. WebKit applies rules in order; ignore-previous-rules wins.
let rulesJSON = """
[{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
 {"trigger":{"url-filter":"^linen-page:"},"action":{"type":"ignore-previous-rules"}},
 {"trigger":{"url-filter":"^about:"},"action":{"type":"ignore-previous-rules"}},
 {"trigger":{"url-filter":"^blob:"},"action":{"type":"ignore-previous-rules"}},
 {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}}]
"""
// Scripts and styles inline (self-contained pages need them); nothing may leave linen-page:.
let cspHeader = "default-src 'none'; script-src linen-page: 'unsafe-inline' 'unsafe-eval' blob:; style-src linen-page: 'unsafe-inline'; img-src linen-page: data: blob:; font-src linen-page: data:; media-src linen-page: data: blob:; worker-src blob: linen-page:; connect-src 'none'; frame-src 'none'; child-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'; manifest-src 'none'"

func count(_ seal: String) -> [String] {
    let text = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
    return text.split(separator: "\n").compactMap { line in
        guard let r = line.range(of: "/\(seal)/") else { return nil }
        return String(line[r.upperBound...].prefix { $0 != " " && $0 != "?" && $0 != "\"" })
    }
}

if port == 0 { print("usage: sealed <port> <log>"); exit(2) }
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    let store = WKContentRuleListStore.default()!
    let rules = try! await store.compileContentRuleList(forIdentifier: "sealed-spike", encodedContentRuleList: rulesJSON)
    let run = Run()
    for (name, r, c) in [("none", nil, nil), ("rules", rules, nil), ("csp", nil, cspHeader), ("both", rules, cspHeader)] as [(String, WKContentRuleList?, String?)] {
        print("== start \(name) at \(String(format: "%.2f", Date().timeIntervalSince1970))")
        let res = await run.seal(name, rules: r, csp: c)
        try? await Task.sleep(for: .seconds(1))
        let hits = Array(Set(count(name))).sorted()
        print("== seal: \(name)")
        print("   page script ran: \(res.ran.isEmpty ? "NO" : "yes (\(res.ran.count) probes started)")")
        print("   witness hits (\(hits.count)): \(hits.joined(separator: ", "))")
        print("   navigations cancelled by the app (\(res.navs.count)): \(res.navs.joined(separator: " | "))")
    }
    exit(0)
}
app.run()
