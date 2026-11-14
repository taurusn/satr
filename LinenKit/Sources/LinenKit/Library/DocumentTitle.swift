import Foundation

/// The title the Library shows for a file: a note's first heading, a board's own title (`linen.title`), a page's
/// `<title>`, else the file name without its extension. Reads at most the first 64 KB.
public enum DocumentTitle {
    public static func title(of url: URL, kind: DocumentKind) -> String {
        let fallback = (url.lastPathComponent as NSString).deletingPathExtension
        guard let handle = try? FileHandle(forReadingFrom: url) else { return fallback }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 65_536)) ?? Data()
        let text = TextDecoder.decode(data).text
        let found: String?
        switch kind {
        case .note: found = url.pathExtension.lowercased() == "txt" ? nil : noteHeading(text)
        case .board: found = boardTitle(data)
        case .page: found = pageTitle(text)
        }
        let clean = found?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return clean.isEmpty ? fallback : clean
    }

    /// The first level-one heading outside frontmatter and fenced code.
    static func noteHeading(_ text: String) -> String? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).makeIterator()
        var first = true, inFront = false, fence: Substring?
        while let raw = lines.next() {
            let line = raw.hasSuffix("\r") ? raw.dropLast() : raw
            if first {
                first = false
                if line == "---" { inFront = true; continue }
            }
            if inFront {
                if line == "---" || line == "..." { inFront = false }
                continue
            }
            let trimmed = line.drop { $0 == " " }
            if let f = fence {
                if trimmed.hasPrefix(f) { fence = nil }
                continue
            }
            if trimmed.hasPrefix("```") { fence = "```"; continue }
            if trimmed.hasPrefix("~~~") { fence = "~~~"; continue }
            if trimmed.hasPrefix("# ") { return String(trimmed.dropFirst(2)).replacingOccurrences(of: #"\s+#+\s*$"#, with: "", options: .regularExpression) }
        }
        return nil
    }

    static func boardTitle(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let linen = obj["linen"] as? [String: Any] else { return nil }
        return linen["title"] as? String
    }

    static func pageTitle(_ text: String) -> String? {
        guard let open = text.range(of: "<title", options: .caseInsensitive),
              let gt = text.range(of: ">", range: open.upperBound..<text.endIndex),
              let close = text.range(of: "</title>", options: .caseInsensitive, range: gt.upperBound..<text.endIndex) else { return nil }
        let raw = text[gt.upperBound..<close.lowerBound]
        return raw.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}
