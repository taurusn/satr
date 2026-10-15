// Tests for Renderer/layout.js and Renderer/canvas-writer.js (PRD-2 BRD-17, BRD-25, CLI-3).
//   node Tests/layout.test.js
// Measuring here is the estimate inside layout.js (no DOM); the real fonts are measured by
// Tests/Harness/layout-host.swift. Layered sections run the vendored ELK in this process.
"use strict";
const assert = require("assert");
const path = require("path");
const R = path.join(__dirname, "..", "Renderer");
const L = require(path.join(R, "layout.js"));
const W = require(path.join(R, "canvas-writer.js"));
const ELK = require(path.join(R, "vendor", "elk", "elk.bundled.js"));

const tests = [];
const test = (name, fn) => tests.push([name, fn]);

function card(id, x, y, text, extra) {
  return Object.assign({ id, type: "text", text, x, y, width: 200, height: 80 }, extra || {});
}
function group(id, x, y, w, h, linen, label) {
  return { id, type: "group", label: label || id, x, y, width: w, height: h, linen };
}
const measure = (it) => ({ w: it.width, h: it.kind === "section-title" ? 30 : 40 + 20 * Math.ceil(String(it.text).length / 30) });

// ---------- writer ----------

test("an Obsidian-style file is reproduced byte for byte when nothing moves", () => {
  const obj = { nodes: [card("a", 0, 0, "hi", { linen: { kind: "card", note: { title: "t", refs: ["x:1"] } } }), card("b", 300, 0, "yo")], edges: [{ id: "e", fromNode: "a", toNode: "b" }], linen: { dir: "ltr", words: [{ word: "Works", shape: "outline" }] }, extra: { keep: true } };
  const text = W.serialise(obj);
  assert.ok(W.isObsidianStyle(text));
  const r = W.write(text, {});
  assert.strictEqual(r.text, text);
  assert.strictEqual(r.normalised, false);
  assert.strictEqual(r.changed, 0);
});

test("Obsidian's style: flat objects on one line, nested ones spread with tabs, no final newline", () => {
  const text = W.serialise({ nodes: [card("a", 1, 2, "t", { linen: { kind: "card" } })], edges: [] });
  assert.strictEqual(text, '{\n\t"nodes":[\n\t\t{\n\t\t\t"id":"a",\n\t\t\t"type":"text",\n\t\t\t"text":"t",\n\t\t\t"x":1,\n\t\t\t"y":2,\n\t\t\t"width":200,\n\t\t\t"height":80,\n\t\t\t"linen":{"kind":"card"}\n\t\t}\n\t],\n\t"edges":[]\n}');
  const flat = W.serialise({ nodes: [card("a", 1, 2, "t")], edges: [] });
  assert.strictEqual(flat, '{\n\t"nodes":[\n\t\t{"id":"a","type":"text","text":"t","x":1,"y":2,"width":200,"height":80}\n\t],\n\t"edges":[]\n}');
});

test("patching changes only the numbers that moved and keeps unknown fields", () => {
  const obj = { nodes: [card("a", 0, 0, "é   \"q\"", { linen: { kind: "card", future: [1, 2] }, other: "kept" }), card("b", 300, 0, "yo")], edges: [], zz: 1 };
  const text = W.serialise(obj) + "\n";
  const r = W.write(text, { a: { x: 10, y: 20.4, width: 200, height: 99.6 } });
  assert.strictEqual(r.normalised, false);
  assert.strictEqual(r.changed, 1);
  const before = text.split("\n"), after = r.text.split("\n");
  assert.strictEqual(before.length, after.length);
  const diff = before.map((l, i) => [l, after[i]]).filter(([a, b]) => a !== b);
  assert.deepStrictEqual(diff.map(([, b]) => b.trim()), ['"x":10,', '"y":20,', '"height":100,']);
  assert.ok(r.text.endsWith("\n"), "a final newline it had is kept");
  const back = JSON.parse(r.text);
  assert.strictEqual(back.nodes[0].other, "kept");
  assert.deepStrictEqual(back.nodes[0].linen.future, [1, 2]);
  assert.strictEqual(back.zz, 1);
});

