// Tests for Renderer/board-model.js (PRD-2 BRD-1, BRD-4, BRD-6, BRD-13, BRD-20, BRD-27, WORDS, NOTE, CLI-2).
// Run: node Tests/board-model.test.js   (regenerates the fixtures first; prints timings; exits 1 on any failure)
"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const { execFileSync } = require("child_process");

const ROOT = path.resolve(__dirname, "..");
// LINEN_MODEL points the suite at another copy of the model (to show a new test failing before its fix).
const MODEL = process.env.LINEN_MODEL ? path.resolve(process.env.LINEN_MODEL) : path.join(ROOT, "Renderer", "board-model.js");
const FIX = path.join(__dirname, "Fixtures", "boards");
const JSC = "/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc";

const { obsidian } = require(path.join(FIX, "gen.js")); // writes the fixtures (only files whose content changed)

// The model in this realm (for timing, as a page or worker would run it) ...
vm.runInThisContext(fs.readFileSync(MODEL, "utf8"), { filename: MODEL });
const C = globalThis.LinenCanvas;

let passed = 0, failed = 0;
const failures = [];
const timing = {};
function test(name, fn) {
  try { fn(); passed++; } catch (e) { failed++; failures.push(name + ": " + (e && e.message)); }
}
function eq(a, b, what) { if (a !== b) throw new Error((what || "value") + ": expected " + JSON.stringify(b) + ", got " + JSON.stringify(a)); }
function same(a, b, what) { const x = JSON.stringify(a), y = JSON.stringify(b); if (x !== y) throw new Error((what || "value") + ": expected " + y + ", got " + x); }
function ok(c, what) { if (!c) throw new Error(what || "expected true"); }

const read = (name) => fs.readFileSync(path.join(FIX, name), "utf8");
const sidecarOf = (name) => (fs.existsSync(path.join(FIX, name + ".notes.json")) ? read(name + ".notes.json") : null);
const load = (name) => C.parse(read(name), { sidecarText: sidecarOf(name) });
/** 1-based line of the nth occurrence of needle, found independently of the model. */
function lineOf(text, needle, nth) {
  let at = -1;
  for (let i = 0; i <= (nth || 0); i++) { at = text.indexOf(needle, at + 1); if (at < 0) throw new Error("needle not found: " + needle); }
  return text.slice(0, at).split("\n").length;
}
function lineAfter(text, anchor, needle) {
  const a = text.indexOf(anchor);
  const at = text.indexOf(needle, a);
  return text.slice(0, at).split("\n").length;
}
const byPath = (list, p) => list.filter((x) => x.path === p);
const kinds = (b) => Object.fromEntries(b.nodes.map((n) => [n.id, n.kind]));

// ---------- isolation: no node, no DOM ----------
test("runs in a bare context with nothing but the language", () => {
  const ctx = vm.createContext({});
  vm.runInContext(fs.readFileSync(MODEL, "utf8"), ctx);
  const b = ctx.LinenCanvas.parse(read("connectors.canvas"));
  eq(b.nodes.length, 5, "nodes");
  eq(b.edges.length, 8, "edges");
});
test("sets LinenCanvas on self in a worker-like global", () => {
  const ctx = vm.createContext({});
  vm.runInContext("var self = globalThis;", ctx);
  vm.runInContext(fs.readFileSync(MODEL, "utf8"), ctx);
  ok(ctx.self.LinenCanvas && typeof ctx.self.LinenCanvas.parse === "function", "self.LinenCanvas");
});

// ---------- kinds, titles, bodies (BRD-2) ----------
test("kinds.canvas: every node kind", () => {
  const b = load("kinds.canvas");
  same(kinds(b), {
    "card-titled": "card", "card-plain": "card", "card-linen-title": "card", sticky: "sticky",
    "shape-rect": "shape", "shape-rounded": "shape", "shape-ellipse": "shape", "shape-diamond": "shape", "shape-pill": "shape",
    "shape-cylinder": "shape", "shape-hexagon": "shape", "shape-bad": "shape", "text-title": "text",
    image: "image", note: "note", board: "board", page: "page", "other-file": "file", link: "link", "kind-bad": "card",
  }, "kinds");
  const n = b.byId;
  eq(n.get("card-titled").title, "Gateway");
  ok(n.get("card-titled").body.startsWith("Routes requests"), "body after the heading");
  eq(n.get("card-plain").title, null);
  eq(n.get("card-plain").body, "A card without a heading line.");
  eq(n.get("card-linen-title").title, "Explicit title");
  eq(n.get("card-linen-title").eyebrow, "Edge");
  eq(n.get("card-linen-title").body, "Body under an explicit title.");
  for (const s of ["rect", "rounded", "ellipse", "diamond", "pill", "cylinder", "hexagon"]) eq(n.get("shape-" + s).shape, s, "shape " + s);
  eq(n.get("shape-bad").shape, "rect");
  eq(n.get("note").subpath, "#Scope");
  eq(n.get("note").title, "Plan");
  eq(n.get("board").title, "system");
  eq(n.get("link").url, "https://example.com/docs");
  eq(n.get("link").title, "Docs");
  const t = read("kinds.canvas");
  same(b.problems.map((p) => [p.severity, p.path, p.line]), [
    ["warning", "$.nodes[11].linen.shape", lineAfter(t, '"id":"shape-bad"', '"linen"')],
    ["warning", "$.nodes[19].linen.kind", lineAfter(t, '"id":"kind-bad"', '"linen"')],
  ], "problems");
  same(n.get("card-plain").line, [lineOf(t, '"id":"card-plain"'), lineOf(t, '"id":"card-plain"')], "a flat node is one line");
  const multi = n.get("card-linen-title").line;
  ok(multi[1] > multi[0], "a node with a nested object spans lines");
});

// ---------- sections, parents, reading order (BRD-3, BRD-27) ----------
test("sections-nested.canvas: parents, depth, order", () => {
  const b = load("sections-nested.canvas");
  const parent = Object.fromEntries(b.nodes.map((n) => [n.id, n.parent]));
  same(parent, { outer: null, inner: "outer", inner2: "outer", deeper: "inner", c1: "inner", c2: "deeper", c3: "inner2", loose: null }, "parents");
  const depth = Object.fromEntries(b.nodes.map((n) => [n.id, n.depth]));
  same(depth, { outer: 0, inner: 1, inner2: 1, deeper: 2, c1: 2, c2: 3, c3: 2, loose: 0 }, "depth");
  same(b.order, ["outer", "inner", "c1", "deeper", "c2", "inner2", "c3", "loose"], "order");
  same(b.roots, ["outer", "loose"], "roots");
  same(b.children.get("inner"), ["c1", "deeper"], "children of inner");
  eq(b.byId.get("outer").background, "assets/ground.png");
  eq(b.byId.get("outer").title, "Platform services");
  eq(b.byId.get("outer").label, "Platform");
  eq(b.problems.length, 0, "no problems");
  same(b.bounds, { x: 0, y: 0, w: 1580, h: 800 }, "bounds");
});

