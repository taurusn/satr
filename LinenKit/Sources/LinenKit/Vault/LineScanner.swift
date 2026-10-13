import Foundation

/// Scans one line of Markdown for wiki links and builds a plain version of the line, with link
/// markup reduced to labels, from which the sentence holding each link is cut.
struct LineScanner {
    struct Found {
        let raw: String
        let isEmbed: Bool
        /// Where the link's label starts in `plain`.
        let start: Int
        let end: Int
    }

    private(set) var plain: [UInt8] = []
    private(set) var links: [Found] = []
    /// Sentence terminators outside link labels, as (index, length), in order.
    private var boundaries: [(at: Int, length: Int)] = []
    private var marker = 0
    private var table = false

    private static let backtick = UInt8(ascii: "`")
    private static let open = UInt8(ascii: "[")
    private static let close = UInt8(ascii: "]")
    private static let bang = UInt8(ascii: "!")
    private static let backslash = UInt8(ascii: "\\")

    /// Scans `bytes`. With `skipCode`, inline code spans are kept as text but never searched for links.
    init(_ bytes: [UInt8], skipCode: Bool) {
        plain.reserveCapacity(bytes.count)
        let count = bytes.count
        var index = 0
        while index < count {
            let byte = bytes[index]
            if byte == Self.backslash, index + 1 < count, bytes[index + 1] < 0x80,
               bytes[index + 1] != Self.backslash, Self.isPunctuation(bytes[index + 1]) {
                plain.append(bytes[index + 1])
                index += 2
                continue
            }
            if skipCode, byte == Self.backtick {
                index = consumeCode(bytes, from: index)
                continue
            }
            if byte == Self.open, index + 1 < count, bytes[index + 1] == Self.open,
               let end = Self.wikiClose(bytes, from: index + 2) {
                let raw = String(decoding: bytes[(index + 2)..<end], as: UTF8.self)
                if !raw.trimmingCharacters(in: .whitespaces).isEmpty {
                    let isEmbed = index > 0 && bytes[index - 1] == Self.bang
                    if isEmbed, plain.last == Self.bang { plain.removeLast() }
                    let start = plain.count
                    plain.append(contentsOf: LinkTarget.displayLabel(for: raw).utf8)
                    links.append(Found(raw: raw, isEmbed: isEmbed, start: start, end: plain.count))
                    index = end + 2
                    continue
                }
            }
            if byte == Self.open, let (textEnd, linkEnd) = Self.markdownLink(bytes, from: index) {
                if index > 0, bytes[index - 1] == Self.bang, plain.last == Self.bang { plain.removeLast() }
                plain.append(contentsOf: bytes[(index + 1)..<textEnd])
                index = linkEnd + 1
                continue
            }
            plain.append(byte)
            index += 1
        }
        guard !links.isEmpty else { return }
        marker = Self.leadingMarkerLength(plain)
        table = marker < plain.count && plain[marker] == UInt8(ascii: "|")
        findBoundaries()
    }

    /// Records every sentence terminator once, skipping link labels.
    private mutating func findBoundaries() {
        var linkIndex = 0
        var index = marker
        while index < plain.count {
            while linkIndex < links.count, links[linkIndex].end <= index { linkIndex += 1 }
            if linkIndex < links.count, index >= links[linkIndex].start {
                index = links[linkIndex].end
                continue
            }
            if let length = boundaryLength(at: index) {
                boundaries.append((index, length))
                index += length
            } else {
                index += 1
            }
        }
    }

    /// Copies an inline code span's text to `plain` and returns the index after it. A backtick run
    /// with no closing run of the same length is literal text.
    private mutating func consumeCode(_ bytes: [UInt8], from start: Int) -> Int {
        var run = 0
        while start + run < bytes.count, bytes[start + run] == Self.backtick { run += 1 }
        var index = start + run
        while index < bytes.count {
            if bytes[index] == Self.backtick {
                var other = 0
                while index + other < bytes.count, bytes[index + other] == Self.backtick { other += 1 }
                if other == run {
                    plain.append(contentsOf: bytes[(start + run)..<index])
                    return index + other
                }
                index += other
            } else {
                index += 1
            }
        }
        plain.append(contentsOf: bytes[start..<(start + run)])
        return start + run
    }

    /// The index of the `]]` closing a wiki link whose text starts at `from`.
    private static func wikiClose(_ bytes: [UInt8], from: Int) -> Int? {
        var index = from
        while index + 1 < bytes.count {
            if bytes[index] == close, bytes[index + 1] == close { return index }
            if bytes[index] == open, bytes[index + 1] == open { return nil }
            index += 1
        }
        return nil
    }

