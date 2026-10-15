// Tests for Renderer/board-author.js: node Tests/board-author.test.js
"use strict";
const path = require("path");
const R = path.join(__dirname, "..", "Renderer");
const Author = require(path.join(R, "board-author.js"));
const Writer = require(path.join(R, "canvas-writer.js"));
require(path.join(R, "board-model.js"));
const Canvas = globalThis.LinenCanvas || global.self?.LinenCanvas;

let pass = 0, fail = 0;
function ok(name, cond, detail) {
  if (cond) pass++; else { fail++; console.log("FAIL " + name + (detail ? ": " + detail : "")); }
}

const spec = {
  title: "Requests readiness",
  columns: 2,
  sections: [
    { id: "s-intake", title: "Intake", cols: 2, cards: [
      { id: "form", title: "Request form", body: "Validates and stores a request.", word: "Works" },
      { id: "api", title: "Night intake API", body: "Runs nightly; the last run failed.", word: "Broken", note: { title: "The nightly run fails", body: "Stops at export.", refs: ["jobs/nightly.py:42"] } },
      { id: "idea", kind: "sticky", title: "Ask finance about the batch window", color: "3" },
    ] },
    { id: "s-review", title: "Review", cards: [
      { id: "queue", title: "Review queue", body: "Sorted by age.", word: "Partial" },
      { id: "plan", kind: "file", file: "plans/review.md" },
      { id: "gate", kind: "shape", shape: "diamond", title: "Approved?" },
    ] },
    { id: "s-ship", title: "Ship", cards: [{ id: "ship", title: "Ship it", word: "Planned" }] },
  ],
  edges: [
    { from: "form", to: "api", label: "queues", kind: "code" },
    { from: "api", to: "queue" },
    { from: "queue", to: "ghost" },
  ],
};

const r = Author.compose(spec);
ok("compose reports the edge to a missing box", r.problems.some((p) => p.path === "edges[2].to" && p.severity === "error"));
spec.edges.pop();
const good = Author.compose(spec);
ok("compose of a good spec has no errors", !good.problems.some((p) => p.severity === "error"), JSON.stringify(good.problems));
const text = Writer.serialise(good.canvas);
const notes = JSON.stringify(good.notes);
const board = Canvas.parse(text, { sidecarText: notes });
ok("the composed board parses without fatal", !board.fatal, JSON.stringify(board.fatal));
const checked = Canvas.check(board).filter((p) => p.severity === "error");
ok("the composed board passes check", checked.length === 0, JSON.stringify(checked.slice(0, 3)));
ok("every box is placed", board.nodes.every((n) => n.placed !== false));
ok("ids are kept", ["form", "api", "idea", "queue", "plan", "gate", "ship", "s-intake"].every((id) => board.byId.has(id)));
ok("cards sit in their sections", board.byId.get("api").parent === "s-intake" && board.byId.get("gate").parent === "s-review" && board.byId.get("ship").parent === "s-ship");
ok("the note went to the sidecar", board.byId.get("api").noteFrom === "sidecar");
ok("kinds are right", board.byId.get("idea").kind === "sticky" && board.byId.get("gate").kind === "shape" && board.byId.get("plan").kind === "note");
ok("words are read", board.byId.get("api").word === "Broken");
ok("title is set", board.title === "Requests readiness");
ok("two columns of sections: ship starts a second row", board.byId.get("s-ship").y > board.byId.get("s-intake").y + board.byId.get("s-intake").h);
ok("no sections overlap", (() => {
  const gs = board.nodes.filter((n) => n.kind === "section");
  return gs.every((a, i) => gs.every((b, j) => i === j || a.x + a.w <= b.x || b.x + b.w <= a.x || a.y + a.h <= b.y || b.y + b.h <= a.y));
})());
ok("cards inside a section do not overlap", (() => {
  const kids = board.nodes.filter((n) => n.parent === "s-intake");
  return kids.every((a, i) => kids.every((b, j) => i === j || a.x + a.w <= b.x || b.x + b.w <= a.x || a.y + a.h <= b.y || b.y + b.h <= a.y));
})());

