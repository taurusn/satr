import AppKit
import Foundation

/// `linen mcp`: Linen for coding agents over the Model Context Protocol (PRD-2 section 6.10), on stdio. One JSON-RPC 2.0
/// message per line on stdin and stdout; logs go to stderr only. The renderer host is made on first use and kept, so a
/// session's later shots and layouts start warm.
@MainActor
final class MCPServer {
    /// Dual era (spec 2026-07-28, basic/versioning): modern requests carry their version in `_meta` and are served
    /// statelessly; a legacy `initialize` selects session semantics for this stdio process.
    static let modernVersions = ["2026-07-28"]
    static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    static let versionKey = "io.modelcontextprotocol/protocolVersion"
    let tools: LinenTools
    /// Requests in flight, by JSON-RPC id, so a cancellation reaches the right one and no answer follows it.
    private var inFlight: [String: Task<Void, Never>] = [:]
    private var cancelled = Set<String>()
    /// The renderer is one page: tool calls take turns at it, while pings, lists and cancellations never wait.
    private let gate = SerialGate()
    static let deadline = 30.0
    private var openTasks = 0
    private var inputEnded = false

    init(renderer: URL) { tools = LinenTools(renderer: renderer) }

    /// Reads stdin on a background thread; each message is handled as it arrives, requests in their own tasks.
    func run() {
        let stream = AsyncStream<String> { cont in
            Thread.detachNewThread {
                while let line = readLine(strippingNewline: true) {
                    if !line.trimmingCharacters(in: .whitespaces).isEmpty { cont.yield(line) }
                }
                cont.finish()
            }
        }
        Task { @MainActor in
            for await line in stream { self.receive(line) }
            self.inputEnded = true
            self.exitWhenIdle()
        }
    }

    private func exitWhenIdle() { if inputEnded && openTasks == 0 { exit(0) } }

    private static func key(_ id: Any) -> String {
        if let n = id as? NSNumber { return "n:\(n.stringValue)" }
        return "s:\(id)"
    }

