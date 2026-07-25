import AppKit

final class WelcomeViewController: NSViewController, NSWindowDelegate {
    private let onOpenRequested: (URL?) -> Void
    var onWindowClose: (() -> Void)?

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

        let description = NSTextField(wrappingLabelWithString: "Open a Markdown file to read its text, diagrams, tables, images, and links in one place.")
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

        let stack = NSStackView(views: [icon, title, description, dropZone, openButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.setCustomSpacing(9, after: title)
        stack.setCustomSpacing(26, after: description)
        stack.setCustomSpacing(22, after: dropZone)
        stack.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 82),
            icon.heightAnchor.constraint(equalToConstant: 82),
            description.widthAnchor.constraint(lessThanOrEqualToConstant: 430),
            dropZone.widthAnchor.constraint(equalToConstant: 430),
            dropZone.heightAnchor.constraint(equalToConstant: 92),
            openButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 130),
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: -6)
        ])

        view = root
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
    private let label = NSTextField(labelWithString: "Drop a .md file here")

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
        return urls.first { ["md", "markdown", "mdown", "mkd"].contains($0.pathExtension.lowercased()) }
    }

    private func updateStyle(isDragging: Bool) {
        layer?.cornerRadius = 10
        layer?.borderWidth = isDragging ? 2 : 1
        layer?.borderColor = (isDragging ? NSColor.systemGreen : NSColor.separatorColor).cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        label.textColor = isDragging ? .labelColor : .secondaryLabelColor
    }
}
