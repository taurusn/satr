import AppKit
import UniformTypeIdentifiers
import WebKit

final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    let documentURL: URL

    private let webView: WKWebView
    private let renderer: MarkdownRenderer
    private let localFileHandler: LocalFileSchemeHandler
    private let onClose: () -> Void
    private var filePresenter: MarkdownFilePresenter?
    private var zoomLevel: CGFloat = 1
    private var reloadWorkItem: DispatchWorkItem?

    init(documentURL: URL, onClose: @escaping () -> Void) throws {
        self.documentURL = documentURL
        self.onClose = onClose
        renderer = try MarkdownRenderer()
        localFileHandler = LocalFileSchemeHandler(rootURL: documentURL.deletingLastPathComponent())

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(localFileHandler, forURLScheme: "satr-local")

        webView = WKWebView(frame: .zero, configuration: configuration)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        super.init(window: window)

        webView.navigationDelegate = self
        webView.allowsMagnification = true
        webView.underPageBackgroundColor = .windowBackgroundColor
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        configuration.userContentController.add(self, name: "satr")

        window.contentView = webView
        window.delegate = self
        window.title = documentURL.lastPathComponent
        window.representedURL = documentURL
        window.titleVisibility = .visible
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 560, height: 420)
        window.center()

        let toolbar = NSToolbar(identifier: "SatrDocumentToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        let presenter = MarkdownFilePresenter(url: documentURL) { [weak self] in
            self?.scheduleReload()
        }
        filePresenter = presenter
        NSFileCoordinator.addFilePresenter(presenter)

        try loadDocument()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let filePresenter {
            NSFileCoordinator.removeFilePresenter(filePresenter)
        }
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "satr")
    }

    @objc func openAnotherDocument(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.openDocumentAction(sender)
    }

    @objc func reloadDocument(_ sender: Any?) {
        do {
            try loadDocument()
        } catch {
            showReadError(error)
        }
    }

    @objc func revealInFinder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([documentURL])
    }

    @objc func increaseTextSize(_ sender: Any?) {
        zoomLevel = min(1.8, zoomLevel + 0.1)
        webView.pageZoom = zoomLevel
    }

    @objc func decreaseTextSize(_ sender: Any?) {
        zoomLevel = max(0.7, zoomLevel - 0.1)
        webView.pageZoom = zoomLevel
    }

    @objc func resetTextSize(_ sender: Any?) {
        zoomLevel = 1
        webView.pageZoom = zoomLevel
    }

    func windowWillClose(_ notification: Notification) {
        reloadWorkItem?.cancel()
        if let filePresenter {
            NSFileCoordinator.removeFilePresenter(filePresenter)
            self.filePresenter = nil
        }
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "satr")
        onClose()
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.openDocument, .reloadDocument, .revealDocument, .smallerText, .largerText, .flexibleSpace, .space]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.openDocument, .flexibleSpace, .reloadDocument, .revealDocument, .space, .smallerText, .largerText]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .openDocument:
            return toolbarItem(itemIdentifier, label: "Open", symbol: "folder", action: #selector(openAnotherDocument(_:)))
        case .reloadDocument:
            return toolbarItem(itemIdentifier, label: "Reload", symbol: "arrow.clockwise", action: #selector(reloadDocument(_:)))
        case .revealDocument:
            return toolbarItem(itemIdentifier, label: "Reveal in Finder", symbol: "magnifyingglass", action: #selector(revealInFinder(_:)))
        case .smallerText:
            return toolbarItem(itemIdentifier, label: "Smaller Text", symbol: "textformat.size.smaller", action: #selector(decreaseTextSize(_:)))
        case .largerText:
            return toolbarItem(itemIdentifier, label: "Larger Text", symbol: "textformat.size.larger", action: #selector(increaseTextSize(_:)))
        default:
            return nil
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        if url.scheme == "satr-wiki" {
            openWikiLink(url)
        } else if url.isFileURL, Self.isMarkdown(url) {
            (NSApp.delegate as? AppDelegate)?.openDocument(url)
        } else if url.scheme == "http" || url.scheme == "https" || url.scheme == "mailto" {
            NSWorkspace.shared.open(url)
        } else if url.isFileURL {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "satr", let payload = message.body as? [String: Any] else { return }
        if let title = payload["title"] as? String, !title.isEmpty {
            window?.subtitle = title == documentURL.deletingPathExtension().lastPathComponent ? "" : title
        }
        if let errors = payload["mermaidErrors"] as? Int, errors > 0 {
            window?.subtitle = "\(errors) diagram\(errors == 1 ? "" : "s") could not render"
        }
    }

    private func loadDocument() throws {
        var encoding = String.Encoding.utf8
        let markdown = try String(contentsOf: documentURL, usedEncoding: &encoding)
        let html = try renderer.render(markdown: markdown, fileName: documentURL.lastPathComponent)
        webView.loadHTMLString(html, baseURL: documentURL.deletingLastPathComponent())
    }

    private func scheduleReload() {
        reloadWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.reloadDocument(nil) }
        reloadWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: item)
    }

    private func toolbarItem(_ identifier: NSToolbarItem.Identifier, label: String, symbol: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = self
        item.action = action
        return item
    }

    private func showReadError(_ error: Error) {
        let message = error.localizedDescription
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        webView.loadHTMLString("""
        <!doctype html><meta charset="utf-8"><style>body{font:15px -apple-system;padding:48px;color:#242723;background:#f4f5f2}h1{font-size:22px}p{line-height:1.6;color:#666}</style><h1>This document could not be read</h1><p>\(message)</p>
        """, baseURL: nil)
    }

    private func openWikiLink(_ url: URL) {
        let rawTarget = String(url.absoluteString.dropFirst("satr-wiki:".count))
        guard let decoded = rawTarget.removingPercentEncoding else { return }
        let parts = decoded.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let pathPart = String(parts.first ?? "")
        let anchor = parts.count > 1 ? String(parts[1]) : nil

        if pathPart.isEmpty {
            if let anchor {
                scrollToHeading(anchor)
            }
            return
        }

        var relativePath = pathPart
        if URL(fileURLWithPath: relativePath).pathExtension.isEmpty {
            relativePath += ".md"
        }

        var directory = documentURL.deletingLastPathComponent()
        while true {
            let candidate = directory.appendingPathComponent(relativePath).standardizedFileURL
            if FileManager.default.fileExists(atPath: candidate.path) {
                (NSApp.delegate as? AppDelegate)?.openDocument(candidate)
                return
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
    }

    private func scrollToHeading(_ heading: String) {
        let data = try? JSONSerialization.data(withJSONObject: heading)
        let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        webView.evaluateJavaScript("window.satrScrollToHeading(\(json))")
    }

    private static func isMarkdown(_ url: URL) -> Bool {
        ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased())
    }
}

private final class MarkdownFilePresenter: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let onChange: () -> Void

    init(url: URL, onChange: @escaping () -> Void) {
        presentedItemURL = url
        self.onChange = onChange
        let queue = OperationQueue()
        queue.name = "sa.hatim.Satr.file-presenter"
        queue.maxConcurrentOperationCount = 1
        presentedItemOperationQueue = queue
        super.init()
    }

    func presentedItemDidChange() {
        DispatchQueue.main.async { [onChange] in onChange() }
    }
}

private final class LocalFileSchemeHandler: NSObject, WKURLSchemeHandler {
    private let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              let components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false),
              let rawPath = components.queryItems?.first(where: { $0.name == "path" })?.value,
              let fileURL = resolvedURL(for: rawPath) else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        do {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                return
            }

            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            let mimeType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let response = URLResponse(
                url: requestURL,
                mimeType: mimeType,
                expectedContentLength: values.fileSize ?? data.count,
                textEncodingName: nil
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func resolvedURL(for path: String) -> URL? {
        if path.hasPrefix("file://"), let url = URL(string: path), url.isFileURL {
            return url.standardizedFileURL
        }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return rootURL.appendingPathComponent(path).standardizedFileURL
    }
}

private extension NSToolbarItem.Identifier {
    static let openDocument = NSToolbarItem.Identifier("sa.hatim.Satr.toolbar.open")
    static let reloadDocument = NSToolbarItem.Identifier("sa.hatim.Satr.toolbar.reload")
    static let revealDocument = NSToolbarItem.Identifier("sa.hatim.Satr.toolbar.reveal")
    static let smallerText = NSToolbarItem.Identifier("sa.hatim.Satr.toolbar.smaller")
    static let largerText = NSToolbarItem.Identifier("sa.hatim.Satr.toolbar.larger")
}