// Edits change exactly the boxes they touch.
const hashOf = (b) => new Map(b.nodes.map((n) => [n.id, n.hash]));
const before = hashOf(board);
const e = Author.edit(good.canvas, good.notes, [
  { op: "set", id: "api", word: "Works", body: "Fixed: the export step retries." },
  { op: "set", id: "queue", note: { body: "Now sorted by team too." } },
]);
ok("edit has no problems", e.problems.length === 0, JSON.stringify(e.problems));
ok("edit reports the changed ids", JSON.stringify(e.changed.sort()) === JSON.stringify(["api", "queue"]));
const after = Canvas.parse(Writer.serialise(e.canvas), { sidecarText: JSON.stringify(e.notes) });
const ah = hashOf(after);
const moved = [...before.keys()].filter((id) => before.get(id) !== ah.get(id));
// api changed text and word; queue changed its note; form, which connects to api, keeps its hash (connections, not their ends' text).
ok("only the edited boxes change hash", JSON.stringify(moved.sort()) === JSON.stringify(["api", "queue"]), moved.join(","));
ok("the title survives a body edit", after.byId.get("api").title === "Night intake API");
ok("a note stays where it lived (sidecar)", after.byId.get("queue").noteFrom === "sidecar" && e.notes.queue.body === "Now sorted by team too.");

const e2 = Author.edit(e.canvas, e.notes, [
  { op: "add", section: "s-review", card: { id: "audit", title: "Audit trail", word: "Missing" } },
  { op: "connect", from: "queue", to: "audit", kind: "plan" },
  { op: "remove", id: "idea" },
]);
const bad = Author.edit(e.canvas, e.notes, [{ op: "set", id: "nope", word: "Works" }]);
ok("an unknown id is an error with a hint", bad.rejected && bad.problems.some((p) => /No box with id "nope".*read_outline/.test(p.message)));
const b2 = Canvas.parse(Writer.serialise(e2.canvas), { sidecarText: JSON.stringify(e2.notes) });
ok("added box sits in its section", b2.byId.get("audit") && b2.byId.get("audit").parent === "s-review");
ok("removed box is gone with no dangling edges", !b2.byId.has("idea") && Canvas.check(b2).filter((p) => p.severity === "error").length === 0);

// Reflow after layout grows a section keeps rows apart and never overlaps.
const grown = JSON.parse(JSON.stringify(good.canvas));
const members = Author.membership(grown);
grown.nodes.find((n) => n.id === "s-intake").height += 900;
const rf = Author.reflow(grown, members);
const b3 = Canvas.parse(Writer.serialise(rf.canvas), { sidecarText: notes });
ok("reflow moves the second row below the grown section", b3.byId.get("s-ship").y >= b3.byId.get("s-intake").y + b3.byId.get("s-intake").h + 150);
ok("reflow keeps cards inside their sections", b3.byId.get("ship").parent === "s-ship" && b3.byId.get("api").parent === "s-intake");
ok("reflow changes no hash", [...hashOf(b3)].every(([id, h]) => hashOf(board).get(id) === h));
const hand = { nodes: [{ id: "a", type: "text", text: "x", x: 5, y: 5, width: 100, height: 60 }], edges: [] };
ok("reflow never moves a hand-placed board", Author.reflow(hand).moved === 0);

