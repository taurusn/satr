// Tests for boards in notes (PRD-2 BRD-19, BLK-8; gate 4E): the embed renderer, the Markdown placeholders, the
// note check, and `linen check` through the built command when it is there.
//   node Tests/board-embed.test.js [path/to/linen]
"use strict";
const assert = require("assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");
const R = path.join(__dirname, "..", "Renderer");
require(path.join(R, "board-model.js"));
globalThis.LinenRouter = require(path.join(R, "router.js"));
const E = require(path.join(R, "board-embed.js"));
const { marked } = require(path.join(R, "vendor", "marked.js"));
require(path.join(R, "extensions.js"));
globalThis.LinenDialect.configure(marked);

const tests = [];
const test = (name, fn) => tests.push([name, fn]);
const board = (extra) => JSON.stringify(Object.assign({
  nodes: [
    { id: "s1", type: "group", x: 0, y: 0, width: 640, height: 200, label: "Intake" },
    { id: "a", type: "text", text: "# Request\nArrives by form.", x: 24, y: 24, width: 260, height: 120, linen: { word: "Works" } },
    { id: "b", type: "text", text: "# Review\nA person <script>alert(1)</script> checks it.", x: 340, y: 24, width: 260, height: 120 },
    { id: "s2", type: "group", x: 0, y: 300, width: 320, height: 200, label: "Archive" },
    { id: "c", type: "text", text: "# Store\nKept a year.", x: 24, y: 324, width: 260, height: 120 },
  ],
  edges: [{ id: "e1", fromNode: "a", toNode: "b", label: "queues" }, { id: "e2", fromNode: "b", toNode: "c" }],
  linen: { route: "elbow" },
}, extra || {}));

test("a board draws as one SVG with its sections, boxes, routed lines, heads and chips", () => {
  const r = E.render(board());
  assert.ok(!r.error, r.error);
  for (const bit of ['class="bs"', 'class="bn"', 'class="bc', 'class="bl works"', 'class="bh', 'class="bk"', ">queues<", ">Intake<"]) assert.ok(r.svg.includes(bit), bit);
  assert.ok(r.w > 600 && r.h > 450, `${r.w} x ${r.h}`);
  assert.strictEqual(r.boxes.get("a"), "Request");
});

test("text from the file is escaped, never markup", () => {
  const r = E.render(board());
  assert.ok(!/<script/i.test(r.svg));
  assert.ok(r.svg.includes("&lt;script"));
});

test("one section by its name or id; a missing section says so", () => {
  const r = E.render(board(), { section: "archive" });
  assert.ok(!r.error && r.title === "Archive" && r.svg.includes(">Store<") && !r.svg.includes(">Request<"), r.error);
  assert.ok(!E.render(board(), { section: "s1" }).error);
  assert.match(E.render(board(), { section: "Nope" }).error, /No section called “Nope”/);
});

test("a broken board and an inline board over 64 KB are refused with the reason", () => {
  assert.match(E.render("{nope", { inline: true }).error, /JSON/);
  assert.match(E.render(" ".repeat(70000) + "{}", { inline: true }).error, /64 KB/);
});

test("the frame's height follows the board's shape, at most 600 px", () => {
  assert.strictEqual(E.frameHeight(1000, 500, 720), 360);
  assert.strictEqual(E.frameHeight(700, 1100, 720), 600);
});

test("old boards keep their curves inside a note", () => {
  const r = E.render(board({ linen: {} }));
  assert.ok(/class="bl works"[^>]* d="M[^"]*C/.test(r.svg), "a cubic curve");
});

test("Markdown: wiki embeds, image-style embeds and the board fence become placeholders; images stay images", () => {
  const html = marked.parse("![[map.canvas#Intake|The flow]]\n\n![Flow](my%20map.canvas)\n\n![pic](a.png)\n\n```board\n{}\n```");
  assert.ok(html.includes('data-req="wiki:map.canvas" data-target="map.canvas#Intake" data-caption="The flow"'), html);
  assert.ok(html.includes('data-req="path:my map.canvas"'), html);
  assert.ok(html.includes('<img src="a.png"'), html);
  assert.ok(html.includes('class="board-src"'), html);
});

test("touches: ids are read from a cell; the check names ids not on the board above and bad inline boards", () => {
  assert.deepStrictEqual(E.touchesOf("touches: [a, 'b']"), ["a", "b"]);
  assert.strictEqual(E.touchesOf("touches a"), null);
  const note = "# Steps\n\n```board\n" + board() + "\n```\n\n| Step | Boxes |\n|---|---|\n| 1 | touches: [a, ghost] |\n\n```board\n{oops\n```\n";
  const p = E.check(note);
  assert.ok(p.some((x) => x.severity === "warning" && /ghost/.test(x.message) && x.line === 9), JSON.stringify(p));
  assert.ok(p.some((x) => x.severity === "error" && /Inline board/.test(x.message) && x.line === 11), JSON.stringify(p));
});

test("linen check: a missing board, a missing section and a bad inline board (built command)", () => {
  const bin = process.argv[2] || path.join(__dirname, "..", "build/DerivedData/Build/Products/Debug/Linen.app/Contents/Helpers/linen");
  if (!fs.existsSync(bin)) { console.log("     (skipped: no built command at " + bin + ")"); return; }
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "linen-embed-"));
  fs.writeFileSync(path.join(dir, "map.canvas"), board());
  fs.writeFileSync(path.join(dir, "note.md"), "# Note\n\n![[map.canvas]]\n\n![[map.canvas#Archive]]\n\n![[map.canvas#Nowhere]]\n\n![[ghost.canvas]]\n\n```board\n{bad\n```\n");
  let out;
  try { out = execFileSync(bin, ["check", path.join(dir, "note.md"), "--json"], { encoding: "utf8" }); } catch (e) { out = e.stdout; }
  const parsed = JSON.parse(out), probs = (Array.isArray(parsed) ? parsed[0] : parsed).problems;
  const msgs = probs.map((p) => `${p.line}: ${p.severity} ${p.message}`);
  assert.ok(msgs.some((m) => /^7: error No section called Nowhere on map.canvas/.test(m)), msgs.join("\n"));
  assert.ok(msgs.some((m) => /^9: error No board called ghost.canvas/.test(m)), msgs.join("\n"));
  assert.ok(msgs.some((m) => /^11: error Inline board/.test(m)), msgs.join("\n"));
  assert.ok(!msgs.some((m) => /^[35]: error/.test(m)), msgs.join("\n"));
});

(async () => {
  let failed = 0;
  for (const [name, fn] of tests) {
    try { await fn(); console.log("ok  " + name); } catch (e) { failed++; console.log("FAIL " + name + "\n     " + (e && e.stack || e)); }
  }
  console.log(`${tests.length - failed} of ${tests.length} passed`);
  process.exit(failed ? 1 : 0);
})();
