import Foundation
import JavaScriptCore
import LinenKit

/// One thing `linen check` found (CLI-1's JSON shape).
struct Problem: Codable {
    var severity: String   // "error" or "warning"
    var path: String       // JSON path for boards, "" for notes and pages
    var line: Int?
    var message: String

    var isError: Bool { severity == "error" }
}

struct FileReport: Codable {
    var file: String
    var problems: [Problem]
    /// Said once for a page with scripts: the check cannot see references a script builds (CLI-2).
    var note: String?
}

enum Checker {
    /// Runs the renderer's own board model (`board-model.js`) in JavaScriptCore, so `check` agrees with what Linen draws
    /// and needs no WebKit, window or network.
    static func board(_ file: URL, renderer: URL) throws -> FileReport {
        let text = try readText(file)
        let sidecar = try? readText(URL(fileURLWithPath: file.path + ".notes.json"))
        return try boardText(text, sidecar: sidecar, file: file.path, renderer: renderer)
    }

    /// The same check on text not yet written, so a board is checked before it replaces anything (MCP-4, MCP-5).
    static func boardText(_ text: String, sidecar: String?, file: String, renderer: URL) throws -> FileReport {
        guard let ctx = JSContext() else { throw CLIError.renderer("JavaScriptCore did not start") }
        var thrown: String?
        ctx.exceptionHandler = { _, e in thrown = e?.toString() }
        ctx.evaluateScript("var self = this; var globalThis = this;")
        let model = try String(contentsOf: renderer.appendingPathComponent("board-model.js"), encoding: .utf8)
        ctx.evaluateScript(model, withSourceURL: renderer.appendingPathComponent("board-model.js"))
        if let thrown { throw CLIError.renderer("board-model.js: \(thrown)") }
        ctx.setObject(text, forKeyedSubscript: "__text" as NSString)
        ctx.setObject(sidecar as Any? ?? NSNull(), forKeyedSubscript: "__sidecar" as NSString)
        let json = ctx.evaluateScript("""
          (function () {
            var b = LinenCanvas.parse(__text, { sidecarText: __sidecar });
            var list = LinenCanvas.check ? LinenCanvas.check(b) : (b.fatal ? b.fatal.problems : b.problems);
            return JSON.stringify(list || []);
          })()
        """)?.toString() ?? "[]"
        if let thrown { throw CLIError.renderer("board check: \(thrown)") }
        let raw = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] ?? []
        let problems = raw.map { p in
            Problem(severity: (p["severity"] as? String) == "warning" ? "warning" : "error", path: p["path"] as? String ?? "",
                    line: (p["line"] as? NSNumber)?.intValue, message: p["message"] as? String ?? "")
        }
        return FileReport(file: file, problems: problems, note: nil)
    }

    /// Notes: wiki links and embeds that resolve to nothing, local links and images that are not there, and Loom blocks
    /// whose YAML does not read (when the renderer's block module offers a check).
    static func note(_ file: URL, renderer: URL) async throws -> FileReport {
        let text = try readText(file)
        // Names only: the check reads no file but the one given (MCP-13). Aliases are not resolved, so an alias link
        // that finds no file is a warning that says so.
        let names = NameIndex(root: VaultLocator.vault(for: file).root)
        var problems: [Problem] = []
        var inFence = false
        var fence = ""
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = i + 1
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let mark = String(trimmed.prefix(3))
                if !inFence { inFence = true; fence = mark } else if trimmed.hasPrefix(fence) { inFence = false }
                continue
            }
            if inFence { continue }
            for target in matches(#"!?\[\[([^\]\|#\^]+)"#, in: raw) {
                let t = target.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { continue }
                if !names.has(t) {
                    problems.append(Problem(severity: "warning", path: "", line: line, message: "No note or file called \(t) (aliases are not checked)"))
                }
            }
            for target in matches(#"!?\[[^\]]*\]\(([^)\s]+)"#, in: raw) {
                if target.contains("://") || target.hasPrefix("#") || target.hasPrefix("mailto:") { continue }
                let clean = (target.removingPercentEncoding ?? target).split(separator: "#", maxSplits: 1).first.map(String.init) ?? target
                let dest = clean.hasPrefix("/") ? URL(fileURLWithPath: clean) : file.deletingLastPathComponent().appendingPathComponent(clean)
                if !FileManager.default.fileExists(atPath: dest.path) {
                    problems.append(Problem(severity: "warning", path: "", line: line, message: "Nothing at \(clean)"))
                }
            }
        }
        problems += blockProblems(text, sidecar: try? readText(URL(fileURLWithPath: file.path + ".notes.json")), renderer: renderer)
        if names.truncated, problems.contains(where: { $0.message.hasPrefix("No note or file called") }) {
            problems.append(Problem(severity: "warning", path: "", line: nil, message: "The link check stopped after 50,000 files in this folder tree; a link reported missing may point past that."))
        }
        return FileReport(file: file.path, problems: problems, note: nil)
    }

    /// Loom blocks (BLK): the renderer's `blocks.js` may export `LinenBlocks.check(source)` returning problems with lines.
    static func blockProblems(_ text: String, sidecar: String?, renderer: URL) -> [Problem] {
        let file = renderer.appendingPathComponent("blocks.js")
        guard let src = try? String(contentsOf: file, encoding: .utf8), let ctx = JSContext() else { return [] }
        var thrown: String?
        ctx.exceptionHandler = { _, e in thrown = e?.toString() }
        ctx.evaluateScript("var self = this; var globalThis = this; var window = this;")
        ctx.evaluateScript(src, withSourceURL: file)
        ctx.setObject(text, forKeyedSubscript: "__text" as NSString)
        ctx.setObject(sidecar as Any? ?? NSNull(), forKeyedSubscript: "__sidecar" as NSString)
        let json = ctx.evaluateScript("(self.LinenBlocks && LinenBlocks.check) ? JSON.stringify(LinenBlocks.check(__text, __sidecar)) : '[]'")?.toString() ?? "[]"
        if thrown != nil { return [] }
        let raw = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] ?? []
        return raw.map { Problem(severity: ($0["severity"] as? String) == "warning" ? "warning" : "error", path: "", line: ($0["line"] as? NSNumber)?.intValue, message: $0["message"] as? String ?? "") }
    }

    /// Pages, statically (CLI-2): references written in the HTML that a sealed page will refuse: anything off the page's
    /// own folder (web addresses, other schemes, `file:`, paths that climb out) and sibling files that are not there.
    static func page(_ file: URL) throws -> FileReport {
        let text = try readText(file)
        let folder = file.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        var problems: [Problem] = []
        let lines = text.components(separatedBy: "\n")
        let patterns = [#"(?:src|href|action|poster|data)\s*=\s*["']([^"']+)["']"#, #"url\(\s*["']?([^"')]+)["']?\s*\)"#, #"@import\s+["']([^"']+)["']"#]
        for (i, raw) in lines.enumerated() {
            for p in patterns {
                for ref in matches(p, in: raw) {
                    let r = ref.trimmingCharacters(in: .whitespaces)
                    if r.isEmpty || r.hasPrefix("#") || r.hasPrefix("data:") || r.hasPrefix("blob:") || r.hasPrefix("javascript:") || r.hasPrefix("about:") { continue }
                    if r.hasPrefix("linen-kit:") { continue }
                    let lower = r.lowercased()
                    if lower.hasPrefix("http:") || lower.hasPrefix("https:") || lower.hasPrefix("//") {
                        // Links (href on <a>) open in the browser after Linen asks; loads are refused.
                        let isLink = raw.range(of: #"<a\s[^>]*href\s*=\s*["']"# + NSRegularExpression.escapedPattern(for: r), options: .regularExpression) != nil
                        if !isLink { problems.append(Problem(severity: "error", path: "", line: i + 1, message: "A sealed page cannot load \(r): pages reach nothing off their folder")) }
                        continue
                    }
                    if let colon = r.firstIndex(of: ":"), r[..<colon].allSatisfy({ $0.isLetter || $0 == "+" || $0 == "-" || $0 == "." }), r.distance(from: r.startIndex, to: colon) > 1 {
                        let isLink = raw.range(of: #"<a\s"#, options: .regularExpression) != nil
                        problems.append(Problem(severity: isLink ? "warning" : "error", path: "", line: i + 1, message: "\(r[..<colon]): links are refused in sealed pages"))
                        continue
                    }
                    let clean = (r.removingPercentEncoding ?? r).split(separator: "?").first.map(String.init) ?? r
                    let pathOnly = clean.split(separator: "#").first.map(String.init) ?? clean
                    if pathOnly.isEmpty { continue }
                    let dest = (pathOnly.hasPrefix("/") ? URL(fileURLWithPath: pathOnly) : file.deletingLastPathComponent().appendingPathComponent(pathOnly))
                        .resolvingSymlinksInPath().standardizedFileURL
                    if !dest.path.hasPrefix(folder.path + "/") {
                        problems.append(Problem(severity: "error", path: "", line: i + 1, message: "\(pathOnly) is outside the page's folder; a sealed page cannot reach it"))
                    } else if !FileManager.default.fileExists(atPath: dest.path) {
                        problems.append(Problem(severity: "warning", path: "", line: i + 1, message: "Nothing at \(pathOnly)"))
                    }
                }
            }
        }
        let hasScripts = text.range(of: #"<script\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        return FileReport(file: file.path, problems: problems,
                          note: hasScripts ? "Static check only: this page has scripts, and references a script builds are not seen here." : nil)
    }

    static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return TextDecoder.decode(data, override: nil).text
    }

    static func matches(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            m.numberOfRanges > 1 && m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)) : nil
        }
    }
}