// Codex review m8 findings, each a case that failed before the fix.
const dup = Author.compose({ sections: [{ id: "x", title: "X", cards: [{ id: "x", title: "card" }] }] });
ok("an explicit id used twice is an error (#3)", dup.problems.some((p) => p.severity === "error" && /used twice/.test(p.message)));
const twoEdges = Author.compose({ sections: [{ id: "s", title: "S", cards: [{ id: "a", title: "A" }, { id: "b", title: "B" }] }], edges: [{ from: "a", to: "b" }, { from: "a", to: "b" }] });
const tb = Canvas.parse(Writer.serialise(twoEdges.canvas), {});
ok("two connectors between the same boxes get distinct ids (#4)", new Set(twoEdges.canvas.edges.map((e) => e.id)).size === 2 && Canvas.check(tb).filter((p) => p.severity === "error").length === 0);
const sb = Author.edit(good.canvas, good.notes, [{ op: "set_board", title: "Renamed", dir: "rtl" }]);
ok("set_board alone is a change (#5)", sb.boardChanged === true && sb.canvas.linen.title === "Renamed" && !sb.rejected);
const nested = Author.compose({ sections: [{ id: "outer", title: "Outer", cards: [{ id: "o1", title: "One" }] }] });
nested.canvas.nodes.push({ id: "inner", type: "group", x: nested.canvas.nodes[1].x, y: nested.canvas.nodes[1].y + 200, width: 200, height: 160, label: "Inner" });
nested.canvas.nodes.push({ id: "deep", type: "text", text: "Deep", x: nested.canvas.nodes[1].x + 10, y: nested.canvas.nodes[1].y + 240, width: 150, height: 60 });
nested.canvas.nodes[0].height += 400;
const rs = Author.edit(nested.canvas, null, [{ op: "remove_section", id: "outer" }]);
ok("removing a section removes its nested sections and boxes (#6)", !rs.rejected && rs.canvas.nodes.length === 0, rs.canvas.nodes.map((n) => n.id).join(","));
const tx = Author.edit(good.canvas, good.notes, [{ op: "remove", id: "form" }, { op: "set", id: "ghost", word: "Works" }]);
ok("one failing op leaves the board untouched (#1)", tx.rejected === true && tx.changed.length === 0 && tx.canvas.nodes.some((n) => n.id === "form"));
const typed = Author.edit(good.canvas, good.notes, [{ op: "set", id: "api", note: 7 }]);
ok("a wrong field type is refused before anything changes (#8)", typed.rejected === true && /note must be/.test(typed.problems[0].message) && typed.notes.api);
const dragged = JSON.parse(JSON.stringify(good.canvas));
const ship = dragged.nodes.find((n) => n.id === "s-ship");
const dxShip = 5000 - ship.x;
for (const n of dragged.nodes) if (n.id === "s-ship" || n.id === "ship") { n.x += dxShip; }
const keep = Author.reflow(dragged, Author.membership(dragged));
ok("reflow leaves a section dragged clear of the others where it is (#7)", keep.canvas.nodes.find((n) => n.id === "s-ship").x === 5000 && keep.moved === 0, "moved " + keep.moved);

