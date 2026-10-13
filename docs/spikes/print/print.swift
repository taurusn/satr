// Spike S(e): prints a long page through WKWebView's print operation to a PDF and reports what came out:
// page count, whether CSS page margin boxes drew page numbers, whether headings became a PDF outline.
import AppKit
import PDFKit
import WebKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let face = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "-apple-system"
let mode = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "print"
var body = "<h1>Print spike</h1>"
for i in 1...12 { body += "<h2>Section \(i)</h2>" + String(repeating: "<p>Linen prints a long page so we can see page breaks, margins and numbers. سطر يطبع الصفحة.</p>", count: 8) }
let html = """
<!doctype html><meta charset="utf-8"><style>
@page { size: A4; margin: 20mm 18mm; @bottom-center { content: "MARGINBOX " counter(page); } }
@font-face { font-family: "LinenSans"; src: url("file:///Users/hatim/Library/Fonts/thmanyahsans-Regular.otf"); }
body { font: 12pt \(face); color: #1F3328; } h2 { break-after: avoid; }
</style>\(body)
"""
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let win = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 1000), styleMask: [.borderless], backing: .buffered, defer: false)
let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 1000))
win.contentView = web
win.orderBack(nil)
final class D: NSObject, WKNavigationDelegate {
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if mode == "pdf" {
                w.createPDF { r in
                    if case .success(let data) = r { try? data.write(to: out) }
                    self.report(true)
                }
                return
            }
            let info = NSPrintInfo()
            info.paperSize = NSSize(width: 595, height: 842)
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = out
            info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
            let op = w.printOperation(with: info)
            op.showsPrintPanel = false
            op.showsProgressPanel = false
            op.view?.frame = w.bounds
            op.runModal(for: win, delegate: self, didRun: #selector(self.done(_:success:context:)), contextInfo: nil)
        }
    }
    @objc func done(_ op: NSPrintOperation, success: Bool, context: UnsafeMutableRawPointer?) { report(success) }
    func report(_ success: Bool) {
        guard let pdf = PDFDocument(url: out) else { print("no PDF written, success=\(success)"); exit(1) }
        let text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
        print("success \(success)  pages \(pdf.pageCount)")
        print("margin box text present: \(text.contains("MARGINBOX"))")
        print("PDF outline present: \(pdf.outlineRoot != nil && (pdf.outlineRoot?.numberOfChildren ?? 0) > 0)")
        print("Arabic text extractable: \(text.contains("سطر"))  phrase intact: \(text.contains("يطبع الصفحة"))")
        exit(0)
    }
}
let d = D()
web.navigationDelegate = d
web.loadHTMLString(html, baseURL: URL(fileURLWithPath: "/Users/hatim/Library/Fonts/"))
app.run()
