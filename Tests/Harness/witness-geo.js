// The line witness's geometry (PRD-2 17.6, round 10 findings 2 and 9), run inside the page by board-host witness.
// Works on any renderer: a line's points are the router's route when there is one, else the curve, elbow or straight
// line exactly as edgeGeom draws it (the same formulas in today's renderer and the branch), sampled.
// window.__witGeo(): once per board, in board units. window.__witView(): per view, in screen px (chips are DOM).
(function () {
  const S = window.LinenBoard._state, b = S.board;
  const NORMAL = { top: [0, -1], bottom: [0, 1], left: [-1, 0], right: [1, 0] };
  const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));
  function sidePt(n, side) {
    switch (side) {
      case "top": return [n.x + n.w / 2, n.y];
      case "bottom": return [n.x + n.w / 2, n.y + n.h];
      case "left": return [n.x, n.y + n.h / 2];
      default: return [n.x + n.w, n.y + n.h / 2];
    }
  }
  const inside = (p, q) => p.x >= q.x && p.y >= q.y && p.x + p.w <= q.x + q.w && p.y + p.h <= q.y + q.h;
  function poly(e) {
    const a = b.byId.get(e.from), c = b.byId.get(e.to);
    if (e.missing || !e.drawable || !a || !c || !a.placed || !c.placed || a === c) return null;
    if (inside(a, c) || inside(c, a)) return null; // a box and the section around it: no route to judge
    const rt = S.routes && S.routes.get(e.id);
    if (rt) return { pts: rt.pts, routed: true, clear: rt.clear !== false, label: rt.label || null };
    const p1 = sidePt(a, e.fromSide), p2 = sidePt(c, e.toSide);
    const n1 = NORMAL[e.fromSide] || [1, 0], n2 = NORMAL[e.toSide] || [-1, 0];
    if (e.route === "straight") return { pts: [p1, p2] };
    if (e.route === "elbow") {
      const o = 22, a1 = [p1[0] + n1[0] * o, p1[1] + n1[1] * o], a2 = [p2[0] + n2[0] * o, p2[1] + n2[1] * o];
      const pts = [p1, a1];
      if (n1[0] !== 0) { const mx = (a1[0] + a2[0]) / 2; pts.push([mx, a1[1]], [mx, a2[1]]); } else { const my = (a1[1] + a2[1]) / 2; pts.push([a1[0], my], [a2[0], my]); }
      pts.push(a2, p2);
      return { pts };
    }
    const dist = Math.hypot(p2[0] - p1[0], p2[1] - p1[1]), k = clamp(dist * 0.42, 24, 260);
    const c1 = [p1[0] + n1[0] * k, p1[1] + n1[1] * k], c2 = [p2[0] + n2[0] * k, p2[1] + n2[1] * k];
    const pts = [];
    for (let i = 0; i <= 32; i++) {
      const t = i / 32, u = 1 - t;
      pts.push([u * u * u * p1[0] + 3 * u * u * t * c1[0] + 3 * u * t * t * c2[0] + t * t * t * p2[0], u * u * u * p1[1] + 3 * u * u * t * c1[1] + 3 * u * t * t * c2[1] + t * t * t * p2[1]]);
    }
    return { pts };
  }
  // distance from segment p-q to rectangle r (0 when they meet)
  function segRectDist(p, q, r) {
    const x0 = r.x, y0 = r.y, x1 = r.x + r.w, y1 = r.y + r.h;
    if (segHitsRect(p, q, x0, y0, x1, y1)) return 0;
    let d = Infinity;
    for (const c of [[x0, y0], [x1, y0], [x0, y1], [x1, y1]]) d = Math.min(d, ptSeg(c, p, q));
    for (const v of [p, q]) d = Math.min(d, Math.hypot(Math.max(x0 - v[0], 0, v[0] - x1), Math.max(y0 - v[1], 0, v[1] - y1)));
    return d;
  }
  function ptSeg(c, p, q) {
    const dx = q[0] - p[0], dy = q[1] - p[1], L = dx * dx + dy * dy;
    const t = L ? clamp(((c[0] - p[0]) * dx + (c[1] - p[1]) * dy) / L, 0, 1) : 0;
    return Math.hypot(p[0] + dx * t - c[0], p[1] + dy * t - c[1]);
  }
  function segHitsRect(p, q, x0, y0, x1, y1) { // Liang-Barsky on the open rectangle
    let t0 = 0, t1 = 1;
    const dx = q[0] - p[0], dy = q[1] - p[1];
    for (const [pp, qq] of [[-dx, p[0] - x0], [dx, x1 - p[0]], [-dy, p[1] - y0], [dy, y1 - p[1]]]) {
      if (pp === 0) { if (qq <= 0) return false; continue; }
      const t = qq / pp;
      if (pp < 0) { if (t > t1) return false; if (t > t0) t0 = t; } else { if (t < t0) return false; if (t < t1) t1 = t; }
    }
    return t1 - t0 > 1e-6;
  }
  function polys() {
    const out = [];
    for (const e of b.edges) { const g = poly(e); if (g) out.push(Object.assign(g, { e })); }
    return out;
  }
  window.__witGeo = function () {
    const L = polys();
    const res = { lines: L.length, routed: L.filter((g) => g.routed).length, through: [], aboveBoxes: [], near: 0, minNear: null, nearList: [], overlapPairs: 0, overlapPx: 0, overlapList: [], sharedEnds: 0, crossings: 0, chipOnChip: 0, badGeometry: 0 };
    // boxes a line passes through (shrunk 0.5 px) and how close it comes to boxes that are not its ends
    for (const g of L) {
      const ends = new Set([g.e.from, g.e.to]);
      let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
      for (const [x, y] of g.pts) { x0 = Math.min(x0, x); y0 = Math.min(y0, y); x1 = Math.max(x1, x); y1 = Math.max(y1, y); }
      const hit = [];
      let dmin = Infinity;
      for (const id of b.grid.query(x0 - 10, y0 - 10, x1 - x0 + 20, y1 - y0 + 20)) {
        const n = b.byId.get(id);
        if (!n || !n.placed || n.kind === "section" || ends.has(id)) continue;
        // a box that holds an end (a group around it) is not crossed by that line
        const ea = b.byId.get(g.e.from), ec = b.byId.get(g.e.to);
        if ((ea && inside(ea, n)) || (ec && inside(ec, n))) continue;
        const r = { x: n.x + 0.5, y: n.y + 0.5, w: n.w - 1, h: n.h - 1 };
        let d = Infinity;
        for (let i = 1; i < g.pts.length; i++) d = Math.min(d, segRectDist(g.pts[i - 1], g.pts[i], r));
        if (d === 0) hit.push(id);
        else dmin = Math.min(dmin, d);
      }
      if (hit.length) { res.through.push(g.e.id + " x " + hit.slice(0, 3).join("+")); if (g.routed && !g.clear) res.aboveBoxes.push(g.e.id + " x " + hit.slice(0, 3).join("+")); }
      if (g.routed && g.clear && hit.length) res.badGeometry++;
      if (g.routed) for (let i = 1; i < g.pts.length; i++) { const a = g.pts[i - 1], c = g.pts[i]; if (Math.abs(a[0] - c[0]) > 0.01 && Math.abs(a[1] - c[1]) > 0.01 && g.e.route !== "straight") { res.badGeometry++; break; } }
      if (!hit.length && dmin < 8) { res.near++; if (res.nearList.length < 8) res.nearList.push(g.e.id + " " + dmin.toFixed(1)); }
      if (!hit.length && dmin < Infinity) res.minNear = res.minNear == null ? dmin : Math.min(res.minNear, dmin);
    }
    // segments, in a spatial hash
    const segs = [], cell = 64, H = new Map();
    L.forEach((g, gi) => { for (let i = 1; i < g.pts.length; i++) segs.push({ gi, a: g.pts[i - 1], b: g.pts[i] }); });
    segs.forEach((s, si) => {
      const i0 = Math.floor(Math.min(s.a[0], s.b[0]) / cell), i1 = Math.floor(Math.max(s.a[0], s.b[0]) / cell), j0 = Math.floor(Math.min(s.a[1], s.b[1]) / cell), j1 = Math.floor(Math.max(s.a[1], s.b[1]) / cell);
      for (let i = i0; i <= i1; i++) for (let j = j0; j <= j1; j++) { const k = i * 100003 + j; if (!H.has(k)) H.set(k, []); H.get(k).push(si); }
    });
    // overlaps: two lines parallel within 3 px over more than 10 px (summed per pair); crossings: proper crossings
    const pairOv = new Map(), seenPair = new Set();
    const cross = (p, q, r, s) => { const d = (a, b2, c) => (b2[0] - a[0]) * (c[1] - a[1]) - (b2[1] - a[1]) * (c[0] - a[0]); const d1 = d(r, s, p), d2 = d(r, s, q), d3 = d(p, q, r), d4 = d(p, q, s); return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)); };
    for (const cellList of H.values()) for (let x = 0; x < cellList.length; x++) for (let y = x + 1; y < cellList.length; y++) {
      const si = cellList[x], sj = cellList[y], s = segs[si], t = segs[sj];
      if (s.gi === t.gi) continue;
      const key = si < sj ? si * 1e6 + sj : sj * 1e6 + si;
      if (seenPair.has(key)) continue;
      seenPair.add(key);
      if (cross(s.a, s.b, t.a, t.b)) res.crossings++;
      const ux = s.b[0] - s.a[0], uy = s.b[1] - s.a[1], ul = Math.hypot(ux, uy), vx = t.b[0] - t.a[0], vy = t.b[1] - t.a[1], vl = Math.hypot(vx, vy);
      if (ul < 0.5 || vl < 0.5) continue;
      if (Math.abs(ux * vy - uy * vx) / (ul * vl) > 0.087) continue; // more than 5 degrees apart
      const ex = ux / ul, ey = uy / ul;
      // t's ends across s's line, and the overlap along it
      const da = Math.abs((t.a[0] - s.a[0]) * ey - (t.a[1] - s.a[1]) * ex), db = Math.abs((t.b[0] - s.a[0]) * ey - (t.b[1] - s.a[1]) * ex);
      if (Math.max(da, db) > 3) continue;
      const pa = (t.a[0] - s.a[0]) * ex + (t.a[1] - s.a[1]) * ey, pb = (t.b[0] - s.a[0]) * ex + (t.b[1] - s.a[1]) * ey;
      const ov = Math.min(ul, Math.max(pa, pb)) - Math.max(0, Math.min(pa, pb));
      if (ov <= 0) continue;
      const pk = s.gi < t.gi ? s.gi + "|" + t.gi : t.gi + "|" + s.gi;
      pairOv.set(pk, (pairOv.get(pk) || 0) + ov);
    }
    for (const [pk, ov] of pairOv) if (ov > 10) {
      res.overlapPairs++; res.overlapPx += ov;
      if (res.overlapList.length < 8) { const [i, j] = pk.split("|").map(Number); res.overlapList.push(L[i].e.id + "~" + L[j].e.id + " " + ov.toFixed(0)); }
    }
    res.overlapPx = Math.round(res.overlapPx);
    // line ends at the same point as another line's end
    const endAt = new Map();
    for (const g of L) for (const p of [g.pts[0], g.pts[g.pts.length - 1]]) { const k = Math.round(p[0]) + "," + Math.round(p[1]); endAt.set(k, (endAt.get(k) || 0) + 1); }
    for (const n of endAt.values()) if (n > 1) res.sharedEnds += n;
    // line ends on one side of a box closer than 8 px to the next (lines that crowd one side)
    const sides = new Map();
    for (const g of L) for (const [id, p] of [[g.e.from, g.pts[0]], [g.e.to, g.pts[g.pts.length - 1]]]) {
      const n = b.byId.get(id);
      if (!n) continue;
      const side = Math.abs(p[0] - n.x) < 0.5 ? "l" : Math.abs(p[0] - n.x - n.w) < 0.5 ? "r" : Math.abs(p[1] - n.y) < 0.5 ? "t" : Math.abs(p[1] - n.y - n.h) < 0.5 ? "b" : null;
      if (!side) continue;
      const k = id + "|" + side;
      if (!sides.has(k)) sides.set(k, []);
      sides.get(k).push(side === "l" || side === "r" ? p[1] : p[0]);
    }
    res.crowdedEnds = 0;
    for (const v of sides.values()) { v.sort((a, c) => a - c); for (let i = 1; i < v.length; i++) if (v[i] - v[i - 1] < 8) res.crowdedEnds++; }
    // label chips placed by the router on top of each other (board units)
    const chips = L.filter((g) => g.label && g.e.label).map((g) => g.label);
    for (let i = 0; i < chips.length; i++) for (let j = i + 1; j < chips.length; j++) {
      const p = chips[i], q = chips[j];
      if (Math.abs(p.x - q.x) < (p.w + q.w) / 2 - 1 && Math.abs(p.y - q.y) < (p.h + q.h) / 2 - 1) res.chipOnChip++;
    }
    res.through = res.through.length + (res.through.length ? " (" + res.through.slice(0, 6).join(", ") + ")" : "");
    res.aboveBoxes = res.aboveBoxes.length + (res.aboveBoxes.length ? " (" + res.aboveBoxes.slice(0, 6).join(", ") + ")" : "");
    if (res.minNear != null) res.minNear = +res.minNear.toFixed(1);
    return JSON.stringify(res);
  };
  // Per view, in screen px: label chips on screen that sit on each other, and lines under another line's chip.
  window.__witView = function () {
    const v = S.view, cr = document.querySelector(".b-canvas").getBoundingClientRect();
    const shown = [];
    for (const [id, o] of S.edgesOn) {
      if (!o.chip || !o.chip.isConnected) continue;
      const cs = getComputedStyle(o.chip);
      if (cs.display === "none" || cs.visibility === "hidden" || o.chip.classList.contains("hid")) continue;
      const r = o.chip.getBoundingClientRect();
      if (r.width < 1) continue;
      shown.push({ id, x0: r.left - cr.left, y0: r.top - cr.top, x1: r.right - cr.left, y1: r.bottom - cr.top });
    }
    let chipOnChip = 0, under = 0;
    for (let i = 0; i < shown.length; i++) for (let j = i + 1; j < shown.length; j++) {
      const p = shown[i], q = shown[j];
      if (Math.min(p.x1, q.x1) - Math.max(p.x0, q.x0) > 2 && Math.min(p.y1, q.y1) - Math.max(p.y0, q.y0) > 2) chipOnChip++;
    }
    const L = polys();
    for (const c of shown) {
      const x0 = c.x0 + 2, y0 = c.y0 + 2, x1 = c.x1 - 2, y1 = c.y1 - 2;
      for (const g of L) {
        if (g.e.id === c.id) continue;
        for (let i = 1; i < g.pts.length; i++) {
          const a = g.pts[i - 1], q = g.pts[i];
          const p0 = [a[0] * v.s + v.tx, a[1] * v.s + v.ty], p1 = [q[0] * v.s + v.tx, q[1] * v.s + v.ty];
          if (segHitsRect(p0, p1, x0, y0, x1, y1)) { under++; break; }
        }
      }
    }
    return JSON.stringify({ chips: shown.length, chipOnChip, under });
  };
  return 1;
})();
