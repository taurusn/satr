// Tests for Renderer/router.js (PRD-2 section 17: ENG-1, ENG-2, ENG-5).
//   node Tests/router.test.js
// Geometry only: the pixel witness (board-host witness) checks what is drawn.
"use strict";
const assert = require("assert");
const fs = require("fs");
const path = require("path");
const R = path.join(__dirname, "..", "Renderer");
require(path.join(R, "board-model.js"));
const Router = require(path.join(R, "router.js"));
const { LinenCanvas } = globalThis;
const FIX = path.join(__dirname, "Fixtures", "boards");

const tests = [];
const test = (name, fn) => tests.push([name, fn]);

const box = (id, x, y, w, h, extra) => Object.assign({ id, x, y, w: w || 200, h: h || 80, section: false, parent: null }, extra || {});
const edge = (id, from, to, extra) => Object.assign({ id, from, to, route: "elbow", kind: "works" }, extra || {});
const run = (boxes, edges, bands) => Router.route({ boxes, edges, bands: bands || [] });

// A segment enters a box when it overlaps the box's open interior (touching its border is allowed at the line's ends).
function entersBox(a, b, r) {
  const x0 = Math.min(a[0], b[0]), x1 = Math.max(a[0], b[0]), y0 = Math.min(a[1], b[1]), y1 = Math.max(a[1], b[1]);
  return x1 > r.x + 0.01 && x0 < r.x + r.w - 0.01 && y1 > r.y + 0.01 && y0 < r.y + r.h - 0.01;
}
function clearOf(route, boxes) {
  for (let i = 1; i < route.pts.length; i++) for (const r of boxes) if (entersBox(route.pts[i - 1], route.pts[i], r)) return r.id;
  return null;
}
const orthogonal = (pts) => pts.every((p, i) => i === 0 || p[0] === pts[i - 1][0] || p[1] === pts[i - 1][1]);

test("a line goes around a box that stands between its ends", () => {
  const boxes = [box("a", 0, 0), box("wall", 300, -100, 120, 280), box("b", 520, 0)];
  const { routes } = run(boxes, [edge("e", "a", "b")]);
  const r = routes.get("e");
  assert.ok(r.clear);
  assert.ok(orthogonal(r.pts), "right angles only");
  assert.strictEqual(clearOf(r, boxes), null);
  // it keeps the gap: no point closer than 4 px to the wall
  for (const p of r.pts) assert.ok(!(p[0] > 296 && p[0] < 424 && p[1] > -104 && p[1] < 184), "kept off the wall: " + p);
});

test("boxes side by side face each other: right to left, straight when level", () => {
  const { routes } = run([box("a", 0, 0), box("b", 400, 0)], [edge("e", "a", "b")]);
  const r = routes.get("e");
  assert.strictEqual(r.fromSide, "right");
  assert.strictEqual(r.toSide, "left");
  assert.strictEqual(r.pts.length, 2, JSON.stringify(r.pts));
  assert.deepStrictEqual(r.pts[0], [200, 40]);
  assert.deepStrictEqual(r.pts[1], [400, 40]);
});

test("sides the file gives are kept", () => {
  const { routes } = run([box("a", 0, 0), box("b", 400, 0)], [edge("e", "a", "b", { fromSide: "bottom", toSide: "bottom", fromSideGiven: true, toSideGiven: true })]);
  const r = routes.get("e");
  assert.strictEqual(r.fromSide, "bottom");
  assert.strictEqual(r.toSide, "bottom");
  assert.ok(r.clear);
  assert.ok(r.pts[0][1] === 80 && r.pts[r.pts.length - 1][1] === 80);
});