test("a file in another style is normalised once, then left alone", () => {
  const obj = { nodes: [card("a", 0.4, 0, "x"), card("b", 300, 0, "y")], edges: [], linen: { title: "T" } };
  const pretty = JSON.stringify(obj, null, 2);
  const r1 = W.write(pretty, {});
  assert.strictEqual(r1.normalised, true);
  assert.ok(r1.message);
  assert.strictEqual(JSON.parse(r1.text).nodes[0].x, 0, "whole numbers");
  assert.strictEqual(JSON.parse(r1.text).linen.title, "T");
  const r2 = W.write(r1.text, {});
  assert.strictEqual(r2.normalised, false);
  assert.strictEqual(r2.text, r1.text);
});

// ---------- layout ----------

function boardA() {
  return {
    nodes: [
      group("s", 0, 0, 1000, 400, { layout: "grid", cols: 3, title: "Section" }),
      card("lead", 20, 50, "A lead paragraph that spans the whole section width", { linen: { span: "all" } }),
      card("c1", 20, 150, "one"), card("c2", 240, 150, "two two two two two two two two two two two"), card("c3", 460, 150, "three"),
      card("c4", 20, 260, "four"),
      card("free", 1200, 0, "hand placed"),
      group("below", 0, 500, 1000, 200, null),
    ],
    edges: [{ id: "e1", fromNode: "c1", toNode: "c4" }],
  };
}

test("grid: cells, spans, shared row heights; hand-placed nodes never move", async () => {
  const c = boardA();
  const r = await L.layout(c, { measure });
  const p = r.positions;
  assert.ok(!p.free, "a free node is not touched");
  const pad = L.METRICS.sectionPad;
  assert.strictEqual(p.lead.x, pad);
  assert.strictEqual(p.lead.width, 1000 - 2 * pad);
  assert.strictEqual(p.c1.y, p.c2.y);
  assert.strictEqual(p.c1.height, p.c2.height, "a row shares its height");
  assert.ok(p.c2.x > p.c1.x && p.c3.x > p.c2.x);
  assert.ok(p.c4.y > p.c1.y + p.c1.height);
  assert.ok(p.s.height > 0);
  assert.ok(r.routes.e1 && r.routes.e1.points.length >= 2, "an elbow route inside the section");
});

test("BRD-25: a section below is pushed down to keep rowGap", async () => {
  const c = boardA();
  c.nodes[0].height = 100;
  c.nodes[7].y = 150; // starts inside where the grown section will reach
  const r = await L.layout(c, { measure });
  const s = r.positions.s, b = r.positions.below;
  assert.ok(b, "the section below moved");
  assert.strictEqual(b.y, s.y + s.height + L.METRICS.rowGap);
  assert.deepStrictEqual(r.moved, ["below"]);
});

test("BRD-25: sections that started on one row move together", async () => {
  const c = {
    nodes: [
      group("tall", 0, 0, 400, 100, { layout: "stack" }),
      card("t1", 10, 30, "x".repeat(400)),
      group("short", 600, 0, 400, 100, null),
      group("r2a", 0, 300, 400, 100, null),
      group("r2b", 600, 300, 400, 100, null), // nothing above it grows, but it keeps its row
    ],
    edges: [],
  };
  const r = await L.layout(c, { measure });
  const tall = r.positions.tall;
  assert.strictEqual(r.positions.r2a.y, tall.y + tall.height + L.METRICS.rowGap);
  assert.strictEqual(r.positions.r2b.y, r.positions.r2a.y, "the row stays a row");
});

test("layout is idempotent through the writer", async () => {
  const text = W.serialise(boardA());
  const r1 = await L.layout(JSON.parse(text), { measure });
  const t1 = W.write(text, r1.positions).text;
  const r2 = await L.layout(JSON.parse(t1), { measure });
  assert.deepStrictEqual(r2.positions, {}, "a second run moves nothing");
  assert.strictEqual(W.write(t1, r2.positions).text, t1);
});