// ---------- connectors (BRD-4) and Obsidian's side rule ----------
test("connectors.canvas: kinds, ends, routes, sides", () => {
  const b = load("connectors.canvas");
  const e = b.edgesById;
  const pick = (id) => { const x = e.get(id); return [x.kind, x.route, x.fromEnd, x.toEnd, x.fromSide, x.toSide, x.sidesFilled, x.label]; };
  same(pick("e-works"), ["works", "curved", "none", "arrow", "right", "left", true, null], "e-works");
  same(pick("e-main"), ["main", "curved", "none", "arrow", "bottom", "top", false, null], "e-main");
  same(pick("e-code"), ["code", "curved", "none", "arrow", "bottom", "top", true, "async"], "e-code");
  same(pick("e-plan"), ["plan", "elbow", "arrow", "arrow", "right", "left", true, null], "e-plan");
  same(pick("e-fail"), ["fail", "straight", "none", "none", "bottom", "top", true, null], "e-fail");
  same(pick("e-left"), ["works", "curved", "none", "arrow", "left", "right", false, "reply"], "e-left");
  same(pick("e-badside"), ["works", "curved", "none", "arrow", "bottom", "top", true, null], "e-badside (angle rule)");
  same(pick("e-badkind"), ["works", "curved", "none", "arrow", "bottom", "top", true, null], "e-badkind");
  same(e.get("e-works").p1, { x: 200, y: 50 }, "p1");
  same(e.get("e-works").p2, { x: 500, y: 50 }, "p2");
  const t = read("connectors.canvas");
  same(b.problems.map((p) => [p.path, p.line]), [
    ["$.edges[6].fromSide", lineOf(t, '"id":"e-badside"')],
    ["$.edges[7].fromEnd", lineOf(t, '"fromEnd":"dot"')],
    ["$.edges[7].linen.kind", lineAfter(t, '"id":"e-badkind"', '"linen"')],
    ["$.edges[7].linen.route", lineAfter(t, '"id":"e-badkind"', '"linen"')],
  ], "problems");
  same(b.edgesOf.get("a").slice().sort(), ["e-badside", "e-left", "e-main", "e-works"], "edgesOf a");
});
test("sideFor follows Obsidian's angle against the node's diagonal", () => {
  const a = { x: 0, y: 0, w: 400, h: 100 };
  eq(C.sideFor(a, { x: 300, y: 120, w: 200, h: 100 }), "bottom", "below-right of a wide node");
  eq(C.sideFor(a, { x: 500, y: 20, w: 200, h: 100 }), "right", "beside");
  eq(C.sideFor(a, { x: -500, y: 0, w: 200, h: 100 }), "left", "left");
  eq(C.sideFor(a, { x: 100, y: -300, w: 200, h: 100 }), "top", "above");
  const sq = { x: 0, y: 0, w: 100, h: 100 };
  eq(C.sideFor(sq, { x: 100, y: 100, w: 100, h: 100 }), "right", "exact diagonal goes right (r <= o)");
});

// ---------- colours ----------
test("colours.canvas: presets, hex, and refused values", () => {
  const b = load("colours.canvas");
  for (const c of ["1", "2", "3", "4", "5", "6"]) eq(b.byId.get("preset-" + c).color, c, "preset " + c);
  eq(b.byId.get("hex").color, "#4A6B57");
  eq(b.byId.get("bad-seven").color, null);
  eq(b.byId.get("bad-number").color, null);
  same(b.problems.map((p) => p.path), ["$.nodes[7].color", "$.nodes[8].color"], "problems");
  eq(b.edgesById.get("col-edge").color, "3");
  eq(b.edgesById.get("hex-edge").color, "#123456");
});

// ---------- words (WORDS-1 to WORDS-3) ----------
test("words-default.canvas: defaults, counts, quiet Works, case folding", () => {
  const b = load("words-default.canvas");
  same(b.words.map((w) => [w.word, w.shape, w.quiet, w.count]), [
    ["Works", "outline", true, 3], ["Partial", "threads", false, 2], ["Broken", "rust", false, 2], ["Missing", "dashed", false, 1], ["Planned", "dotted", false, 1],
  ], "words");
  eq(b.byId.get("b2").word, "Broken", "lowercase resolves to the vocabulary's spelling");
  eq(b.byId.get("u1").word, "Unknown");
  same(b.problems.map((p) => [p.severity, p.path]), [["warning", "$.nodes[9].linen.word"]], "problems");
});
test("words-custom.canvas: custom vocabulary, one quiet word, Arabic, rust check", () => {
  const b = load("words-custom.canvas");
  same(b.words.map((w) => [w.word, w.shape, w.quiet, w.count]), [
    ["Live", "outline", true, 2], ["Shaky", "threads", false, 1], ["Down", "rust", false, 1], ["Idea", "dotted", false, 1], ["متوقف", "solid", false, 1], ["Hot", "rust", false, 1],
  ], "words");
  same(b.problems.map((p) => p.path), ["$.linen.words[3].quiet"], "parse problems");
  const chk = C.check(b);
  const rust = chk.filter((p) => /Rust is for failures/.test(p.message));
  same(rust.map((p) => p.path), ["$.linen.words[5]"], "only Hot is warned; Down says it failed");
  eq(rust[0].line, lineOf(read("words-custom.canvas"), '{"word":"Hot","shape"'), "line");
});
test("words-seven.canvas: a seventh word is an error and unused", () => {
  const b = load("words-seven.canvas");
  eq(b.words.length, 6);
  const t = read("words-seven.canvas");
  const err = byPath(b.problems, "$.linen.words[6]");
  eq(err.length, 1);
  eq(err[0].severity, "error");
  eq(err[0].line, lineOf(t, '{"word":"Seven","shape"'));
  eq(byPath(b.problems, "$.nodes[1].linen.word").length, 1, "the node using it is warned");
});

