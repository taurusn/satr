// Protocol tests for `linen mcp` (PRD-2 MCP-1, MCP-3, MCP-12): node Tests/mcp.test.js [path/to/linen]
// Talks to the real command over stdio in both protocol eras and checks every line it writes.
"use strict";
const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");
const os = require("os");

const bin = process.argv[2] || path.join(__dirname, "..", "build/DerivedData/Build/Products/Debug/Linen.app/Contents/Helpers/linen");
const fixtures = path.join(__dirname, "Fixtures", "boards");
let pass = 0, fail = 0;
const ok = (name, cond, detail) => { if (cond) pass++; else { fail++; console.log("FAIL " + name + (detail ? ": " + detail : "")); } };

function session(messages) {
  return new Promise((resolve) => {
    const p = spawn(bin, ["mcp"], { stdio: ["pipe", "pipe", "pipe"] });
    let out = "";
    p.stdout.on("data", (d) => (out += d));
    p.on("close", (code) => {
      const lines = out.split("\n").filter((l) => l.length);
      const parsed = lines.map((l) => { try { return JSON.parse(l); } catch (_) { return { unparsed: l }; } });
      resolve({ code, lines, parsed, byId: new Map(parsed.filter((m) => m.id != null).map((m) => [m.id, m])) });
    });
    for (const m of messages) p.stdin.write(JSON.stringify(m) + "\n");
    p.stdin.end();
  });
}

