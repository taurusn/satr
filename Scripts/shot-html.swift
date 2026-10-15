// Screenshots an HTML file with WebKit (the engine Linen uses), offscreen.
//   swiftc -O -o build/shot-html Scripts/shot-html.swift -framework AppKit -framework WebKit
//   build/shot-html <file.html> <out-prefix> [width] [selector]
// With a selector, writes one PNG per matching element (<out-prefix>-<n>.png); else one PNG of the full page.
import AppKit
import WebKit

let a = CommandLine.arguments
let file = URL(fileURLWithPath: a[1]), prefix = a[2]
let width = a.count > 3 ? Double(a[3])! : 1400
let selector = a.count > 4 ? a[4] : nil

@MainActor final class Shot: NSObject, WKNavigationDelegate {
    let web: WKWebView, win: NSWindow
    override init() {
        win = NSWindow(contentRect: NSRect(x: -40000, y: -40000, width: width, height: 1000), styleMask: [.borderless], backing: .buffered, defer: false)
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 1000))
        super.init()
        win.contentView = web
        web.navigationDelegate = self
        web.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            let h = (try? await web.evaluateJavaScript("document.documentElement.scrollHeight")) as? Double ?? 1000
            win.setContentSize(NSSize(width: width, height: h)); web.frame = NSRect(x: 0, y: 0, width: width, height: h)
            try? await Task.sleep(for: .milliseconds(600))
            var rects: [NSRect] = [NSRect(x: 0, y: 0, width: width, height: h)]
            if let selector {
                let js = "JSON.stringify([...document.querySelectorAll(\(String(reflecting: selector)))].map(e=>{const r=e.getBoundingClientRect();return [r.x+scrollX,r.y+scrollY,r.width,r.height]}))"
                let s = (try? await web.evaluateJavaScript(js)) as? String ?? "[]"
                rects = (try! JSONSerialization.jsonObject(with: Data(s.utf8)) as! [[Double]]).map { NSRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
            }
            for (i, r) in rects.enumerated() {
                let c = WKSnapshotConfiguration(); c.rect = r
                let img = try! await web.takeSnapshot(configuration: c)
                let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
                let out = selector == nil ? "\(prefix).png" : "\(prefix)-\(i + 1).png"
                try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
                print(out)
            }
            exit(0)
        }
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let shot = MainActor.assumeIsolated { Shot() }
app.run()