test("lines on one side of a box leave from spread points, ordered by their other ends", () => {
  const boxes = [box("hub", 0, 200, 200, 200), box("t1", 500, 0), box("t2", 500, 260), box("t3", 500, 520)];
  const edges = [edge("e3", "hub", "t3"), edge("e1", "hub", "t1"), edge("e2", "hub", "t2")];
  const { routes } = run(boxes, edges);
  const ys = ["e1", "e2", "e3"].map((id) => routes.get(id).pts[0][1]);
  assert.ok(ys[0] < ys[1] && ys[1] < ys[2], "top to bottom like their targets: " + ys);
  assert.ok(new Set(ys).size === 3);
  for (const id of ["e1", "e2", "e3"]) assert.strictEqual(routes.get(id).pts[0][0], 200);
});

test("the same input gives the same lines (the file's order decides)", () => {
  const text = fs.readFileSync(path.join(FIX, "big-500.canvas"), "utf8");
  const b = LinenCanvas.parse(text);
  const a1 = Router.route(Router.fromBoard(b, { all: true })), a2 = Router.route(Router.fromBoard(b, { all: true }));
  for (const [id, r] of a1.routes) assert.deepStrictEqual(r.pts, a2.routes.get(id).pts, id);
});

test("a label chip is a cost, never a wall: two labelled lines through one narrow gap both stay clear", () => {
  const boxes = [box("a1", 0, 0), box("a2", 0, 100), box("b1", 280, 0), box("b2", 280, 100)];
  const { routes } = run(boxes, [edge("e1", "a1", "b1", { label: "sends a long label" }), edge("e2", "a2", "b2", { label: "and another one" })]);
  for (const id of ["e1", "e2"]) { assert.ok(routes.get(id).clear, id); assert.strictEqual(clearOf(routes.get(id), boxes), null, id); }
});

test("a label sits on the line's longest run, clear of boxes", () => {
  const boxes = [box("a", 0, 0), box("b", 600, 300)];
  const { routes } = run(boxes, [edge("e", "a", "b", { label: "approves" })]);
  const L = routes.get("e").label;
  assert.ok(L && L.clear);
  for (const r of boxes) assert.ok(!(L.x + L.w / 2 > r.x && L.x - L.w / 2 < r.x + r.w && L.y + L.h / 2 > r.y && L.y - L.h / 2 < r.y + r.h), "chip off box " + r.id);
});

test("straight lines stay straight when clear, and take corners round a box", () => {
  const boxes = [box("a", 0, 0), box("b", 600, 300), box("c", 0, 400), box("d", 600, 400), box("mid", 280, 380, 120, 120)];
  const { routes } = run(boxes, [edge("s", "a", "b", { route: "straight" }), edge("t", "c", "d", { route: "straight" })]);
  assert.strictEqual(routes.get("s").how, "straight");
  assert.strictEqual(routes.get("s").pts.length, 2);
  assert.notStrictEqual(routes.get("t").how, "straight");
  assert.ok(routes.get("t").straightBlocked);
  assert.strictEqual(clearOf(routes.get("t"), boxes), null);
});

test("a box's line to itself loops outside it", () => {
  const boxes = [box("a", 0, 0)];
  const r = run(boxes, [edge("e", "a", "a")]).routes.get("e");
  assert.strictEqual(r.how, "loop");
  assert.strictEqual(clearOf(r, boxes), null);
});

test("section names are kept clear", () => {
  const boxes = [box("a", 0, 200), box("b", 0, -300)];
  const band = { x: -200, y: 20, w: 600, h: 60 };
  const r = run(boxes, [edge("e", "a", "b")], [band]).routes.get("e");
  assert.ok(r.clear);
  assert.strictEqual(clearOf(r, [{ id: "band", ...band }]), null);
});

test("a line between a box and the section around it is left to the plain drawing", () => {
  const boxes = [box("s", 0, 0, 800, 600, { section: true }), box("a", 100, 100, 200, 80, { parent: "s" })];
  const { routes } = run(boxes, [edge("e", "a", "s")]);
  assert.ok(!routes.has("e"));
});

