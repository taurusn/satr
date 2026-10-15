import Foundation
import JavaScriptCore

/// The renderer's board scripts in JavaScriptCore: the model, the Obsidian-style writer and the author.
final class BoardJS {
    let ctx: JSContext
    private var thrown: String?

    init(renderer: URL) throws {
        guard let c = JSContext() else { throw LinenTools.ToolError(message: "JavaScriptCore did not start.") }
        ctx = c
        ctx.exceptionHandler = { [weak self] _, e in self?.thrown = e?.toString() }
        ctx.evaluateScript("var self = this; var globalThis = this;")
        for f in ["board-model.js", "canvas-writer.js", "board-author.js"] {
            let src = try String(contentsOf: renderer.appendingPathComponent(f), encoding: .utf8)
            ctx.evaluateScript(src, withSourceURL: renderer.appendingPathComponent(f))
            if let thrown { throw LinenTools.ToolError(message: "\(f) failed to load: \(thrown)") }
        }
    }

    /// Calls `body` (a JS function body using `input`) with a JSON input and returns its JSON output.
    func run(_ body: String, _ input: Any) throws -> [String: Any] {
        thrown = nil
        let data = try JSONSerialization.data(withJSONObject: input)
        ctx.setObject(String(decoding: data, as: UTF8.self), forKeyedSubscript: "__input" as NSString)
        let out = ctx.evaluateScript("(function () { var input = JSON.parse(__input); \(body) })()")?.toString() ?? "{}"
        if let thrown { throw LinenTools.ToolError(message: "Linen's board author failed: \(thrown)") }
        return (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any] ?? [:]
    }
}

