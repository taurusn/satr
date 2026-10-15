import Foundation
import JavaScriptCore
import LinenKit

/// A board as an agent needs it: an outline, not raw JSON (MCP-6). Built from the renderer's own board model, plus
/// which boxes Hatim has not seen since they last changed, from the baselines Linen keeps (read, never written).
enum BoardReader {
    static func model(_ text: String, sidecar: String?, renderer: URL) throws -> [String: Any] {
        guard let ctx = JSContext() else { throw LinenTools.ToolError(message: "JavaScriptCore did not start.") }
        var thrown: String?
        ctx.exceptionHandler = { _, e in thrown = e?.toString() }
        ctx.evaluateScript("var self = this; var globalThis = this;")
        let src = try String(contentsOf: renderer.appendingPathComponent("board-model.js"), encoding: .utf8)
        ctx.evaluateScript(src)
        ctx.setObject(text, forKeyedSubscript: "__text" as NSString)
        ctx.setObject(sidecar as Any? ?? NSNull(), forKeyedSubscript: "__sidecar" as NSString)
        let json = ctx.evaluateScript("""
          (function () {
            var b = LinenCanvas.parse(__text, { sidecarText: __sidecar });
            var nodes = (b.nodes || []).map(function (n) { return { id: n.id, kind: n.kind, title: n.title || n.label || n.file || n.url || (n.body || n.text || '').split('\\n')[0].slice(0, 80),
              word: n.word || null, note: !!n.note, parent: n.parent || null, hash: n.hash, line: n.line, placed: n.placed !== false, file: n.file || null }; });
            return JSON.stringify({ fatal: b.fatal ? { reason: b.fatal.reason, problems: (b.fatal.problems || []).slice(0, 10) } : null,
              title: b.title || null, dir: b.dir, words: b.words || [], order: b.order || [], nodes: nodes,
              edges: (b.edges || []).length, problems: (b.problems || []).length });
          })()
        """)?.toString() ?? "{}"
        if let thrown { throw LinenTools.ToolError(message: "The board model failed: \(thrown)") }
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    /// The `id:hash` pairs Hatim acknowledged on this board, or nil when he has never opened it in Linen.
    static func seen(_ url: URL) -> Set<String>? {
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Linen/baselines.json")
        guard let data = try? Data(contentsOf: file), let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        let key = FileKey.make(for: url)
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let entry = list.first { $0["key"] as? String == key } ?? list.first { $0["path"] as? String == path }
        guard let hashes = entry?["value"] as? [String] else { return nil }
        return Set(hashes)
    }

    @MainActor
    static func outline(_ u: URL, renderer: URL, offset: Int, limit: Int, section: String?, onlyUnseen: Bool = false) throws -> [String: Any] {
        let text = try Checker.readText(u)
        let sidecar = try? Checker.readText(URL(fileURLWithPath: u.path + ".notes.json"))
        let m = try model(text, sidecar: sidecar, renderer: renderer)
        if let fatal = m["fatal"] as? [String: Any], fatal["reason"] as? String != "limits" {
            let problems = (fatal["problems"] as? [[String: Any]] ?? []).map { "\($0["path"] ?? "$") line \($0["line"] ?? "?"): \($0["message"] ?? "")" }
            return LinenTools(renderer: renderer).failure("\(u.lastPathComponent) cannot be drawn: \(problems.joined(separator: "; ")). Fix these and run check_files.")
        }
        let ref = Refs.path(for: u)
        let nodes = m["nodes"] as? [[String: Any]] ?? []
        let byID = Dictionary(nodes.map { ($0["id"] as? String ?? "", $0) }, uniquingKeysWith: { a, _ in a })
        let order = (m["order"] as? [String] ?? []).compactMap { byID[$0] }
        let seen = seen(u)
        let sections = order.filter { $0["kind"] as? String == "section" }
        let sectionTitle = Dictionary(sections.map { ($0["id"] as? String ?? "", $0["title"] as? String ?? "") }, uniquingKeysWith: { a, _ in a })
        var boxes = order.filter { $0["kind"] as? String != "section" }
        if let section { boxes = boxes.filter { $0["parent"] as? String == section } }
        if onlyUnseen {
            guard let seen else {
                return LinenTools(renderer: renderer).ok("Hatim has not opened \(u.lastPathComponent) in Linen yet, so every box is new to him.", ["kind": "board", "path": u.path, "seenBefore": false])
            }
            boxes = boxes.filter { !seen.contains("\($0["id"] ?? ""):\($0["hash"] ?? "")") }
        }
        let total = boxes.count
        let page = Array(boxes.dropFirst(offset).prefix(limit))
        var unseenCount = 0
        if let seen { unseenCount = nodes.filter { !seen.contains("\($0["id"] ?? ""):\($0["hash"] ?? "")") }.count }
        let rows: [[String: Any]] = page.map { n in
            let id = n["id"] as? String ?? ""
            var r: [String: Any] = ["id": id, "ref": "\(ref)#\(id)", "kind": n["kind"] ?? "card", "title": n["title"] ?? ""]
            if let s = n["parent"] as? String { r["section"] = s }
            if let w = n["word"] as? String { r["word"] = w }
            if (n["note"] as? Bool) == true { r["note"] = true }
            if let f = n["file"] as? String { r["file"] = f }
            if (n["placed"] as? Bool) == false { r["placed"] = false }
            if let seen { r["unseen"] = !seen.contains("\(id):\(n["hash"] ?? "")") }
            return r
        }
        let words = (m["words"] as? [[String: Any]] ?? []).map { "\($0["word"] ?? "") \($0["count"] ?? 0)" }.joined(separator: ", ")
        var lines = ["\(m["title"] as? String ?? u.lastPathComponent): \(total) boxes, \(sections.count) sections, \(m["edges"] ?? 0) connectors. Words: \(words.isEmpty ? "none" : words)."]
        if let seen { lines.append(unseenCount == 0 ? "Hatim has seen every box's latest version." : "\(unseenCount) boxes changed since Hatim last looked (unseen: true).") ; _ = seen }
        else { lines.append("Hatim has not opened this board in Linen yet.") }
        var current: String?
        for r in rows {
            let s = r["section"] as? String
            if s != current { current = s; lines.append("## \(s.flatMap { sectionTitle[$0] } ?? "Outside sections") \(s.map { "(\($0))" } ?? "")") }
            lines.append("- \(r["id"]!): \(r["title"]!)\((r["word"] as? String).map { " [\($0)]" } ?? "")\((r["note"] as? Bool) == true ? " (note)" : "")\((r["unseen"] as? Bool) == true ? " (unseen)" : "")")
        }
        if offset + page.count < total { lines.append("… \(total - offset - page.count) more boxes: call again with offset \(offset + page.count).") }
        var structured: [String: Any] = ["kind": "board", "path": u.path, "title": m["title"] ?? NSNull(), "total": total, "offset": offset,
                                         "sections": sections.map { ["id": $0["id"] ?? "", "title": $0["title"] ?? ""] }, "boxes": rows,
                                         "words": m["words"] ?? [], "problems": m["problems"] ?? 0]
        structured["seenBefore"] = seen != nil
        structured["summary"] = lines[0]
        structured["shown"] = page.count
        let remaining = max(0, total - offset - page.count)
        structured["remaining"] = remaining
        if remaining > 0 { structured["next_offset"] = offset + page.count }
        if seen != nil { structured["unseen"] = unseenCount }
        return LinenTools(renderer: renderer).ok(lines.joined(separator: "\n"), structured)
    }
}

/// The path an agent understands, as Copy Reference writes it: relative to the git root inside a repository, else ~/-relative.
enum Refs {
    static func path(for url: URL) -> String {
        var dir = url.deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) { return String(url.path.dropFirst(dir.path.count + 1)) }
            dir = dir.deletingLastPathComponent()
        }
        return url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }
}