test("nested groups: inner grids are laid out first and carry a label band", async () => {
  const c = {
    nodes: [
      group("s", 0, 0, 900, 800, { layout: "grid", cols: 2, ratios: [1, 2] }),
      group("g1", 30, 40, 280, 300, { layout: "grid", cols: 1 }, "First"),
      card("a", 40, 80, "a"), card("b", 40, 200, "b"),
      group("g2", 330, 40, 540, 300, { layout: "grid", cols: 2 }, "Second"),
      card("c", 340, 80, "c"), card("d", 560, 80, "d"), card("e", 340, 200, "e"),
    ],
    edges: [],
  };
  const r = await L.layout(c, { measure });
  const p = r.positions;
  const g1 = p.g1 || c.nodes[1], g2 = p.g2;
  assert.ok(g2.width > (p.g1 ? p.g1.width : 280) * 1.8, "ratios 1:2");
  assert.strictEqual(g1.y, L.METRICS.sectionPad + L.METRICS.labelBand);
  for (const id of ["a", "b"]) assert.ok(p[id].x >= g1.x && p[id].x + p[id].width <= g1.x + g1.width + 0.5);
  for (const id of ["c", "d", "e"]) assert.ok(p[id].y >= g2.y && p[id].y + p[id].height <= g2.y + g2.height);
  assert.ok(p.s.height >= g2.y + g2.height);
});

test("stack and lanes", async () => {
  const c = {
    nodes: [
      group("st", 0, 0, 400, 300, { layout: "stack" }), card("x", 10, 40, "x"), card("y", 10, 140, "y"),
      group("ln", 600, 0, 900, 300, { layout: "lanes" }), card("l1", 610, 40, "one"), card("l2", 900, 40, "two two two two two two two two two two two two two two two two"), card("l3", 1200, 40, "three"),
    ],
    edges: [],
  };
  const r = await L.layout(c, { measure, rowGap: 0 });
  const p = r.positions;
  assert.strictEqual(p.x.x, p.y.x);
  assert.ok(p.y.y > p.x.y);
  assert.strictEqual(p.l1.y, p.l2.y);
  assert.strictEqual(p.l1.height, p.l3.height, "lanes share a height");
  assert.ok(p.l2.x > p.l1.x && p.l3.x > p.l2.x);
});

test("right to left mirrors the columns (BRD-27)", async () => {
  const c = boardA();
  c.linen = { dir: "rtl" };
  const r = await L.layout(c, { measure });
  const p = r.positions;
  // Reading order runs from the right: c3 (rightmost in the file) is first and takes the first column, on the right;
  // c4, alone on the next row, starts that row on the right too.
  assert.ok(p.c3.x > p.c2.x && p.c2.x > p.c1.x, "columns run right to left");
  assert.strictEqual(p.c4.x, p.c3.x, "a new row starts on the right");
  assert.strictEqual(p.c3.x + p.c3.width, 1000 - L.METRICS.sectionPad);
});

test("layered: ELK places the nodes and routes the edges orthogonally", async () => {
  const nodes = [group("s", 0, 0, 1200, 600, { layout: "layered", title: "Flow" })];
  for (let i = 0; i < 18; i++) nodes.push(card("n" + i, 20 + (i % 6) * 190, 60 + Math.floor(i / 6) * 150, "Node " + i));
  const edges = [];
  for (let i = 1; i < 18; i++) edges.push({ id: "e" + i, fromNode: "n" + Math.floor((i - 1) / 2), toNode: "n" + i });
  const t = Date.now();
  const r = await L.layout({ nodes, edges }, { measure, elk: new ELK() });
  const ms = Date.now() - t;
  assert.strictEqual(r.problems.length, 0, JSON.stringify(r.problems));
  const p = r.positions;
  for (let i = 0; i < 18; i++) assert.ok(p["n" + i], "n" + i + " placed");
  const routes = Object.values(r.routes);
  assert.strictEqual(routes.length, 17);
  for (const rt of routes) for (let i = 1; i < rt.points.length; i++) {
    const [a, b] = [rt.points[i - 1], rt.points[i]];
    assert.ok(Math.abs(a[0] - b[0]) < 0.01 || Math.abs(a[1] - b[1]) < 0.01, "orthogonal segments");
  }
  // No two nodes overlap.
  const boxes = Object.entries(p).filter(([id]) => id !== "s").map(([, v]) => v);
  for (let i = 0; i < boxes.length; i++) for (let j = i + 1; j < boxes.length; j++) {
    const a = boxes[i], b = boxes[j];
    assert.ok(a.x + a.width <= b.x || b.x + b.width <= a.x || a.y + a.height <= b.y || b.y + b.height <= a.y, "overlap");
  }
  console.log(`    layered 18 nodes in ${ms} ms (ELK ${Math.round(r.stats.elkMs)} ms, first call includes ELK start)`);
});