/// File names under a vault or repository, for resolving wiki links without reading any file (at most 50,000 entries;
/// hidden folders, `node_modules` and `build` are skipped).
struct NameIndex {
    private var names = Set<String>()     // lowercased file names, and names without .md
    private var tails = Set<String>()     // lowercased relative paths, and without .md
    /// True when the walk stopped at its limit: a link reported missing may then be a file it did not reach.
    private(set) var truncated = false

    init(root: URL) {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        var seen = 0
        let base = root.standardizedFileURL.path
        while let u = e.nextObject() as? URL {
            seen += 1
            if seen > 50_000 { truncated = true; break }
            if ["node_modules", "build", "DerivedData"].contains(u.lastPathComponent) { e.skipDescendants(); continue }
            // Files only: a folder called Plans is not a note called Plans.
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let name = u.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
            names.insert(name)
            if name.hasSuffix(".md") { names.insert(String(name.dropLast(3))) }
            let rel = String(u.standardizedFileURL.path.dropFirst(base.count + 1)).precomposedStringWithCanonicalMapping.lowercased()
            tails.insert(rel)
            if rel.hasSuffix(".md") { tails.insert(String(rel.dropLast(3))) }
        }
    }

    /// True when a wiki-link target names a file: by name (`Note`, `image.png`) or by path (`folder/Note`).
    func has(_ target: String) -> Bool {
        let t = target.precomposedStringWithCanonicalMapping.lowercased().trimmingCharacters(in: .whitespaces)
        if t.contains("/") { return tails.contains(t) || tails.contains(where: { $0.hasSuffix("/" + t) }) }
        return names.contains(t)
    }
}

enum CLIError: Error {
    case usage(String)
    case renderer(String)
}
