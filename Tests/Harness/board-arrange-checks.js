// ENG-8 to ENG-14 and ENG-21 in the page, driven by synthetic pointer events (board-host arrange <file>). The body of an
// async function: `text` is the board file; returns [{name, pass, detail}]. The Mac app's side (writing, undo, Reset
// Arrangement) is proven in the lab copy with real input; here the app's write is played by applyArrange + update.
const S = window.LinenBoard._state;
const sent = [];
window.linenInternals = window.linenInternals || {};
window.linenInternals.post = (m) => { sent.push(m); };
const C = document.querySelector(".b-canvas");
// a frame, or 60 ms where frames nearly stop (an offscreen window)
const raf = () => new Promise((r) => { let done = false; const go = () => { if (!done) { done = true; r(); } }; requestAnimationFrame(go); setTimeout(go, 60); });
const out = [];
const check = (name, pass, detail) => out.push({ name, pass: !!pass, detail: String(detail) });
const ev = (type, target, x, y, extra) => target.dispatchEvent(new PointerEvent(type, Object.assign({ clientX: x, clientY: y, pointerId: 1, pointerType: "mouse", button: 0, buttons: type === "pointerup" ? 0 : 1, bubbles: true, cancelable: true, isPrimary: true }, extra || {})));
const scr = (bx, by) => ({ x: bx * S.view.s + S.view.tx + S.ox, y: by * S.view.s + S.view.ty + S.oy });
const centreOf = (el) => { const r = el.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; };
async function drag(target, p, dx, dy, extra, opts) {
  ev("pointerdown", target, p.x, p.y, extra);
  const steps = (opts && opts.steps) || 8;
  for (let i = 1; i <= steps; i++) { ev("pointermove", C, p.x + dx * i / steps, p.y + dy * i / steps, extra); await raf(); if (opts && opts.mid && i === steps) await opts.mid(); } // mid: after the last move, before the release
  if (!(opts && opts.noUp)) { ev("pointerup", C, p.x + dx, p.y + dy, extra); await raf(); }
}
const arranges = () => sent.filter((m) => m.type === "arrange");
let file = text, version = S.version;
// the app's write, played here: the change applied by id to the file, then the file comes back as an update
async function save(m, which) {
  const r = await window.LinenBoard.receive({ type: "command", name: "applyArrange", text: file, state: m[which || "after"] });
  file = r.text;
  version += 1;
  await window.LinenBoard.receive({ type: "update", kind: "board", docId: S.docId, text: file, sidecar: null, version });
  await raf();
  return r;
}
const card = (id) => document.querySelector(`.b-node[data-id="${id}"]`);
const close = (a, b, d) => Math.abs(a - b) <= (d == null ? 0.5 : d);

