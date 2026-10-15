import AppKit

/// What Hatim has open in Linen, for agents (MCP-9): the front tab, the other tabs, and on a board the selected node, the
/// node in view and how many changes he has not seen. Written to `~/Library/Application Support/Linen/now.json`, local
/// only, debounced, atomically; `linen mcp` reads it. Nothing is written about a document's text.
@MainActor
enum NowState {
    private static var pending: DispatchWorkItem?

    static var file: URL { Library.shared.support.appendingPathComponent("now.json") }

    /// Schedules a write 300 ms after the last change, so a gesture or a burst of tab changes writes once.
    static func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { write(running: true) } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    static func write(running: Bool) {
        let docs = NSApp.orderedWindows.compactMap { $0.windowController as? DocumentWindow }
        let key = NSApp.keyWindow?.windowController as? DocumentWindow ?? docs.first
        func entry(_ d: DocumentWindow) -> [String: Any] {
            var e: [String: Any] = ["path": d.url.path, "kind": "\(d.kind)", "title": d.window?.title ?? d.url.lastPathComponent]
            if let v = d.lastView { e["view"] = v }
            return e
        }
        var state: [String: Any] = ["running": running, "updated": ISO8601DateFormatter().string(from: Date()), "pid": ProcessInfo.processInfo.processIdentifier]
        if running {
            if let key { state["front"] = entry(key) }
            state["tabs"] = docs.map(entry)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