// ---------- direction (BRD-27) ----------
test("arabic-mixed.canvas: ltr by majority, per-node direction by ARB-1's 60/40 rule", () => {
  const b = load("arabic-mixed.canvas");
  eq(b.dir, "ltr");
  // "سطر Linen قارئ" is 7 Arabic letters of 12 (58 percent): between the thresholds, so it takes the board's ltr.
  same(Object.fromEntries(b.nodes.map((n) => [n.id, n.dir])), { en1: "ltr", en2: "ltr", ar1: "rtl", "mixed-ltr": "ltr", "mixed-rtl": "ltr" }, "dirs");
});
test("arabic-rtl.canvas: rtl reading order from the right", () => {
  const b = load("arabic-rtl.canvas");
  eq(b.dir, "rtl");
  eq(b.title, "خريطة النظام");
  same(b.order, ["s1", "a3", "a2", "a1", "a4", "s2", "a5"], "order");
  eq(b.problems.length, 0);
});
test("arabic-inferred.canvas: rtl without linen.dir", () => {
  eq(load("arabic-inferred.canvas").dir, "rtl");
});

// ---------- notes (BRD-6, NOTE-1, NOTE-2) ----------
test("notes-inline.canvas: notes on nodes and edges, bad notes listed", () => {
  const b = load("notes-inline.canvas");
  const n1 = b.byId.get("n1");
  eq(n1.noteFrom, "board");
  same(n1.note, { area: "Edge", title: "Why partial", body: "Retries work; **timeouts** do not.", state: "Partial", refs: ["src/gateway.ts:40-52"], fields: { Owner: "Platform", Seen: "2026-10-01" } }, "note");
  eq(b.byId.get("n2").note, null);
  same(b.byId.get("n3").note.refs, ["a.md"], "refs keep text only");
  eq(b.edgesById.get("e1").note.title, "Edge note");
  const t = read("notes-inline.canvas");
  same(b.problems.map((p) => [p.severity, p.path, p.line]), [
    ["error", "$.nodes[1].linen.note", lineOf(t, '"note":"just a string"')],
    ["warning", "$.nodes[2].linen.note.refs[1]", lineOf(t, '"refs":["a.md",7]')],
  ], "problems at the field's own line");
});
test("notes-sidecar.canvas: sidecar notes and an orphan id", () => {
  const b = load("notes-sidecar.canvas");
  eq(b.byId.get("n1").noteFrom, "sidecar");
  eq(b.byId.get("n1").note.title, "From the sidecar");
  eq(b.byId.get("n2").note, null);
  eq(b.edgesById.get("e1").noteFrom, "sidecar");
  same(b.problems.map((p) => [p.severity, p.path, p.file, p.line]), [["warning", "$.ghost", "sidecar", lineOf(read("notes-sidecar.canvas.notes.json"), '"ghost"')]], "problems");
});
test("notes-both.canvas: a note in both places is an error; the board's is shown", () => {
  const b = load("notes-both.canvas");
  eq(b.byId.get("n1").note.title, "In the board");
  eq(b.byId.get("n2").noteFrom, "sidecar");
  same(b.problems.map((p) => [p.severity, p.path]), [["error", "$.nodes[0].linen.note"]], "problems");
});

// ---------- tours, layouts, links ----------
test("tours.canvas: tours kept, a bad one listed", () => {
  const b = load("tours.canvas");
  eq(b.tours.length, 1);
  eq(b.tours[0].title, "The happy path");
  same(b.problems.map((p) => p.path), ["$.linen.tours[1]"], "problems");
});
test("layouts.canvas: each section layout", () => {
  const b = load("layouts.canvas");
  same(["lanes", "grid", "stack", "layered", "spiral"].map((id) => b.byId.get(id).layout), ["lanes", "grid", "stack", "layered", null], "layouts");
  eq(b.byId.get("grid").cols, 3);
  eq(b.byId.get("grid").gap, 24);
  eq(b.byId.get("stack").gap, 16);
  ok(b.hasLayout, "hasLayout");
  same(b.problems.map((p) => p.path), ["$.nodes[8].linen.layout", "$.nodes[8].linen.cols", "$.nodes[9].linen.layout"], "problems");
  eq(b.byId.get("l1").parent, "lanes");
});
test("node-links.canvas: file nodes with subpaths", () => {
  const b = load("node-links.canvas");
  eq(b.byId.get("note-sub").subpath, "#Scope");
  eq(b.byId.get("board-sub").kind, "board");
  eq(b.byId.get("board-sub").subpath, "#gateway");
  ok(b.byId.get("source").body.indexOf("[[node-links.canvas#target]]") !== -1, "link text kept");
  eq(b.problems.length, 0);
});

// ---------- fatal files (BRD-1) ----------
test("invalid-not-json.canvas: fatal with line and column", () => {
  const b = load("invalid-not-json.canvas");
  eq(b.fatal.reason, "json");
  eq(b.fatal.problems.length, 1);
  eq(b.fatal.problems[0].line, 4);
  eq(b.fatal.problems[0].column, 3);
  same(C.check(b).map((p) => p.line), [4], "check returns it");
});
test("invalid-root.canvas and invalid-nodes-object.canvas: fatal shape", () => {
  const r = load("invalid-root.canvas");
  eq(r.fatal.reason, "shape");
  const o = load("invalid-nodes-object.canvas");
  eq(o.fatal.reason, "shape");
  same(o.fatal.problems.map((p) => [p.path, p.line]), [["$.nodes", 2]], "problem");
});
test("empty files are empty boards", () => {
  for (const f of ["empty.canvas", "empty-object.canvas"]) {
    const b = load(f);
    eq(b.fatal, null, f);
    eq(b.problems.length, 0, f);
    eq(b.words.length, 5, f);
  }
});
test("invalid-2001-nodes.canvas: past the limit, fatal for the canvas, parsed for List view", () => {
  const b = load("invalid-2001-nodes.canvas");
  eq(b.fatal.reason, "limits");
  eq(b.nodes.length, 2001);
  eq(b.order.length, 2001);
  same(b.fatal.problems.map((p) => p.path), ["$.nodes"], "problem");
});