// Evaluation round 2 findings.
const rtl2 = Author.compose({ dir: "rtl", columns: 3, sections: [1, 2, 3].map((i) => ({ id: "s" + i, title: "قسم " + i, cards: [{ id: "c" + i, title: "صندوق " + i }] })) });
const xs = ["s1", "s2", "s3"].map((id) => rtl2.canvas.nodes.find((n) => n.id === id).x);
ok("an rtl board puts its first section at the right", xs[0] > xs[1] && xs[1] > xs[2], xs.join(","));
const custom = Author.compose({ words: [{ word: "Tested", shape: "solid" }, { word: "Built", shape: "outline", quiet: true }], sections: [{ id: "s", title: "S", cards: [{ id: "a", title: "A", word: "Works" }] }] });
ok("a box word the board does not define is an error before writing", custom.problems.some((p) => p.severity === "error" && /not one of this board's words \(Tested, Built\)/.test(p.message)));
const customOk = Author.compose({ words: [{ word: "Tested", shape: "solid" }, { word: "Built", shape: "outline", quiet: true }], sections: [{ id: "s", title: "S", cards: [{ id: "a", title: "A", word: "Built" }] }] });
const w1 = Author.edit(customOk.canvas, null, [{ op: "set", id: "a", word: "Works" }]);
ok("edit refuses a word the board does not define, with the list", w1.rejected && /Tested, Built/.test(w1.problems[0].message));
const w2 = Author.edit(customOk.canvas, null, [{ op: "set_board", words: ["Tested", "Built", { word: "Works", shape: "outline" }] }, { op: "set", id: "a", word: "Works" }]);
ok("set_board with names keeps their definitions and the new word works in the same call", !w2.rejected && w2.canvas.linen.words[0].shape === "solid" && w2.canvas.linen.words[1].quiet === true && w2.changed.includes("a"));

// Codex verification of the m8 fixes: its reproductions.
const v1 = Author.edit(good.canvas, good.notes, [{ op: "remove", id: "form" }, { op: "disconnect", id: "missing-edge" }]);
ok("a disconnect that matches nothing rejects the batch (v#3)", v1.rejected && v1.canvas.nodes.some((n) => n.id === "form"));
const v2 = Author.edit(good.canvas, good.notes, [{ op: "remove", id: "s-intake" }]);
ok("remove on a section is refused and points to remove_section (v#3)", v2.rejected && /remove_section/.test(v2.problems[0].message));
const v3 = Author.edit(good.canvas, good.notes, [{ op: "add", section: "s-intake", card: { id: "z", note: 7, kind: "bogus" } }]);
ok("add checks the card's fields (v#3)", v3.rejected && v3.problems.length >= 2);
const v4 = Author.edit(customOk.canvas, null, [{ op: "add_section", section: { id: "s2", title: "More", cards: [{ id: "b2", title: "B2", word: "Built" }] } }]);
ok("add_section on a board with its own words accepts them (v#4)", !v4.rejected && v4.changed.includes("b2"), JSON.stringify(v4.problems));
const cross = { linen: { rows: { columns: 3 } }, edges: [], nodes: [
  { id: "early", type: "group", x: 500, y: 0, width: 200, height: 500, label: "E" },
  { id: "l1", type: "group", x: 0, y: 600, width: 400, height: 100, label: "L1" },
  { id: "l2", type: "group", x: 300, y: 600, width: 300, height: 100, label: "L2" },
] };
const rc = Author.reflow(cross, Author.membership(cross)).canvas.nodes;
ok("the reflow case is two top-level sections in one row", !Author.membership(cross).l2);
const overlaps = rc.some((a, i) => rc.some((b, j) => i < j && a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height));
ok("reflow never creates an overlap across rows (v#5)", !overlaps, JSON.stringify(rc.map((n) => [n.id, n.x, n.y])));

// Codex verification 2: its reproductions.
const t1 = Author.edit(good.canvas, good.notes, [{ op: "add", section: "s-intake", card: { id: "q", file: 7, color: {}, note: { refs: [7] } } }]);
ok("add refuses mistyped file, color and note refs (v2#5)", t1.rejected && t1.problems.length >= 3, JSON.stringify(t1.problems.map((p) => p.path)));
const t2 = Author.edit(good.canvas, good.notes, [{ op: "move", id: "s-review", section: "s-intake" }]);
ok("move refuses a section as the box (v2#5)", t2.rejected && /is a section/.test(t2.problems[0].message));
const t3 = Author.compose({ sections: [{ id: "s", title: "S", cards: [{ id: "a", title: 5 }] }] });
ok("compose refuses a mistyped field instead of coercing it", t3.problems.some((p) => p.severity === "error" && /title must be text/.test(p.message)));
const exact = { linen: { rows: { columns: 3 } }, edges: [], nodes: [
  { id: "early", type: "group", x: 500, y: 0, width: 200, height: 500, label: "E" },
  { id: "l1", type: "group", x: 0, y: 100, width: 400, height: 100, label: "L1" },
  { id: "l2", type: "group", x: 300, y: 100, width: 100, height: 100, label: "L2" },
] };
// Codex's exact case: l2 lies wholly inside l1, which is how JSON Canvas (and Obsidian) nests a section, so it moves
// with l1 rather than being pushed apart from it; what must hold is that no top-level section overlaps another.
const ex = Author.reflow(exact, Author.membership(exact)).canvas.nodes;
const top = ex.filter((n) => n.id !== "l2");
ok("Codex's exact reflow case: l2 is nested in l1 and no top-level sections overlap", Author.membership(exact).l2 === "l1" &&
  !top.some((a, i) => top.some((b, j) => i < j && a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height)),
  JSON.stringify(ex.map((n) => [n.id, n.x, n.y])));

// Arabic and right to left.
const ar = Author.compose({ dir: "rtl", sections: [{ id: "s-1", title: "الاستلام", cards: [{ id: "c1", title: "نموذج الطلب", body: "يتحقق من الطلب ويحفظه.", word: "Works" }] }] });
const bar = Canvas.parse(Writer.serialise(ar.canvas), {});
ok("an Arabic board is right to left", bar.dir === "rtl");

console.log(`${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
