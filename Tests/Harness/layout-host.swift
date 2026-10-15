// Linen's layout host (spike B(b), PRD-2 BRD-17 and CLI-3): loads Renderer/page.html offscreen with the real
// Thmanyah faces, runs `LinenLayout.run` on a board file and reports timings and any text that does not fit.
//
//   layout-host <file.canvas> [--runs 5] [--out <file>] [--write] [--layered 176]
//
//   --runs N       cold runs (the measure cache is cleared before each); the first run's result is the one written
//   --out FILE     write the laid-out text there; --write writes it over the input (atomically)
//   --layered N    also time a generated layered board of N nodes through the ELK worker
//
// Build: swiftc -swift-version 5 -O -o build/layout-host Tests/Harness/layout-host.swift -framework AppKit -framework WebKit
import AppKit
import UniformTypeIdentifiers
import WebKit

let args = Array(CommandLine.arguments.dropFirst())
let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let rendererDir = repo.appendingPathComponent("Renderer")
let fontsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Fonts")

func value(_ name: String) -> String? {
    if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
    return nil
}

/// Serves Renderer/ as linen-app://renderer/, and fonts/ from ~/Library/Fonts, the way Scripts/copy-renderer.sh
/// places them in the app.
final class AppScheme: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let rel = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        let file: URL
        if rel.hasPrefix("fonts/") && rel.hasSuffix(".otf") && !rel.contains("..") {
            file = fontsDir.appendingPathComponent(String(rel.dropFirst(6)))
        } else {
            file = rendererDir.appendingPathComponent(rel).standardizedFileURL
            guard file.path.hasPrefix(rendererDir.standardizedFileURL.path) else { task.didFailWithError(URLError(.noPermissionsToReadFile)); return }
        }
        guard let data = try? Data(contentsOf: file) else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)"])!)
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