    /// For `[text](target)` starting at `from`, the index of `]` and of `)`.
    private static func markdownLink(_ bytes: [UInt8], from: Int) -> (Int, Int)? {
        var index = from + 1
        var depth = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == open { depth += 1 }
            if byte == close {
                if depth == 0 { break }
                depth -= 1
            }
            index += 1
        }
        guard index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "(") else { return nil }
        let textEnd = index
        var end = index + 2
        while end < bytes.count, bytes[end] != UInt8(ascii: ")") { end += 1 }
        return end < bytes.count ? (textEnd, end) : nil
    }

    private static func isPunctuation(_ byte: UInt8) -> Bool {
        (0x21...0x2F).contains(byte) || (0x3A...0x40).contains(byte)
            || (0x5B...0x60).contains(byte) || (0x7B...0x7E).contains(byte)
    }

    // MARK: Sentences

    /// The sentence of `plain` that holds the link at `linkIndex`, trimmed and at most 300 characters.
    func sentence(for linkIndex: Int) -> String {
        let link = links[linkIndex]
        var start = marker
        var end = plain.count
        for boundary in boundaries {
            let after = boundary.at + boundary.length
            if after <= link.start {
                start = after
            } else if boundary.at >= link.end {
                end = table ? boundary.at : after
                break
            }
        }
        var text = String(decoding: plain[start..<max(start, end)], as: UTF8.self)
        text = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "==", with: "")
        text = text.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "|")))
        return Self.clip(text, around: String(decoding: plain[link.start..<link.end], as: UTF8.self))
    }

    /// The length of a sentence terminator at `index`.
    private func boundaryLength(at index: Int) -> Int? {
        let byte = plain[index]
        if table, byte == UInt8(ascii: "|") { return 1 }
        var length = 0
        if byte == UInt8(ascii: ".") || byte == UInt8(ascii: "!") || byte == UInt8(ascii: "?") {
            length = 1
        } else if byte == 0xD8, index + 1 < plain.count, plain[index + 1] == 0x9F {
            length = 2  // Arabic question mark U+061F
        } else {
            return nil
        }
        let next = index + length
        if next == plain.count || plain[next] == UInt8(ascii: " ") || plain[next] == UInt8(ascii: "\t") {
            return length
        }
        return nil
    }

    /// The length of block markers at the start of a line: quote marks, list bullets, task boxes,
    /// heading marks and callout types.
    static func leadingMarkerLength(_ bytes: [UInt8]) -> Int {
        var index = 0
        var changed = true
        func skipSpaces() { while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09 { index += 1 } }
        while changed {
            changed = false
            skipSpaces()
            guard index < bytes.count else { break }
            let byte = bytes[index]
            let next = index + 1 < bytes.count ? bytes[index + 1] : 0x20
            if byte == UInt8(ascii: ">") {
                index += 1; changed = true
            } else if (byte == UInt8(ascii: "-") || byte == UInt8(ascii: "*") || byte == UInt8(ascii: "+")), next == 0x20 {
                index += 2; changed = true
            } else if byte == UInt8(ascii: "#") {
                var level = 0
                while index + level < bytes.count, bytes[index + level] == UInt8(ascii: "#") { level += 1 }
                if level <= 6, index + level == bytes.count || bytes[index + level] == 0x20 { index += level; changed = true }
            } else if (0x30...0x39).contains(byte) {
                var digits = 0
                while index + digits < bytes.count, (0x30...0x39).contains(bytes[index + digits]) { digits += 1 }
                let mark = index + digits
                if digits <= 9, mark + 1 < bytes.count, bytes[mark] == UInt8(ascii: ".") || bytes[mark] == UInt8(ascii: ")"),
                   bytes[mark + 1] == 0x20 {
                    index = mark + 2; changed = true
                }
            } else if byte == UInt8(ascii: "["), index + 2 < bytes.count, bytes[index + 2] == UInt8(ascii: "]"),
                      [UInt8(ascii: " "), UInt8(ascii: "x"), UInt8(ascii: "X")].contains(bytes[index + 1]) {
                index += 3; changed = true
            } else if byte == UInt8(ascii: "["), next == UInt8(ascii: "!"),
                      let end = bytes[index...].firstIndex(of: UInt8(ascii: "]")) {
                index = end + 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") { index += 1 }
                changed = true
            }
        }
        return min(index, bytes.count)
    }

    /// Shortens a long sentence to about 300 characters around the link's label.
    static func clip(_ text: String, around label: String, limit: Int = 300) -> String {
        guard text.count > limit else { return text }
        let characters = Array(text)
        var labelStart = 0
        if let range = text.range(of: label) { labelStart = text.distance(from: text.startIndex, to: range.lowerBound) }
        let from = max(0, min(labelStart - limit / 3, characters.count - limit))
        let to = min(characters.count, from + limit)
        let body = String(characters[from..<to]).trimmingCharacters(in: .whitespaces)
        return (from > 0 ? "…" : "") + body + (to < characters.count ? "…" : "")
    }
}
