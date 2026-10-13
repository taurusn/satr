import Foundation

/// The parts of a wiki link's inner text: `path#heading|label` or `path#^block|label`.
struct LinkTarget: Sendable, Equatable {
    /// The path as written, trimmed, in NFC, without label, heading or block.
    var path: String
    var heading: String?
    var block: String?
    var label: String?

    init(path: String, heading: String? = nil, block: String? = nil, label: String? = nil) {
        self.path = path
        self.heading = heading
        self.block = block
        self.label = label
    }

    /// Splits a link's inner text. The first `|` starts the label (a `\|` written inside a table
    /// counts as a `|`); the first `#` starts the subpath, where `^id` is a block and anything else a
    /// heading (for nested `#A#B`, the last heading).
    static func parse(_ raw: String) -> LinkTarget {
        var body = Substring(raw)
        var label: String?
        if let bar = body.firstIndex(of: "|") {
            let text = body[body.index(after: bar)...].trimmingCharacters(in: .whitespaces)
            label = text.isEmpty ? nil : text.nfc
            body = body[..<bar]
            if body.hasSuffix("\\") { body = body.dropLast() }
        }
        var heading: String?
        var block: String?
        if let hash = body.firstIndex(of: "#") {
            let sub = body[body.index(after: hash)...]
            body = body[..<hash]
            let parts = sub.split(separator: "#", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if let last = parts.last {
                if last.hasPrefix("^") {
                    let id = String(last.dropFirst())
                    block = id.isEmpty ? nil : id
                    if parts.count > 1 { heading = parts[parts.count - 2].nfc }
                } else {
                    heading = last.nfc
                }
            }
        }
        let path = body.trimmingCharacters(in: .whitespaces).nfc
        return LinkTarget(path: path, heading: heading, block: block, label: label)
    }

    /// The text a reader sees for a link: its label, else the target's file name without `.md`,
    /// with `> heading` appended when the link points at a heading.
    static func displayLabel(for raw: String) -> String {
        let target = parse(raw)
        if let label = target.label { return label }
        var name = target.path.split(separator: "/").last.map(String.init) ?? ""
        if name.lowercased().hasSuffix(".md") { name = String(name.dropLast(3)) }
        if let heading = target.heading { return name.isEmpty ? heading : "\(name) > \(heading)" }
        return name.isEmpty ? raw.trimmingCharacters(in: .whitespaces) : name
    }
}
