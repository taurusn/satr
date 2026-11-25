import Foundation

/// Boards embedded in a note (PRD-2 BRD-19, BLK-8): which boards a note names (`![[board.canvas#Section|caption]]`,
/// `![caption](board.canvas)`), and their text, read with the note so the page knows each frame's height before it
/// draws. Shared by the app and the `linen` command (shot, check), like SafeOpen.
enum BoardEmbeds {
    static let maxBytes = 2 * 1024 * 1024
    static let maxPerNote = 24

    struct Ref {
        let key: String        // what the page asks by: "wiki:name.canvas" or "path:folder/name.canvas"
        let wiki: String?
        let path: String?
        let section: String?
        let line: Int
    }

    private static let wikiRE = try! NSRegularExpression(pattern: #"!\[\[([^\]\|#\^\n]+?\.canvas)\s*(?:#([^\]\|\n]*))?(?:\|[^\]\n]*)?\]\]"#, options: [.caseInsensitive])
    private static let mdRE = try! NSRegularExpression(pattern: #"!\[[^\]\n]*\]\(([^)\s]+?\.canvas)(?:#([^)\s]*))?\)"#, options: [.caseInsensitive])

    /// The boards a note embeds, outside code fences, in order, each once per key and section.
    static func refs(in text: String) -> [Ref] {
        var out: [Ref] = []
        var inFence = false, fence = ""
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let mark = String(trimmed.prefix(3))
                if !inFence { inFence = true; fence = mark } else if trimmed.hasPrefix(fence) { inFence = false }
                continue
            }
            if inFence { continue }
            let ns = raw as NSString
            for m in wikiRE.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let sec = m.range(at: 2).location == NSNotFound ? nil : ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
                out.append(Ref(key: "wiki:" + name, wiki: name, path: nil, section: sec?.isEmpty == true ? nil : sec, line: i + 1))
            }
            for m in mdRE.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
                let href = ns.substring(with: m.range(at: 1))
                if href.contains("://") { continue }
                let path = href.removingPercentEncoding ?? href
                var sec = m.range(at: 2).location == NSNotFound ? nil : ns.substring(with: m.range(at: 2))
                sec = sec.map { $0.removingPercentEncoding ?? $0 }
                out.append(Ref(key: "path:" + path, wiki: nil, path: path, section: sec?.isEmpty == true ? nil : sec, line: i + 1))
            }
            if out.count >= maxPerNote * 4 { break }
        }
        return out
    }

    /// The file a reference names: a wiki name through the caller's resolver, a path relative to the note's folder.
    static func file(_ r: Ref, note: URL, resolveWiki: (String) -> URL?) -> URL? {
        if let w = r.wiki { return resolveWiki(w) }
        guard let p = r.path else { return nil }
        return p.hasPrefix("/") ? URL(fileURLWithPath: p) : note.deletingLastPathComponent().appendingPathComponent(p).standardizedFileURL
    }

    /// Each embedded board's text by key: `status` ok (with `text`, `sidecar`, `name`, `path`), missing, outside,
    /// large or unreadable. `allowed` says whether Linen may read a file the note names (the vault rule for images).
    static func read(_ refs: [Ref], note: URL, resolveWiki: (String) -> URL?, allowed: (URL) -> Bool) -> [String: Any] {
        var map: [String: Any] = [:]
        for r in refs where map[r.key] == nil {
            if map.count >= maxPerNote { map[r.key] = ["status": "unreadable"]; continue }
            guard let u = file(r, note: note, resolveWiki: resolveWiki), FileManager.default.fileExists(atPath: u.path) else { map[r.key] = ["status": "missing"]; continue }
            guard allowed(u) else { map[r.key] = ["status": "outside", "name": u.lastPathComponent]; continue }
            let size = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? NSNumber)?.intValue ?? 0
            if size > maxBytes { map[r.key] = ["status": "large", "name": u.lastPathComponent]; continue }
            guard let data = try? Data(contentsOf: u), let text = String(data: data, encoding: .utf8) else { map[r.key] = ["status": "unreadable"]; continue }
            var info: [String: Any] = ["status": "ok", "text": text, "name": u.lastPathComponent, "path": u.path]
            let side = URL(fileURLWithPath: u.path + ".notes.json")
            if let d = try? Data(contentsOf: side), d.count <= maxBytes, let s = String(data: d, encoding: .utf8) { info["sidecar"] = s }
            map[r.key] = info
        }
        return map
    }

    /// True when `u` lies inside `root` (after resolving links), the rule images follow.
    static func inside(_ u: URL, _ root: URL) -> Bool {
        let p = u.resolvingSymlinksInPath().standardizedFileURL.path, r = root.resolvingSymlinksInPath().standardizedFileURL.path
        return p == r || p.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }
}