@MainActor
final class Host: NSObject, WKScriptMessageHandler {
    let web: WKWebView
    let window: NSWindow
    var ready = false
    var errors: [String] = []

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(AppScheme(), forURLScheme: "linen-app")
        window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1176, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1176, height: 900), configuration: config)
        super.init()
        config.userContentController.add(self, name: "linen")
        config.userContentController.add(self, name: "console")
        config.userContentController.addUserScript(WKUserScript(source: """
          window.addEventListener('error', e => webkit.messageHandlers.console.postMessage('error: ' + e.message + ' @' + (e.filename||'') + ':' + (e.lineno||'')));
          window.addEventListener('securitypolicyviolation', e => webkit.messageHandlers.console.postMessage('csp: ' + e.violatedDirective + ' ' + e.blockedURI));
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        window.contentView = web
        window.orderBack(nil)
    }

    nonisolated func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        let name = m.name, body = m.body
        MainActor.assumeIsolated {
            if name == "console" { errors.append("\(body)"); return }
            if let msg = body as? [String: Any], msg["type"] as? String == "ready" { ready = true }
            if let msg = body as? [String: Any], msg["type"] as? String == "error" { errors.append("page: \(msg["message"] ?? "")") }
        }
    }

    func open() async {
        web.load(URLRequest(url: URL(string: "linen-app://renderer/page.html")!))
        let start = Date()
        while !ready && Date().timeIntervalSince(start) < 20 { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    func js(_ code: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        try await web.callAsyncJavaScript(code, arguments: arguments, contentWorld: .page)
    }
}

func pct(_ xs: [Double], _ p: Double) -> Double {
    let s = xs.sorted()
    guard !s.isEmpty else { return 0 }
    return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
}

@MainActor
func main() async {
    guard let path = args.first, !path.hasPrefix("--") else {
        print("usage: layout-host <file.canvas> [--runs 5] [--out <file>] [--write] [--layered 176]")
        exit(2)
    }
    let file = URL(fileURLWithPath: path)
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { print("cannot read \(path)"); exit(2) }
    let sidecar = try? String(contentsOf: URL(fileURLWithPath: path + ".notes.json"), encoding: .utf8)
    let runs = Int(value("--runs") ?? "5") ?? 5

    let host = Host()
    await host.open()
    if !host.ready { print("page did not become ready; errors: \(host.errors)"); exit(3) }
    print("page ready")

    // The real faces, loaded before anything is measured.
    let fonts = (try? await host.js("""
      const want = ['400 15px "Linen Sans"', '500 15px "Linen Sans"', '300 19px "Linen Serif Display"', '300 24px "Linen Serif Display"'];
      const got = [];
      for (const f of want) { const faces = await document.fonts.load(f); got.push(f + ': ' + faces.map((x) => x.status).join(',')); }
      await document.fonts.ready;
      return got;
    """)) as? [String] ?? []
    print("fonts: " + fonts.joined(separator: " | "))
    if fonts.contains(where: { !$0.contains("loaded") }) { print("A Thmanyah face did not load; measurements would be wrong."); exit(3) }

    var times: [Double] = [], totals: [Double] = []
    var first: [String: Any] = [:]
    for i in 0..<runs {
        do {
            let r = try await host.js("""
              LinenLayout.clearCache();
              const t = performance.now();
              const r = await LinenLayout.run(text, { sidecarText: sidecar });
              r.wall = performance.now() - t;
              return r;
            """, ["text": text, "sidecar": sidecar ?? NSNull()]) as? [String: Any] ?? [:]
            if i == 0 { first = r }
            times.append((r["ms"] as? Double) ?? Double(r["ms"] as? Int ?? 0))
            totals.append((r["wall"] as? Double) ?? 0)
        } catch {
            print("run \(i + 1) failed: \(error)")
            exit(3)
        }
    }
    let out = first["text"] as? String ?? text
    let overflow = first["overflow"] as? [String] ?? []
    let stats = first["stats"] as? [String: Any] ?? [:]
    print(String(format: "layout: p50 %.0f ms, max %.0f ms (layout only); whole run p50 %.0f ms, max %.0f ms; %d runs, cold cache",
                 pct(times, 0.5), times.max() ?? 0, pct(totals, 0.5), totals.max() ?? 0, runs))
    print("measured \(stats["measured"] ?? "?") items, \(stats["sections"] ?? "?") sections laid out; changed \(first["changed"] ?? "?") nodes; normalised \(first["normalised"] ?? "?"); moved sections \(first["moved"] ?? [])")
    print("measured with: \(first["measuredWith"] ?? "?")")
    print("overflow: \(overflow.count)" + (overflow.isEmpty ? "" : " " + overflow.joined(separator: ", ")))
    if let problems = first["problems"] as? [[String: Any]], !problems.isEmpty {
        print("problems: " + problems.map { "\($0["id"] ?? ""): \($0["message"] ?? "")" }.joined(separator: "; "))
    }

    // A second run over the written text must change nothing.
    do {
        let r2 = try await host.js("return await LinenLayout.run(text, { sidecarText: sidecar });", ["text": out, "sidecar": sidecar ?? NSNull()]) as? [String: Any] ?? [:]
        let same = (r2["text"] as? String) == out
        print("second run: changed \(r2["changed"] ?? "?"), text identical \(same)")
    } catch { print("second run failed: \(error)") }

    if args.contains("--probe-worker") {
        let r = try? await host.js("""
          const w = new Worker(new URL('layout-worker.js', location.href));
          return await new Promise((res) => {
            const t = setTimeout(() => res('timeout after 8 s'), 8000);
            w.onerror = (e) => { clearTimeout(t); res('error: ' + e.message + ' ' + (e.filename || '') + ':' + (e.lineno || '')); };
            w.onmessage = (e) => { clearTimeout(t); res(JSON.stringify(e.data).slice(0, 300)); };
            w.postMessage({ id: 1, graph: { id: 'r', children: [{ id: 'a', width: 10, height: 10 }, { id: 'b', width: 10, height: 10 }], edges: [{ id: 'e', sources: ['a'], targets: ['b'] }] } });
          });
        """)
        print("worker probe: \(r.map { "\($0 ?? "nil")" } ?? "call failed")")
    }

    if let n = value("--layered").flatMap(Int.init) {
        let r = (try? await host.js("""
          const nodes = [{ id: 's', type: 'group', label: 'Flow', x: 0, y: 0, width: 2000, height: 1200, linen: { layout: 'layered', title: 'A layered section' } }];
          const edges = [];
          for (let i = 0; i < n; i++) nodes.push({ id: 'n' + i, type: 'text', text: '## Step ' + i + '\\n\\nA short line of body text for step ' + i + '.', x: 20 + (i % 20) * 90, y: 80 + Math.floor(i / 20) * 110, width: 220, height: 80 });
          for (let i = 1; i < n; i++) edges.push({ id: 'e' + i, fromNode: 'n' + Math.floor((i - 1) / 2), toNode: 'n' + i });
          const out = [];
          for (let k = 0; k < 3; k++) {
            const t = performance.now();
            const r = await LinenLayout.layout({ nodes, edges }, {});
            out.push({ ms: performance.now() - t, elk: r.stats.elkMs, placed: Object.keys(r.positions).length, routes: Object.keys(r.routes).length, problems: r.problems.length });
          }
          return out;
        """, ["n": n])) as? [[String: Any]] ?? []
        for (k, x) in r.enumerated() {
            print(String(format: "layered %d nodes via the worker, run %d: %.0f ms (ELK %.0f ms), %@ placed, %@ routes, %@ problems",
                         n, k + 1, x["ms"] as? Double ?? 0, x["elk"] as? Double ?? 0, "\(x["placed"] ?? "?")", "\(x["routes"] ?? "?")", "\(x["problems"] ?? "?")"))
        }
    }

    if !host.errors.isEmpty { print("page errors: \(host.errors.prefix(5))") }

    let dest: URL? = args.contains("--write") ? file : value("--out").map { URL(fileURLWithPath: $0) }
    if let dest, out != text || dest != file {
        let tmp = dest.deletingLastPathComponent().appendingPathComponent(".\(dest.lastPathComponent).linen-tmp")
        do {
            try Data(out.utf8).write(to: tmp)
            _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)
            print("wrote \(dest.path)")
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            if !FileManager.default.fileExists(atPath: dest.path), (try? Data(out.utf8).write(to: dest, options: .atomic)) != nil { print("wrote \(dest.path)") }
            else { print("could not write \(dest.path): \(error)") }
        }
    }
    exit(overflow.isEmpty ? 0 : 1)
}

setvbuf(stdout, nil, _IOLBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in await main() }
app.run()