// ---------- problems never blank a board (BRD-1) ----------
test("invalid-no-position.canvas: unplaced nodes listed, the rest drawn", () => {
  const b = load("invalid-no-position.canvas");
  const t = read("invalid-no-position.canvas");
  same(b.unplaced, ["nopos", "nosize", "zero", "strpos"], "unplaced");
  ok(b.byId.get("frac").placed, "a fractional position is still placed");
  same(b.problems.map((p) => [p.path, p.line]), [
    ["$.nodes[1].x", lineOf(t, '"id":"nopos"')], ["$.nodes[2].width", lineOf(t, '"id":"nosize"')],
    ["$.nodes[3].width", lineOf(t, '"id":"zero"')], ["$.nodes[4].x", lineOf(t, '"id":"strpos"')],
  ], "problems");
  same(byPath(C.check(b), "$.nodes[5]").map((p) => p.severity), ["warning"], "check warns about the fraction");
  const e = b.edgesById.get("to-unplaced");
  eq(e.missing, null);
  eq(e.drawable, false);
  eq(e.stub, "to", "a stub from the placed end to its gap mark");
  same(b.order.slice(-4), ["nopos", "nosize", "zero", "strpos"], "unplaced at the end of the order");
  eq(b.grid.size, 2, "only placed nodes are indexed");
});
test("invalid-ids.canvas: missing and duplicate ids", () => {
  const b = load("invalid-ids.canvas");
  const t = read("invalid-ids.canvas");
  same(b.nodes.map((n) => n.id), ["a", "b"], "nodes");
  eq(b.byId.get("a").body, "First a", "the first is kept");
  same(b.problems.map((p) => [p.path, p.line]), [
    ["$.nodes[0].id", lineOf(t, '"text":"No id"')], ["$.nodes[1].id", lineOf(t, '"id":""')],
    ["$.nodes[3].id", lineOf(t, '"id":"a"', 1)], ["$.edges[1].id", lineOf(t, '"id":"dup"', 1)],
  ], "problems");
  eq(b.edgesById.get("dup").from, "a");
});
test("invalid-unknown-type.canvas: unknown types are unplaced", () => {
  const b = load("invalid-unknown-type.canvas");
  eq(b.byId.get("sticker").kind, "unknown");
  same(b.unplaced, ["sticker", "typeless"], "unplaced");
  same(b.problems.map((p) => p.path), ["$.nodes[0].type", "$.nodes[1].type"], "problems");
  const e = b.edgesById.get("to-sticker");
  eq(e.missing, null);
  eq(e.drawable, false);
});
test("invalid-dangling.canvas: edges to missing nodes", () => {
  const b = load("invalid-dangling.canvas");
  const t = read("invalid-dangling.canvas");
  same(b.edges.map((e) => [e.id, e.missing, e.drawable]), [["to-ghost", "to", false], ["from-ghost", "from", false], ["ghosts", "both", false], ["fine", null, true]], "edges");
  same(b.problems.map((p) => [p.path, p.line]), [
    ["$.edges[0].toNode", lineOf(t, '"id":"to-ghost"')], ["$.edges[1].fromNode", lineOf(t, '"id":"from-ghost"')], ["$.edges[2].fromNode", lineOf(t, '"id":"ghosts"')],
  ], "problems");
});
test("invalid-shapes.canvas: wrong-shaped entries skipped with their paths", () => {
  const b = load("invalid-shapes.canvas");
  const t = read("invalid-shapes.canvas");
  same(b.nodes.map((n) => n.id), ["valid", "badlinen", "valid2"], "nodes");
  same(b.edges.map((e) => e.id), ["e-ok"], "edges");
  same(b.problems.map((p) => [p.severity, p.path, p.line]), [
    ["error", "$.nodes[0]", lineOf(t, "null")], ["error", "$.nodes[1]", lineOf(t, "42")], ["error", "$.nodes[2]", lineOf(t, '"card"')],
    ["error", "$.nodes[4].text", lineOf(t, '"id":"numtext"')], ["warning", "$.nodes[5].linen", lineOf(t, '"id":"badlinen"')],
    ["error", "$.edges[0].id", lineOf(t, '{"fromNode":"valid"')], ["error", "$.edges[1].fromNode", lineOf(t, '"id":"e-bad-from"')],
  ], "problems");
});
test("invalid-big-node.canvas: a node over 64 KB is cut and listed", () => {
  const b = load("invalid-big-node.canvas");
  const h = b.byId.get("huge");
  ok(h.truncated, "truncated");
  ok(Buffer.byteLength(h.text, "utf8") <= 65536, "cut to 64 KB of UTF-8");
  eq(h.title, "Huge card");
  same(b.problems.map((p) => [p.severity, p.path]), [["error", "$.nodes[0]"]], "problems");
  eq(b.byId.get("small").truncated, false);
});

// ---------- change hashes (BRD-13) ----------
function hashes(b) { return { n: new Map(b.nodes.map((x) => [x.id, x.hash])), e: new Map(b.edges.map((x) => [x.id, x.hash])) }; }
function diff(a, b) {
  const out = [];
  for (const [k, v] of a.n) if (b.n.get(k) !== v) out.push(k);
  for (const k of b.n.keys()) if (!a.n.has(k)) out.push("+" + k);
  for (const [k, v] of a.e) if (b.e.get(k) !== v) out.push(k);
  for (const k of b.e.keys()) if (!a.e.has(k)) out.push("+" + k);
  return out.sort();
}
test("hashes ignore reformatting, moves, resizes and reordering", () => {
  const text = read("big-500.canvas"), side = read("big-500.canvas.notes.json");
  const base = hashes(C.parse(text, { sidecarText: side }));
  const data = JSON.parse(text);
  same(diff(base, hashes(C.parse(JSON.stringify(data, null, 2), { sidecarText: side }))), [], "reformatted");
  const moved = JSON.parse(text);
  for (const n of moved.nodes) { n.x += 137; n.y -= 59; n.width += 10; n.height += 7; }
  same(diff(base, hashes(C.parse(JSON.stringify(moved), { sidecarText: side }))), [], "moved and resized");
  const rev = JSON.parse(text);
  rev.nodes.reverse(); rev.edges.reverse();
  same(diff(base, hashes(C.parse(JSON.stringify(rev), { sidecarText: side }))), [], "reordered");
});
test("hashes change with content: text, word, note, connections, labels", () => {
  const text = read("big-500.canvas"), side = read("big-500.canvas.notes.json");
  const base = hashes(C.parse(text, { sidecarText: side }));
  const run = (edit, editSide) => {
    const d = JSON.parse(text), s = JSON.parse(side);
    edit(d, s);
    return diff(base, hashes(C.parse(JSON.stringify(d), { sidecarText: JSON.stringify(s) })));
  };
  const node = (d, id) => d.nodes.find((n) => n.id === id);
  same(run((d) => { node(d, "card-10").text += " More."; }), ["card-10"], "text");
  same(run((d) => { node(d, "card-11").linen.word = node(d, "card-11").linen.word === "Broken" ? "Works" : "Broken"; }), ["card-11"], "word");
  ok(JSON.parse(side)["card-0"], "card-0 has a sidecar note");
  same(run((d, s) => { s["card-0"].body = "Changed."; }), ["card-0"], "sidecar note");
  same(run((d, s) => { const n = node(d, "card-3"); s["card-3"] = n.linen.note; delete n.linen.note; }), [], "a note moved to the sidecar unchanged");
  same(run((d) => { d.edges.push({ id: "new-edge", fromNode: "card-20", toNode: "card-21" }); }), ["+new-edge", "card-20", "card-21"], "new connection");
  const e0 = JSON.parse(text).edges[0];
  same(run((d) => { d.edges[0].label = "relabelled"; }), [e0.fromNode, e0.toNode, "edge-0"].sort(), "edge label");
  same(run((d) => { d.edges[0].fromSide = "top"; d.edges[0].toSide = "bottom"; }), [], "sides are geometry, not content");
});

