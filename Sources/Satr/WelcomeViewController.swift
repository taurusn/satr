import AppKit

final class WelcomeViewController: NSViewController, NSWindowDelegate {
    private let onOpenRequested: (URL?) -> Void
    var onWindowClose: (() -> Void)?
    private let recentStack = NSStackView()
    private let recentSection = NSStackView()

    init(onOpenRequested: @escaping (URL?) -> Void) {
        self.onOpenRequested = onOpenRequested
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = WelcomeRootView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Satr")
        title.font = .systemFont(ofSize: 31, weight: .semibold)
        title.textColor = .labelColor
        title.alignment = .center

        let description = NSTextField(wrappingLabelWithString: "Open Markdown and plain-text files to read their content in one focused place.")
        description.font = .systemFont(ofSize: 15)
        description.textColor = .secondaryLabelColor
        description.alignment = .center
        description.maximumNumberOfLines = 2

        let dropZone = DropZoneView { [weak self] url in
            self?.onOpenRequested(url)
        }
        dropZone.translatesAutoresizingMaskIntoConstraints = false

        let openButton = NSButton(title: "Open file", target: self, action: #selector(openFile))
        openButton.bezelStyle = .rounded
        openButton.controlSize = .large
        openButton.keyEquivalent = "\r"
        openButton.translatesAutoresizingMaskIntoConstraints = false

        let recentHeading = NSTextField(labelWithString: "Recently Opened")
        recentHeading.font = .systemFont(ofSize: 12, weight: .semibold)
        recentHeading.textColor = .secondaryLabelColor
        recentStack.orientation = .vertical
        recentStack.alignment = .leading
        recentStack.spacing = 2
        recentSection.orientation = .vertical
        recentSection.alignment = .leading
        recentSection.spacing = 6
        recentSection.setViews([recentHeading, recentStack], in: .top)
        NotificationCenter.default.addObserver(self, selector: #selector(reloadRecents), name: RecentDocuments.didChange, object: nil)
        reloadRecents()

        let stack = NSStackView(views: [icon, title, description, dropZone, openButton, recentSection])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.setCustomSpacing(9, after: title)
        stack.setCustomSpacing(26, after: description)
        stack.setCustomSpacing(22, after: dropZone)
        stack.setCustomSpacing(24, after: openButton)
        stack.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 82),
            icon.heightAnchor.constraint(equalToConstant: 82),
            description.widthAnchor.constraint(lessThanOrEqualToConstant: 430),
            dropZone.widthAnchor.constraint(equalToConstant: 430),
            dropZone.heightAnchor.constraint(equalToConstant: 92),
            openButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 130),
            recentSection.widthAnchor.constraint(equalToConstant: 430),
            recentStack.widthAnchor.constraint(equalTo: recentSection.widthAnchor),
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: -6)
        ])

        view = root
    }

    @objc private func reloadRecents() {
        recentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let urls = Array(RecentDocuments.shared.urls.prefix(5))
        recentSection.isHidden = urls.isEmpty
        for url in urls {
            let button = RecentFileButton(url: url) { [weak self] in self?.onOpenRequested(url) }
            recentStack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: recentStack.widthAnchor).isActive = true
        }
    }

    @objc private func openFile() {
        onOpenRequested(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onWindowClose?()
    }
}

private final class WelcomeRootView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        updateColor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }

    private func updateColor() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
}

private final class DropZoneView: NSView {
    private let onDrop: (URL?) -> Void
    private let label = NSTextField(labelWithString: "Drop a .md or .txt file here")

    init(onDrop: @escaping (URL?) -> Void) {
        self.onDrop = onDrop
        super.init(frame: .zero)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])

        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        updateStyle(isDragging: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateStyle(isDragging: false)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard markdownURL(from: sender) != nil else { return [] }
        updateStyle(isDragging: true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        updateStyle(isDragging: false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        updateStyle(isDragging: false)
        guard let url = markdownURL(from: sender) else { return false }
        onDrop(url)
        return true
    }

    private func markdownURL(from draggingInfo: NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = draggingInfo.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] else {
            return nil
        }
        return urls.first { ["md", "markdown", "mdown", "mkd", "txt"].contains($0.pathExtension.lowercased()) }
    }

    private func updateStyle(isDragging: Bool) {
        layer?.cornerRadius = 10
        layer?.borderWidth = isDragging ? 2 : 1
        layer?.borderColor = (isDragging ? NSColor.systemGreen : NSColor.separatorColor).cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        label.textColor = isDragging ? .labelColor : .secondaryLabelColor
    }
}

private final class RecentFileButton: NSButton {
    private let onClick: () -> Void

    init(url: URL, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        isBordered = false
        title = ""
        target = self
        action = #selector(clicked)
        toolTip = url.path
        setButtonType(.momentaryChange)

        let name = NSTextField(labelWithString: url.lastPathComponent)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let folder = NSTextField(labelWithString: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
        folder.font = .systemFont(ofSize: 12)
        folder.textColor = .secondaryLabelColor
        folder.lineBreakMode = .byTruncatingHead
        folder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [name, folder])
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 22)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func clicked() {
        onClick()
    }
}