test("corners round for drawing, stubs into boxes stay straight", () => {
  const pts = [[0, 0], [20, 0], [20, 100], [120, 100]];
  const sm = Router.smooth(pts, 8);
  assert.deepStrictEqual(sm[0], [0, 0]);
  assert.deepStrictEqual(sm[sm.length - 1], [120, 100]);
  assert.ok(sm.length > pts.length);
  // the last run into the box is horizontal for at least 6 px
  const last = sm[sm.length - 1], prev = sm[sm.length - 2];
  assert.strictEqual(prev[1], 100);
  assert.ok(last[0] - prev[0] >= 6);
});

test("the fixtures and a flow board route clear of every box", () => {
  for (const f of ["connectors.canvas", "arabic-rtl.canvas", "notes-inline.canvas", "big-500.canvas"]) {
    const b = LinenCanvas.parse(fs.readFileSync(path.join(FIX, f), "utf8"));
    const input = Router.fromBoard(b, { all: true });
    const res = Router.route(input);
    const rects = input.boxes.filter((x) => !x.section);
    for (const [id, r] of res.routes) {
      if (!r.clear) continue; // reported as drawn above the boxes
      const e = b.edgesById.get(id);
      const others = rects.filter((x) => x.id !== e.from && x.id !== e.to);
      assert.strictEqual(clearOf(r, others), null, `${f} ${id}`);
      assert.ok(r.how === "straight" || orthogonal(r.pts), `${f} ${id} orthogonal`);
    }
    console.log(`     ${f}: ${res.stats.routed} lines in ${res.stats.ms.toFixed(0)} ms, ${res.stats.crossings} crossings, ${res.stats.notClear} not clear`);
  }
});

test("a line is routed on its own: moving a box away from it changes nothing (round 10, finding 3)", () => {
  const boxes = [box("a", 0, 0), box("b", 600, 300), box("wall", 300, -60, 80, 300), box("far", 1400, 900), box("far2", 1800, 900)];
  const edges = [edge("e", "a", "b"), edge("f", "far", "far2")];
  const r1 = run(boxes, edges).routes.get("e");
  const moved = boxes.map((q) => (q.id === "far" ? Object.assign({}, q, { x: q.x + 40 }) : q));
  const r2 = run(moved, edges).routes.get("e");
  assert.deepStrictEqual(r1.pts, r2.pts);
});

test("lines that share a gap are spread apart, and stay clear", () => {
  // two lines from the left column to the right column, both through the one gap in the wall between them
  const boxes = [box("a1", 0, 0), box("a2", 0, 120), box("m1", 400, -300, 120, 480), box("m2", 400, 260, 120, 400), box("b1", 900, 0), box("b2", 900, 120)];
  const { routes } = run(boxes, [edge("e1", "a1", "b1"), edge("e2", "a2", "b2")]);
  const walls = boxes.filter((q) => q.id.startsWith("m"));
  for (const id of ["e1", "e2"]) { assert.ok(routes.get(id).clear, id); assert.strictEqual(clearOf(routes.get(id), walls), null, id); }
  assert.ok(routes.get("e1").pts.some((p) => p[1] > 180 && p[1] < 260), "through the gap");
  // any two parallel runs of different lines that overlap are at least 4 px apart
  const runs = [];
  for (const id of ["e1", "e2"]) { const p = routes.get(id).pts; for (let i = 1; i < p.length; i++) runs.push({ id, a: p[i - 1], b: p[i] }); }
  for (const u of runs) for (const v of runs) {
    if (u.id >= v.id) continue;
    const uh = u.a[1] === u.b[1], vh = v.a[1] === v.b[1];
    if (uh !== vh) continue;
    const ax = uh ? 0 : 1, cr = uh ? 1 : 0;
    const ov = Math.min(Math.max(u.a[ax], u.b[ax]), Math.max(v.a[ax], v.b[ax])) - Math.max(Math.min(u.a[ax], u.b[ax]), Math.min(v.a[ax], v.b[ax]));
    if (ov > 2) assert.ok(Math.abs(u.a[cr] - v.a[cr]) >= 4, "runs on top of each other: " + JSON.stringify([u, v]));
  }
});

