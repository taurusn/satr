import Foundation

/// Reads the parts of YAML frontmatter the index needs, without a YAML library.
enum Frontmatter {
    /// The top-level key of a line such as `aliases: [a, b]`, with the text after the colon.
    static func topLevelKey(_ line: Substring) -> (key: String, value: Substring)? {
        guard let first = line.first, !first.isWhitespace, first != "-", first != "#",
              let colon = line.firstIndex(of: ":") else { return nil }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return (key, line[line.index(after: colon)...])
    }

    /// Aliases from `aliases:` (or `alias:`): a block list, an inline `[a, b]` list or one string.
    static func aliases(in lines: ArraySlice<Substring>) -> [String] {
        var result: [String] = []
        var index = lines.startIndex
        while index < lines.endIndex {
            guard let (key, value) = topLevelKey(lines[index]),
                  ["aliases", "alias"].contains(key.lowercased()) else {
                index += 1
                continue
            }
            let text = value.trimmingCharacters(in: .whitespaces)
            index += 1
            if text.isEmpty {
                while index < lines.endIndex {
                    let item = lines[index].trimmingCharacters(in: .whitespaces)
                    if item.isEmpty { index += 1; continue }
                    guard item.hasPrefix("-") else { break }
                    result.append(unquote(String(item.dropFirst()).trimmingCharacters(in: .whitespaces)))
                    index += 1
                }
            } else if text.hasPrefix("["), text.hasSuffix("]") {
                result += splitInlineList(String(text.dropFirst().dropLast())).map(unquote)
            } else {
                result.append(unquote(text))
            }
        }
        return result
            .map { $0.nfc }
            .filter { !$0.isEmpty && $0 != "null" && $0 != "~" }
    }

    /// Splits `a, "b, c", 'd'` on commas outside quotes.
    static func splitInlineList(_ text: String) -> [String] {
        var items: [String] = []
        var current = ""
        var quote: Character?
        for character in text {
            if let open = quote {
                current.append(character)
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
                current.append(character)
            } else if character == "," {
                items.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        items.append(current.trimmingCharacters(in: .whitespaces))
        return items.filter { !$0.isEmpty }
    }

    /// Removes one pair of matching YAML quotes.
    static func unquote(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, first == text.last, first == "\"" || first == "'" else {
            return text
        }
        let inner = String(text.dropFirst().dropLast())
        return first == "'" ? inner.replacingOccurrences(of: "''", with: "'")
                            : inner.replacingOccurrences(of: "\\\"", with: "\"")
    }
}

extension Substring {
    func trimmingTrailingWhitespace() -> Substring {
        var end = endIndex
        while end > startIndex, self[index(before: end)].isWhitespace { end = index(before: end) }
        return self[startIndex..<end]
    }
}