// ---------- spatial indexes (BRD-20) ----------
test("node and edge grids return exactly what a brute-force scan finds", () => {
  const b = load("big-2000.canvas");
  let seed = 7;
  const rand = () => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed / 0x7fffffff; };
  const B = b.bounds;
  for (let i = 0; i < 100; i++) {
    const w = 200 + rand() * 3000, h = 200 + rand() * 2000;
    const x = B.x - 500 + rand() * (B.w + 1000), y = B.y - 500 + rand() * (B.h + 1000);
    const got = b.grid.query(x, y, w, h);
    const want = b.nodes.filter((n) => n.placed && n.x <= x + w && n.x + n.w >= x && n.y <= y + h && n.y + n.h >= y).map((n) => n.id);
    eq(got.size, want.length, "node query " + i);
    for (const id of want) ok(got.has(id), "node " + id + " in query " + i);
    const egot = b.edgeGrid.query(x, y, w, h);
    const ewant = b.edges.filter((e) => e.box && e.box.x <= x + w && e.box.x + e.box.w >= x && e.box.y <= y + h && e.box.y + e.box.h >= y).map((e) => e.id);
    eq(egot.size, ewant.length, "edge query " + i);
    for (const id of ewant) ok(egot.has(id), "edge " + id + " in query " + i);
  }
});
test("big boards: every node once in the order, sections first, rows left to right", () => {
  for (const f of ["big-500.canvas", "big-2000.canvas"]) {
    const b = load(f);
    eq(b.problems.length, 0, f + " problems");
    eq(new Set(b.order).size, b.nodes.length, f + " order covers every node once");
    eq(b.order.length, b.nodes.length, f + " order length");
    same(b.order.slice(0, 4), ["sec-0", "card-0", "card-1", "card-2"], f + " order start");
    same(b.roots.slice(0, 3), ["sec-0", "sec-1", "sec-2"], f + " roots");
  }
});

// ---------- Codex review of the model (docs/reviews/m7-model-codex.md): one test per accepted finding ----------
const J = (obj) => JSON.stringify(obj);
const tnode = (id, x, y, w, h, extra) => Object.assign({ id, type: "text", text: id, x, y, width: w, height: h }, extra || {});