test("layered: a flow with loops keeps the main path in box order", async () => {
  // A review flow: two returns to the start and a retry; the loops must not reverse the main path.
  const ids = ["intake", "review", "ready", "meet", "vote", "done", "rejected"];
  const nodes = [group("s", 0, 0, 1200, 400, { layout: "layered", title: "Flow" })];
  ids.forEach((id, i) => nodes.push(card(id, 20 + i * 150, 60, id)));
  const pairs = [["intake", "review"], ["review", "ready"], ["ready", "meet"], ["meet", "vote"], ["vote", "done"], ["vote", "rejected"],
    ["review", "intake"], ["ready", "intake"], ["vote", "meet"], ["vote", "intake"]];
  const edges = pairs.map(([a, b], i) => ({ id: "e" + i, fromNode: a, toNode: b }));
  const r = await L.layout({ nodes, edges }, { measure, elk: new ELK() });
  assert.strictEqual(r.problems.length, 0, JSON.stringify(r.problems));
  const x = (id) => r.positions[id].x;
  for (let i = 1; i < 5; i++) assert.ok(x(ids[i]) > x(ids[i - 1]), ids[i] + " sits right of " + ids[i - 1]);
  assert.ok(x("done") > x("vote") && x("rejected") > x("vote"), "the ends sit after the vote");
  // Where the boxes sit before the layout must not change the flow's order: start from a scrambled board (the
  // ends stacked on the left, the start on the right, as a bad earlier layout leaves it) and expect file order.
  const scrambled = [nodes[0]].concat(ids.map((id, i) => card(id, 20 + (ids.length - 1 - i) * 150, 60 + (i % 3) * 110, id)));
  const r2 = await L.layout({ nodes: scrambled, edges }, { measure, elk: new ELK() });
  const x2 = (id) => (r2.positions[id] || scrambled.find((n) => n.id === id)).x;
  for (let i = 1; i < 5; i++) assert.ok(x2(ids[i]) > x2(ids[i - 1]), "from a scrambled board, " + ids[i] + " sits right of " + ids[i - 1]);
});

test("measurements are cached by content and width", async () => {
  L.clearCache();
  let calls = 0;
  const counting = (it) => { calls++; return measure(it); };
  await L.layout(boardA(), { measure: counting });
  const first = calls;
  await L.layout(boardA(), { measure: counting });
  assert.strictEqual(calls, first, "the second layout measures nothing");
});

test("a malformed node list does not throw", async () => {
  const r = await L.layout({ nodes: [null, 3, "x", { id: "g", type: "group", linen: { layout: "grid" } }, group("s", 0, 0, 300, 100, { layout: "grid" })], edges: [null] }, { measure });
  assert.ok(r.problems.some((p) => p.id === "g"));
});

(async () => {
  let failed = 0;
  for (const [name, fn] of tests) {
    try { await fn(); console.log("ok  " + name); } catch (e) { failed++; console.log("FAIL " + name + "\n     " + (e && e.stack || e)); }
  }
  console.log(`${tests.length - failed} of ${tests.length} passed`);
  process.exit(failed ? 1 : 0);
})();
