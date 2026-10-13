// Spike S(d): renders every Markdown file under the given folders in Satr's current renderer, offscreen,
// and reports render time, script errors and Mermaid failures. Prints counts and file paths only, never content.
import AppKit
import WebKit

let res = URL(fileURLWithPath: CommandLine.arguments[1])          // folder with reader.html, reader.css, *.js
let roots = CommandLine.arguments.dropFirst(2).map { URL(fileURLWithPath: $0) }

func resource(_ n: String) -> String { (try? String(contentsOf: res.appendingPathComponent(n), encoding: .utf8)) ?? "" }
func safe(_ s: String) -> String { s.replacingOccurrences(of: "</script", with: "<\\/script", options: .caseInsensitive) }
let template: String = {
    var h = resource("reader.html")
    h = h.replacingOccurrences(of: "__SATR_STYLES__", with: resource("reader.css"))
    for (k, f) in [("__SATR_MARKED__", "marked.js"), ("__SATR_PURIFY__", "purify.min.js"), ("__SATR_MERMAID__", "mermaid.min.js"), ("__SATR_READER__", "reader.js")] {
        h = h.replacingOccurrences(of: k, with: safe(resource(f)))
    }
    return h
}()

var files: [URL] = []
for r in roots {
    let e = FileManager.default.enumerator(at: r, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    while let u = e?.nextObject() as? URL {
        if u.path.contains("/node_modules/") || u.path.contains("/.build/") || u.path.contains("/build/") { continue }
        if ["md", "markdown"].contains(u.pathExtension.lowercased()) { files.append(u) }
    }
}

final class Catcher: NSObject, WKScriptMessageHandler {
    var errors: [String] = []
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { errors.append("\(m.body)") }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let catcher = Catcher()
let config = WKWebViewConfiguration()
config.websiteDataStore = .nonPersistent()
config.userContentController.add(catcher, name: "spike")
config.userContentController.addUserScript(WKUserScript(source: """
  window.addEventListener('error', e => webkit.messageHandlers.spike.postMessage('error: ' + e.message));
  const ce = console.error; console.error = (...a) => { webkit.messageHandlers.spike.postMessage('console: ' + a.join(' ').slice(0, 160)); ce(...a); };
""", injectionTime: .atDocumentStart, forMainFrameOnly: true))
let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 980, height: 760), styleMask: [.borderless], backing: .buffered, defer: false)
let web = WKWebView(frame: window.contentView!.bounds, configuration: config)
window.contentView = web
window.orderBack(nil)

var results: [(String, Double, Int, String, Int)] = []
func run(_ i: Int) {
    guard i < files.count else { report(); return }
    let f = files[i]
    guard let md = try? String(contentsOf: f, encoding: .utf8) else { results.append((f.path, -1, 0, "unreadable", 0)); run(i + 1); return }
    catcher.errors = []
    let html = template
        .replacingOccurrences(of: "__SATR_MARKDOWN_B64__", with: Data(md.utf8).base64EncodedString())
        .replacingOccurrences(of: "__SATR_FILENAME_B64__", with: Data(f.lastPathComponent.utf8).base64EncodedString())
    var start = CFAbsoluteTimeGetCurrent()
    // Mark the old page, so a file with the same name as the last one is not mistaken for it.
    web.evaluateJavaScript("window.__spikeOld = true") { _, _ in
        start = CFAbsoluteTimeGetCurrent()
        web.loadHTMLString(html, baseURL: f.deletingLastPathComponent())
        poll()
    }
    func poll() {
        let expected = Data(f.lastPathComponent.utf8).base64EncodedString()
        // Only the new page counts: until the navigation commits, the old page still answers.
        web.evaluateJavaScript("(!window.__spikeOld && window.SATR_DOCUMENT && window.SATR_DOCUMENT.fileNameBase64 === '\(expected)' && document.body) ? (document.body.dataset.rendered || '') : ''") { v, _ in
            let state = (v as? String) ?? ""
            let t = (CFAbsoluteTimeGetCurrent() - start) * 1000
            if state.isEmpty && t < 15000 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { poll() }; return }
            web.evaluateJavaScript("document.querySelectorAll('.mermaid-error').length") { m, _ in
                results.append((f.path, t, catcher.errors.count, state.isEmpty ? "timeout" : state, (m as? Int) ?? 0))
                if !catcher.errors.isEmpty { FileHandle.standardError.write(Data("\(f.path): \(catcher.errors.prefix(2))\n".utf8)) }
                run(i + 1)
            }
        }
    }
}

func report() {
    let ok = results.filter { $0.3 == "true" && $0.2 == 0 }
    let times = results.map(\.1).filter { $0 >= 0 }.sorted()
    func pct(_ p: Double) -> Double { times.isEmpty ? 0 : times[min(times.count - 1, Int(Double(times.count) * p))] }
    print("files \(results.count)  clean \(ok.count)  errorState \(results.filter { $0.3 == "error" }.count)  timeouts \(results.filter { $0.3 == "timeout" }.count)  withScriptErrors \(results.filter { $0.2 > 0 }.count)  mermaidFailures \(results.reduce(0) { $0 + $1.4 })")
    print(String(format: "render ms  p50 %.0f  p90 %.0f  p99 %.0f  max %.0f", pct(0.5), pct(0.9), pct(0.99), times.last ?? 0))
    for r in results.sorted(by: { $0.1 > $1.1 }).prefix(6) { print(String(format: "  slow %.0f ms  %@", r.1, r.0)) }
    for r in results where r.3 != "true" || r.4 > 0 { print("  problem \(r.3) mermaid=\(r.4)  \(r.0)") }
    exit(0)
}

DispatchQueue.main.async { run(0) }
app.run()