test("#1 absurd geometry is unplaced, huge items go to the overflow list, parsing never hangs", () => {
  // In a child process, so a hang fails the test instead of stalling the suite.
  const input = J({ nodes: [{ id: "n", type: "text", text: "x", x: 1e308, y: 0, width: 1, height: 1 }, tnode("wide", 0, 0, 1e9, 10), tnode("ok", 0, 0, 100, 100)], edges: [] });
  const script = "const fs=require('fs'),vm=require('vm');vm.runInThisContext(fs.readFileSync(process.argv[1],'utf8'));const b=LinenCanvas.parse(process.argv[2]);console.log(JSON.stringify({u:b.unplaced,p:b.problems.map(p=>p.path)}));";
  let out;
  try { out = JSON.parse(execFileSync(process.execPath, ["-e", script, MODEL, input], { encoding: "utf8", timeout: 5000 })); } catch (e) { throw new Error("parse did not finish within 5 s"); }
  same(out.u, ["n", "wide"], "unplaced");
  same(out.p, ["$.nodes[0].x", "$.nodes[1].width"], "problems");
  const b = C.parse(J({ nodes: [{ id: "g", type: "group", x: 0, y: 0, width: 900000, height: 900000 }, tnode("c", 10, 10, 100, 100)], edges: [] }));
  ok(b.byId.get("g").placed, "an allowed large section is placed");
  ok(b.grid.overflow && b.grid.overflow.indexOf("g") !== -1, "it sits in the overflow list");
  ok(b.grid.query(800000, 800000, 10, 10).has("g"), "a query far inside finds it");
  ok(b.grid.query(10, 10, 5, 5).has("c"), "small items stay in cells");
});
test("#3 wrong-typed linen fields are listed, not dropped or rounded silently", () => {
  const b = C.parse('{"linen":{"words":[{"word":"OK","shape":"outline","meaning":7,"quiet":"yes"}]},"nodes":[{"id":"g","type":"group","x":0,"y":0,"width":100,"height":100,"linen":{"layout":"grid","cols":1.5,"gap":2.25}}],"edges":[]}');
  same(b.problems.map((p) => p.path).sort(), ["$.linen.words[0].meaning", "$.linen.words[0].quiet", "$.nodes[0].linen.cols", "$.nodes[0].linen.gap"], "paths");
  eq(b.byId.get("g").cols, null);
  eq(b.byId.get("g").gap, null);
  eq(b.words[0].meaning, null);
  eq(b.words[0].quiet, false);
});
test("#5 direction counts letters as ARB-1 does, never the first letter", () => {
  const b = C.parse(J({ nodes: [tnode("n", 0, 0, 100, 100, { text: "ا English English" })], edges: [] }));
  eq(b.byId.get("n").dir, "ltr", "node");
  eq(b.dir, "ltr", "board");
  const c = C.parse(J({ nodes: [tnode("a", 0, 0, 100, 100, { text: "`code code code` العربية هنا [link text](https://example.com)" })], edges: [] }));
  eq(c.byId.get("a").dir, "rtl", "code and links are left out of the count");
});
test("#5 the letters counted are exactly Linen 1's RTL_RE and LTR_RE (read from Renderer/page.js)", () => {
  const page = fs.readFileSync(path.join(ROOT, "Renderer", "page.js"), "utf8");
  const grab = (name) => new RegExp(new RegExp("const " + name + " = /(\\[[^\\]]*\\])/g").exec(page)[1], "g");
  const RTL = grab("RTL_RE"), LTR = grab("LTR_RE");
  let s = "";
  for (let c = 0; c < 0x10000; c++) if (c < 0xd800 || c > 0xdfff) s += String.fromCharCode(c);
  same(C.letters(s), [(s.match(RTL) || []).length, (s.match(LTR) || []).length], "counts over the BMP");
  for (const sample of ["ا English English", "سطر Linen قارئ", "Ünïcödé Ελληνικά Русский", "ﭐﹰ֐"]) {
    same(C.letters(sample), [(sample.match(RTL) || []).length, (sample.match(LTR) || []).length], sample);
  }
});
test("#5 (verify) reference links, indented code and HTML links are left out too", () => {
  const dirOf = (text) => C.parse(J({ linen: { dir: "ltr" }, nodes: [tnode("n", 0, 0, 100, 100, { text })], edges: [] })).byId.get("n").dir;
  eq(dirOf("[English English English][r] العربية العربية\n\n[r]: https://example.com"), "rtl", "reference link and its definition");
  eq(dirOf("    code code code code code\n\nالعربية هنا"), "rtl", "indented code");
  eq(dirOf('<a href="x">English English English</a> العربية'), "rtl", "an HTML link");
  eq(dirOf("www.example.com/english/words العربية"), "rtl", "a www autolink");
  eq(dirOf("[English English English][missing] العربية"), "ltr", "an unresolved reference stays text, as marked prints it");
  eq(dirOf("``English English English`` العربية"), "rtl", "a double-backtick code span");
  eq(dirOf("foo@example.com العربية"), "rtl", "an email autolink");
  eq(dirOf("[English English English][] العربية\n\n[English English English]: https://example.com"), "rtl", "a collapsed reference");
});
test("#5 (verify) per-node direction agrees with marked's own lexer on 3,000 random notes", () => {
  // Oracle: marked 18 (the renderer's parser, GFM on) lexes the note; the text a reader sees outside code, links
  // and images is counted (Linen 1's directionOf skips CODE, PRE, A, KBD, SUP), then ARB-1's 60/40 rule.
  const ctx = vm.createContext({});
  vm.runInContext(fs.readFileSync(path.join(ROOT, "node_modules", "marked", "lib", "marked.umd.js"), "utf8"), ctx);
  const marked = ctx.marked;
  const SKIP = new Set(["code", "codespan", "link", "image", "html", "def", "space"]);
  const visible = (tokens) => {
    let out = "";
    for (const t of tokens) {
      if (SKIP.has(t.type)) continue;
      if (t.tokens && t.tokens.length) out += visible(t.tokens) + " ";
      else if (t.items) out += t.items.map((i) => visible(i.tokens || [])).join(" ") + " ";
      else if (typeof t.text === "string") out += t.text + " ";
    }
    return out;
  };
  const oracle = (md, fallback) => {
    // Linen's extension renders [[wiki links]] as links, which plain marked does not know.
    const [r, l] = C.letters(visible(marked.lexer(md.replace(/!?\[\[[^\]\n]*\]\]/g, "[wiki](x)"), { gfm: true })));
    if (r + l === 0) return null;
    const q = r / (r + l);
    return q > 0.6 ? "rtl" : q < 0.4 ? "ltr" : fallback;
  };
  const PIECES = ["English words here", "more English", "العربية هنا", "نص عربي طويل", "`code English`", "``code `tick` English``",
    "[English link](https://example.com)", "[English ref][r]", "[English ref][missing]", "[English][]", "[r]",
    "https://example.com/english/path", "www.example.com/english", "foo@example.com", "<https://example.com/english>",
    "**bold English**", "*عربي مائل*", "[[Wiki English]]", "![English alt](img.png)",
    // Forms from Codex's verification probes (docs/reviews/m7-model-verify2-codex.md, -verify3-codex.md).
    "\\`English English\\`", '<span class="English English">العربية</span>', "<!-- English English -->",
    "[English English\nEnglish](https://example.com)", "``` English English inline ticks", "\\[English\\]"];
  let seed = 77;
  const r = () => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed / 0x7fffffff; };
  const pick = (a) => a[Math.floor(r() * a.length)];
  // A line starting with "<!--" is an HTML block, which marked keeps whole as one html token while the DOM still
  // shows the text after the comment; the oracle cannot judge that, so a comment never opens a paragraph here.
  const para = () => {
    const p = Array.from({ length: 1 + Math.floor(r() * 5) }, () => pick(PIECES));
    if (p[0].startsWith("<!--")) p.unshift("English words here");
    return p.join(" ");
  };
  const kinds = [para, () => "    indented English code\n    more code", () => "```\nfenced English code\n```", () => "- " + para() + "\n- " + para(),
    () => "[r]: https://example.com", () => "[English English English]:", () => "````\n```\nEnglish inside a longer fence\n```\n````", () => "~~~~\nEnglish tilde fence\n~~~~"];
  // The page's realm: marked, Linen's dialect and the model, in page.html's order. There the model reads tokens.
  const pageRealm = vm.createContext({});
  for (const f of [path.join(ROOT, "node_modules", "marked", "lib", "marked.umd.js"), path.join(ROOT, "Renderer", "extensions.js"), MODEL]) {
    vm.runInContext(fs.readFileSync(f, "utf8"), pageRealm);
  }
  const PC = pageRealm.LinenCanvas;
  const exact = [], fallback = [];
  let cases = 0;
  for (let k = 0; k < 3000; k++) {
    let md = Array.from({ length: 1 + Math.floor(r() * 4) }, () => pick(kinds)()).join("\n\n");
    if (r() < 0.3) md = md.replace(/\n/g, "\r\n");
    for (const fb of ["ltr", "rtl"]) {
      cases++;
      const want = oracle(md, fb);
      if (PC.blockDirection(md, fb) !== want) exact.push(JSON.stringify(md));
      if (C.proseDirection(md, fb) !== want) fallback.push(JSON.stringify(md));
    }
  }
  eq(exact.length, 0, "page path: notes where the model and marked disagree (first: " + (exact[0] || "") + ")");
  timing.fallbackAgreement = +(100 * (1 - fallback.length / cases)).toFixed(2) + "% of " + cases;
  ok(fallback.length / cases <= 0.01, "the source-level fallback agrees on at least 99 percent: " + timing.fallbackAgreement);
  // In the page, a node's direction comes from that path, lazily.
  const b = PC.parse(J({ linen: { dir: "ltr" }, nodes: [tnode("n", 0, 0, 100, 100, { text: "- ```English English English\n- العربية هنا" })], edges: [] }));
  eq(b.byId.get("n").dir, PC.blockDirection("- ```English English English\n- العربية هنا", "ltr"), "node.dir in the page");
  eq(b.byId.get("n").dir, "rtl", "a fence inside a list item is code");
});
test("#5 (verify) the board's direction reads the text before any cut", () => {
  eq(C.parse(J({ nodes: [tnode("a", 0, 0, 100, 100, { text: "ا".repeat(100000) }), tnode("b", 200, 0, 100, 100, { text: "a".repeat(70000) })], edges: [] })).dir, "rtl");
});
test("#11 (verify) text and note together never pass 64 KB; lone surrogates count as U+FFFD", () => {
  const total = (n) => Buffer.byteLength(n.text || "", "utf8") + (n.note ? Buffer.byteLength(JSON.stringify(n.note), "utf8") : 0);
  const a = C.parse(J({ nodes: [tnode("a", 0, 0, 100, 100, { text: "x".repeat(65536), linen: { note: { title: "T" } } })], edges: [] })).byId.get("a");
  ok(total(a) <= 65536, "65,536 text bytes and a short note: " + total(a));
  eq(a.note && a.note.title, "T", "the short note is kept");
  const b = C.parse(J({ nodes: [tnode("b", 0, 0, 100, 100, { linen: { note: { title: "t".repeat(70000) } } })], edges: [] })).byId.get("b");
  ok(b.truncated && total(b) <= 65536, "a 70,000-character note title: " + total(b));
  const c = C.parse(J({ nodes: [tnode("c", 0, 0, 100, 100, { text: "\ud800ا".repeat(15000) })], edges: [] })).byId.get("c");
  ok(c.truncated && Buffer.byteLength(c.text, "utf8") <= 65536, "lone surrogates: " + Buffer.byteLength(c.text, "utf8"));
  let seed = 3;
  const r = () => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed / 0x7fffffff; };
  const parts = ["a", "é", "ب", "😀", "\ud800", "\udc00", "中", "\n", '"'];
  for (let k = 0; k < 300; k++) {
    let s = "";
    const n = Math.floor(r() * 400);
    for (let i = 0; i < n; i++) s += parts[Math.floor(r() * parts.length)];
    eq(C.utf8Length(s), Buffer.byteLength(s, "utf8"), "utf8Length " + k);
    const max = Math.floor(r() * 600);
    const cut = C.cutUtf8(s, max);
    ok(s.startsWith(cut) && Buffer.byteLength(cut, "utf8") <= max, "the cut fits " + k);
    const next = s.slice(cut.length);
    if (next) ok(Buffer.byteLength(cut + String.fromCodePoint(next.codePointAt(0)), "utf8") > max, "the cut is maximal " + k);
  }
});
test("#6 overlapping nodes share a reading row", () => {
  same(C.parse(J({ nodes: [tnode("right", 100, 0, 100, 100), tnode("left", 0, 99, 100, 100)], edges: [] })).order, ["left", "right"]);
});
test("#7 the smallest section holding a node's centre is its parent, whatever the node's size", () => {
  const b = C.parse(J({ nodes: [{ id: "g", type: "group", x: 50, y: 50, width: 100, height: 100 }, tnode("c", 0, 0, 200, 200)], edges: [] }));
  eq(b.byId.get("c").parent, "g");
  const d = C.parse(J({ nodes: [{ id: "A", type: "group", x: 0, y: 0, width: 100, height: 100 }, { id: "B", type: "group", x: 0, y: 0, width: 100, height: 100 }], edges: [] }));
  eq(d.byId.get("B").parent, "A", "equal sections: the earlier holds the later");
  eq(d.byId.get("A").parent, null);
});
test("#8 a dangling connection still counts in its existing end's hash", () => {
  const mk = (label) => C.parse(J({ nodes: [tnode("a", 0, 0, 100, 100)], edges: [{ id: "e", fromNode: "a", toNode: "ghost", label }] }));
  ok(mk("one").byId.get("a").hash !== mk("two").byId.get("a").hash, "a label change shows on a");
  same(mk("one").edgesOf.get("a"), ["e"], "edgesOf");
});
test("#9 a note field named __proto__ is kept and hashed", () => {
  const mk = (v) => C.parse('{"nodes":[{"id":"a","type":"text","text":"A","x":0,"y":0,"width":100,"height":100,"linen":{"note":{"title":"T","fields":{"__proto__":"' + v + '"}}}}],"edges":[]}');
  const one = mk("one"), two = mk("two");
  ok(Object.prototype.hasOwnProperty.call(one.byId.get("a").note.fields, "__proto__"), "own field");
  eq(one.byId.get("a").note.fields["__proto__"], "one");
  ok(one.byId.get("a").hash !== two.byId.get("a").hash, "the hash changes");
});
test("#10 a connector with one end missing is a stub to its gap mark, and indexed", () => {
  const b = C.parse(J({ nodes: [tnode("a", 0, 0, 100, 100)], edges: [{ id: "e", fromNode: "a", toNode: "ghost" }, { id: "f", fromNode: "ghost", toNode: "a", toSide: "top" }] }));
  const e = b.edgesById.get("e"), f = b.edgesById.get("f");
  eq(e.stub, "to");
  same([e.p1, e.p2], [{ x: 100, y: 50 }, { x: 148, y: 50 }], "e out of the right side");
  eq(f.stub, "from");
  same([f.p1, f.p2], [{ x: 50, y: -48 }, { x: 50, y: 0 }], "f into the top");
  ok(b.edgeGrid.query(90, 40, 20, 20).has("e"), "e found beside a");
  ok(b.edgeGrid.query(40, -60, 20, 20).has("f"), "f found above a");
});
test("#11 byte limits count UTF-8, inline and in the notes file", () => {
  const n = C.parse(J({ nodes: [tnode("a", 0, 0, 100, 100, { text: "ا".repeat(40000) })], edges: [] })).byId.get("a");
  const bytes = Buffer.byteLength(n.text, "utf8");
  ok(n.truncated && bytes <= 65536 && bytes > 65000, "80,000 bytes of Arabic cut to 64 KB, got " + bytes);
  const sc = C.parse(J({ nodes: [tnode("a", 0, 0, 100, 100)], edges: [] }), { sidecarText: J({ a: { title: "Big", body: "x".repeat(2100000) } }) });
  eq(sc.fatal && sc.fatal.reason, "limits", "a 2.1 MB notes file is past the board's limit");
  ok(Buffer.byteLength(JSON.stringify(sc.byId.get("a").note), "utf8") <= 65536, "the sidecar note is cut to the node's budget");
  const inl = C.parse(J({ nodes: [tnode("a", 0, 0, 100, 100, { linen: { note: { title: "T", body: "ب".repeat(40000) } } })], edges: [] })).byId.get("a");
  ok(inl.truncated && Buffer.byteLength(JSON.stringify(inl.note), "utf8") <= 65536, "an inline note is cut too");
});
test("#12 limits count accepted entries, not skipped ones", () => {
  const b = C.parse(J({ nodes: [tnode("a", 0, 0, 100, 100)].concat(Array(2000).fill(null)), edges: [] }));
  eq(b.fatal, null);
  eq(b.nodes.length, 1);
  eq(b.problems.length, 2000);
});
test("#13 2,000 nested sections: right parents and depths, under 60 ms (p95)", () => {
  const text = read("nested-2000.canvas");
  const t0 = performance.now();
  const b = C.parse(text);
  const first = performance.now() - t0;
  eq(b.problems.length, 0, "no problems");
  eq(b.byId.get("g0").parent, "g1");
  eq(b.byId.get("g1998").parent, "g1999");
  eq(b.byId.get("g1999").parent, null);
  eq(b.byId.get("g0").depth, 1999);
  same(b.order.slice(0, 3), ["g1999", "g1998", "g1997"], "order from the outside in");
  eq(b.order.length, 2000);
  ok(first < 1000, "first parse " + first.toFixed(0) + " ms");
  for (let i = 0; i < 5; i++) C.parse(text);
  const t = [];
  for (let i = 0; i < 20; i++) { const s = performance.now(); C.parse(text); t.push(performance.now() - s); }
  t.sort((x, y) => x - y);
  timing.nested = { p50: +t[10].toFixed(1), p95: +t[18].toFixed(1) };
  ok(t[18] < 60, "p95 " + t[18].toFixed(1) + " ms");
});
test("#14 nested field problems point at the field's own line", () => {
  const text = obsidian({
    nodes: [tnode("a", 0, 0, 100, 100, { linen: { word: 42, note: { title: "T", refs: ["ok", 7] } } })],
    edges: [{ id: "e", fromNode: "a", toNode: "a", linen: { kind: "maybe", note: { body: 5 } } }],
  });
  const b = C.parse(text);
  const at = (p) => (b.problems.find((x) => x.path === p) || {}).line;
  eq(at("$.nodes[0].linen.word"), lineOf(text, '"word":42'), "word");
  eq(at("$.nodes[0].linen.note.refs[1]"), lineOf(text, '"refs":["ok",7]'), "refs[1]");
  eq(at("$.edges[0].linen.kind"), lineOf(text, '"kind":"maybe"'), "edge kind");
  eq(at("$.edges[0].linen.note.body"), lineOf(text, '"note":{"body":5}'), "edge note body");
});
test("#15 node and edge ids share one namespace", () => {
  const b = C.parse(J({ nodes: [tnode("a", 0, 0, 100, 100), tnode("b", 200, 0, 100, 100)], edges: [{ id: "a", fromNode: "a", toNode: "b" }] }), { sidecarText: J({ a: { title: "Note" } }) });
  eq(b.edgesById.has("a"), false, "the edge is skipped");
  same(b.problems.map((p) => [p.severity, p.path]), [["error", "$.edges[0].id"]], "problems");
  eq(b.byId.get("a").note.title, "Note", "the note belongs to the node");
});

