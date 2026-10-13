import Foundation

/// What the index extracts from one note's text.
struct ParsedNote: Sendable {
    var aliases: [String] = []
    var headings: [Heading] = []
    var links: [WikiLink] = []
}

/// Extracts aliases, headings and wiki links from a note. Headings and body links are taken only
/// outside fenced code, and body links only outside inline code. Links in frontmatter values count
/// too, as Obsidian counts them. Works on UTF-8 bytes line by line; only frontmatter, heading lines
/// and lines holding `[[` are turned into strings.
enum NoteParser {
    static func parse(_ text: String) -> ParsedNote {
        var text = text
        return text.withUTF8 { parse(bytes: $0) }
    }

    static func parse(bytes: UnsafeBufferPointer<UInt8>) -> ParsedNote {
        var note = ParsedNote()
        let lines = lineRanges(bytes)
        var bodyStart = 0
        if let range = frontmatterRange(bytes, lines) {
            let yaml = lines[range].map { Substring(String(decoding: UnsafeBufferPointer(rebasing: bytes[$0]), as: UTF8.self)) }
            note.aliases = Frontmatter.aliases(in: yaml[...])
            note.links += frontmatterLinks(yaml, firstLine: range.lowerBound + 1)
            bodyStart = range.upperBound + 1
        }
        var fence: (byte: UInt8, count: Int)?
        for index in bodyStart..<lines.count {
            let line = UnsafeBufferPointer(rebasing: bytes[lines[index]])
            let lineNumber = index + 1
            if let open = fence {
                if isFenceClose(line, byte: open.byte, count: open.count) { fence = nil }
                continue
            }
            if let open = fenceOpen(line) {
                fence = open
                continue
            }
            if let heading = heading(line, line: lineNumber) { note.headings.append(heading) }
            guard containsLinkOpen(line) else { continue }
            let scan = LineScanner(Array(line), skipCode: true)
            for (position, link) in scan.links.enumerated() {
                note.links.append(WikiLink(raw: link.raw, isEmbed: link.isEmbed, inFrontmatter: false,
                                           line: lineNumber, sentence: scan.sentence(for: position)))
            }
        }
        return note
    }

    /// Line ranges split at `\n`, each without its line ending (a trailing `\r` is dropped too).
    static func lineRanges(_ bytes: UnsafeBufferPointer<UInt8>) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        guard let base = bytes.baseAddress else { return [0..<0] }
        var start = 0
        while start <= bytes.count {
            let remaining = bytes.count - start
            var end = bytes.count
            if remaining > 0, let found = memchr(base + start, 0x0A, remaining) {
                end = base.distance(to: found.assumingMemoryBound(to: UInt8.self))
            }
            var trimmed = end
            if trimmed > start, bytes[trimmed - 1] == 0x0D { trimmed -= 1 }
            ranges.append(start..<trimmed)
            start = end + 1
        }
        return ranges
    }

    private static func frontmatterRange(_ bytes: UnsafeBufferPointer<UInt8>, _ lines: [Range<Int>]) -> Range<Int>? {
        func isMarker(_ range: Range<Int>, _ marker: StaticString) -> Bool {
            var end = range.upperBound
            while end > range.lowerBound, bytes[end - 1] == 0x20 || bytes[end - 1] == 0x09 { end -= 1 }
            guard end - range.lowerBound == marker.utf8CodeUnitCount else { return false }
            return (0..<marker.utf8CodeUnitCount).allSatisfy { bytes[range.lowerBound + $0] == marker.utf8Start[$0] }
        }
        guard let first = lines.first, isMarker(first, "---") else { return nil }
        for index in 1..<max(1, lines.count) where isMarker(lines[index], "---") || isMarker(lines[index], "...") {
            return 1..<index
        }
        return nil
    }

    /// Links in frontmatter values, each with `key: value` as its context.
    private static func frontmatterLinks(_ lines: [Substring], firstLine: Int) -> [WikiLink] {
        var links: [WikiLink] = []
        var key = ""
        for (offset, line) in lines.enumerated() {
            var value = line
            if let found = Frontmatter.topLevelKey(line) {
                key = found.key
                value = found.value
            }
            let bytes = Array(value.utf8)
            guard bytes.withUnsafeBufferPointer(containsLinkOpen) else { continue }
            let scan = LineScanner(bytes, skipCode: false)
            for (position, link) in scan.links.enumerated() {
                let text = scan.sentence(for: position).replacingOccurrences(of: "\"", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "' -[],"))
                links.append(WikiLink(raw: link.raw, isEmbed: link.isEmbed, inFrontmatter: true,
                                      line: firstLine + offset, sentence: key.isEmpty ? text : "\(key): \(text)"))
            }
        }
        return links
    }

    /// An ATX heading: up to three spaces, one to six `#`, then a space or the end of the line.
    static func heading(_ bytes: UnsafeBufferPointer<UInt8>, line: Int) -> Heading? {
        var index = 0
        while index < bytes.count, index < 3, bytes[index] == 0x20 { index += 1 }
        guard index < bytes.count, bytes[index] == UInt8(ascii: "#") else { return nil }
        var level = 0
        while index + level < bytes.count, bytes[index + level] == UInt8(ascii: "#") { level += 1 }
        guard level <= 6 else { return nil }
        let after = index + level
        guard after == bytes.count || bytes[after] == 0x20 || bytes[after] == 0x09 else { return nil }
        var text = Substring(String(decoding: UnsafeBufferPointer(rebasing: bytes[after...]), as: UTF8.self))
            .trimmingTrailingWhitespace()
        var closing = text.endIndex
        while closing > text.startIndex, text[text.index(before: closing)] == "#" { closing = text.index(before: closing) }
        if closing == text.startIndex || text[text.index(before: closing)].isWhitespace { text = text[..<closing] }
        return Heading(level: level, text: text.trimmingCharacters(in: .whitespaces).nfc, line: line)
    }

    /// A fence opening: up to three spaces, then three or more backticks or tildes.
    static func fenceOpen(_ bytes: UnsafeBufferPointer<UInt8>) -> (byte: UInt8, count: Int)? {
        var index = 0
        while index < bytes.count, index < 3, bytes[index] == 0x20 { index += 1 }
        guard index < bytes.count, bytes[index] == UInt8(ascii: "`") || bytes[index] == UInt8(ascii: "~") else { return nil }
        let byte = bytes[index]
        var count = 0
        while index + count < bytes.count, bytes[index + count] == byte { count += 1 }
        guard count >= 3 else { return nil }
        if byte == UInt8(ascii: "`"), bytes[(index + count)...].contains(byte) { return nil }
        return (byte, count)
    }

    static func isFenceClose(_ bytes: UnsafeBufferPointer<UInt8>, byte: UInt8, count: Int) -> Bool {
        var index = 0
        while index < bytes.count, index < 3, bytes[index] == 0x20 { index += 1 }
        guard index < bytes.count, bytes[index] == byte else { return false }
        var run = 0
        while index + run < bytes.count, bytes[index + run] == byte { run += 1 }
        guard run >= count else { return false }
        return bytes[(index + run)...].allSatisfy { $0 == 0x20 || $0 == 0x09 }
    }

    /// True when the bytes hold `[[`.
    static func containsLinkOpen(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard bytes.count >= 2, let base = bytes.baseAddress else { return false }
        return memmem(base, bytes.count, "[[", 2) != nil
    }
}
