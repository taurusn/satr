import AppKit
import PDFKit
import WebKit

/// Print and Save as PDF (EXP-1, spike S(e)): WebKit paginates to a PDF, then PDFKit stamps the running title and
/// page numbers (WebKit's print ignores CSS page margin boxes) and writes an outline from the headings; the
/// system print panel then prints it or saves it as a PDF.
@MainActor
enum Printer {
    static func print(web: WKWebView, window: NSWindow, title: String, headings: [[String: Any]]) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("linen-print-\(UUID().uuidString).pdf")
        let info = NSPrintInfo()
        info.paperSize = NSPrintInfo.shared.paperSize
        info.topMargin = 46; info.bottomMargin = 46; info.leftMargin = 44; info.rightMargin = 44
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = tmp
        let op = web.printOperation(with: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.view?.frame = web.bounds
        let ctx = PrintContext(tmp: tmp, title: title, headings: headings, window: window)
        PrintContext.live[ObjectIdentifier(ctx)] = ctx
        op.runModal(for: window, delegate: ctx, didRun: #selector(PrintContext.done(_:success:context:)), contextInfo: nil)
    }
}

@MainActor
final class PrintContext: NSObject {
    /// Each print in progress keeps its own context alive until its pass finishes.
    static var live: [ObjectIdentifier: PrintContext] = [:]
    let tmp: URL
    let title: String
    let headings: [[String: Any]]
    weak var window: NSWindow?

    init(tmp: URL, title: String, headings: [[String: Any]], window: NSWindow) {
        self.tmp = tmp
        self.title = title
        self.headings = headings
        self.window = window
    }

    /// AppKit calls this on the print operation's own thread; the work continues on the main thread.
    @objc nonisolated func done(_ op: NSPrintOperation, success: Bool, context: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.finish(success: success) } }
    }

    private func finish(success: Bool) {
        defer { PrintContext.live[ObjectIdentifier(self)] = nil }
        guard success, let pdf = PDFDocument(url: tmp), let window else { try? FileManager.default.removeItem(at: tmp); return }
        stamp(pdf)
        outline(pdf)
        pdf.documentAttributes = [PDFDocumentAttribute.titleAttribute: title, PDFDocumentAttribute.creatorAttribute: "Linen"]
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.jobDisposition = .spool
        guard let printOp = pdf.printOperation(for: info, scalingMode: .pageScaleNone, autoRotate: true) else { return }
        printOp.jobTitle = title
        printOp.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        try? FileManager.default.removeItem(at: tmp)
    }

    /// The running title at the top and the page number at the foot of every page.
    private func stamp(_ pdf: PDFDocument) {
        let ink = NSColor(srgbRed: 0x1F / 255, green: 0x33 / 255, blue: 0x28 / 255, alpha: 0.75)
        let font = NSFont(name: "thmanyahsans-Regular", size: 8.5) ?? .systemFont(ofSize: 8.5)
        for i in 0..<pdf.pageCount {
            guard let page = pdf.page(at: i) else { continue }
            let box = page.bounds(for: .mediaBox)
            let titleAnn = PDFAnnotation(bounds: NSRect(x: 44, y: box.height - 32, width: box.width - 88, height: 14), forType: .freeText, withProperties: nil)
            titleAnn.contents = title.uppercased()
            titleAnn.font = font
            titleAnn.fontColor = ink
            titleAnn.color = .clear
            titleAnn.border = PDFBorder()
            titleAnn.border?.lineWidth = 0
            titleAnn.alignment = .left
            if i > 0 { page.addAnnotation(titleAnn) }
            let num = PDFAnnotation(bounds: NSRect(x: 0, y: 18, width: box.width, height: 14), forType: .freeText, withProperties: nil)
            num.contents = "\(i + 1)"
            num.font = font
            num.fontColor = ink
            num.color = .clear
            num.border = PDFBorder()
            num.border?.lineWidth = 0
            num.alignment = .center
            page.addAnnotation(num)
        }
    }

    /// A PDF outline from the headings, each found on the first page that holds its text.
    private func outline(_ pdf: PDFDocument) {
        let root = PDFOutline()
        var stack: [(Int, PDFOutline)] = [(0, root)]
        var fromPage = 0
        for h in headings {
            guard let text = h["text"] as? String, let level = h["level"] as? Int, !text.isEmpty else { continue }
            var found: PDFPage?
            for i in fromPage..<pdf.pageCount {
                if let p = pdf.page(at: i), (p.string ?? "").contains(text) { found = p; fromPage = i; break }
            }
            guard let page = found else { continue }
            let item = PDFOutline()
            item.label = text
            item.destination = PDFDestination(page: page, at: NSPoint(x: 0, y: page.bounds(for: .mediaBox).height))
            while let last = stack.last, last.0 >= level, stack.count > 1 { stack.removeLast() }
            stack.last!.1.insertChild(item, at: stack.last!.1.numberOfChildren)
            stack.append((level, item))
        }
        if root.numberOfChildren > 0 { pdf.outlineRoot = root }
    }
}
