// Spike B(a) host: shows board.html in an on-screen WKWebView (animation frames are throttled offscreen),
// runs its scripted pan and zoom, prints the frame report, exits. Does not take focus.
//   swiftc -O -o build/board-bench docs/spikes/boards/bench.swift -framework AppKit -framework WebKit
//   ./build/board-bench <n> [cull 1|0] [width] [height]
import AppKit
import WebKit

let a = CommandLine.arguments
let n = a.count > 1 ? a[1] : "500", cull = a.count > 2 ? a[2] : "1", ver = a.count > 5 ? a[5] : "1"
let w = a.count > 3 ? Double(a[3])! : 1176, h = a.count > 4 ? Double(a[4])! : 687
let page = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("board.html")

final class Sink: NSObject, WKScriptMessageHandler {
    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
        if let d = try? JSONSerialization.data(withJSONObject: m.body, options: [.sortedKeys]) { print(String(decoding: d, as: UTF8.self)) }
        exit(0)
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let sink = Sink()
let config = WKWebViewConfiguration()
config.userContentController.add(sink, name: "spike")
let screen = NSScreen.main!.visibleFrame
let win = NSWindow(contentRect: NSRect(x: screen.maxX - w, y: screen.minY, width: w, height: h), styleMask: [.titled], backing: .buffered, defer: false)
win.title = "Linen spike: board frames (closes itself)"
let web = WKWebView(frame: NSRect(x: 0, y: 0, width: w, height: h), configuration: config)
win.contentView = web
win.orderFrontRegardless()
var comps = URLComponents(string: "http://127.0.0.1:48720/board.html")!  // served by serve.py
comps.queryItems = [.init(name: "n", value: n), .init(name: "cull", value: cull), .init(name: "bench", value: "1"), .init(name: "v", value: ver)]
web.load(URLRequest(url: comps.url!))
DispatchQueue.main.asyncAfter(deadline: .now() + 60) { print("{\"error\":\"timeout\"}"); exit(1) }
app.run()