test("ports follow the routes: a line that turns up leaves above a line that goes straight", () => {
  // from the hub's right side: one line straight across, one that must go up and over a wall to a box above
  const boxes = [box("hub", 0, 200, 200, 120), box("r", 500, 220), box("up", 500, -200), box("wall", 260, -260, 40, 400)];
  const { routes } = run(boxes, [edge("s", "hub", "r"), edge("u", "hub", "up", { fromSide: "right", toSide: "left", fromSideGiven: true, toSideGiven: true })]);
  assert.strictEqual(routes.get("u").fromSide, "right");
  assert.ok(routes.get("u").pts[0][1] < routes.get("s").pts[0][1], "up-turning line leaves higher: " + routes.get("u").pts[0][1] + " vs " + routes.get("s").pts[0][1]);
});

test("a label chip keeps off other lines where it can", () => {
  const boxes = [box("a", 0, 0), box("b", 700, 0), box("c", 300, -300), box("d", 300, 300)];
  const { routes } = run(boxes, [edge("v", "c", "d"), edge("h", "a", "b", { label: "a fairly long label" })]);
  const L = routes.get("h").label;
  assert.ok(L && L.clear);
  assert.strictEqual(L.over, 0, "chip over another line");
});

test("the route cache gives the same lines as routing afresh", () => {
  const b = LinenCanvas.parse(fs.readFileSync(path.join(FIX, "big-500.canvas"), "utf8"));
  const input = Router.fromBoard(b, { all: true });
  const cache = new Map();
  Router.route(input, { cache });
  const moved = Object.assign({}, input, { boxes: input.boxes.map((q, i) => (i === 40 && !q.section ? Object.assign({}, q, { y: q.y + 40 }) : q)) });
  const c = Router.route(moved, { cache }), f = Router.route(moved);
  assert.ok(c.stats.cached > 0);
  for (const [id, r] of f.routes) assert.deepStrictEqual(c.routes.get(id).pts, r.pts, id);
});

test("a side holds as many lines as fit 10 px apart; the rest leave from the next side (round 10, finding 14)", () => {
  // a short box with eight lines out of its right side to a column of targets
  const boxes = [box("hub", 0, 300, 200, 60)];
  const edges = [];
  for (let i = 0; i < 8; i++) { boxes.push(box("t" + i, 600, i * 110, 200, 60)); edges.push(edge("e" + i, "hub", "t" + i)); }
  const { routes, stats } = run(boxes, edges);
  const right = [...routes.values()].filter((r) => r.fromSide === "right");
  assert.ok(right.length <= Math.floor((60 * 0.9) / 10) + 1, "right side holds " + right.length);
  assert.ok(stats.spilled >= 1);
  const ys = right.map((r) => r.pts[0][1]).sort((a, b) => a - b);
  for (let i = 1; i < ys.length; i++) assert.ok(ys[i] - ys[i - 1] >= 9.9, "ports 10 px apart: " + ys);
  for (const r of routes.values()) assert.ok(r.clear);
});

test("a name over a box's port does not block that line (round 10, finding 17)", () => {
  const boxes = [box("a", 0, 200), box("b", 0, -200)];
  const band = { x: -20, y: 150, w: 240, h: 70 }; // covers a's top side and the start of its stub
  const r = run(boxes, [edge("e", "a", "b", { fromSide: "top", toSide: "bottom", fromSideGiven: true, toSideGiven: true })], [band]).routes.get("e");
  assert.ok(r.clear, r.how);
});

test("lines into one box do not cross each other where they can fan out (gate 3)", () => {
  // the fan-in case: a box left and lower, a box right and higher, both into a box further down to the right
  const boxes = [box("build", 704, 24, 272, 116), box("sdks", 704, 156, 272, 116), box("plan", 704, 288, 272, 116), box("apply", 704, 420, 272, 116),
    box("c1", 1084, 24, 272, 126), box("c2", 1084, 166, 272, 126), box("sync", 1084, 308, 272, 116),
    box("engine", 996, 856, 280, 126), box("pg", 1384, 856, 272, 95), box("audit", 1384, 967, 272, 95)];
  const { routes } = run(boxes, [edge("e1", "apply", "pg"), edge("e2", "sync", "pg")]);
  assert.strictEqual(Router.countCrossings(routes), 0);
});