// 1. A box follows the pointer and is pinned where it is dropped (ENG-8)
{
  const n0 = S.board.byId.get("audit"), x0 = n0.x, y0 = n0.y;
  const before = arranges().length;
  await drag(card("audit"), centreOf(card("audit")), 137, 71);
  const m = arranges()[before];
  const a = m && m.after.nodes.audit;
  check("a dragged box is written where it was dropped, pinned, with its old place for undo", m && a.pinned === true && close(a.x, x0 + 137 / S.view.s, 7) && close(a.y, y0 + 71 / S.view.s, 7) && m.before.nodes.audit.x === x0 && m.before.nodes.audit.pinned === false && m.label === "Move",
    m ? JSON.stringify(m.after.nodes) + " before " + JSON.stringify(m.before.nodes.audit) : "no arrange message");
  check("drag frames are timed", m && m.stats && m.stats.frames >= 3 && m.stats.p95 >= 0, m && JSON.stringify(m.stats));
  if (m) {
    const r = await save(m);
    const n = S.board.byId.get("audit");
    check("the saved file draws the box there, pinned; only its numbers and the pin changed", n.pinned && close(n.x, a.x, 0) && r.changed >= 1 && r.missing.length === 0 && !/"text":"# Audit trail[^"]*"[^}]*"x":24,/.test(file), `pinned ${n.pinned} x ${n.x}`);
    const undo = await window.LinenBoard.receive({ type: "command", name: "applyArrange", text: file, state: m.before });
    check("undo writes the old place and takes the pin away, byte for byte", undo.text === text, undo.text === text ? "same as the file before the drag" : "differs");
  }
}
// 2. A click without moving still selects; ⌥-drag moves nothing (it selects text)
{
  const before = arranges().length, p = centreOf(card("form"));
  ev("pointerdown", card("form"), p.x, p.y); ev("pointerup", C, p.x + 1, p.y); await raf();
  check("a click selects the box and writes nothing", arranges().length === before && S.selected === "form", `selected ${S.selected}`);
  await drag(card("form"), p, 90, 30, { altKey: true });
  check("⌥-drag on a card moves nothing (it selects text)", arranges().length === before && close(S.board.byId.get("form").x, 24, 0), `arranges ${arranges().length - before}`);
}
// 3. A section dragged by its name moves with everything in it, and is pinned (ENG-9)
{
  const name = document.querySelector('.b-slbl[data-id="s-b"] b');
  const before = arranges().length, imp = S.board.byId.get("import").x, sec = S.board.byId.get("s-b").x;
  if (name) await drag(name, centreOf(name), 80, 40);
  const m = arranges()[before];
  check("a section dragged by its name moves with its boxes and is pinned", m && m.after.nodes["s-b"].pinned === true && close(m.after.nodes.import.x - imp, m.after.nodes["s-b"].x - sec, 1) && m.after.nodes.import.pinned === undefined && m.label === "Move Section",
    m ? JSON.stringify(m.after.nodes) : name ? "no arrange message" : "no section name on screen");
  if (m) await save(m);
}
// 4. Snapping: a box's left edge lands on another's within 6 screen px, with a guide; ⌘ turns it off (ENG-10)
{
  const f = S.board.byId.get("form"), q = S.board.byId.get("queue");
  const before = arranges().length;
  let guide = false;
  // move queue so its left edge ends 4 screen px right of form's, and 200 px lower
  const want = (f.x - q.x) * S.view.s + 4;
  await drag(card("queue"), centreOf(card("queue")), want, 200, null, { mid: async () => { const g = document.querySelector(".b-guide.x"); guide = !!g && !g.hidden; } });
  const m = arranges()[before];
  check("a box snaps to another box's edge, with a guide line", m && m.after.nodes.queue.x === Math.round(f.x) && guide, m ? `x ${m.after.nodes.queue.x} vs ${f.x}, guide ${guide}` : "no arrange");
  if (m) await save(m, "before");
}
// 5. A line's run dragged sideways: the ends and the relation stay, the bends are written (ENG-21)
{
  const rt = S.routes.get("e2");
  let k = -1;
  for (let i = 1; i + 2 < rt.pts.length; i++) if (Math.abs(rt.pts[i][0] - rt.pts[i + 1][0]) < 0.01 || Math.abs(rt.pts[i][1] - rt.pts[i + 1][1]) < 0.01) { k = i; break; }
  if (k < 0) k = 0;
  const a = rt.pts[k], b = rt.pts[k + 1], horiz = Math.abs(a[1] - b[1]) < 0.01;
  const mid = scr((a[0] + b[0]) / 2, (a[1] + b[1]) / 2);
  const before = arranges().length, from0 = S.board.edgesById.get("e2").from, to0 = S.board.edgesById.get("e2").to;
  await drag(C, mid, horiz ? 0 : 60, horiz ? 60 : 0);
  const m = arranges()[before];
  const e = m && m.after.edges.e2;
  check("a dragged run writes the line's bends and sides, nothing else", m && Array.isArray(e.via) && e.via.length >= 1 && e.fromSide && e.toSide && Object.keys(e).sort().join() === "fromSide,toSide,via" && m.label === "Reshape Line" && m.before.edges.e2.via === null,
    m ? JSON.stringify(m.after.edges) : `no arrange (run ${k} of ${rt.pts.length - 1}, ${horiz ? "horizontal" : "vertical"})`);
  if (m) {
    await save(m);
    const r2 = S.routes.get("e2"), e2 = S.board.edgesById.get("e2");
    check("the saved line is drawn as shaped, between the same two boxes", r2 && r2.how === "shaped" && e2.from === from0 && e2.to === to0, r2 && r2.how);
    // the end box moves: the shape stays, only the end runs follow
    const imp = S.board.byId.get("import");
    const before2 = arranges().length;
    await drag(card("import"), centreOf(card("import")), 0, 24, { metaKey: true });
    const m2 = arranges()[before2];
    if (m2) await save(m2);
    const r3 = S.routes.get("e2");
    const inner = (p) => JSON.stringify(p.slice(2, -2));
    check("moving an end box keeps the shape and stretches only the end runs", r3 && r3.how === "shaped" && inner(r3.pts) === inner(r2.pts), r3 && `${r3.how} ${JSON.stringify(r3.pts)} vs ${JSON.stringify(r2.pts)}`);
    void imp;
  }
}
// 6. A label chip drags along its line and stays there (ENG-21)
{
  const chip = document.querySelector('.b-elbl[data-edge="e4"]') || document.querySelector(".b-elbl");
  const id = chip && chip.dataset.edge;
  const before = arranges().length;
  if (chip) await drag(chip, centreOf(chip), -50, 0);
  const m = arranges()[before];
  const f = m && m.after.edges[id] && m.after.edges[id].labelAt;
  check("a label chip dragged along its line is written as labelAt", m && typeof f === "number" && f >= 0 && f <= 1 && m.label === "Move Label", m ? JSON.stringify(m.after.edges) : "no chip or no arrange");
  if (m) { await save(m); const r = S.routes.get(id); check("the chip is drawn where it was dropped", r && r.label && r.label.at === f, r && JSON.stringify(r.label)); }
}
// 6b. A line's end (its arrowhead) slides around the border of the same box; side and place are written (ENG-21)
{
  const e0 = S.board.edgesById.get("e3"), rt = S.routes.get("e3");
  const tip = rt.pts[rt.pts.length - 1], to = S.board.byId.get(e0.to);
  const p = scr(tip[0], tip[1] - 4); // just off the border, on the head
  const before = arranges().length;
  // drag the head from the box's top round to its left side, a third of the way down
  const dest = scr(to.x - 20, to.y + to.h / 3);
  await drag(C, p, dest.x - p.x, dest.y - p.y);
  const m = arranges()[before];
  const a = m && m.after.edges.e3;
  check("an arrowhead dragged round its box writes the side and the place along it, same two boxes", m && a.toSide === "left" && close(a.toAt, 1 / 3, 0.05) && m.label === "Move Line End" && m.before.edges.e3.toAt === null && Object.keys(a).sort().join() === "toAt,toSide",
    m ? JSON.stringify(m.after.edges) + " before " + JSON.stringify(m.before.edges) : "no arrange (tip " + JSON.stringify(tip) + ")");
  if (m) {
    await save(m);
    const r = S.routes.get("e3"), q = r.pts[r.pts.length - 1], n = S.board.byId.get("export"), e1 = S.board.edgesById.get("e3");
    check("the router keeps the end where it was put, and the relation is unchanged", r.toSide === "left" && close(q[0], n.x, 0.5) && close(q[1], n.y + n.h * a.toAt, 0.5) && e1.from === "import" && e1.to === "export", JSON.stringify(q));
    const undo = await window.LinenBoard.receive({ type: "command", name: "applyArrange", text: file, state: m.before });
    const e3u = JSON.parse(undo.text).edges.find((x) => x.id === "e3");
    check("undo takes the end back (no side, no place)", !(e3u.linen && "toAt" in e3u.linen) && e3u.toSide === undefined, JSON.stringify(e3u));
  }
}
// 7. An outside save during a drag waits for the drop (ENG-12); Esc puts a drag back
{
  const before = arranges().length;
  let held = false;
  await drag(card("export"), centreOf(card("export")), 60, 30, null, { mid: async () => {
    const r = await window.LinenBoard.receive({ type: "update", kind: "board", docId: S.docId, text: file, sidecar: null, version: version + 1 });
    held = r === true && !!S.heldUpdate;
  } });
  version += 1;
  check("an update that lands mid-drag is held until the drop", held && arranges().length === before + 1 && !S.heldUpdate, `held ${held}, arranges ${arranges().length - before}`);
  const m = arranges()[before];
  if (m) await save(m);
  const x0 = S.board.byId.get("form").x, before2 = arranges().length;
  await drag(card("form"), centreOf(card("form")), 70, 20, null, { noUp: true });
  document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  ev("pointerup", C, 0, 0); await raf();
  check("Esc puts a drag back and writes nothing", arranges().length === before2 && close(S.board.byId.get("form").x, x0, 0), `x ${S.board.byId.get("form").x} vs ${x0}`);
}
// 8. Reset Arrangement takes every pin and shape out and lays the board out again (ENG-14)
{
  const c = await window.LinenBoard.receive({ type: "command", name: "arrangement" });
  const r = await window.LinenBoard.receive({ type: "command", name: "resetArrangement", text: file, sidecar: null });
  const j = JSON.parse(r.text);
  const left = j.nodes.filter((n) => n.linen && n.linen.pinned).length + j.edges.filter((e) => e.linen && (e.linen.via || e.linen.labelAt != null)).length;
  check("Reset Arrangement removes every pin, line shape and dragged label", c.pins >= 2 && c.shapes >= 2 && left === 0 && r.pins === c.pins && r.shapes === c.shapes, `before ${JSON.stringify(c)}, left ${left}`);
}
// 9. Not where the host does not allow it (Quick Look, export, linen shot, the iPhone)
{
  const before = arranges().length;
  await window.LinenBoard.receive({ type: "load", kind: "board", docId: "ro", name: "arrange.canvas", path: "/tmp/arrange.canvas", text: file, sidecar: null, version: 1, meta: {} });
  await raf(); await raf();
  const el = card("form");
  if (el) await drag(el, centreOf(el), 80, 20);
  check("without canArrange a drag moves nothing", arranges().length === before, `arranges ${arranges().length - before}`);
}
return out;
