import AppKit
import Foundation

// linen: Linen's agent kit (PRD-2 section 6.7). An agent writes a board, a note or a page, then checks it, lays it out,
// shoots it at phone and laptop widths in both looks, and opens it in Linen, with no browser in the loop.
//
//   linen check <file>... [--json]
//   linen layout <file.canvas> [--json]
//   linen shot <file> [--width 390|1176|1440] [--theme paper|night] [--view fit|<node id>] [--full] [--out file.png]
//   linen open <file> [--line n | --node id] [--focus]
//
// Exit status: 0 clean, 1 problems found, 2 bad usage, 3 the renderer failed or timed out. Needs no network; writes only
// the target file (layout) and --out paths.

let usage = """
usage: linen check <file>... [--json]
       linen layout <file.canvas> [--json]
       linen shot <file> [--width 390|1176|1440] [--theme paper|night] [--view fit|<node id>] [--full] [--out file.png]
       linen open <file> [--line n | --node id] [--focus]
       linen mcp            (Model Context Protocol server on stdio, for coding agents)
"""

let argv = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let i = argv.firstIndex(of: name), i + 1 < argv.count else { return nil }
    return argv[i + 1]
}

func has(_ name: String) -> Bool { argv.contains(name) }

/// Arguments that are not options or option values.
func positional() -> [String] {
    var out: [String] = []
    var skip = false
    let valued: Set<String> = ["--width", "--theme", "--view", "--out", "--line", "--node", "--height"]
    for a in argv.dropFirst() {
        if skip { skip = false; continue }
        if valued.contains(a) { skip = true; continue }
        if a.hasPrefix("--") { continue }
        out.append(a)
    }
    return out
}

func fileURL(_ path: String) -> URL {
    let expanded = (path as NSString).expandingTildeInPath
    let u = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(expanded)
    return u.standardizedFileURL
}