// ---------- speed ----------
test("parse + order + index of 2,000 nodes and 3,000 edges under 60 ms (p95, node)", () => {
  const text = read("big-2000.canvas"), side = read("big-2000.canvas.notes.json");
  for (let i = 0; i < 10; i++) C.parse(text, { sidecarText: side });
  const t = [];
  for (let i = 0; i < 30; i++) { const t0 = performance.now(); C.parse(text, { sidecarText: side }); t.push(performance.now() - t0); }
  t.sort((a, b) => a - b);
  timing.node = { p50: +t[15].toFixed(1), p95: +t[28].toFixed(1) };
  ok(t[28] < 60, "p95 " + t[28].toFixed(1) + " ms");
});

// ---------- bare JavaScriptCore (the engine inside WKWebView) ----------
test("runs in bare JavaScriptCore with no DOM and no node", () => {
  if (!fs.existsSync(JSC)) throw new Error("jsc not found at " + JSC);
  const script = path.join(ROOT, "build", "board-model-jsc.js");
  fs.mkdirSync(path.dirname(script), { recursive: true });
  fs.writeFileSync(script, [
    "load(" + JSON.stringify(MODEL) + ");",
    "var dir = " + JSON.stringify(FIX + "/") + ";",
    "var C = LinenCanvas;",
    "var k = C.parse(readFile(dir + 'kinds.canvas'));",
    "var bad = C.parse(readFile(dir + 'invalid-not-json.canvas'));",
    "var text = readFile(dir + 'big-2000.canvas'), side = readFile(dir + 'big-2000.canvas.notes.json');",
    "for (var i = 0; i < 10; i++) C.parse(text, { sidecarText: side });",
    "var t = [];",
    "for (var i = 0; i < 30; i++) { var t0 = preciseTime(); var b = C.parse(text, { sidecarText: side }); t.push((preciseTime() - t0) * 1000); }",
    "t.sort(function (a, b) { return a - b; });",
    "print(JSON.stringify({ kinds: k.nodes.length, badLine: bad.fatal.problems[0].line, badColumn: bad.fatal.problems[0].column, nodes: b.nodes.length, edges: b.edges.length, order: b.order.length, p50: +t[15].toFixed(1), p95: +t[28].toFixed(1) }));",
  ].join("\n"));
  const out = JSON.parse(execFileSync(JSC, [script], { encoding: "utf8" }).trim());
  eq(out.kinds, 20, "kinds in jsc");
  eq(out.badLine, 4, "error line in jsc");
  eq(out.badColumn, 3, "error column in jsc");
  eq(out.nodes, 2000);
  eq(out.edges, 3000);
  eq(out.order, 2000);
  timing.jsc = { p50: out.p50, p95: out.p95 };
  ok(out.p95 < 60, "jsc p95 " + out.p95 + " ms");
});

console.log(passed + " passed, " + failed + " failed");
console.log("big-2000 parse (ms):", JSON.stringify(timing));
for (const f of failures) console.log("FAIL " + f);
process.exit(failed ? 1 : 0);