    private func receive(_ line: String) {
        // A request larger than any board Linen draws (2 MB of text) plus room for a spec is refused unread.
        if line.utf8.count > 8_000_000 {
            send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": "Request too large (over 8 MB)"]])
            return
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
            return
        }
        let id = obj["id"]
        guard obj["jsonrpc"] as? String == "2.0", let method = obj["method"] as? String,
              obj["params"] == nil || obj["params"] is [String: Any] else {
            if let id { send(["jsonrpc": "2.0", "id": id, "error": ["code": -32600, "message": "Invalid Request: expected {jsonrpc: \"2.0\", method, params}"]]) }
            return
        }
        let params = obj["params"] as? [String: Any] ?? [:]
        // Notifications carry no id, get no answer, and are acted on at once.
        guard let id, !(id is NSNull) else {
            if method == "notifications/cancelled", let rid = params["requestId"] {
                let k = Self.key(rid)
                if let t = inFlight[k] { cancelled.insert(k); deadlines[k]?.expired = true; t.cancel() }
            }
            return
        }
        let k = Self.key(id)
        let meta = params["_meta"] as? [String: Any]
        if let v = meta?[Self.versionKey], !(v is String) {
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32600, "message": "Invalid Request: \(Self.versionKey) must be a string"]])
            return
        }
        let modern = meta?[Self.versionKey] as? String
        if let modern, !Self.modernVersions.contains(modern) {
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32022, "message": "Unsupported protocol version",
                                                       "data": ["supported": Self.modernVersions + [Self.legacyVersions[0]], "requested": modern]]])
            return
        }
        openTasks += 1
        let box = Box(id)
        inFlight[k] = Task { @MainActor in
            defer { self.inFlight[k] = nil; self.cancelled.remove(k); self.openTasks -= 1; self.exitWhenIdle() }
            do {
                var result = try await self.dispatch(method, params, modern: modern != nil, key: k, id: box)
                if result[Self.alreadySent] != nil { return }
                // A cancelled request gets no further messages (stdio transport).
                if self.cancelled.contains(k) || Task.isCancelled { return }
                if modern != nil || method == "server/discover" { result["resultType"] = "complete" }
                self.send(["jsonrpc": "2.0", "id": box.value, "result": result])
            } catch let e as RPCError {
                if !self.cancelled.contains(k) { self.send(["jsonrpc": "2.0", "id": box.value, "error": ["code": e.code, "message": e.message]]) }
            } catch {
                if !self.cancelled.contains(k) { self.send(["jsonrpc": "2.0", "id": box.value, "error": ["code": -32603, "message": error.localizedDescription]]) }
            }
        }
    }

    /// Calls that may still be running, by request key: a cancellation or a missed deadline marks them expired, and an
    /// expired call never commits a write (AuthorTools checks before it writes).
    private var deadlines: [String: Deadline] = [:]
    static let alreadySent = "__linen_already_sent"

    /// A tool call: one at a time at the renderer, within the deadline (MCP-1). Past it the answer goes out at once as an
    /// error; the late work is marked expired so it writes nothing, keeps the renderer until it ends (so two calls
    /// never share it), and the renderer is then replaced.
    private func callTool(_ name: String, _ args: [String: Any], key: String, id: Box, modern: Bool) async -> [String: Any] {
        // The deadline counts from arrival, so time spent waiting behind another call counts too (MCP-1).
        let arrived = Date()
        return await gate.run {
            if self.cancelled.contains(key) { return [Self.alreadySent: true] }   // cancelled while waiting: never runs
            let remaining = Self.deadline - Date().timeIntervalSince(arrived)
            if remaining <= 1 {
                var answer = self.tools.failure("\(name) waited \(Int(Self.deadline)) s behind other calls and did not run; nothing was written. Try again.")
                if modern { answer["resultType"] = "complete" }
                return answer
            }
            let deadline = Deadline()
            self.deadlines[key] = deadline
            defer { self.deadlines[key] = nil }
            self.tools.deadline = deadline
            let child = Task { @MainActor in Box(await self.tools.call(name, args)) }
            let flag = Flag()
            let result: Box? = await withCheckedContinuation { (c: CheckedContinuation<Box?, Never>) in
                Task { @MainActor in
                    let r = await child.value
                    if !flag.done { flag.done = true; c.resume(returning: r) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + remaining) {
                    MainActor.assumeIsolated { if !flag.done { flag.done = true; deadline.expired = true; c.resume(returning: nil) } }
                }
            }
            if let r = result?.value as? [String: Any] { return r }
            if !self.cancelled.contains(key) {
                // Say exactly what happened: a write that landed before the deadline is reported, so a retry never repeats it.
                var answer: [String: Any]
                if let done = deadline.committed {
                    answer = self.tools.ok("\(done) Then \(name) ran past \(Int(Self.deadline)) s before its screenshot; the change is written. Do not repeat it; call preview_file to see it.")
                } else {
                    answer = self.tools.failure("\(name) took longer than \(Int(Self.deadline)) s and was stopped; nothing was written. Try once more; if it happens again, preview a smaller part (a section id) or run check_files.")
                }
                if modern { answer["resultType"] = "complete" }
                self.send(["jsonrpc": "2.0", "id": id.value, "result": answer])
            }
            // The late work can no longer write (it is expired); wait for it a bounded time so the renderer is not shared,
            // then retire the renderer either way so a hung page never holds the queue.
            let finished = Flag()
            _ = await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                Task { @MainActor in _ = await child.value; if !finished.done { finished.done = true; c.resume() } }
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { MainActor.assumeIsolated { if !finished.done { finished.done = true; c.resume() } } }
            }
            self.tools.resetRenderer()
            return [Self.alreadySent: true]
        }
    }

    private func dispatch(_ method: String, _ params: [String: Any], modern: Bool, key: String, id: Box) async throws -> [String: Any] {
        // Lists and the guide change only with a new Linen, so modern clients may cache them for the session.
        let cache: [String: Any] = modern ? ["ttlMs": 3_600_000, "cacheScope": "private"] : [:]
        switch method {
        case "server/discover":
            return [
                "supportedVersions": Self.modernVersions + [Self.legacyVersions[0]],
                "capabilities": ["tools": [:], "resources": [:]],
                "_meta": ["io.modelcontextprotocol/serverInfo": ["name": "linen", "title": "Linen", "version": LinenTools.version]],
                "instructions": LinenTools.instructions,
                "ttlMs": 3_600_000, "cacheScope": "private",
            ]
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? Self.legacyVersions[0]
            let version = Self.legacyVersions.contains(asked) ? asked : Self.legacyVersions[0]
            return [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false], "resources": ["listChanged": false, "subscribe": false]],
                "serverInfo": ["name": "linen", "title": "Linen", "version": LinenTools.version],
                "instructions": LinenTools.instructions,
            ]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": LinenTools.allDefinitions].merging(cache) { a, _ in a }
        case "tools/call":
            guard let name = params["name"] as? String else { throw RPCError(code: -32602, message: "tools/call needs a name") }
            guard LinenTools.allDefinitions.contains(where: { $0["name"] as? String == name }) else {
                throw RPCError(code: -32602, message: "Unknown tool \(name). Linen's tools: \(LinenTools.allDefinitions.compactMap { $0["name"] as? String }.joined(separator: ", "))")
            }
            if let a = params["arguments"], !(a is [String: Any]) { throw RPCError(code: -32602, message: "arguments must be an object") }
            let args = params["arguments"] as? [String: Any] ?? [:]
            return await callTool(name, args, key: key, id: id, modern: modern)
        case "resources/list":
            return ["resources": LinenTools.resourceList].merging(cache) { a, _ in a }
        case "resources/read":
            guard let uri = params["uri"] as? String, let r = LinenTools.readResource(uri) else { throw RPCError(code: -32002, message: "Resource not found") }
            return ["contents": [r]].merging(cache) { a, _ in a }
        case "resources/templates/list":
            return ["resourceTemplates": []]
        case "prompts/list":
            return ["prompts": []]
        default:
            throw RPCError(code: -32601, message: "Method not found: \(method)")
        }
    }

    private func send(_ msg: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: msg, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }
}

struct RPCError: Error {
    let code: Int
    let message: String
}

/// A JSON value crossing a continuation; only ever touched on the main actor.
struct Box: @unchecked Sendable {
    let value: Any
    init(_ v: Any) { value = v }
}

@MainActor
final class Flag { var done = false }

/// Set when a call is cancelled or misses its deadline; the call's writes check it last thing before they happen.
/// `committed` is set the moment a write lands, so a timeout after it reports the write, not "nothing was written".
@MainActor
final class Deadline {
    var expired = false
    var committed: String?
}

/// Runs async work one piece at a time, in arrival order.
@MainActor
final class SerialGate {
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func run<T>(_ body: () async -> T) async -> T {
        if busy { await withCheckedContinuation { waiting.append($0) } }
        busy = true
        let out = await body()
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
        return out
    }
}