test("a long line's label sits near where it leaves, not out on its detour (gate 3)", () => {
  const boxes = [box("a", 0, 0), box("wall", 260, -900, 60, 2000), box("b", 600, 0)];
  const { routes } = run(boxes, [edge("e", "a", "b", { label: "skills" })]);
  const r = routes.get("e"), L = r.label;
  assert.ok(L && L.clear);
  assert.ok(Math.hypot(L.x - r.pts[0][0], L.y - r.pts[0][1]) < 400, JSON.stringify(L) + " " + JSON.stringify(r.pts));
});

test("a reshaped line keeps its corners; moving an end box stretches only its end runs (ENG-21)", () => {
  // a from (0,0) to b (600,0); Hatim dragged the middle run down to y 300
  const via = [[300, 40], [300, 300], [500, 300], [500, 40]];
  const e = edge("e", "a", "b", { fromSide: "right", toSide: "left", via });
  const r0 = run([box("a", 0, 0), box("b", 700, 0)], [e]).routes.get("e");
  assert.strictEqual(r0.how, "shaped");
  assert.deepStrictEqual(r0.pts, [[200, 40], [300, 40], [300, 300], [500, 300], [500, 40], [700, 40]]);
  // a moves 20 px down: the port and the first corner follow, the run along y 300 stays
  const r1 = run([box("a", 0, 20), box("b", 700, 0)], [e]).routes.get("e");
  assert.deepStrictEqual(r1.pts, [[200, 40], [300, 40], [300, 300], [500, 300], [500, 40], [700, 40]], "level with the corner while it fits the side");
  const r2 = run([box("a", 0, 200), box("b", 700, 0)], [e]).routes.get("e");
  assert.strictEqual(r2.how, "shaped");
  assert.strictEqual(r2.pts[0][1], r2.pts[1][1], "the first run stays straight");
  assert.ok(r2.pts[0][1] >= 200 + 80 * 0.15 && r2.pts[0][1] <= 200 + 80 * 0.85, JSON.stringify(r2.pts));
  assert.deepStrictEqual(r2.pts.slice(2), [[300, 300], [500, 300], [500, 40], [700, 40]], "the middle and the other end are as placed");
  assert.ok(orthogonal(r2.pts));
  // a moves past its first corner: this drawing routes the line as usual, and says so
  const r3 = run([box("a", 400, 0), box("b", 700, 0)], [e]);
  assert.notStrictEqual(r3.routes.get("e").how, "shaped");
  assert.deepStrictEqual(r3.stats.shapeDropped, ["e"]);
});

test("a shaped line is fixed in the spacing pass; others spread around it; a box under it makes it not clear (ENG-21)", () => {
  const boxes = [box("a", 0, 0), box("b", 700, 0), box("c", 0, 400), box("d", 700, 400)];
  const via = [[300, 40], [300, 440]];
  const edges = [edge("e1", "a", "d", { fromSide: "right", toSide: "left", via: [[300, 40], [300, 440]] }), edge("e2", "c", "b", { fromSide: "right", toSide: "left" })];
  const { routes } = run(boxes, edges);
  assert.deepStrictEqual(routes.get("e1").pts, [[200, 40], [300, 40], [300, 440], [700, 440]]);
  assert.ok(routes.get("e1").clear);
  void via;
  const blocked = run(boxes.concat([box("wall", 260, 200, 80, 60)]), [edges[0]]).routes.get("e1");
  assert.strictEqual(blocked.how, "shaped");
  assert.strictEqual(blocked.clear, false, "drawn above the boxes, principle 1");
});