func fail(_ code: Int32, _ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func printReport(_ r: FileReport, json: Bool) {
    if json {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let d = try? enc.encode(r), let s = String(data: d, encoding: .utf8) { print(s) }
        return
    }
    let errors = r.problems.filter(\.isError).count, warnings = r.problems.count - errors
    print(r.problems.isEmpty ? "\(r.file): no problems" : "\(r.file): \(errors) error\(errors == 1 ? "" : "s"), \(warnings) warning\(warnings == 1 ? "" : "s")")
    for p in r.problems {
        let at = [p.line.map { "line \($0)" }, p.path.isEmpty ? nil : p.path].compactMap { $0 }.joined(separator: ", ")
        print("  \(p.severity): \(at.isEmpty ? "" : at + ": ")\(p.message)")
    }
    if let n = r.note { print("  \(n)") }
}

enum Kind { case note, board, page }

func kind(of u: URL) -> Kind? {
    switch u.pathExtension.lowercased() {
    case "md", "markdown", "mdown", "mkd", "txt": .note
    case "canvas": .board
    case "html", "htm": .page
    default: nil
    }
}

/// Unknown options and bad values are usage errors (exit 2), never silently a default.
func strictOptions(_ cmd: String) {
    let allowed: [String: Set<String>] = [
        "check": ["--json"], "layout": ["--json"], "mcp": [],
        "shot": ["--width", "--height", "--theme", "--view", "--out", "--full"],
        "open": ["--line", "--node", "--focus"],
    ]
    guard let ok = allowed[cmd] else { return }
    for a in argv.dropFirst() where a.hasPrefix("--") && !ok.contains(a) { fail(2, "linen \(cmd): unknown option \(a)\n" + usage) }
    var seen = Set<String>()
    for a in argv.dropFirst() where a.hasPrefix("--") {
        if seen.contains(a) { fail(2, "linen \(cmd): \(a) given twice") }
        seen.insert(a)
    }
    if ["layout", "shot", "open"].contains(cmd), positional().count > 1 { fail(2, "linen \(cmd) takes one file\n" + usage) }
    if let w = option("--width"), !["390", "1176", "1440"].contains(w) { fail(2, "linen: --width is 390, 1176 or 1440") }
    if let t = option("--theme"), !["paper", "night"].contains(t) { fail(2, "linen: --theme is paper or night") }
    if let l = option("--line"), Int(l) == nil { fail(2, "linen: --line takes a line number") }
    if let h = option("--height"), Double(h) == nil { fail(2, "linen: --height takes a number of pixels") }
    for o in ["--width", "--theme", "--view", "--out", "--line", "--node", "--height"] where has(o) && option(o) == nil { fail(2, "linen: \(o) needs a value") }
}

@MainActor
func run() async -> Int32 {
    guard let cmd = argv.first else { fail(2, usage) }
    strictOptions(cmd)
    let json = has("--json")
    switch cmd {
    case "check":
        let files = positional()
        guard !files.isEmpty else { fail(2, usage) }
        guard let renderer = Locate.renderer else { fail(3, "linen: cannot find Linen's renderer (is Linen.app installed?)") }
        var found = false
        for f in files {
            let u = fileURL(f)
            guard FileManager.default.fileExists(atPath: u.path) else { fail(2, "linen: no file at \(u.path)") }
            do {
                let r: FileReport
                switch kind(of: u) {
                case .board: r = try Checker.board(u, renderer: renderer)
                case .note: r = try await Checker.note(u, renderer: renderer)
                case .page: r = try Checker.page(u)
                case nil: fail(2, "linen: \(u.lastPathComponent) is not a note, board or page")
                }
                if r.problems.contains(where: \.isError) { found = true }
                printReport(r, json: json)
            } catch CLIError.renderer(let why) {
                fail(3, "linen: \(why)")
            } catch {
                fail(2, "linen: cannot read \(u.path): \(error.localizedDescription)")
            }
        }
        return found ? 1 : 0

    case "layout":
        guard let f = positional().first else { fail(2, usage) }
        let u = fileURL(f)
        guard kind(of: u) == .board else { fail(2, "linen: layout takes a .canvas board") }
        guard let renderer = Locate.renderer else { fail(3, "linen: cannot find Linen's renderer") }
        guard FileManager.default.fileExists(atPath: u.path) else { fail(2, "linen: no file at \(u.path)") }
        let host = RendererHost(renderer: renderer, width: 1176, height: 900)
        guard await host.open() else { fail(3, "linen: the renderer did not start") }
        // Layout runs in the renderer with Linen's own fonts and card styles (BRD-17, CLI-3): measure, place, then patch
        // only the numbers it changed into the file's own text.
        let r: Layout.Result
        do { r = try await Layout.run(u, host: host) } catch let e as LinenTools.ToolError { fail(3, "linen: \(e.message)") } catch { fail(3, "linen: \(error.localizedDescription)") }
        let overflow = r.structured["overflow"] as? [String] ?? []
        let problems = overflow.map { Problem(severity: "error", path: "$.nodes[id=\($0)]", line: nil, message: "Text still does not fit its card after layout") }
        printReport(FileReport(file: u.path, problems: problems, note: r.summary), json: json)
        return problems.isEmpty ? 0 : 1

    case "shot":
        guard let f = positional().first else { fail(2, usage) }
        let u = fileURL(f)
        guard let k = kind(of: u) else { fail(2, "linen: shot takes a note, board or page") }
        guard let renderer = Locate.renderer else { fail(3, "linen: cannot find Linen's renderer") }
        let width = Double(option("--width") ?? "1176") ?? 1176
        let height = Double(option("--height") ?? (width <= 500 ? "844" : "900")) ?? 900
        let theme = option("--theme") == "night" ? "night" : "paper"
        let out = fileURL(option("--out") ?? (u.deletingPathExtension().lastPathComponent + "-\(Int(width))-\(theme).png"))
        if k == .page { fail(3, "linen: page shots arrive with sealed pages (M9)") }
        guard let text = try? Checker.readText(u) else { fail(2, "linen: cannot read \(u.path)") }
        let sidecar = k == .board ? try? Checker.readText(URL(fileURLWithPath: u.path + ".notes.json")) : nil
        let host = RendererHost(renderer: renderer, width: width, height: height)
        let deadline = DispatchTime.now() + 30
        DispatchQueue.main.asyncAfter(deadline: deadline) { fail(3, "linen: shot timed out after 30 s") }
        guard await host.open() else { fail(3, "linen: the renderer did not start") }
        guard await host.load(u, text: text, sidecar: sidecar, theme: theme) else {
            fail(3, "linen: \(u.lastPathComponent) did not render\(host.consoleErrors.isEmpty ? "" : ": " + host.consoleErrors.prefix(2).joined(separator: " | "))")
        }
        if k == .board {
            if let v = option("--view"), v != "fit" { _ = await host.command("goNode", ["id": v]) } else if option("--view") == "fit" { _ = await host.command("fit") }
            _ = await host.command("settled")
        }
        guard let png = await host.snapshot(fullHeight: has("--full") && k == .note) else { fail(3, "linen: snapshot failed") }
        do { try png.write(to: out) } catch { fail(2, "linen: cannot write \(out.path)") }
        print(out.path)
        if !host.consoleErrors.isEmpty { FileHandle.standardError.write(Data(("console: " + host.consoleErrors.prefix(3).joined(separator: " | ") + "\n").utf8)) }
        return 0

    case "open":
        guard let f = positional().first else { fail(2, usage) }
        let u = fileURL(f)
        guard kind(of: u) != nil else { fail(2, "linen: Linen opens notes, boards and pages") }
        guard FileManager.default.fileExists(atPath: u.path) else { fail(2, "linen: no file at \(u.path)") }
        if let n = option("--node"), let renderer = Locate.renderer {
            guard kind(of: u) == .board else { fail(2, "linen: --node is for boards; use --line for a note") }
            let text = (try? Checker.readText(u)) ?? ""
            let m = (try? BoardReader.model(text, sidecar: try? Checker.readText(URL(fileURLWithPath: u.path + ".notes.json")), renderer: renderer)) ?? [:]
            guard (m["nodes"] as? [[String: Any]] ?? []).contains(where: { $0["id"] as? String == n }) else {
                fail(1, "linen: there is no box \"\(n)\" on \(u.lastPathComponent)")
            }
        }
        var comps = URLComponents()
        comps.scheme = "linen"
        comps.host = "open"
        var items = [URLQueryItem(name: "path", value: u.path)]
        if let n = option("--node") { items.append(URLQueryItem(name: "node", value: n)) }
        if let l = option("--line") { items.append(URLQueryItem(name: "line", value: l)) }
        if has("--focus") { items.append(URLQueryItem(name: "focus", value: "1")) }
        comps.queryItems = items
        guard let link = comps.url, let app = Locate.appBundle else { fail(3, "linen: cannot find Linen.app") }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = has("--focus")
        config.addsToRecentItems = false
        do { _ = try await NSWorkspace.shared.open([link], withApplicationAt: app, configuration: config) } catch { fail(3, "linen: could not open Linen: \(error.localizedDescription)") }
        return 0

    case "mcp":
        // Linen for coding agents (MCP rows): the server lives as long as its client keeps stdin open.
        guard let renderer = Locate.renderer else { fail(3, "linen: cannot find Linen's renderer (is Linen.app installed?)") }
        let server = MCPServer(renderer: renderer)
        server.run()
        return -1

    case "--help", "-h", "help":
        print(usage)
        return 0

    default:
        fail(2, usage)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    let code = await run()
    if code >= 0 { exit(code) }   // -1: a long-lived command (mcp) keeps the run loop going
}
app.run()