(async () => {
  const modern = (id, method, params = {}) => ({ jsonrpc: "2.0", id, method, params: { ...params, _meta: { "io.modelcontextprotocol/protocolVersion": "2026-07-28" } } });
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "linen-mcp-"));
  const board = path.join(tmp, "t.canvas");

  // Legacy era.
  const a = await session([
    { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "t", version: "0" } } },
    { jsonrpc: "2.0", method: "notifications/initialized" },
    { jsonrpc: "2.0", id: 2, method: "tools/list" },
    { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "nope", arguments: {} } },
    { jsonrpc: "2.0", id: 4, method: "tools/call", params: { name: "check_files", arguments: {} } },
    { jsonrpc: "2.0", id: 5, method: "tools/call", params: { name: "check_files", arguments: { paths: [path.join(fixtures, "invalid-dangling.canvas")] } } },
    { jsonrpc: "2.0", id: 6, method: "ping" },
    { jsonrpc: "2.0", id: 7, method: "nope/method" },
    { jsonrpc: "2.0", id: 8, method: "initialize", params: { protocolVersion: "1999-01-01", capabilities: {}, clientInfo: { name: "t", version: "0" } } },
    { jsonrpc: "2.0", id: 9, method: "resources/read", params: { uri: "linen://guide/board" } },
    { jsonrpc: "2.0", id: 10, method: "tools/call", params: { name: "write_board", arguments: { path: board, board: { title: "T", sections: [{ id: "s", title: "S", cards: [{ id: "a", title: "A", word: "Works" }, { id: "b", title: "B", body: "Two words." }] }], edges: [{ from: "a", to: "b" }] }, shot: "none" } } },
    { jsonrpc: "2.0", id: 11, method: "tools/call", params: { name: "write_board", arguments: { path: board, board: { sections: [{ title: "S", cards: [{ id: "x" }] }] } } } },
    { jsonrpc: "2.0", id: 12, method: "tools/call", params: { name: "edit_board", arguments: { path: board, ops: [{ op: "set", id: "a", word: "Broken" }], shot: "none" } } },
    { jsonrpc: "2.0", id: 13, method: "tools/call", params: { name: "read_outline", arguments: { path: board } } },
    { jsonrpc: "2.0", id: 14, method: "tools/call", params: { name: "edit_board", arguments: { path: board, ops: [{ op: "set", id: "ghost", word: "Works" }] } } },
  ]);
  ok("stdin end closes the server", a.code === 0, "code " + a.code);
  ok("every stdout line is JSON-RPC", a.parsed.every((m) => m.jsonrpc === "2.0"), a.lines.find((l) => !l.startsWith("{")));
  ok("notifications get no answer", a.parsed.length === 14, "lines " + a.parsed.length);
  ok("initialize echoes a supported version", a.byId.get(1).result.protocolVersion === "2025-06-18");
  ok("initialize carries instructions under 4,096 chars", (a.byId.get(1).result.instructions || "").length > 200 && a.byId.get(1).result.instructions.length < 4096);
  const tools = a.byId.get(2).result.tools;
  ok("nine tools in a fixed order", tools.map((t) => t.name).join(",") === "format_guide,write_board,edit_board,check_files,preview_file,open_in_linen,get_reader_state,read_outline,layout_board", tools.map((t) => t.name).join(","));
  ok("every tool has a title, annotations and an object schema", tools.every((t) => t.title && t.annotations && t.inputSchema && t.inputSchema.type === "object"));
  ok("every description is under 1,600 chars and has an example", tools.every((t) => t.description.length < 1600 && /Example:/.test(t.description)), tools.filter((t) => t.description.length >= 1600 || !/Example:/.test(t.description)).map((t) => t.name + " " + t.description.length).join(", "));
  ok("read-only tools are marked so", ["format_guide", "check_files", "preview_file", "get_reader_state", "read_outline"].every((n) => tools.find((t) => t.name === n).annotations.readOnlyHint === true));
  ok("an unknown tool is a protocol error", a.byId.get(3).error && a.byId.get(3).error.code === -32602);
  ok("bad arguments are a tool error that says what to pass", a.byId.get(4).result.isError === true && /Pass paths/.test(a.byId.get(4).result.content[0].text));
  const chk = a.byId.get(5).result;
  ok("a file with problems is a successful check", chk.isError === false && chk.structuredContent.clean === false && chk.structuredContent.files[0].errors === 3);
  ok("ping answers", a.byId.get(6).result && Object.keys(a.byId.get(6).result).length === 0);
  ok("an unknown method is -32601", a.byId.get(7).error.code === -32601);
  ok("an unknown legacy version gets one the server supports", a.byId.get(8).result.protocolVersion === "2025-11-25");
  ok("the guide resource reads", /## Boards/.test(a.byId.get(9).result.contents[0].text));
  const w = a.byId.get(10).result;
  ok("write_board writes a clean board", w.isError === false && fs.existsSync(board) && /no errors/.test(w.content[0].text), w.content[0].text.slice(0, 300));
  ok("write_board refuses to overwrite without replace", a.byId.get(11).result.isError === true && /already exists/.test(a.byId.get(11).result.content[0].text));
  const e = a.byId.get(12).result;
  ok("edit_board changes one box", e.isError === false && /Changed 1 box/.test(e.content[0].text), e.content[0].text.slice(0, 200));
  const r = a.byId.get(13).result;
  ok("read_outline lists the boxes with words", r.structuredContent.boxes.some((b) => b.id === "a" && b.word === "Broken"));
  ok("an unknown box id says where ids come from", a.byId.get(14).result.isError === true && /read_outline/.test(a.byId.get(14).result.content[0].text));

  // Review m8: malformed requests, cancellation, and a ping that never waits behind a render.
  const c = await session([
    { id: 1, method: "ping" },
    { jsonrpc: "2.0", id: 2, method: "tools/list", params: { _meta: { "io.modelcontextprotocol/protocolVersion": 7 } } },
    { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "preview_file", arguments: { path: path.join(fixtures, "kinds.canvas") } } },
    { jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 3 } },
    { jsonrpc: "2.0", id: 4, method: "ping" },
    { jsonrpc: "2.0", id: 5, method: "tools/call", params: { name: "preview_file", arguments: { path: path.join(fixtures, "kinds.canvas"), view: "no-such-box" } } },
    { jsonrpc: "2.0", id: 6, method: "tools/call", params: { name: "check_files", arguments: { paths: new Array(21).fill(path.join(fixtures, "kinds.canvas")) } } },
    { jsonrpc: "2.0", id: 7, method: "tools/call", params: { name: "check_files", arguments: "not an object" } },
  ]);
  ok("a request without jsonrpc 2.0 is -32600", c.byId.get(1) && c.byId.get(1).error && c.byId.get(1).error.code === -32600);
  ok("a non-string protocol version is -32600", c.byId.get(2).error && c.byId.get(2).error.code === -32600);
  ok("a cancelled call gets no answer", !c.byId.has(3));
  ok("ping is answered while a render is cancelled", c.byId.get(4) && c.byId.get(4).result);
  ok("an unknown view id points to read_outline", c.byId.get(5).result.isError === true && /read_outline/.test(c.byId.get(5).result.content[0].text));
  ok("more than 20 paths is refused with the limit", c.byId.get(6).result.isError === true && /at most 20/.test(c.byId.get(6).result.content[0].text));
  ok("arguments that are not an object are -32602", c.byId.get(7).error && c.byId.get(7).error.code === -32602);

  // Modern era.
  const b = await session([
    { jsonrpc: "2.0", id: 1, method: "server/discover", params: {} },
    modern(2, "tools/list"),
    modern(3, "tools/call", { name: "read_outline", arguments: { path: path.join(fixtures, "big-500.canvas"), limit: 3 } }),
    { jsonrpc: "2.0", id: 4, method: "tools/list", params: { _meta: { "io.modelcontextprotocol/protocolVersion": "1900-01-01" } } },
  ]);
  const d = b.byId.get(1).result;
  ok("server/discover lists both eras", JSON.stringify(d.supportedVersions) === JSON.stringify(["2026-07-28", "2025-11-25"]));
  ok("server/discover carries serverInfo in _meta and resultType", d._meta["io.modelcontextprotocol/serverInfo"].name === "linen" && d.resultType === "complete");
  ok("modern tools/list carries resultType, ttlMs and cacheScope", b.byId.get(2).result.resultType === "complete" && b.byId.get(2).result.ttlMs > 0 && b.byId.get(2).result.cacheScope === "private");
  ok("modern tools/call is complete and pages", b.byId.get(3).result.resultType === "complete" && /call again with offset 3/.test(b.byId.get(3).result.content[0].text));
  ok("an unsupported modern version is -32022 with the list", b.byId.get(4).error.code === -32022 && b.byId.get(4).error.data.supported.includes("2026-07-28"));

  fs.rmSync(tmp, { recursive: true, force: true });
  console.log(`${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