extension LinenTools {
    static let boxSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "id": ["type": "string", "description": "Stable id (a short slug such as \"approve-flow\"); references and change marks follow it."],
            "title": ["type": "string", "description": "Short title, set in serif. A few words."],
            "body": ["type": "string", "description": "Markdown body: one to three short sentences. What is true, not how you found it."],
            "word": ["type": "string", "description": "One status word from the board's words (default: Works, Partial, Broken, Missing, Planned)."],
            "note": ["type": "object", "description": "Evidence shown on hover: {title, body, refs: [\"path/file.py:118\"], area}.",
                     "properties": ["title": ["type": "string"], "body": ["type": "string"], "area": ["type": "string"], "refs": ["type": "array", "items": ["type": "string"]]]],
            "kind": ["type": "string", "enum": ["card", "sticky", "shape", "text", "file", "link"], "description": "card (default), sticky, shape, text (big title text), file (a .md, .canvas, .html or image beside the board), link (a web address)."],
            "shape": ["type": "string", "enum": ["rect", "rounded", "ellipse", "diamond", "pill", "cylinder", "hexagon"]],
            "file": ["type": "string"], "url": ["type": "string"],
            "eyebrow": ["type": "string", "description": "Optional small label above the title, one to three words (a step number, a layer). Leave it out when the section already says it."],
            "color": ["type": "string", "description": "\"1\" to \"6\" or #RRGGBB, drawn as a calm wash. Never use colour for status; use word."],
        ],
    ]

    static let edgeSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "from": ["type": "string"], "to": ["type": "string"], "label": ["type": "string", "description": "A verb or noun of one to three words."],
            "kind": ["type": "string", "enum": ["works", "main", "code", "plan", "fail"], "description": "works (seen working), main (the main path, heavier), code (exists in code, not seen working), plan (not built), fail (broken link)."],
            "two_way": ["type": "boolean"],
        ],
        "required": ["from", "to"],
    ]

    static let authorDefinitions: [[String: Any]] = [
        tool("write_board", "Make a board for Hatim",
             """
             Makes a new board (.canvas) for Hatim from sections of boxes and connectors: Linen writes the file, sizes every \
             box to its text with its own fonts, puts sections in tidy rows, checks it and returns a screenshot. Never place \
             boxes by hand. Use it for readiness maps, architecture diagrams, plans and comparisons: one section per area; \
             per box a title of a few words, a body of one or two short sentences, one status word, and the evidence in \
             note.refs as path:line. Ten sections of up to twenty boxes read well; more belongs in two boards. To change an \
             existing board use edit_board. Writes nothing when the spec has errors, and says what to fix. Example: \
             {"path": "/abs/requests.canvas", "board": {"title": "Requests readiness", "sections": [{"id": "s-intake", \
             "title": "Intake", "cols": 2, "cards": [{"id": "form", "title": "Request form", "body": "Validates and stores a \
             request.", "word": "Works"}, {"id": "nightly", "title": "Nightly import", "body": "The last run failed at export.", \
             "word": "Broken", "note": {"body": "Stops at the export step.", "refs": ["jobs/nightly.py:42"]}}]}], \
             "edges": [{"from": "form", "to": "nightly", "label": "queues", "kind": "code"}]}}
             """,
             ["path": ["type": "string", "description": "Where to write the .canvas file (notes go beside it in <name>.canvas.notes.json)."],
              "board": ["type": "object", "description": "The board.", "properties": [
                "title": ["type": "string"], "dir": ["type": "string", "enum": ["ltr", "rtl"], "description": "rtl for an Arabic board."],
                "columns": ["type": "integer", "minimum": 1, "maximum": 8, "description": "Sections per row (default up to 5)."],
                "words": ["type": "array", "description": "Optional custom status words, at most six: [{word, shape: outline|threads|solid|dashed|dotted|rust, meaning, quiet}]. Give the most common word the outline shape and quiet: true, so the usual state stays calm; solid is the heaviest shape, for the few boxes that must stand out; rust only for failure. Without this list the board uses Works (quiet), Partial, Broken, Missing, Planned.", "items": ["type": "object"]],
                "sections": ["type": "array", "items": ["type": "object", "properties": [
                    "id": ["type": "string"], "title": ["type": "string"],
                    "cols": ["type": "integer", "minimum": 1, "maximum": 6, "description": "Columns of boxes in the section (default 1 or 2)."],
                    "layout": ["type": "string", "enum": ["grid", "stack", "lanes", "layered"], "description": "grid (default); layered for a flow of connected boxes."],
                    "cards": ["type": "array", "items": boxSchema]], "required": ["title", "cards"]]],
                "cards": ["type": "array", "description": "Boxes outside any section.", "items": boxSchema],
                "edges": ["type": "array", "items": edgeSchema]], "required": ["sections"]],
              "replace": ["type": "boolean", "default": false, "description": "Overwrite an existing file. Prefer edit_board for changes: Hatim then sees only what changed."],
              "shot": ["type": "string", "default": "fit", "description": "\"fit\" (the whole board), a section or box id, or \"none\"."],
              "width": ["type": "integer", "enum": [390, 1176, 1440], "default": 1176]],
             required: ["path", "board"], readOnly: false, destructive: false, idempotent: false),
        tool("edit_board", "Change boxes on a board by id",
             """
             Changes an existing board in place by box id, lays out what moved, checks it and returns a screenshot of the \
             first changed box. Untouched boxes keep every byte, so Hatim's change marks show exactly what you changed. \
             Use it for every update to a board, small or large, instead of rewriting the file. Ops: set (title, body, \
             word, note, kind, shape, color, eyebrow; null clears a field), add (a card into a section), remove, move (to \
             another section), connect, disconnect, add_section, remove_section, set_board (title, words, dir). Get ids \
             from read_outline. Example: {"path": "/abs/requests.canvas", "ops": [{"op": "set", "id": "nightly", "word": \
             "Works", "body": "Runs nightly; fixed retries at export."}, {"op": "add", "section": "s-intake", "card": \
             {"id": "audit", "title": "Audit trail", "word": "Missing"}}]}
             """,
             ["path": ["type": "string"],
              "ops": ["type": "array", "minItems": 1, "items": ["type": "object", "properties": [
                "op": ["type": "string", "enum": ["set", "add", "remove", "move", "connect", "disconnect", "add_section", "remove_section", "set_board"]],
                "id": ["type": "string"], "section": ["description": "add/move: the section id; add_section: the section object.", "type": ["string", "object"]],
                "card": boxSchema, "title": ["type": "string"], "body": ["type": "string"], "word": ["type": ["string", "null"]],
                "note": ["type": ["object", "null"]], "from": ["type": "string"], "to": ["type": "string"], "label": ["type": "string"],
                "kind": ["type": "string"], "color": ["type": ["string", "null"]],
                "shape": ["type": "string", "enum": ["rect", "rounded", "ellipse", "diamond", "pill", "cylinder", "hexagon"]],
                "eyebrow": ["type": ["string", "null"]], "dir": ["type": "string", "enum": ["ltr", "rtl"]],
                "two_way": ["type": "boolean"], "keep_cards": ["type": "boolean"],
                "words": ["type": "array", "description": "set_board: the board's whole word list, at most six. Give a word by name to keep its current definition, or as {word, shape: outline|threads|solid|dashed|dotted|rust, meaning, quiet}. To add one word, pass the existing names plus the new object.",
                          "items": ["type": ["string", "object"]]]], "required": ["op"]]],
              "shot": ["type": "string", "default": "changed", "description": "\"changed\" (the first changed box), \"fit\", an id, or \"none\"."],
              "width": ["type": "integer", "enum": [390, 1176, 1440], "default": 1176]],
             required: ["path", "ops"], readOnly: false, destructive: true, idempotent: false),
    ]

    func writeBoardTool(_ args: [String: Any]) async throws -> [String: Any] {
        guard let p = args["path"] as? String, !p.isEmpty else { throw ToolError(message: "Pass path: where to write the .canvas file.") }
        let u = fileURL(p)
        guard u.pathExtension.lowercased() == "canvas" else { throw ToolError(message: "path must end in .canvas.") }
        let exists = FileManager.default.fileExists(atPath: u.path)
        if exists && (args["replace"] as? Bool) != true {
            throw ToolError(message: "\(u.lastPathComponent) already exists. Use edit_board to change it (Hatim then sees only what changed), or pass replace: true to start over.")
        }
        if exists, !Self.isRegularFile(u) { throw ToolError(message: "\(u.path) is not a regular file; Linen writes boards only over boards.") }
        guard let spec = args["board"] as? [String: Any] else { throw ToolError(message: "Pass board: {title, sections: [{title, cards: [...]}], edges: [...]}. Read format_guide topic board for the format.") }
        let js = try BoardJS(renderer: renderer)
        let composed = try js.run("""
          var r = LinenAuthor.compose(input);
          return JSON.stringify({ text: LinenCanvasWriter.serialise(r.canvas), notes: r.notes ? JSON.stringify(r.notes, null, "\\t") : null,
            problems: r.problems, members: LinenAuthor.membership(r.canvas) });
        """, spec)
        let problems = composed["problems"] as? [[String: Any]] ?? []
        let errors = problems.filter { $0["severity"] as? String == "error" }
        if !errors.isEmpty {
            return failure("Nothing written; fix these in board and call again:\n" + errors.prefix(30).map { "- \($0["path"] ?? ""): \($0["message"] ?? "")" }.joined(separator: "\n"))
        }
        guard let text = composed["text"] as? String else { throw ToolError(message: "The board author returned nothing.") }
        return try await stageAndCommit(u, text: text, notes: composed["notes"] as? String, removeSidecar: exists, js: js,
                                        members: composed["members"] as? [String: Any] ?? [:], changed: [], args: args,
                                        lead: "\(exists ? "Replaced" : "Wrote") \(u.lastPathComponent)", warnings: problems)
    }

    func editBoardTool(_ args: [String: Any]) async throws -> [String: Any] {
        let u = try file(args, kinds: ["board"])
        guard let ops = args["ops"] as? [Any], !ops.isEmpty else { throw ToolError(message: "Pass ops: a list such as [{op: \"set\", id: \"approve-flow\", word: \"Works\"}].") }
        let text = try Checker.readText(u)
        let sidecarURL = URL(fileURLWithPath: u.path + ".notes.json")
        let sidecar = try? Checker.readText(sidecarURL)
        let js = try BoardJS(renderer: renderer)
        let edited = try js.run("""
          var canvas; try { canvas = JSON.parse(input.text); } catch (e) { return JSON.stringify({ fatal: "The board is not valid JSON: " + e.message + ". Run check_files." }); }
          var notes = null; if (input.sidecar) { try { notes = JSON.parse(input.sidecar); } catch (e) { return JSON.stringify({ fatal: "The notes file is not valid JSON: " + e.message }); } }
          var r = LinenAuthor.edit(canvas, notes, input.ops);
          return JSON.stringify({ text: LinenCanvasWriter.serialise(r.canvas), notes: r.notes ? JSON.stringify(r.notes, null, "\\t") : null,
            changed: r.changed, boardChanged: r.boardChanged, rejected: r.rejected, problems: r.problems,
            members: LinenAuthor.membership(r.canvas), styled: LinenCanvasWriter.isObsidianStyle(input.text) });
        """, ["text": text, "sidecar": sidecar ?? NSNull(), "ops": ops])
        if let fatal = edited["fatal"] as? String { throw ToolError(message: fatal) }
        let problems = edited["problems"] as? [[String: Any]] ?? []
        let changed = edited["changed"] as? [String] ?? []
        let errors = problems.filter { $0["severity"] as? String == "error" }
        // All or nothing: one failing op leaves the board as it was (MCP-5).
        if (edited["rejected"] as? Bool) == true || !errors.isEmpty {
            return failure("Nothing changed; the board is as it was. Fix these ops and call again:\n" + errors.prefix(30).map { "- \($0["path"] ?? ""): \($0["message"] ?? "")" }.joined(separator: "\n"))
        }
        let boardChanged = (edited["boardChanged"] as? Bool) == true
        if changed.isEmpty && !boardChanged { return failure("Nothing changed: the ops matched nothing on the board. Call read_outline for its ids.") }
        guard let out = edited["text"] as? String else { throw ToolError(message: "The board author returned nothing.") }
        var lead = changed.isEmpty ? "Changed the board's settings on \(u.lastPathComponent)"
            : "Changed \(changed.count) box\(changed.count == 1 ? "" : "es") on \(u.lastPathComponent): \(changed.prefix(12).joined(separator: ", "))\(changed.count > 12 ? ", …" : "")"
        if (edited["styled"] as? Bool) == false { lead += ". The file was rewritten once in Obsidian's style" }
        return try await stageAndCommit(u, text: out, notes: edited["notes"] as? String, removeSidecar: false, js: js,
                                        members: edited["members"] as? [String: Any] ?? [:], changed: changed, args: args, lead: lead, warnings: problems)
    }

    /// Writes a board and its notes as one change: both are staged beside their targets first, the old notes are kept
    /// aside, and the renames happen only if the call is still live; if the board's rename fails, the old notes come back.
    /// A board written without notes takes away a notes file left beside it, so stale notes never attach to it.
    private func commitPair(board u: URL, text: String, notes: String?, removeSidecar: Bool) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sidecar = URL(fileURLWithPath: u.path + ".notes.json")
        let tag = UUID().uuidString.prefix(8)
        let stagedBoard = u.deletingLastPathComponent().appendingPathComponent(".\(u.lastPathComponent).linen-\(tag)")
        let stagedNotes = u.deletingLastPathComponent().appendingPathComponent(".\(sidecar.lastPathComponent).linen-\(tag)")
        let keptNotes = u.deletingLastPathComponent().appendingPathComponent(".\(sidecar.lastPathComponent).old-\(tag)")
        defer { try? fm.removeItem(at: stagedBoard); try? fm.removeItem(at: stagedNotes) }
        try Data(text.utf8).write(to: stagedBoard)
        if let notes { try Data(notes.utf8).write(to: stagedNotes) }
        guard deadline?.expired != true else { throw ToolError(message: "Stopped at its deadline before writing; nothing was written.") }
        // A notes path that exists but is not a plain file (a link, a folder) is someone else's; nothing is written.
        var st = stat()
        if lstat(sidecar.path, &st) == 0, (st.st_mode & S_IFMT) != S_IFREG {
            throw ToolError(message: "\(sidecar.lastPathComponent) is not a plain file (a link or a folder), so Linen will not write beside it; nothing was written.")
        }
        // Old notes are always set aside: the new pair replaces them, or a board written without notes drops them.
        let hadNotes = Self.isRegularFile(sidecar)
        _ = removeSidecar
        if hadNotes {
            guard Darwin.rename(sidecar.path, keptNotes.path) == 0 else { throw ToolError(message: "Could not set the old notes file aside; nothing was written.") }
        }
        if notes != nil, Darwin.rename(stagedNotes.path, sidecar.path) != 0 {
            if hadNotes { _ = Darwin.rename(keptNotes.path, sidecar.path) }
            throw ToolError(message: "Could not write the notes file; nothing was written.")
        }
        guard Darwin.rename(stagedBoard.path, u.path) == 0 else {
            try? fm.removeItem(at: sidecar)
            let restored = !hadNotes || Darwin.rename(keptNotes.path, sidecar.path) == 0
            throw ToolError(message: restored ? "Could not write \(u.lastPathComponent); the board and its notes are as they were."
                : "Could not write \(u.lastPathComponent), and the old notes could not be put back: they are in \(keptNotes.lastPathComponent) beside the board.")
        }
        try? fm.removeItem(at: keptNotes)
        deadline?.committed = "Wrote \(u.lastPathComponent)\(notes != nil ? " and its notes" : "")."
    }

    static func isRegularFile(_ u: URL) -> Bool {
        var st = stat()
        return lstat(u.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
    }

    /// Layout, tidy rows and check on the staged text; only a board with no errors replaces the files on disk, and
    /// then the screenshot. Nothing is written when any step fails (MCP-4, MCP-5).
    private func stageAndCommit(_ u: URL, text: String, notes: String?, removeSidecar: Bool, js: BoardJS, members: [String: Any],
                                changed: [String], args: [String: Any], lead: String, warnings: [[String: Any]]) async throws -> [String: Any] {
        let width = (args["width"] as? NSNumber)?.doubleValue ?? 1176
        let h = try await layoutHost()
        let laid = try await Layout.runText(text, sidecar: notes, name: u.lastPathComponent, host: h)
        let reflowed = try js.run("""
          var c = JSON.parse(input.text); var r = LinenAuthor.reflow(c, input.members);
          return JSON.stringify({ moved: r.moved, text: r.moved ? LinenCanvasWriter.serialise(r.canvas) : input.text });
        """, ["text": laid.text, "members": members])
        let final = reflowed["text"] as? String ?? laid.text
        let report = try Checker.boardText(final, sidecar: notes, file: u.path, renderer: renderer)
        let errors = report.problems.filter(\.isError)
        if !errors.isEmpty {
            return failure("Nothing written: the result would not pass check_files. " + errors.prefix(20).map { "\($0.path): \($0.message)" }.joined(separator: "; "))
        }
        try commitPair(board: u, text: final, notes: notes, removeSidecar: removeSidecar)

        var lines = ["\(lead). \(laid.summary)"]
        lines.append("check_files: no errors\(report.problems.isEmpty ? "" : ", \(report.problems.count) warnings").")
        for p in report.problems.prefix(20) { lines.append("  \(p.severity) \(p.path): \(p.message)") }
        for w in warnings.prefix(10) where w["severity"] as? String == "warning" { lines.append("  note \(w["path"] ?? ""): \(w["message"] ?? "")") }
        var extra: [[String: Any]] = []
        let shot = args["shot"] as? String ?? (changed.isEmpty ? "fit" : "changed")
        if shot != "none" {
            let view = shot == "changed" ? (changed.first ?? "fit") : shot
            // The board is written; a screenshot that fails is said, never turned into a failed write.
            do {
                let r = try await shotTool(["path": u.path, "width": width, "view": view])
                if let content = r["content"] as? [[String: Any]] {
                    extra = content.filter { $0["type"] as? String == "image" }
                    if extra.isEmpty, let t = content.first?["text"] as? String { lines.append("No screenshot: \(t)") }
                }
            } catch let e as ToolError {
                lines.append("No screenshot: \(e.message) The board itself is written; call preview_file.")
            } catch {
                lines.append("No screenshot: \(error.localizedDescription). The board itself is written; call preview_file.")
            }
            if !extra.isEmpty { lines.append("Screenshot: \(view == "fit" ? "the whole board" : view) at \(Int(width)) px. Look at it before you hand the board over; use preview_file for other views and 390 px.") }
        }
        lines.append("Show it to Hatim with open_in_linen when it is ready.")
        return ok(lines.joined(separator: "\n"), ["path": u.path, "changed": changed, "errors": 0, "warnings": report.problems.count,
                                                   "layout": laid.structured, "summary": lines[0], "next_action": "preview_file, then open_in_linen"], extra: extra)
    }

}