test("an end Hatim placed is a fixed port, on a side that is never a hint, and moves with its box (ENG-21)", () => {
  // b is right of a; Hatim put the line's end on b's TOP side, a quarter along it (a side that faces away would be a hint)
  const e = edge("e", "a", "b", { toSide: "top", toAt: 0.25 });
  const r = run([box("a", 0, 100), box("b", 500, 100)], [e]).routes.get("e");
  assert.deepStrictEqual(r.pts[r.pts.length - 1], [550, 100]);
  assert.strictEqual(r.toSide, "top");
  // with three more lines into b's top, this one keeps its place and the others spread around it
  const more = [edge("e2", "c", "b", { toSide: "top" }), edge("e3", "d", "b", { toSide: "top" })];
  const r2 = run([box("a", 0, 100), box("b", 500, 100), box("c", 400, -300), box("d", 700, -300)], [e, ...more]).routes;
  assert.deepStrictEqual(r2.get("e").pts[r2.get("e").pts.length - 1], [550, 100]);
  for (const id of ["e2", "e3"]) { const q = r2.get(id).pts; assert.notDeepStrictEqual(q[q.length - 1], [550, 100], id); }
  // the box moves: the end stays a quarter along its top
  const r3 = run([box("a", 0, 100), box("b", 640, 180)], [e]).routes.get("e");
  assert.deepStrictEqual(r3.pts[r3.pts.length - 1], [690, 180]);
});

test("a line keeps out of the title strip of a section that holds neither end (E1 polish)", () => {
  // section S between a and b, its first card 60 px below its top: the straight line at y 40 would run along S's strip
  const boxes = [box("a", 0, 0, 200, 80), box("S", 300, 0, 300, 300, { section: true }), box("c", 324, 60, 252, 200, { parent: "S" }), box("b", 700, 0, 200, 80)];
  const inStrip = (pts) => pts.some((p, i) => i && p[1] === pts[i - 1][1] && p[1] > 0 && p[1] < 60 && Math.min(Math.max(p[0], pts[i - 1][0]), 600) - Math.max(Math.min(p[0], pts[i - 1][0]), 300) > 8);
  // the section's name sits above it, as on a real board, so going over the top is not free
  const bands = [{ x: 300, y: -40, w: 300, h: 40 }];
  const off = Router.route({ boxes, edges: [edge("e", "a", "b")], bands }, { stripRate: 0 }).routes.get("e");
  const on = Router.route({ boxes, edges: [edge("e", "a", "b")], bands }).routes.get("e");
  assert.ok(inStrip(off.pts), "without the cost the line runs along the strip: " + JSON.stringify(off.pts));
  assert.ok(!inStrip(on.pts), JSON.stringify(on.pts));
  assert.ok(on.clear);
  // a line that ends in S may still use its strip
  const own = Router.route({ boxes, edges: [edge("e2", "a", "c", { toSide: "top" })], bands }).routes.get("e2");
  assert.ok(own.clear);
});

test("a dragged label sits where it was dropped along its line (ENG-21)", () => {
  const { routes } = run([box("a", 0, 0), box("b", 600, 0)], [edge("e", "a", "b", { label: "asks", labelAt: 0.25 })]);
  const r = routes.get("e");
  const len = r.pts.reduce((t, p, i) => (i ? t + Math.hypot(p[0] - r.pts[i - 1][0], p[1] - r.pts[i - 1][1]) : 0), 0);
  assert.ok(Math.abs(r.label.x - (r.pts[0][0] + len * 0.25)) < 1, JSON.stringify(r.label));
  assert.strictEqual(r.label.at, 0.25);
});

(async () => {
  let failed = 0;
  for (const [name, fn] of tests) {
    try { await fn(); console.log("ok  " + name); } catch (e) { failed++; console.log("FAIL " + name + "\n     " + (e && e.stack || e)); }
  }
  console.log(`${tests.length - failed} of ${tests.length} passed`);
  process.exit(failed ? 1 : 0);
})();
