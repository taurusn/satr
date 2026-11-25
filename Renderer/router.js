/* Linen's line router (PRD-2 section 17: ENG-1, ENG-2, ENG-5). Every connector between two placed boxes goes around
   every other box and every section name and title, in straight segments that turn at right angles, with a clear gap.
   Each line is routed on its own (so moving one box moves only the lines that end at it or pass beside it); lines on
   one side of a box leave from points spread along it in the order their routes turn; lines that share a gap are then
   spread apart; label chips go last, on their own line, away from boxes, names, other chips and other lines. The result
   depends only on the file, so the same file draws the same lines in the app, `linen shot`, export and the iPhone.
   Nothing here is stored in the file (principle 2).

   A plain script: self.LinenRouter in the page, module.exports in node, a global in JavaScriptCore. No DOM.

   route(input, opts) with input = {
     boxes:    [{id, x, y, w, h, section: bool, parent: id|null}]   every placed node; sections are not obstacles
     bands:    [{x, y, w, h}]                                         section names and titles (drawn over lines)
     edges:    [{id, from, to, fromSide, toSide, route, kind, label}] fromSide/toSide only when the file gives them
   }, opts = {labelWidth(text), cache: Map kept between calls (searches reused while nothing in their window moved)}
   returns { routes: Map(id -> {pts, raw, fromSide, toSide, clear, how, label}), stats }.
   fromBoard(board, opts) builds the input from a LinenCanvas board. smooth(pts, r) rounds corners for drawing. */
(function (root) {
  "use strict";

  const PAD = 16;        // the clear gap a line keeps from a box (board px)
  const HARD = 4;        // never closer than this, even in a narrow gap
  const STUB = 16;       // a line leaves and enters a box straight for this long
  const BEND = 36;       // cost of a corner, in px of length
  const NEAR = 1.5;        // cost per px of running beside a card, at its closest (falls off with the square of the distance)
  const CLEAR = 32;      // the room a line keeps from cards that are not its ends, where the board has it
  const FOREIGN = 1.2;   // cost per px inside a section that holds neither end (lines go between sections)
  const CROSS_SIB = 80;  // cost of crossing an earlier line that shares an end box with this one
  const OUTSIDE = 1.0;   // cost per px outside the board's own area (lines stay on the board)
  const REGION = 240;    // the search box around both ends
  const FACE = 480;      // how far apart two boxes still make a gap with a middle line
  const PORT_GAP = 22;   // preferred spacing of lines on one side of a box
  const NUDGE = 8;       // spacing of lines that share a gap
  const MIN_RUN = 12;    // a line's first and last runs keep at least this, for the arrowheads, where there is room
  const MIN_STUB = 4;    // and never less than this
  const SOFT = 8;        // spread lines keep this far from boxes when the gap has room (else HARD)
  const MINSEP = 5;      // the soft margin wins while lines can still be this far apart
  const MIN_PORT = 10;   // the closest two lines leave one side of a box; more than fit go to the next side
  const PORT_SPAN = 0.9; // a crowded side spreads its lines over this much of its length
  const SOFTBAND = 1.5;  // cost per px under a name's part beyond its section (drawn there only when zoomed far out)
  const MAX_EXPAND = 120000;
  const STEPS = 25000;   // steps for the cheapest route before a quicker search takes over
  const DRAG_STEPS = 2500; // steps per line in a drag frame (ENG-16)
  const STRIP = 3;         // per px of a run along the title strip of a section that holds neither end (E1 polish)
  const LONG = 8000;     // a line longer than this (board px, end to end) takes the quicker search at once
  const QUICK = 1.25;    // the quicker search's weight on the distance left
  const TIE = 1e-11, TIE2 = 1e-9; // tie-breaks between equal routes, far below any real cost
  const TIEB = 1e-8;              // per corner, by its squared distance from the middle between the ends
  const AWAY = 1e-4;              // per px of a run on a grid line away from the box or gap that made it

  const NORMAL = { top: [0, -1], bottom: [0, 1], left: [-1, 0], right: [1, 0] };
  const DIRV = [[1, 0], [-1, 0], [0, 1], [0, -1]]; // 0 +x, 1 -x, 2 +y, 3 -y
  const dirOf = (v) => (v[0] > 0 ? 0 : v[0] < 0 ? 1 : v[1] > 0 ? 2 : 3);
  const OPPOSITE = [1, 0, 3, 2];
  const now = () => (typeof performance !== "undefined" ? performance.now() : Date.now());

  // ---------- a spatial hash of rectangles {x0, y0, x1, y1} ----------
  function Hash(cell) { this.cell = cell; this.cells = new Map(); this.items = []; this.big = []; this.stamp = 0; this.seen = []; }
  Hash.prototype.add = function (r) {
    const c = this.cell, id = this.items.length;
    this.items.push(r); this.seen.push(0);
    const i0 = Math.floor(r.x0 / c), i1 = Math.floor(r.x1 / c), j0 = Math.floor(r.y0 / c), j1 = Math.floor(r.y1 / c);
    if ((i1 - i0 + 1) * (j1 - j0 + 1) > 256) { this.big.push(id); return id; }
    for (let i = i0; i <= i1; i++) for (let j = j0; j <= j1; j++) {
      const k = i * 92821 + j;
      let a = this.cells.get(k);
      if (!a) this.cells.set(k, (a = []));
      a.push(id);
    }
    return id;
  };
  Hash.prototype.query = function (x0, y0, x1, y1, fn) {
    const c = this.cell, st = ++this.stamp;
    const i0 = Math.floor(x0 / c), i1 = Math.floor(x1 / c), j0 = Math.floor(y0 / c), j1 = Math.floor(y1 / c);
    const visit = (id) => {
      if (this.seen[id] === st) return;
      this.seen[id] = st;
      const r = this.items[id];
      if (r.x1 >= x0 && r.x0 <= x1 && r.y1 >= y0 && r.y0 <= y1) fn(r, id);
    };
    for (let i = i0; i <= i1; i++) for (let j = j0; j <= j1; j++) {
      const a = this.cells.get(i * 92821 + j);
      if (a) for (let t = 0; t < a.length; t++) visit(a[t]);
    }
    for (let t = 0; t < this.big.length; t++) visit(this.big[t]);
  };

  // ---------- a binary heap of (f, state) ----------
  function Heap() { this.f = []; this.s = []; }
  Heap.prototype.push = function (f, s) {
    const F = this.f, S = this.s;
    let i = F.length;
    F.push(f); S.push(s);
    while (i > 0) {
      const p = (i - 1) >> 1;
      if (F[p] <= f) break;
      F[i] = F[p]; S[i] = S[p]; i = p;
    }
    F[i] = f; S[i] = s;
  };
  Heap.prototype.pop = function () {
    const F = this.f, S = this.s, top = S[0], lf = F.pop(), ls = S.pop(), n = F.length;
    if (n) {
      let i = 0;
      for (;;) {
        let c = 2 * i + 1;
        if (c >= n) break;
        if (c + 1 < n && F[c + 1] < F[c]) c++;
        if (F[c] >= lf) break;
        F[i] = F[c]; S[i] = S[c]; i = c;
      }
      F[i] = lf; S[i] = ls;
    }
    return top;
  };

  function sidePoint(b, side, t) { // t in [0, 1] along the side (left to right, top to bottom)
    switch (side) {
      case "top": return [b.x + b.w * t, b.y];
      case "bottom": return [b.x + b.w * t, b.y + b.h];
      case "left": return [b.x, b.y + b.h * t];
      default: return [b.x + b.w, b.y + b.h * t];
    }
  }
  const centre = (b) => [b.x + b.w / 2, b.y + b.h / 2];

  /** Rounded corners for drawing: each corner becomes a short arc of radius up to r (less where a segment is short),
      sampled into points so the canvas strokes, dashes and culls it as a polyline. */
  function smooth(pts, r) {
    if (!pts || pts.length < 3 || !(r > 0)) return pts ? pts.slice() : [];
    const out = [pts[0]];
    for (let i = 1; i < pts.length - 1; i++) {
      const a = pts[i - 1], b = pts[i], c = pts[i + 1];
      const l1 = Math.hypot(b[0] - a[0], b[1] - a[1]), l2 = Math.hypot(c[0] - b[0], c[1] - b[1]);
      // the first and last segments are stubs into boxes: keep them straight for the arrowheads
      const lim1 = i === 1 ? l1 - 6 : l1 / 2, lim2 = i === pts.length - 2 ? l2 - 6 : l2 / 2;
      const rr = Math.max(0, Math.min(r, lim1, lim2));
      if (rr < 1 || !l1 || !l2) { out.push(b); continue; }
      const u1 = [(b[0] - a[0]) / l1, (b[1] - a[1]) / l1], u2 = [(c[0] - b[0]) / l2, (c[1] - b[1]) / l2];
      const p0 = [b[0] - u1[0] * rr, b[1] - u1[1] * rr], p2 = [b[0] + u2[0] * rr, b[1] + u2[1] * rr];
      const n = rr > 20 ? 8 : 5;
      for (let k = 0; k <= n; k++) { // a quadratic through the corner, close to a circular arc for right angles
        const t = k / n, s = 1 - t;
        out.push([s * s * p0[0] + 2 * s * t * b[0] + t * t * p2[0], s * s * p0[1] + 2 * s * t * b[1] + t * t * p2[1]]);
      }
    }
    out.push(pts[pts.length - 1]);
    return out;
  }

  function simplify(pts) {
    const out = [];
    for (const p of pts) {
      const q = out[out.length - 1];
      if (q && Math.abs(q[0] - p[0]) < 0.01 && Math.abs(q[1] - p[1]) < 0.01) continue;
      out.push([p[0], p[1]]);
      while (out.length >= 3) {
        const a = out[out.length - 3], b = out[out.length - 2], c = out[out.length - 1];
        const col = (Math.abs(a[0] - b[0]) < 0.01 && Math.abs(b[0] - c[0]) < 0.01) || (Math.abs(a[1] - b[1]) < 0.01 && Math.abs(b[1] - c[1]) < 0.01);
        if (!col) break;
        out.splice(out.length - 2, 1);
      }
    }
    return out;
  }

  // Search state, reused between searches and routings (one routing runs at a time): an entry counts only when its
  // stamp is the current search's.
  const BUF = { n: 0, gen: 0 };
  function buffers(N) {
    if (BUF.n < N || BUF.gen > 2e9) {
      const n = Math.max(N, BUF.n * 2, 4096);
      Object.assign(BUF, { n, gen: 0, g: new Float64Array(n), from: new Int32Array(n), seen: new Uint32Array(n), done: new Uint32Array(n), ec: new Float64Array(n), ecAt: new Uint32Array(n) });
    }
    BUF.gen++;
    return BUF;
  }

  // ---------- the router ----------
  // Each line is routed on its own against the boxes, the section names and titles only (never against other lines or
  // chips), so moving one box changes only the lines that end at it or pass beside it (round 10, finding 3). Lines
  // that share a gap are then spread apart by a fixed spacing pass, ports on a side follow the routes, and label chips
  // are placed last, on their own line and away from other lines.
  function route(input, opts) {
    opts = opts || {};
    const t0 = now();
    const boxes = (input.boxes || []).filter((b) => b && isFinite(b.x) && isFinite(b.y) && b.w > 0 && b.h > 0);
    const byId = new Map(boxes.map((b) => [String(b.id), b]));
    const labelWidth = opts.labelWidth || ((s) => String(s).length * 6.7 + 20);
    const cache = opts.cache || null;
    const stats = { edges: 0, routed: 0, fast: 0, searched: 0, wide: 0, notClear: 0, straight: 0, crossings: 0, bends: 0, length: 0, expanded: 0, capped: 0, cached: 0, nudged: 0, reordered: 0, jams: 0, pushed: 0, quick: 0, spilled: 0, exempt: 0, shaped: 0, shapeDropped: [], ms: 0 };

    // Obstacles: boxes (not sections), section names and titles.
    const obs = new Hash(160);
    for (const b of boxes) if (!b.section) obs.add({ x0: b.x, y0: b.y, x1: b.x + b.w, y1: b.y + b.h, id: String(b.id), kind: "box" });
    // A name's part beyond its own section (a top-level name drawn large when zoomed far out, over the gutter) is soft:
    // lines may cross it at a cost and spread through it, so a gutter between two rows of sections stays usable.
    const softs = new Hash(160);
    (input.bands || []).forEach((r, i) => { if (r.w > 0 && r.h > 0) (r.soft ? softs : obs).add({ x0: r.x, y0: r.y, x1: r.x + r.w, y1: r.y + r.h, id: "band:" + i, kind: r.soft ? "soft" : "band" }); });
    const secs = new Hash(400);
    for (const b of boxes) if (b.section) secs.add({ x0: b.x, y0: b.y, x1: b.x + b.w, y1: b.y + b.h, id: String(b.id) });
    // E1 polish (master, after gate 4.0): a section's title strip, its top edge down to its first row, is not a lane for
    // lines that do not end in that section; a run along it costs STRIP per px (it still may, where nothing else goes).
    const STRIP_RATE = opts.stripRate != null ? opts.stripRate : STRIP, STRIP_ALL = opts.stripMode === "all";
    const strips = new Hash(400), firstRow = new Map();
    for (const b of boxes) if (b.parent != null) { const k = String(b.parent); firstRow.set(k, Math.min(firstRow.has(k) ? firstRow.get(k) : Infinity, b.y)); }
    for (const b of boxes) if (b.section && firstRow.has(String(b.id)) && firstRow.get(String(b.id)) > b.y + 1) strips.add({ x0: b.x, y0: b.y, x1: b.x + b.w, y1: firstRow.get(String(b.id)), id: String(b.id) });
    const parentOf = (id) => { const b = byId.get(id); return b && b.parent != null ? String(b.parent) : null; };
    const ancestors = (id) => { const out = new Set(); let p = id, hops = 0; while (p != null && hops++ < 64) { out.add(p); p = parentOf(p); } return out; };

    let bx0 = Infinity, by0 = Infinity, bx1 = -Infinity, by1 = -Infinity;
    for (const b of boxes) { bx0 = Math.min(bx0, b.x); by0 = Math.min(by0, b.y); bx1 = Math.max(bx1, b.x + b.w); by1 = Math.max(by1, b.y + b.h); }
    // The board's own area is its boxes and sections: a line above the top row runs over the section names, off the board.
    const area = { x0: bx0 - PAD, y0: by0 - PAD, x1: bx1 + PAD, y1: by1 + PAD };
    for (const r of input.bands || []) { bx0 = Math.min(bx0, r.x); by0 = Math.min(by0, r.y); bx1 = Math.max(bx1, r.x + r.w); by1 = Math.max(by1, r.y + r.h); }
    const world = { x0: bx0 - REGION, y0: by0 - REGION, x1: bx1 + REGION, y1: by1 + REGION };
    let shut = null; // stretches closed to the line being routed again (a gap too narrow for all its lines)
    let exempt = null; // obstacles that cover the ports of the line being routed
    // Runs of earlier lines (in the routing order) that share an end box with the line being routed: crossing one costs
    // CROSS_SIB, so lines into or out of one box fan out instead of crossing. Only these lines depend on each other.
    let sib = null;
    let sibHash = null;
    function sibCrossings(ax, ay, bx, by) {
      let n = 0;
      const h = ay === by;
      if (!sibHash) { sibHash = new Hash(160); for (const g of sib) sibHash.add(g.h ? { x0: g.lo, y0: g.c, x1: g.hi, y1: g.c, g } : { x0: g.c, y0: g.lo, x1: g.c, y1: g.hi, g }); }
      sibHash.query(Math.min(ax, bx), Math.min(ay, by), Math.max(ax, bx), Math.max(ay, by), (r) => {
        const g = r.g;
        if (g.h === h) return;
        if (h) { if (g.c > Math.min(ax, bx) && g.c < Math.max(ax, bx) && ay > g.lo && ay < g.hi) n++; }
        else if (g.c > Math.min(ay, by) && g.c < Math.max(ay, by) && ax > g.lo && ax < g.hi) n++;
      });
      return n;
    }

    // A horizontal or vertical segment's cost against the board: Infinity when it enters a box or band, else the extra
    // for running close to boxes, through sections that hold neither end, and off the board. Every term is a length
    // times a rate, so a segment costs the same whether the search grid splits it or not.
    function segCost(ax, ay, bx, by, own, allowed) {
      const h = ay === by;
      const x0 = Math.min(ax, bx), x1 = Math.max(ax, bx), y0 = Math.min(ay, by), y1 = Math.max(ay, by);
      let extra = 0, blocked = false;
      obs.query(x0 - CLEAR, y0 - CLEAR, x1 + CLEAR, y1 + CLEAR, (r) => {
        if (blocked) return;
        // Inside the hard margin: blocked (touching exactly at the margin is fine). A line's own two boxes have no
        // margin, since its stubs start on their borders; it still may not pass through them. Something that covers
        // one of the line's ports (finding 17) does not count for that line.
        if (exempt && exempt.has(r.id)) return;
        const m = own && own.has(r.id) ? 0 : HARD;
        if (x1 > r.x0 - m + 1e-6 && x0 < r.x1 + m - 1e-6 && y1 > r.y0 - m + 1e-6 && y0 < r.y1 + m - 1e-6) { blocked = true; return; }
        // Running beside a card (gate 3): a line keeps CLEAR from cards that are not its ends where it can, so a gap
        // between two cards is used by the lines that end there, and lines do not read as card borders. Its own
        // cards cost a quarter (a line leaves and enters them). Names do not count here.
        if (r.kind !== "box") return;
        const k = own && own.has(r.id) ? NEAR / 4 : NEAR;
        if (h) {
          const ov = Math.min(x1, r.x1) - Math.max(x0, r.x0);
          const d = ay < r.y0 ? r.y0 - ay : ay - r.y1;
          if (ov > 0 && d < CLEAR) { const q = (CLEAR - d) / CLEAR; extra += ov * k * q * q; }
        } else {
          const ov = Math.min(y1, r.y1) - Math.max(y0, r.y0);
          const d = ax < r.x0 ? r.x0 - ax : ax - r.x1;
          if (ov > 0 && d < CLEAR) { const q = (CLEAR - d) / CLEAR; extra += ov * k * q * q; }
        }
      });
      if (!blocked && shut) for (const r of shut) if (x1 > r.x0 && x0 < r.x1 && y1 > r.y0 && y0 < r.y1) { blocked = true; break; }
      if (blocked) return Infinity;
      softs.query(x0, y0, x1, y1, (r) => {
        if (h) { if (ay > r.y0 && ay < r.y1) extra += Math.max(0, Math.min(x1, r.x1) - Math.max(x0, r.x0)) * SOFTBAND; }
        else if (ax > r.x0 && ax < r.x1) extra += Math.max(0, Math.min(y1, r.y1) - Math.max(y0, r.y0)) * SOFTBAND;
      });
      if (h && STRIP_RATE) strips.query(x0, ay, x1, ay, (r) => {
        if (!(ay > r.y0 && ay < r.y1) || (!STRIP_ALL && allowed.has(r.id))) return;
        extra += Math.max(0, Math.min(x1, r.x1) - Math.max(x0, r.x0)) * STRIP_RATE;
      });
      // the length inside sections that hold neither end (counted once where such sections nest)
      const ivs = [];
      secs.query(x0, y0, x1, y1, (r) => {
        if (allowed.has(r.id)) return;
        if (h) { if (ay > r.y0 && ay < r.y1 && x1 > r.x0 && x0 < r.x1) ivs.push([Math.max(x0, r.x0), Math.min(x1, r.x1)]); }
        else if (ax > r.x0 && ax < r.x1 && y1 > r.y0 && y0 < r.y1) ivs.push([Math.max(y0, r.y0), Math.min(y1, r.y1)]);
      });
      if (ivs.length) {
        ivs.sort((p, q) => p[0] - q[0]);
        let len = 0, s = ivs[0][0], e = ivs[0][1];
        for (let i = 1; i < ivs.length; i++) { if (ivs[i][0] > e) { len += e - s; s = ivs[i][0]; e = ivs[i][1]; } else if (ivs[i][1] > e) e = ivs[i][1]; }
        extra += (len + e - s) * FOREIGN;
      }
      // the length outside the board's area
      const len = x1 - x0 + y1 - y0;
      let inLen = 0;
      if (h) { if (ay >= area.y0 && ay <= area.y1) inLen = Math.max(0, Math.min(x1, area.x1) - Math.max(x0, area.x0)); }
      else if (ax >= area.x0 && ax <= area.x1) inLen = Math.max(0, Math.min(y1, area.y1) - Math.max(y0, area.y0));
      extra += (len - inLen) * OUTSIDE;
      return extra;
    }
    function polyCost(pts, own, allowed) {
      let total = 0, bends = 0;
      for (let i = 1; i < pts.length; i++) {
        const a = pts[i - 1], b = pts[i];
        if (a[0] !== b[0] && a[1] !== b[1]) return Infinity;
        const sc = segCost(a[0], a[1], b[0], b[1], own, allowed);
        if (sc === Infinity) return Infinity;
        total += Math.abs(b[0] - a[0]) + Math.abs(b[1] - a[1]) + sc;
        if (i >= 2) {
          const p = pts[i - 2];
          const d1 = dirOf([Math.sign(a[0] - p[0]), Math.sign(a[1] - p[1])]), d2 = dirOf([Math.sign(b[0] - a[0]), Math.sign(b[1] - a[1])]);
          if (d1 !== d2) bends++;
          if (d1 === OPPOSITE[d2]) return Infinity;
        }
      }
      return total + bends * BEND;
    }

    // How far a line can leave a box straight before it meets something: to the middle of that gap, at most STUB (so in
    // a narrow gap the line turns on the gap's middle line).
    function stubLength(p, side, ownId) {
      const n = NORMAL[side];
      let free = STUB * 2;
      const qx0 = Math.min(p[0], p[0] + n[0] * STUB * 2), qx1 = Math.max(p[0], p[0] + n[0] * STUB * 2);
      const qy0 = Math.min(p[1], p[1] + n[1] * STUB * 2), qy1 = Math.max(p[1], p[1] + n[1] * STUB * 2);
      obs.query(qx0 - HARD, qy0 - HARD, qx1 + HARD, qy1 + HARD, (r) => {
        if (r.id === ownId) return;
        // distance along the normal to the obstacle's face, when the ray passes within HARD of it
        if (n[0] !== 0) {
          if (p[1] <= r.y0 - HARD || p[1] >= r.y1 + HARD) return;
          const d = n[0] > 0 ? r.x0 - p[0] : p[0] - r.x1;
          if (d >= 0) free = Math.min(free, d);
        } else {
          if (p[0] <= r.x0 - HARD || p[0] >= r.x1 + HARD) return;
          const d = n[1] > 0 ? r.y0 - p[1] : p[1] - r.y1;
          if (d >= 0) free = Math.min(free, d);
        }
      });
      return Math.max(2, Math.min(STUB, free / 2, free - HARD));
    }

    // The plain routes for a pair of sides: straight, one corner, or two corners at the gap's middle.
    function simple(S, T, od, idir) {
      const out = [];
      const oh = od < 2, ih = idir < 2;
      const ahead = (from, to, d) => (d === 0 ? to[0] > from[0] : d === 1 ? to[0] < from[0] : d === 2 ? to[1] > from[1] : to[1] < from[1]);
      if (oh && ih) {
        if (Math.abs(S[1] - T[1]) < 0.5 && od === idir && ahead(S, T, od)) out.push([S, [T[0], S[1]]]);
        const mx = (S[0] + T[0]) / 2;
        if (od === idir && ahead(S, T, od)) out.push([S, [mx, S[1]], [mx, T[1]], T]);
      } else if (!oh && !ih) {
        if (Math.abs(S[0] - T[0]) < 0.5 && od === idir && ahead(S, T, od)) out.push([S, [S[0], T[1]]]);
        const my = (S[1] + T[1]) / 2;
        if (od === idir && ahead(S, T, od)) out.push([S, [S[0], my], [T[0], my], T]);
      } else if (oh && !ih) {
        const c = [T[0], S[1]];
        if (ahead(S, c, od) && ahead(c, T, idir)) out.push([S, c, T]);
      } else {
        const c = [S[0], T[1]];
        if (ahead(S, c, od) && ahead(c, T, idir)) out.push([S, c, T]);
      }
      return out;
    }

    // A* over a sparse grid whose lines are padded box edges, the middles of the gaps between boxes that face each
    // other, and the stubs. starts: [{S, od, g0}], goals: [{T, idir, extra}]: a line whose sides are open starts from
    // any side of its first box and ends at any side of its second, each side with its own penalty.
    // w > 1 weights the estimate (a faster search, not always the cheapest route); cap bounds the steps; a search that
    // hits its cap returns null and sets lastCapped.
    let lastCapped = false;
    function search(starts, goals, own, allowed, region, mid, w, cap) {
      w = w || 1; cap = cap || MAX_EXPAND; lastCapped = false;
      // Grid lines, each with the stretch where it belongs ("home"): a padded edge beside its box, a gap's middle
      // between the two boxes that face each other across it, the line's own stubs and middle everywhere. A run off
      // its line's home costs a hair more, so a box far away never pulls a line onto its edge.
      const xsSet = new Map(), ysSet = new Map();
      const add = (set, v, lo, hi) => {
        if (lo === undefined) { set.set(v, true); return; }
        const h = set.get(v);
        if (h === true) return;
        if (h) h.push(lo, hi); else set.set(v, [lo, hi]);
      };
      add(xsSet, region.x0); add(xsSet, region.x1); add(ysSet, region.y0); add(ysSet, region.y1);
      for (const p of starts) { add(xsSet, p.S[0]); add(ysSet, p.S[1]); }
      for (const p of goals) { add(xsSet, p.T[0]); add(ysSet, p.T[1]); }
      const rs = [];
      obs.query(region.x0, region.y0, region.x1, region.y1, (r) => {
        rs.push(r);
        for (const v of [r.x0 - PAD, r.x1 + PAD]) if (v > region.x0 && v < region.x1) add(xsSet, v, r.y0 - PAD, r.y1 + PAD);
        for (const v of [r.y0 - PAD, r.y1 + PAD]) if (v > region.y0 && v < region.y1) add(ysSet, v, r.x0 - PAD, r.x1 + PAD);
      });
      softs.query(region.x0, region.y0, region.x1, region.y1, (r) => {
        for (const v of [r.x0 - HARD, r.x1 + HARD]) if (v > region.x0 && v < region.x1) add(xsSet, v, r.y0 - PAD, r.y1 + PAD);
        for (const v of [r.y0 - HARD, r.y1 + HARD]) if (v > region.y0 && v < region.y1) add(ysSet, v, r.x0 - PAD, r.x1 + PAD);
      });
      // a gap's middle depends only on the two boxes that face each other across it
      for (const r of rs) {
        const { right, left, down, up } = facing(r);
        const addMid = (set, a, b, lo, hi, h0, h1) => { if (b - a >= 2 * HARD + 2) { const m = (a + b) / 2; if (m > lo && m < hi) add(set, m, h0 - PAD, h1 + PAD); } };
        if (right) addMid(xsSet, r.x1, right.x0, region.x0, region.x1, Math.max(r.y0, right.y0), Math.min(r.y1, right.y1));
        if (left) addMid(xsSet, left.x1, r.x0, region.x0, region.x1, Math.max(r.y0, left.y0), Math.min(r.y1, left.y1));
        if (down) addMid(ysSet, r.y1, down.y0, region.y0, region.y1, Math.max(r.x0, down.x0), Math.min(r.x1, down.x1));
        if (up) addMid(ysSet, up.y1, r.y0, region.y0, region.y1, Math.max(r.x0, up.x0), Math.min(r.x1, up.x1));
      }
      if (starts.length === 1 && goals.length === 1) { add(xsSet, (starts[0].S[0] + goals[0].T[0]) / 2); add(ysSet, (starts[0].S[1] + goals[0].T[1]) / 2); }
      const xs = [...xsSet.keys()].sort((a, b) => a - b), ys = [...ysSet.keys()].sort((a, b) => a - b);
      const homeX = xs.map((v) => xsSet.get(v)), homeY = ys.map((v) => ysSet.get(v));
      // the length of [a, b] off a line's home stretches (exact, so splitting a run never changes its cost)
      const offHome = (h, a, b) => {
        if (h === true) return 0;
        const lo = Math.min(a, b), hi = Math.max(a, b);
        const iv = [];
        for (let k = 0; k < h.length; k += 2) { const u = Math.max(lo, h[k]), v = Math.min(hi, h[k + 1]); if (v > u) iv.push([u, v]); }
        if (!iv.length) return hi - lo;
        iv.sort((p, q) => p[0] - q[0]);
        let inLen = 0, s0 = iv[0][0], e0 = iv[0][1];
        for (let k = 1; k < iv.length; k++) { if (iv[k][0] > e0) { inLen += e0 - s0; s0 = iv[k][0]; e0 = iv[k][1]; } else if (iv[k][1] > e0) e0 = iv[k][1]; }
        return hi - lo - (inLen + e0 - s0);
      };
      const NX = xs.length, NY = ys.length;
      const N = NX * NY * 4;
      const B = buffers(N), gen = B.gen, gv = B.g, from = B.from, seen = B.seen, doneAt = B.done, ecv = B.ec, ecAt = B.ecAt;
      const G = (s) => (seen[s] === gen ? gv[s] : Infinity);
      const heap = new Heap();
      const goalAt = new Map();
      goals.forEach((q, k) => { const c = ys.indexOf(q.T[1]) * NX + xs.indexOf(q.T[0]); if (!goalAt.has(c)) goalAt.set(c, []); goalAt.get(c).push({ q, k }); });
      const one = goals.length === 1 ? goals[0].T : null;
      const h = one ? (i, j) => { const dx = Math.abs(xs[i] - one[0]), dy = Math.abs(ys[j] - one[1]); return dx + dy + (dx > 0.01 && dy > 0.01 ? BEND : 0); } : (i, j) => {
        let best = Infinity;
        for (const q of goals) { const dx = Math.abs(xs[i] - q.T[0]), dy = Math.abs(ys[j] - q.T[1]); const v = dx + dy + (dx > 0.01 && dy > 0.01 ? BEND : 0); if (v < best) best = v; }
        return best;
      };
      const goalCells = new Set(goalAt.keys());
      starts.forEach((p) => {
        const i = xs.indexOf(p.S[0]), j = ys.indexOf(p.S[1]), st = ((j * NX) + i) * 4 + p.od;
        if (p.g0 < G(st)) { gv[st] = p.g0; from[st] = -1; seen[st] = gen; heap.push(p.g0 + w * h(i, j), st); }
      });
      let goal = -1, goalCost = Infinity, goalK = -1, expanded = 0;
      while (heap.f.length) {
        const f = heap.f[0];
        if (f >= goalCost) break;
        const s = heap.pop();
        if (doneAt[s] === gen) continue;
        doneAt[s] = gen;
        if (++expanded > cap) { stats.capped++; lastCapped = true; break; }
        const d = s & 3, cell = s >> 2, i = cell % NX, j = (cell / NX) | 0;
        const here = goalCells.has(cell) ? goalAt.get(cell) : null;
        if (here) for (const { q, k } of here) {
          if (d === OPPOSITE[q.idir]) continue;
          const fin = gv[s] + (d === q.idir ? 0 : BEND) + (q.extra || 0);
          if (fin < goalCost) { goalCost = fin; goal = s; goalK = k; }
        }
        for (let nd = 0; nd < 4; nd++) {
          if (nd === OPPOSITE[d]) continue;
          const ni = i + (nd === 0 ? 1 : nd === 1 ? -1 : 0), nj = j + (nd === 2 ? 1 : nd === 3 ? -1 : 0);
          if (ni < 0 || nj < 0 || ni >= NX || nj >= NY) continue;
          const key = nd < 2 ? (j * NX + Math.min(i, ni)) * 2 : (Math.min(j, nj) * NX + i) * 2 + 1;
          let c = ecAt[key] === gen ? ecv[key] : undefined;
          if (c === undefined) {
            const sc = segCost(xs[i], ys[j], xs[ni], ys[nj], own, allowed);
            const len = Math.abs(xs[ni] - xs[i]) + Math.abs(ys[nj] - ys[j]);
            // Equal-cost routes are told apart by geometry, never by the grid's numbering (which shifts when any box in
            // the window moves): a hair's preference for runs near the middle between the ends (squared, since a
            // linear preference costs every staircase the same), then for higher horizontal runs.
            const off = nd < 2 ? ys[j] - mid[1] : xs[i] - mid[0];
            const away = nd < 2 ? offHome(homeY[j], xs[i], xs[ni]) : offHome(homeX[i], ys[j], ys[nj]);
            c = sc === Infinity ? Infinity : sc + len + len * (Math.min(1.6e7, off * off) * TIE + (nd < 2 ? off * TIE2 : 0)) + away * AWAY + (sib ? sibCrossings(xs[i], ys[j], xs[ni], ys[nj]) * CROSS_SIB : 0);
            ecv[key] = c; ecAt[key] = gen;
          }
          if (c === Infinity) continue;
          const ns = ((nj * NX) + ni) * 4 + nd;
          // a corner far from the middle between the ends costs a hair more, so a free jog sits on the middle line
          // (always a grid line), not on whichever far box's edge is at an extreme
          const ng = gv[s] + c + (nd === d ? 0 : BEND + TIEB * Math.min(1.6e7, (xs[i] - mid[0]) * (xs[i] - mid[0]) + (ys[j] - mid[1]) * (ys[j] - mid[1])));
          if (ng < G(ns)) { gv[ns] = ng; from[ns] = s; seen[ns] = gen; heap.push(ng + w * h(ni, nj), ns); }
        }
      }
      stats.expanded += expanded;
      if (opts.searchLog) opts.searchLog.push({ expanded, n: N, cost: goalCost });
      if (goal < 0 || lastCapped) return null;
      const pts = [];
      for (let s = goal; s >= 0; s = from[s]) { const cell = s >> 2; pts.push([xs[cell % NX], ys[(cell / NX) | 0]]); }
      pts.reverse();
      const sk = starts.findIndex((p) => p.S[0] === pts[0][0] && p.S[1] === pts[0][1]);
      return { pts, cost: goalCost, sk, gk: goalK };
    }

    // The nearest box (or name) facing each side of an obstacle, within FACE px: the two make a gap whose middle is a
    // grid line. Found once per routing.
    const faces = new Map();
    function facing(r) {
      let f = faces.get(r);
      if (f) return f;
      f = { right: null, left: null, down: null, up: null };
      obs.query(r.x0 - FACE, r.y0 - FACE, r.x1 + FACE, r.y1 + FACE, (o) => {
        if (o === r) return;
        if (o.y0 < r.y1 && o.y1 > r.y0) { if (o.x0 >= r.x1 && (!f.right || o.x0 < f.right.x0)) f.right = o; if (o.x1 <= r.x0 && (!f.left || o.x1 > f.left.x1)) f.left = o; }
        if (o.x0 < r.x1 && o.x1 > r.x0) { if (o.y0 >= r.y1 && (!f.down || o.y0 < f.down.y0)) f.down = o; if (o.y1 <= r.y0 && (!f.up || o.y1 > f.up.y1)) f.up = o; }
      });
      faces.set(r, f);
      return f;
    }

    // Round 10, finding 13: at most STEPS steps for the cheapest route in the window; a line that needs more (a long
    // line across a big board) takes a quicker search that weighs the distance left, then the whole board the same way.
    function searchLadder(starts, goals, own, allowed, region, mid) {
      // ENG-16: while a box is dragged, one quick search in the line's window per frame; a line it misses is drawn plain
      // above the boxes for that frame, and the whole board routes properly on release.
      if (opts.drag) { const res = search(starts, goals, own, allowed, region, mid, QUICK, DRAG_STEPS); return { res, how: res ? "quick" : "drag" }; }
      // a line longer than LONG (from its start to its end) takes the quicker search at once
      const far = Math.abs(starts[0].S[0] - goals[0].T[0]) + Math.abs(starts[0].S[1] - goals[0].T[1]) > LONG;
      let res = far ? null : search(starts, goals, own, allowed, region, mid, 1, STEPS);
      if (res) return { res, how: "search" };
      if (far || lastCapped) {
        res = search(starts, goals, own, allowed, region, mid, QUICK, STEPS * 4);
        if (res) return { res, how: "quick" };
      }
      res = search(starts, goals, own, allowed, world, mid, QUICK, STEPS * 8);
      return { res, how: "wide" };
    }

    // A cache key for a search: its ends and everything in its window that the costs read.
    function windowKey(head, region, allowed) {
      const parts = [head, area.x0, area.y0, area.x1, area.y1];
      // obstacles up to FACE beyond the window count too: they decide where the window's gaps have their middles
      const rs = [];
      obs.query(region.x0 - FACE, region.y0 - FACE, region.x1 + FACE, region.y1 + FACE, (r) => rs.push(r));
      rs.sort((p, q) => p.x0 - q.x0 || p.y0 - q.y0 || p.x1 - q.x1 || p.y1 - q.y1);
      for (const r of rs) parts.push(r.x0, r.y0, r.x1, r.y1, r.id || "");
      const sb = [];
      softs.query(region.x0, region.y0, region.x1, region.y1, (r) => sb.push(r));
      sb.sort((p, q) => p.x0 - q.x0 || p.y0 - q.y0);
      for (const r of sb) parts.push("s", r.x0, r.y0, r.x1, r.y1);
      const ss = [];
      secs.query(region.x0, region.y0, region.x1, region.y1, (r) => ss.push(r));
      ss.sort((p, q) => p.x0 - q.x0 || p.y0 - q.y0 || p.x1 - q.x1 || p.y1 - q.y1);
      for (const r of ss) parts.push(r.x0, r.y0, r.x1, r.y1, allowed.has(r.id) ? 1 : 0);
      return parts.join(",");
    }

    // ---------- sides and ports ----------
    const edges = [];
    for (const e of input.edges || []) {
      const a = byId.get(String(e.from)), b = byId.get(String(e.to));
      if (!a || !b) continue;
      edges.push({ e, a, b, id: String(e.id), own: new Set([String(a.id), String(b.id)]), allowed: null });
    }
    for (const it of edges) it.allowed = new Set([...ancestors(String(it.a.id)), ...ancestors(String(it.b.id))]);
    stats.edges = edges.length;
    const inside = (p, q) => p.x >= q.x && p.y >= q.y && p.x + p.w <= q.x + q.w && p.y + p.h <= q.y + q.h;

    // Missing sides: the cheapest of up to four pairs by the plain route's length, corners and what it would cross.
    function chooseSides(it) {
      const { e, a, b } = it;
      const [ax, ay] = centre(a), [bx, by] = centre(b);
      const dx = bx - ax, dy = by - ay;
      const H = dx >= 0 ? ["right", "left"] : ["left", "right"], V = dy >= 0 ? ["bottom", "top"] : ["top", "bottom"];
      const cands = [H, V, [H[0], V[1]], [V[0], H[1]]];
      // A side the file gives is kept, unless it faces away from the other end (round 10, finding 6: stored sides are
      // hints): a line out of a box's top to a box below it would loop round its own box.
      const away = (box, side, other) => {
        const [cx, cy] = centre(box), [ox, oy] = centre(other), l = Math.hypot(ox - cx, oy - cy) || 1;
        return (NORMAL[side][0] * (ox - cx) + NORMAL[side][1] * (oy - cy)) / l < -0.3;
      };
      let fixedFrom = e.fromSide && e.fromSideGiven !== false ? e.fromSide : null, fixedTo = e.toSide && e.toSideGiven !== false ? e.toSide : null;
      // a side whose end Hatim placed (fromAt, toAt) is binding, never a hint
      if (fixedFrom && e.fromAt == null && away(a, fixedFrom, b)) { fixedFrom = null; it.hintDropped = true; }
      if (fixedTo && e.toAt == null && away(b, fixedTo, a)) { fixedTo = null; it.hintDropped = true; }
      let best = null;
      const seen = new Set();
      for (const c of cands) {
        const fs = fixedFrom || c[0], ts = fixedTo || c[1];
        const k = fs + ts;
        if (seen.has(k)) continue;
        seen.add(k);
        const P = sidePoint(a, fs, 0.5), Q = sidePoint(b, ts, 0.5);
        const S = [P[0] + NORMAL[fs][0] * STUB, P[1] + NORMAL[fs][1] * STUB], T = [Q[0] + NORMAL[ts][0] * STUB, Q[1] + NORMAL[ts][1] * STUB];
        const od = dirOf(NORMAL[fs]), idir = OPPOSITE[dirOf(NORMAL[ts])];
        let cost = 4000 + Math.abs(T[0] - S[0]) + Math.abs(T[1] - S[1]) + 3 * BEND; // no plain route: a detour
        for (const pts of simple(S, T, od, idir)) {
          const pc = polyCost([P, ...pts, Q], it.own, it.allowed);
          if (pc < cost) cost = pc;
        }
        // A box's lines leave from the side facing where they go: the facing pair along the main direction wins
        // unless it is blocked (worth more than a corner); across a horizontal gap a little more (flows read along rows).
        const gapX = Math.max(b.x - (a.x + a.w), a.x - (b.x + b.w)), gapY = Math.max(b.y - (a.y + a.h), a.y - (b.y + b.h));
        if (fs === H[0] && ts === H[1] && gapX >= 2 * STUB && Math.abs(dx) >= Math.abs(dy) * 0.8) cost -= BEND * 1.5 + 8;
        else if (fs === V[0] && ts === V[1] && gapY >= 2 * STUB && Math.abs(dy) > Math.abs(dx) * 0.8) cost -= BEND * 1.5;
        if (!best || cost < best.cost) best = { fs, ts, cost };
      }
      it.fromSide = best.fs; it.toSide = best.ts;
      // Every plain route is blocked: a search picks the sides (below), unless the file gave both.
      if (best.cost >= 3000 && !(fixedFrom && fixedTo)) { it.open = true; it.fixedFrom = fixedFrom; it.fixedTo = fixedTo; }
    }
    // A side's penalty for an open line: facing the other box is free, a perpendicular side costs, facing away more.
    function sidePenalty(box, side, other) {
      const [cx, cy] = centre(box), [ox, oy] = centre(other), l = Math.hypot(ox - cx, oy - cy) || 1;
      const dot = (NORMAL[side][0] * (ox - cx) + NORMAL[side][1] * (oy - cy)) / l;
      return dot > 0.5 ? 0 : dot > -0.5 ? BEND * 0.75 : BEND * 2.5;
    }
    // A line whose plain routes are all blocked: one search from the middle of every allowed side of its first box to
    // the middle of every allowed side of its second; the cheapest path decides the sides. Its route comes later, from
    // its port, like every other line's.
    function openSides(it) {
      const { a, b } = it;
      const SIDES = ["right", "bottom", "left", "top"];
      const starts = [], goals = [];
      for (const side of it.fixedFrom ? [it.fixedFrom] : SIDES) {
        const P = sidePoint(a, side, 0.5), l = stubLength(P, side, String(a.id));
        starts.push({ side, S: [P[0] + NORMAL[side][0] * l, P[1] + NORMAL[side][1] * l], od: dirOf(NORMAL[side]), g0: sidePenalty(a, side, b) });
      }
      for (const side of it.fixedTo ? [it.fixedTo] : SIDES) {
        const Q = sidePoint(b, side, 0.5), l = stubLength(Q, side, String(b.id));
        goals.push({ side, T: [Q[0] + NORMAL[side][0] * l, Q[1] + NORMAL[side][1] * l], idir: OPPOSITE[dirOf(NORMAL[side])], extra: sidePenalty(b, side, a) });
      }
      const x0 = Math.min(a.x, b.x), y0 = Math.min(a.y, b.y), x1 = Math.max(a.x + a.w, b.x + b.w), y1 = Math.max(a.y + a.h, b.y + b.h);
      const region = { x0: x0 - REGION, y0: y0 - REGION, x1: x1 + REGION, y1: y1 + REGION };
      const key = cache ? (opts.drag ? "dopen|" : "open|") + windowKey([a.x, a.y, a.w, a.h, b.x, b.y, b.w, b.h, it.fixedFrom || "", it.fixedTo || ""].join(","), region, it.allowed) : null;
      let hit = key ? cache.get(key) : undefined;
      if (hit === undefined) {
        const mid = [(centre(a)[0] + centre(b)[0]) / 2, (centre(a)[1] + centre(b)[1]) / 2];
        const { res } = searchLadder(starts, goals, it.own, it.allowed, region, mid);
        hit = res && res.sk >= 0 ? [starts[res.sk].side, goals[res.gk].side] : null;
        if (key && res) cache.set(key, hit);
      } else stats.cached++;
      if (hit) { it.fromSide = hit[0]; it.toSide = hit[1]; }
    }

    // ENG-21: a line Hatim reshaped keeps its corners (via); only the runs at its ends follow its boxes.
    const clampN = (v, lo, hi) => Math.max(lo, Math.min(hi, v));
    function attach(box, side, c, at) {
      const horiz = side === "left" || side === "right";
      const lo = horiz ? box.y + box.h * 0.15 : box.x + box.w * 0.15, hi = horiz ? box.y + box.h * 0.85 : box.x + box.w * 0.85;
      const along = horiz ? c[1] : c[0];
      // an end Hatim placed keeps its place on the side; else level with the corner within the side's middle 70%
      const t = at != null ? (horiz ? box.y + box.h * at : box.x + box.w * at) : clampN(along, lo, hi);
      const port = horiz ? [side === "left" ? box.x : box.x + box.w, t] : [t, side === "top" ? box.y : box.y + box.h];
      const n = NORMAL[side];
      if ((c[0] - port[0]) * n[0] + (c[1] - port[1]) * n[1] < 1) return null; // the box moved past its first corner
      if (horiz) c[1] = t; else c[0] = t; // the corner slides across to meet the port; the run after it stretches
      return port;
    }
    function shapeOf(it) {
      const v = it.e.via;
      if (!Array.isArray(v) || !v.length) return null;
      const a = it.a, b = it.b;
      const infer = (box, q) => (q[0] < box.x ? "left" : q[0] > box.x + box.w ? "right" : q[1] < box.y ? "top" : q[1] > box.y + box.h ? "bottom" : null);
      const fs = it.e.fromSide || infer(a, v[0]), ts = it.e.toSide || infer(b, v[v.length - 1]);
      if (!NORMAL[fs] || !NORMAL[ts]) return null;
      const mid = v.map((q) => [q[0], q[1]]);
      const P = attach(a, fs, mid[0], it.e.fromAt);
      const Q = P && attach(b, ts, mid[mid.length - 1], it.e.toAt);
      if (!P || !Q) return null;
      const pts = simplify([P, ...mid, Q]);
      if (pts.length < 2) return null;
      for (let i = 1; i < pts.length; i++) if (Math.abs(pts[i][0] - pts[i - 1][0]) > 0.01 && Math.abs(pts[i][1] - pts[i - 1][1]) > 0.01) return null;
      // the line still leaves and enters along its sides' normals
      const d0 = [Math.sign(pts[1][0] - pts[0][0]), Math.sign(pts[1][1] - pts[0][1])], n0 = NORMAL[fs];
      const n = pts.length, d1 = [Math.sign(pts[n - 2][0] - pts[n - 1][0]), Math.sign(pts[n - 2][1] - pts[n - 1][1])], n1 = NORMAL[ts];
      if (d0[0] !== n0[0] || d0[1] !== n0[1] || d1[0] !== n1[0] || d1[1] !== n1[1]) return null;
      // clear unless a box that is not one of its ends lies under it (then drawn above the boxes, principle 1)
      let clear = true;
      for (let i = 1; i < n && clear; i++) {
        const p0 = pts[i - 1], p1 = pts[i];
        const x0 = Math.min(p0[0], p1[0]), x1 = Math.max(p0[0], p1[0]), y0 = Math.min(p0[1], p1[1]), y1 = Math.max(p0[1], p1[1]);
        obs.query(x0, y0, x1, y1, (r) => { if (r.kind === "box" && !it.own.has(r.id) && x1 > r.x0 && x0 < r.x1 && y1 > r.y0 && y0 < r.y1) clear = false; });
      }
      return { pts, fromSide: fs, toSide: ts, clear };
    }

    const loops = [];
    for (const it of edges) {
      if (it.a === it.b) { loops.push(it); continue; }
      if (inside(it.a, it.b) || inside(it.b, it.a)) { it.skip = "nested"; continue; }
      if (it.e.via) {
        const sh = shapeOf(it);
        if (sh) { it.shaped = sh; it.fromSide = sh.fromSide; it.toSide = sh.toSide; it.P = sh.pts[0]; it.Q = sh.pts[sh.pts.length - 1]; stats.shaped++; continue; }
        stats.shapeDropped.push(it.id); // no longer fits its boxes: routed as usual for this drawing
      }
      if (it.e.route === "straight") {
        const st = straightLine(it.a, it.b);
        if (st) { it.straight = st; continue; }
        it.straightBlocked = true;
      }
      chooseSides(it);
      if (it.open) openSides(it);
    }

    // Ports: lines on one side of a box spread over its middle, ordered first by which way their route turns after
    // leaving (so they do not cross at the box), then by where their other ends are.
    const bySide = new Map();
    // ENG-21: an end Hatim dragged sits where he put it on its side (fromAt, toAt); the side's other lines spread around it
    const fixedPort = (it, end) => {
      const at = end === "from" ? it.e.fromAt : it.e.toAt, side = end === "from" ? it.fromSide : it.toSide;
      const given = end === "from" ? it.e.fromSide === side : it.e.toSide === side;
      return at != null && given && NORMAL[side] ? sidePoint(end === "from" ? it.a : it.b, side, at) : null;
    };
    for (const it of edges) {
      if (it.skip || it.straight || it.shaped || it.a === it.b) continue;
      for (const end of ["from", "to"]) {
        const fp = fixedPort(it, end);
        if (fp) { it[end === "from" ? "P" : "Q"] = fp; it[end === "from" ? "fixedP" : "fixedQ"] = fp; continue; }
        const box = end === "from" ? it.a : it.b, side = end === "from" ? it.fromSide : it.toSide;
        const k = box.id + "|" + side;
        let l = bySide.get(k);
        if (!l) bySide.set(k, (l = { box, side, list: [] }));
        const oc = centre(end === "from" ? it.b : it.a);
        l.list.push({ it, end, cls: 1, key: side === "left" || side === "right" ? oc[1] + oc[0] * 1e-6 : oc[0] + oc[1] * 1e-6 });
      }
    }
    const spread = (l) => {
      const n = l.list.length;
      const L = l.side === "left" || l.side === "right" ? l.box.h : l.box.w;
      let span = Math.min(L * 0.7, PORT_GAP * (n - 1));
      if (n > 1 && span / (n - 1) < MIN_PORT) span = Math.min(L * PORT_SPAN, MIN_PORT * (n - 1)); // crowded: more of the side
      l.list.forEach((p, i) => {
        const t = n === 1 ? 0.5 : 0.5 + (i / (n - 1) - 0.5) * span / L;
        p.it[p.end === "from" ? "P" : "Q"] = sidePoint(l.box, l.side, t);
      });
    };
    const portOrder = (p, q) => p.cls - q.cls || p.key - q.key || (p.it.id < q.it.id ? -1 : p.it.id > q.it.id ? 1 : p.end < q.end ? -1 : 1);
    for (const l of bySide.values()) l.list.sort(portOrder);
    // Round 10, finding 14: a side holds as many lines as fit MIN_PORT apart over its middle 70%; the lines past that
    // move to the next side, from the ends of the order (the first toward the side's start, the last toward its end),
    // unless the file gave their side or the next side is full too.
    const NEXT = { left: ["top", "bottom"], right: ["top", "bottom"], top: ["left", "right"], bottom: ["left", "right"] };
    const roomOf = (box, side) => Math.floor(((side === "left" || side === "right" ? box.h : box.w) * PORT_SPAN) / MIN_PORT) + 1;
    for (const l of [...bySide.values()]) {
      let over = l.list.length - roomOf(l.box, l.side);
      for (let turn = 0; over > 0 && turn < l.list.length * 2; turn++) {
        const atStart = turn % 2 === 0, idx = atStart ? 0 : l.list.length - 1;
        // the line at this end, if its side was not given in the file (else the next one in)
        let pick = -1;
        for (let x = 0; x < l.list.length; x++) {
          const i = atStart ? idx + x : idx - x, p = l.list[i];
          if (!p) break;
          const given = p.end === "from" ? p.it.e.fromSideGiven : p.it.e.toSideGiven;
          if (!given) { pick = i; break; }
        }
        if (pick < 0) continue;
        const nextSide = NEXT[l.side][atStart ? 0 : 1], k2 = l.box.id + "|" + nextSide;
        let l2 = bySide.get(k2);
        if (l2 && l2.list.length >= roomOf(l.box, nextSide)) continue;
        if (!l2) bySide.set(k2, (l2 = { box: l.box, side: nextSide, list: [] }));
        const [p] = l.list.splice(pick, 1);
        const oc = centre(p.end === "from" ? p.it.b : p.it.a);
        p.key = nextSide === "left" || nextSide === "right" ? oc[1] + oc[0] * 1e-6 : oc[0] + oc[1] * 1e-6;
        if (p.end === "from") p.it.fromSide = nextSide; else p.it.toSide = nextSide;
        l2.list.push(p); l2.list.sort(portOrder);
        over--; stats.spilled++;
      }
    }
    for (const l of bySide.values()) spread(l);

    // One line from its two ports, on its own: the plain route when it touches nothing, else the search.
    const raw = new Map();
    // A line with both ends in one layered section (a flow) is one of that flow's lines: the flow's lines avoid
    // crossing each other in file order, as ELK orders them (round 10, finding 16).
    function flowOf(it) {
      if (it.flow !== undefined) return it.flow;
      const pa = parentOf(String(it.a.id)), pb = parentOf(String(it.b.id));
      const sec = pa && pa === pb ? byId.get(pa) : null;
      return (it.flow = sec && sec.flow ? pa : null);
    }
    function routeOne(it, closed) {
      const { a, b, id } = it;
      if (it.shaped) { raw.set(id, { pts: it.shaped.pts.map((p) => p.slice()), how: "shaped", clear: it.shaped.clear }); return; }
      const P = it.P, Q = it.Q, fs = it.fromSide, ts = it.toSide;
      const ls = stubLength(P, fs, String(a.id)), lt = stubLength(Q, ts, String(b.id));
      const S = [P[0] + NORMAL[fs][0] * ls, P[1] + NORMAL[fs][1] * ls], T = [Q[0] + NORMAL[ts][0] * lt, Q[1] + NORMAL[ts][1] * lt];
      const od = dirOf(NORMAL[fs]), idir = OPPOSITE[dirOf(NORMAL[ts])];
      let pts = null, how = "";
      shut = closed || null;
      exempt = null;
      for (const q of [P, Q]) obs.query(q[0] - HARD, q[1] - HARD, q[0] + HARD, q[1] + HARD, (r) => {
        if (it.own.has(r.id) || !(q[0] > r.x0 - HARD && q[0] < r.x1 + HARD && q[1] > r.y0 - HARD && q[1] < r.y1 + HARD)) return;
        (exempt = exempt || new Set()).add(r.id);
      });
      if (exempt) stats.exempt++;
      sib = null; sibHash = null;
      const flow = flowOf(it);
      const mine = rankOf.get(it);
      const peers = new Set([...(byBox.get(String(a.id)) || []), ...(byBox.get(String(b.id)) || []), ...(flow ? byFlow.get(flow) || [] : [])]);
      for (const o of [...peers].sort((p, q) => rankOf.get(p) - rankOf.get(q))) {
        if (rankOf.get(o) >= mine) break;
        const r0 = raw.get(o.id);
        if (!r0 || !r0.clear) continue;
        for (let i = 1; i < r0.pts.length; i++) {
          const u = r0.pts[i - 1], v = r0.pts[i];
          if (u[0] !== v[0] && u[1] !== v[1]) continue;
          const hh = u[1] === v[1];
          (sib = sib || []).push({ h: hh, c: hh ? u[1] : u[0], lo: Math.min(hh ? u[0] : u[1], hh ? v[0] : v[1]), hi: Math.max(hh ? u[0] : u[1], hh ? v[0] : v[1]) });
        }
      }
      for (const cand of simple(S, T, od, idir)) {
        const full = [P, ...cand, Q];
        let ok = true;
        for (let i = 1; i < full.length && ok; i++) if (segCost(full[i - 1][0], full[i - 1][1], full[i][0], full[i][1], it.own, it.allowed) !== 0 || (sib && sibCrossings(full[i - 1][0], full[i - 1][1], full[i][0], full[i][1]))) ok = false;
        if (ok) { pts = full; how = "fast"; break; }
      }
      if (!pts) {
        const region = { x0: Math.min(S[0], T[0], a.x, b.x) - REGION, y0: Math.min(S[1], T[1], a.y, b.y) - REGION, x1: Math.max(S[0], T[0], a.x + a.w, b.x + b.w) + REGION, y1: Math.max(S[1], T[1], a.y + a.h, b.y + b.h) + REGION };
        const key = cache && !shut ? (opts.drag ? "d|" : "") + windowKey([P, Q, fs, ts, sib ? JSON.stringify(sib) : ""].join(","), region, it.allowed) : null;
        const hit = key ? cache.get(key) : undefined;
        if (hit !== undefined) { pts = hit.pts ? hit.pts.map((p) => p.slice()) : null; how = hit.how; stats.cached++; }
        else {
          const st = [{ S, od, g0: 0 }], go = [{ T, idir, extra: 0 }];
          const mid = [(S[0] + T[0]) / 2, (S[1] + T[1]) / 2];
          const lad = searchLadder(st, go, it.own, it.allowed, region, mid);
          const res = lad.res;
          how = lad.how;
          if (res) pts = simplify([P, ...res.pts, Q]);
          // a route found on the whole board depends on the whole board: cached only with its window
          if (key && how !== "wide") cache.set(key, { pts: pts ? pts.map((p) => p.slice()) : null, how });
        }
      }
      if (opts.trace && opts.trace.id === id) opts.trace.out = { P, Q, S, T, fs, ts, od, idir, ls, lt, how };
      let clear = true;
      if (!pts) {
        // nothing clear: the plain route, drawn above the boxes and reported (principle 1)
        const c = simple(S, T, od, idir)[0] || [S, [S[0], T[1]], T];
        pts = [P, ...c, Q];
        how = "blocked"; clear = false;
      }
      shut = null; exempt = null; sib = null; sibHash = null;
      raw.set(id, { pts: simplify(pts), how, clear });
    }

    const order = edges.filter((it) => !it.skip && !it.straight && it.a !== it.b).sort((p, q) => (q.e.kind === "main") - (p.e.kind === "main") || (p.e.index || 0) - (q.e.index || 0));
    // the lines at each box and in each flow, for the sibling crossings
    const rankOf = new Map(order.map((it, i) => [it, i])), byBox = new Map(), byFlow = new Map();
    for (const it of order) {
      for (const id of it.own) { if (!byBox.has(id)) byBox.set(id, []); byBox.get(id).push(it); }
      const f = flowOf(it);
      if (f) { if (!byFlow.has(f)) byFlow.set(f, []); byFlow.get(f).push(it); }
    }
    for (const it of order) routeOne(it);

    // Ports follow the routes: on each side, lines that turn toward the side's start take the first ports, straight
    // lines the middle, lines turning toward its end the last. Lines whose port moved are routed once more.
    const turnOf = (pts, end, side) => {
      const p = end === "from" ? pts : pts.slice().reverse();
      if (p.length < 3) return 1;
      const ax = side === "left" || side === "right" ? 1 : 0; // the coordinate along the side
      const d = p[2][ax] - p[1][ax];
      // a jog shorter than the port spacing is no turn (two boxes facing each other: their lines stay parallel)
      return d < -PORT_GAP ? 0 : d > PORT_GAP ? 2 : 1;
    };
    const again = new Set();
    for (const l of bySide.values()) {
      if (l.list.length < 2) continue;
      const before = l.list.slice();
      for (const p of l.list) { const r = raw.get(p.it.id); p.cls = r && r.clear ? turnOf(r.pts, p.end, l.side) : 1; }
      l.list.sort(portOrder);
      if (l.list.some((p, i) => p !== before[i])) { spread(l); l.list.forEach((p, i) => { if (p !== before[i]) again.add(p.it); }); stats.reordered++; }
    }
    for (const it of order) if (again.has(it)) routeOne(it);

    // ---------- spacing: lines that share a gap are spread apart ----------
    const rank = new Map(order.map((it, i) => [it, i]));
    let routes = new Map(), jams = [];
    spreadAll();
    // A gap too narrow for the lines in it: the lines past its room are routed again with that stretch closed, and kept
    // when the new route is clear and not much longer; then everything is spread again. Once, in the routing order.
    if (jams && jams.length) {
      const closed = new Map();
      for (const j of jams) for (const it of j.lines) { if (!closed.has(it)) closed.set(it, []); closed.get(it).push(j.rect); }
      for (const it of order) {
        const cl = closed.get(it);
        if (!cl) continue;
        const before = raw.get(it.id);
        routeOne(it, cl);
        const after = raw.get(it.id);
        const len = (pts) => { let l = 0; for (let i = 1; i < pts.length; i++) l += Math.abs(pts[i][0] - pts[i - 1][0]) + Math.abs(pts[i][1] - pts[i - 1][1]); return l; };
        if (!after.clear || len(after.pts) > len(before.pts) * 1.5 + 300) raw.set(it.id, before); else stats.pushed++;
      }
      stats.jams = jams.length;
      jams = null;
      spreadAll();
    }
    function spreadAll() {
      routes = new Map();
      for (const it of order) {
        const r0 = raw.get(it.id);
        routes.set(it.id, { pts: r0.pts.map((p) => p.slice()), raw: r0.pts, fromSide: it.fromSide, toSide: it.toSide, clear: r0.clear, how: r0.how, label: null, open: !!it.open, straightBlocked: !!it.straightBlocked });
      }
      nudgeAll(false);
      nudgeAll(true);
      // a spread route that now touches a box goes back to its own route
      for (const it of order) {
        const r = routes.get(it.id);
        if (!r.clear || it.shaped) continue;
        let ok = true;
        const p = r.pts;
        for (let i = 1; i < p.length && ok; i++) {
          const a = p[i - 1], b = p[i];
          if (a[0] !== b[0] && a[1] !== b[1]) ok = false;
          else if (i >= 2) { const q = p[i - 2]; if (dirOf([Math.sign(a[0] - q[0]), Math.sign(a[1] - q[1])]) === OPPOSITE[dirOf([Math.sign(b[0] - a[0]), Math.sign(b[1] - a[1])])]) ok = false; }
          if (ok && segCost(a[0], a[1], b[0], b[1], it.own, it.allowed) === Infinity) ok = false;
        }
        if (!ok) r.pts = r.raw.map((q) => q.slice());
        r.pts = simplify(r.pts);
      }
    }
    for (const r of routes.values()) if (r.pts.length !== r.raw.length || r.pts.some((q, i) => q[0] !== r.raw[i][0] || q[1] !== r.raw[i][1])) stats.nudged++;

    // One pass over every channel of one direction (vertical runs when !horiz). A channel is a group of inner runs on
    // (nearly) one line whose extents overlap; its runs are ordered so that each leaves the channel toward the side it
    // turns to, then spaced NUDGE apart inside the free space beside them.
    function nudgeAll(horiz) {
      const A = horiz ? 1 : 0, B = horiz ? 0 : 1; // A: the coordinate across the run, B: along it
      const runs = [];
      for (const it of order) {
        const r = routes.get(it.id);
        if (!r.clear) continue;
        const p = r.pts, n = p.length;
        // every run; a line's first and last runs sit on its ports and do not move, but the others spread around them
        for (let k = 0; k <= n - 2; k++) {
          const u = p[k], v = p[k + 1];
          if (u[A] !== v[A] || u[B] === v[B]) continue;
          const c = u[A];
          const [lo, hi, endLo, endHi] = u[B] < v[B] ? [u[B], v[B], k, k + 1] : [v[B], u[B], k + 1, k];
          // which way the line leaves the channel at each end: toward smaller (-1) or larger (+1) coordinate, 0 into a box
          const away = (idx) => { const q = idx === k ? p[k - 1] : p[k + 2]; return q ? Math.sign(q[A] - c) : 0; };
          runs.push({ it, r, k, c, lo, hi, dLo: away(endLo), dHi: away(endHi), idx: runs.length, fixed: k === 0 || k === n - 2 || !!it.shaped });
        }
      }
      if (!runs.length) return;
      // the free space across each run, with the room its neighbouring runs need: hard (HARD from boxes) and soft
      // (SOFT from boxes, preferred when it leaves room enough)
      for (const s of runs) {
        let lo = -Infinity, hi = Infinity, slo = -Infinity, shi = Infinity;
        const q0 = horiz ? [s.lo, s.c - 64, s.hi, s.c + 64] : [s.c - 64, s.lo, s.c + 64, s.hi];
        obs.query(q0[0] - SOFT, q0[1] - SOFT, q0[2] + SOFT, q0[3] + SOFT, (o) => {
          const mine = s.it.own.has(o.id);
          const oLo = horiz ? o.x0 : o.y0, oHi = horiz ? o.x1 : o.y1, cLo = horiz ? o.y0 : o.x0, cHi = horiz ? o.y1 : o.x1;
          for (const soft of [false, true]) {
            const m = mine ? 0 : soft ? SOFT : HARD;
            if (!(oLo - m < s.hi && oHi + m > s.lo)) continue;
            let a = -Infinity, b = Infinity;
            if (cHi <= s.c + 1e-6) a = cHi + m;
            else if (cLo >= s.c - 1e-6) b = cLo - m;
            else { a = s.c; b = s.c; }
            if (soft) { slo = Math.max(slo, a); shi = Math.min(shi, b); } else { lo = Math.max(lo, a); hi = Math.min(hi, b); }
          }
        });
        const p = s.r.pts, n = p.length;
        s.oLo = lo; s.oHi = hi;
        if (s.fixed) { s.fLo = s.fHi = s.sLo = s.sHi = s.c; continue; }
        // a run out of a box keeps MIN_RUN for its arrowhead (soft), or at least MIN_STUB where lines would otherwise lie
        // on each other (hard); an inner neighbour keeps half its length
        let alo = -Infinity, ahi = Infinity, blo = -Infinity, bhi = Infinity;
        for (const [far, anchored] of [[p[s.k - 1], s.k - 1 === 0], [p[s.k + 2], s.k + 1 === n - 2]]) {
          const L = Math.abs(far[A] - s.c);
          if (anchored) {
            if (far[A] < s.c) { alo = Math.max(alo, Math.min(s.c, far[A] + MIN_RUN)); blo = Math.max(blo, Math.min(s.c, far[A] + MIN_STUB)); }
            else { ahi = Math.min(ahi, Math.max(s.c, far[A] - MIN_RUN)); bhi = Math.min(bhi, Math.max(s.c, far[A] - MIN_STUB)); }
          } else if (far[A] < s.c) { const v = s.c - Math.max(0, L / 2 - 1); alo = Math.max(alo, v); blo = Math.max(blo, v); }
          else { const v = s.c + Math.max(0, L / 2 - 1); ahi = Math.min(ahi, v); bhi = Math.min(bhi, v); }
        }
        s.fLo = Math.min(Math.max(lo, blo), s.c); s.fHi = Math.max(Math.min(hi, bhi), s.c);
        s.sLo = Math.min(Math.max(slo, alo), s.c); s.sHi = Math.max(Math.min(shi, ahi), s.c);
      }
      // channels: runs within NUDGE of one line whose extents overlap or touch
      runs.sort((p, q) => p.c - q.c || p.lo - q.lo || p.idx - q.idx);
      const parent = runs.map((_, i) => i);
      const find = (i) => { while (parent[i] !== i) i = parent[i] = parent[parent[i]]; return i; };
      for (let i = 0; i < runs.length; i++) {
        for (let j = i + 1; j < runs.length && runs[j].c - runs[i].c < NUDGE; j++) {
          if (runs[j].it === runs[i].it) continue;
          if (Math.min(runs[i].hi, runs[j].hi) - Math.max(runs[i].lo, runs[j].lo) >= -1) { const a = find(i), b = find(j); if (a !== b) parent[Math.max(a, b)] = Math.min(a, b); }
        }
      }
      const groupsOf = () => { const m = new Map(); runs.forEach((s, i) => { const g = find(i); if (!m.has(g)) m.set(g, []); m.get(g).push(s); }); return m; };
      const fileOrder = (s) => (s.it.e.index || 0) * 64 + s.k;
      // a before b (smaller coordinate) when that is the side each leaves toward. Where the two ends disagree, one
      // crossing cannot be avoided; it goes where they leave apart, never where both turn at one point (where the
      // wrong order would lay one line on the other).
      const cmp = (a, b) => {
        let t = 0, u = 0, tEq = false, uEq = false;
        if (a.lo > b.lo + 0.5) t = a.dLo; else if (b.lo > a.lo + 0.5) t = -b.dLo; else if (a.dLo !== b.dLo) { t = a.dLo < b.dLo ? -1 : 1; tEq = true; }
        if (a.hi < b.hi - 0.5) u = a.dHi; else if (b.hi < a.hi - 0.5) u = -b.dHi; else if (a.dHi !== b.dHi) { u = a.dHi < b.dHi ? -1 : 1; uEq = true; }
        if (t && u && t !== u && uEq && !tEq) return u;
        return t || u || fileOrder(a) - fileOrder(b);
      };
      // Place every channel; where a spread run comes within MINSEP of a run of another channel, the two channels become
      // one and are placed again (a few rounds).
      const placeGroup = (g, final) => {
        if (g.length < 2 || g.every((s) => s.fixed)) { for (const s of g) s.pos = s.c; return; }
        g.sort((p, q) => fileOrder(p) - fileOrder(q));
        g.sort(cmp);
        const k = g.length;
        let cMin = Infinity, cMax = -Infinity;
        for (const s of g) { cMin = Math.min(cMin, s.c); cMax = Math.max(cMax, s.c); }
        const C = (cMin + cMax) / 2;
        const ov = (a, b) => Math.min(a.hi, b.hi) - Math.max(a.lo, b.lo) >= -1;
        // tracks: in order, each run takes the next track after every earlier run it overlaps (runs that do not
        // overlap may share one); then the widest spacing (up to NUDGE) that fits every run in its free space, and each
        // run as near its track's place around the channel's middle as that allows
        const placeAll = () => {
          const track = new Array(k).fill(0);
          for (let i = 0; i < k; i++) for (let j = 0; j < i; j++) if (ov(g[i], g[j])) track[i] = Math.max(track[i], track[j] + 1);
          const T = Math.max(...track) + 1;
          const place = (loK, hiK) => {
            const pack = (sp) => {
              const P = new Array(k);
              for (let i = 0; i < k; i++) { let v = g[i][loK]; for (let j = 0; j < i; j++) if (ov(g[i], g[j])) v = Math.max(v, P[j] + sp); if (v > g[i][hiK] + 1e-6) return null; P[i] = v; }
              return P;
            };
            if (!pack(0)) return null;
            let a = 0, b = NUDGE;
            if (pack(NUDGE)) a = NUDGE; else for (let it = 0; it < 14; it++) { const m = (a + b) / 2; if (pack(m)) a = m; else b = m; }
            const sp = a, P = pack(sp), Q = new Array(k);
            for (let i = k - 1; i >= 0; i--) { let v = g[i][hiK]; for (let j = i + 1; j < k; j++) if (ov(g[i], g[j])) v = Math.min(v, Q[j] - sp); Q[i] = Math.max(v, P[i]); }
            const pos = g.map((s, i) => Math.max(P[i], Math.min(Q[i], C + (track[i] - (T - 1) / 2) * NUDGE)));
            let gap = NUDGE, score = 0; // the closest two overlapping runs end up, and the room of every pair
            for (let i = 0; i < k; i++) for (let j = 0; j < i; j++) if (ov(g[i], g[j])) { const d = Math.abs(pos[i] - pos[j]); gap = Math.min(gap, d); score += Math.min(d, NUDGE); }
            return { sp, gap, score, pos };
          };
          const soft = place("sLo", "sHi"), hard = place("fLo", "fHi");
          // keeping SOFT from boxes wins while lines stay MINSEP apart, or when it costs the lines no room
          const useSoft = soft && (!hard || soft.gap >= MINSEP - 1e-6 || soft.score >= hard.score - 1e-6);
          return { hard, use: useSoft ? soft : hard, track, T };
        };
        let pl = placeAll();
        // the free space can force an order the turns did not choose: then the order that fits
        if (!pl.hard) { g.sort((p, q) => (p.fLo + p.fHi) - (q.fLo + q.fHi) || cmp(p, q)); pl = placeAll(); }
        const pos = pl.use ? pl.use.pos : g.map((s, i) => Math.max(s.fLo, Math.min(s.fHi, C + (pl.track[i] - (pl.T - 1) / 2) * NUDGE)));
        // Too many lines for the gap (closer than MINSEP): the lines after the first few, in the routing order, are
        // routed again around this stretch (once; see below).
        g.forEach((s, i) => { s.pos = s.fixed ? s.c : Math.round(pos[i] * 100) / 100; });
        if (final && jams) for (let i = 0; i < k; i++) for (let j = 0; j < i; j++) {
          const a = g[i], b = g[j];
          if (a.it === b.it || !ov(a, b) || Math.abs(pos[i] - pos[j]) >= MINSEP - 1e-6) continue;
          const aLo = Math.max(a.lo, b.lo), aHi = Math.min(a.hi, b.hi), oLo = Math.max(a.oLo, b.oLo), oHi = Math.min(a.oHi, b.oHi);
          if (!(aHi > aLo + 1) || !(oHi < Infinity) || !(oLo > -Infinity)) continue;
          const later = rank.get(a.it) > rank.get(b.it) ? a : b;
          if (later.fixed) continue; // a run on a port cannot leave; the other line has to
          const rect = horiz ? { x0: aLo, y0: oLo - HARD, x1: aHi, y1: oHi + HARD } : { x0: oLo - HARD, y0: aLo, x1: oHi + HARD, y1: aHi };
          jams.push({ rect, lines: [later.it] });
        }
      };
      for (let round = 0; ; round++) {
        const groups = groupsOf();
        for (const g of groups.values()) placeGroup(g, false);
        // runs of different channels that ended up too close
        const byPos = runs.map((s, i) => i).sort((a, b) => runs[a].pos - runs[b].pos);
        let merged = false;
        for (let x = 0; x < byPos.length; x++) for (let y = x + 1; y < byPos.length && runs[byPos[y]].pos - runs[byPos[x]].pos < MINSEP; y++) {
          const i = byPos[x], j = byPos[y], a = runs[i], b = runs[j];
          if (a.it === b.it || find(i) === find(j)) continue;
          if (Math.min(a.hi, b.hi) - Math.max(a.lo, b.lo) < -1) continue;
          parent[Math.max(find(i), find(j))] = Math.min(find(i), find(j)); merged = true;
        }
        if (!merged || round >= 3) { if (jams) for (const g of groupsOf().values()) placeGroup(g, true); break; }
      }
      for (const s of runs) if (!s.fixed) { s.r.pts[s.k][A] = s.pos; s.r.pts[s.k + 1][A] = s.pos; }
    }

    // Straight lines between box borders, when they cross nothing.
    function clip(box, from, to) { // where the segment from the box's centre toward `to` leaves the box
      const [cx, cy] = from, dx = to[0] - cx, dy = to[1] - cy;
      const tx = dx ? (dx > 0 ? box.x + box.w - cx : box.x - cx) / dx : Infinity, ty = dy ? (dy > 0 ? box.y + box.h - cy : box.y - cy) / dy : Infinity;
      const t = Math.min(tx, ty);
      return [cx + dx * t, cy + dy * t];
    }
    function segHitsRect(p, q, r) { // Liang-Barsky
      let t0 = 0, t1 = 1;
      const dx = q[0] - p[0], dy = q[1] - p[1];
      const tests = [[-dx, p[0] - (r.x0 - HARD)], [dx, r.x1 + HARD - p[0]], [-dy, p[1] - (r.y0 - HARD)], [dy, r.y1 + HARD - p[1]]];
      for (const [pp, qq] of tests) {
        if (pp === 0) { if (qq < 0) return false; continue; }
        const t = qq / pp;
        if (pp < 0) { if (t > t1) return false; if (t > t0) t0 = t; } else { if (t < t0) return false; if (t < t1) t1 = t; }
      }
      return t1 - t0 > 1e-6;
    }
    function straightLine(a, b) {
      const ca = centre(a), cb = centre(b);
      const p = clip(a, ca, cb), q = clip(b, cb, ca);
      let hit = false;
      obs.query(Math.min(p[0], q[0]), Math.min(p[1], q[1]), Math.max(p[0], q[0]), Math.max(p[1], q[1]), (r) => {
        if (hit || r.id === String(a.id) || r.id === String(b.id)) return;
        if (segHitsRect(p, q, r)) hit = true;
      });
      return hit ? null : [p, q];
    }
    for (const it of edges) {
      if (!it.straight) continue;
      routes.set(it.id, { pts: it.straight, fromSide: null, toSide: null, clear: true, how: "straight", label: null });
      stats.straight++;
    }

    // A box's line to itself: out of its right side, round its top-right corner, into its top.
    for (const it of loops) {
      const a = it.a, k = 24;
      const P = [a.x + a.w, a.y + Math.min(a.h * 0.3, 30)], Q = [a.x + a.w - Math.min(a.w * 0.3, 40), a.y];
      const pts = [P, [P[0] + k, P[1]], [P[0] + k, Q[1] - k], [Q[0], Q[1] - k], Q];
      routes.set(it.id, { pts, fromSide: "right", toSide: "top", clear: true, how: "loop", label: null });
    }

    // ---------- label chips: last, on their own line, clear of boxes, names, other chips and other lines ----------
    const lineSegs = new Hash(160);
    for (const [id, r] of routes) for (let i = 1; i < r.pts.length; i++) {
      const a = r.pts[i - 1], b = r.pts[i];
      lineSegs.add({ x0: Math.min(a[0], b[0]), y0: Math.min(a[1], b[1]), x1: Math.max(a[0], b[0]), y1: Math.max(a[1], b[1]), edge: id });
    }
    const chips = new Hash(160);
    const labelled = edges.filter((it) => it.e.label && routes.has(it.id)).sort((p, q) => (q.e.kind === "main") - (p.e.kind === "main") || (p.e.index || 0) - (q.e.index || 0));
    for (const it of labelled) {
      if (it.e.labelAt != null) placeLabelAt(routes.get(it.id), it.e.label, it.id, it.e.labelAt);
      else placeLabel(routes.get(it.id), it.e.label, it.id);
    }
    // ENG-21: a chip Hatim dragged sits at that fraction of its line's length, and is always shown there.
    function placeLabelAt(r, text, id, f) {
      const w = labelWidth(text), hgt = 22, pts = r.pts;
      let total = 0;
      for (let i = 1; i < pts.length; i++) total += Math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]);
      let want = total * f, x = pts[0][0], y = pts[0][1];
      for (let i = 1; i < pts.length; i++) {
        const len = Math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]);
        if (want <= len || i === pts.length - 1) { const t = len ? Math.min(1, want / len) : 0; x = pts[i - 1][0] + (pts[i][0] - pts[i - 1][0]) * t; y = pts[i - 1][1] + (pts[i][1] - pts[i - 1][1]) * t; break; }
        want -= len;
      }
      const box = { x0: x - w / 2, y0: y - hgt / 2, x1: x + w / 2, y1: y + hgt / 2 };
      let hard = 0;
      obs.query(box.x0, box.y0, box.x1, box.y1, (o) => { if (box.x1 > o.x0 && box.x0 < o.x1 && box.y1 > o.y0 && box.y0 < o.y1) hard += 100; });
      chips.query(box.x0, box.y0, box.x1, box.y1, (o) => { if (box.x1 > o.x0 && box.x0 < o.x1 && box.y1 > o.y0 && box.y0 < o.y1) hard += 50; });
      // shown where Hatim put it, even over a box's edge (a chip that is not clear would be tucked away)
      r.label = { x, y, w, h: hgt, clear: true, over: 0, at: f, onBox: hard >= 100 };
      chips.add({ x0: box.x0, y0: box.y0, x1: box.x1, y1: box.y1, id: "label:" + id });
    }
    // A chip sits near the part of the line it names (gate 3): the middle of a short line, about 200 px from its start
    // on a long one, so a line that detours keeps its words beside where it leaves; then off boxes, names, chips and
    // other lines, on its line before beside it.
    function placeLabel(r, text, id) {
      const w = labelWidth(text), hgt = 22;
      const pts = r.pts;
      let total = 0;
      const runs = [];
      for (let i = 1; i < pts.length; i++) {
        const a = pts[i - 1], b = pts[i], len = Math.hypot(b[0] - a[0], b[1] - a[1]);
        runs.push({ a, b, len, at: total, stub: i === 1 || i === pts.length - 1 });
        total += len;
      }
      const target = Math.min(total / 2, 200);
      let best = null;
      for (const run of runs) {
        if (run.len < 1) continue;
        const fits = run.len >= (run.a[1] === run.b[1] ? w : hgt) + 8;
        const horizRun = run.a[1] === run.b[1];
        const n = Math.max(2, Math.min(10, Math.ceil(run.len / 32)));
        for (let k = 0; k <= n; k++) {
          const t = k / n;
          let onLineClean = false;
          for (const side of [0, -1, 1]) {
            if (side && onLineClean) break; // beside is only for where on the line is taken
            const x = run.a[0] + (run.b[0] - run.a[0]) * t + (horizRun ? 0 : side * (w / 2 + 1)), y = run.a[1] + (run.b[1] - run.a[1]) * t + (horizRun ? side * (hgt / 2 + 1) : 0);
            const box = { x0: x - w / 2, y0: y - hgt / 2, x1: x + w / 2, y1: y + hgt / 2 };
            let hard = 0;
            obs.query(box.x0, box.y0, box.x1, box.y1, (o) => { if (box.x1 > o.x0 && box.x0 < o.x1 && box.y1 > o.y0 && box.y0 < o.y1) hard += 100; });
            chips.query(box.x0, box.y0, box.x1, box.y1, (o) => { if (box.x1 > o.x0 && box.x0 < o.x1 && box.y1 > o.y0 && box.y0 < o.y1) hard += 50; });
            softs.query(box.x0, box.y0, box.x1, box.y1, (o) => { if (box.x1 > o.x0 && box.x0 < o.x1 && box.y1 > o.y0 && box.y0 < o.y1) hard += 30; });
            const under = new Set();
            lineSegs.query(box.x0, box.y0, box.x1, box.y1, (sg) => { if (sg.edge !== id) under.add(sg.edge); });
            const lines = under.size;
            // the chip's ends along a straight run stay off its corners
            const edgeRoom = horizRun || side ? Math.min(t * run.len, (1 - t) * run.len) - (horizRun && !side ? w / 2 : hgt / 2) : 0;
            const score = hard + lines * 10 + (fits ? 0 : 0.5) + (edgeRoom < 0 && !side ? 1 : 0) + (run.stub ? 2 : 0) + (side ? 1.5 : 0) + Math.abs(run.at + t * run.len - target) / 100;
            if (!best || score < best.score) best = { score, box, x, y, hard, lines };
            if (!side && !hard && !lines) onLineClean = true;
          }
        }
      }
      if (!best) return;
      // Clear means off every box, name and other chip; a chip over other lines is counted (best.lines).
      r.label = { x: best.x, y: best.y, w, h: hgt, clear: best.hard < 50, over: best.lines };
      if (best.hard < 50) chips.add({ x0: best.box.x0, y0: best.box.y0, x1: best.box.x1, y1: best.box.y1, id: "label:" + id });
    }

    // ---------- the measures ----------
    for (const r of routes.values()) {
      for (let i = 1; i < r.pts.length; i++) stats.length += Math.hypot(r.pts[i][0] - r.pts[i - 1][0], r.pts[i][1] - r.pts[i - 1][1]);
      stats.bends += Math.max(0, r.pts.length - 2);
      if (r.how === "fast") stats.fast++;
      else if (r.how === "search" || r.how === "quick") { stats.searched++; if (r.how === "quick") stats.quick++; }
      else if (r.how === "wide") { stats.searched++; stats.wide++; }
      else if (r.how === "blocked") stats.notClear++;
    }
    stats.crossings = countCrossings(routes);
    stats.routed = routes.size;
    stats.ms = now() - t0;
    return { routes, stats };
  }


  /** Crossings between different lines (proper crossings of their segments, any angle). */
  function countCrossings(routes) {
    const list = [];
    for (const [id, r] of routes) for (let i = 1; i < r.pts.length; i++) list.push({ id, a: r.pts[i - 1], b: r.pts[i] });
    const H = new Hash(200);
    list.forEach((s) => H.add({ x0: Math.min(s.a[0], s.b[0]), y0: Math.min(s.a[1], s.b[1]), x1: Math.max(s.a[0], s.b[0]), y1: Math.max(s.a[1], s.b[1]), s }));
    const cross = (p, q, r, s) => {
      const d = (a, b, c) => (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
      const d1 = d(r, s, p), d2 = d(r, s, q), d3 = d(p, q, r), d4 = d(p, q, s);
      return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0));
    };
    const pairs = new Set();
    let n = 0;
    for (const s of list) {
      H.query(Math.min(s.a[0], s.b[0]), Math.min(s.a[1], s.b[1]), Math.max(s.a[0], s.b[0]), Math.max(s.a[1], s.b[1]), (o) => {
        const t = o.s;
        if (t === s || t.id === s.id) return;
        const k = s.id < t.id ? s.id + "|" + t.id + "|" + s.a + s.b + t.a + t.b : t.id + "|" + s.id + "|" + t.a + t.b + s.a + s.b;
        if (pairs.has(k)) return;
        if (cross(s.a, s.b, t.a, t.b)) { pairs.add(k); n++; }
      });
    }
    return n;
  }

  /** The router's input from a LinenCanvas board. Bands for section names and titles use opts.textWidth(text, px,
      weight) when given (the renderer measures with its fonts), else an estimate. */
  function fromBoard(board, opts) {
    opts = opts || {};
    const tw = opts.textWidth || ((t, px) => String(t).length * px * 0.52);
    const boxes = [], bands = [];
    // Free room beside a top-level section's top edge, on its trailing side, up to the next box or section (board.js roomRight).
    const tops = board.nodes.filter((n) => n.placed && !n.parent);
    const roomBeside = (sec) => {
      let room = 400;
      for (const o of tops) {
        if (o === sec || o.y > sec.y + 20 || o.y + o.h < sec.y - 90) continue;
        const gap = board.dir === "rtl" ? sec.x - (o.x + o.w) : o.x - (sec.x + sec.w);
        if (gap >= 0) room = Math.min(room, gap - 12);
      }
      return Math.max(0, room);
    };
    for (const n of board.nodes) {
      if (!n.placed) continue;
      boxes.push({ id: n.id, x: n.x, y: n.y, w: n.w, h: n.h, section: n.kind === "section", parent: n.parent || null, flow: n.kind === "section" && n.layout === "layered" });
      if (n.kind !== "section") continue;
      const nested = n.depth > 0;
      if (n.label) {
        // A top-level name keeps 15 px on screen when zoomed out (BRD-8), so in board px it grows as the board shrinks,
        // until it no longer fits beside its section and Linen hides it (board.js sizeLabel). The band is the largest
        // name that still fits: as wide as the room allows, as tall as that size. Nested names keep 15 px at reading zoom.
        let w, h;
        if (nested) {
          w = Math.min(n.w, tw(n.label, 15, 500) * 1.04 + 8); h = 15 * 1.15 + 6;
        } else {
          const room = n.w + roomBeside(n);
          const per = tw(n.label, 24, 300) / 24; // width per px of font
          const f = Math.max(24, Math.min(15 / (opts.nameScale || 0.3), room / (per * 1.04)));
          w = Math.min(room, per * f * 1.04 + 12);
          h = f * 1.15 + 8 * f / 15 + (n.eyebrow ? Math.max(11, 9 * f / 15) * 1.2 + 2 * f / 15 : 0);
        }
        const x = board.dir === "rtl" ? n.x + n.w - w : n.x;
        if (nested || w <= n.w) bands.push({ x, y: n.y - h, w, h });
        else { // the part over the gutter is soft (see route)
          bands.push({ x: n.x, y: n.y - h, w: n.w, h });
          bands.push({ x: board.dir === "rtl" ? x : n.x + n.w, y: n.y - h, w: w - n.w, h, soft: true });
        }
      }
      if (n.title && n.label) {
        const pad = nested ? 14 : 24;
        bands.push({ x: n.x + pad, y: n.y + pad, w: Math.min(n.w - 2 * pad, tw(n.title, 24, 300) + 6), h: 29 });
      }
    }
    const edges = [];
    for (const e of board.edges) {
      if (e.missing || !e.drawable) continue;
      // A line routes when its file or its board asks for a route; others keep Linen's old drawing (opts.all routes all).
      if (!opts.all && !e.routeGiven && !board.routeGiven) continue;
      edges.push({ id: e.id, from: e.from, to: e.to, fromSide: e.fromSideGiven ? e.fromSide : null, toSide: e.toSideGiven ? e.toSide : null,
        fromSideGiven: !!e.fromSideGiven, toSideGiven: !!e.toSideGiven, route: e.route, kind: e.kind, label: e.label, index: e.index,
        via: e.via || null, labelAt: e.labelAt == null ? null : e.labelAt,
        fromAt: e.fromAt == null || !e.fromSideGiven ? null : e.fromAt, toAt: e.toAt == null || !e.toSideGiven ? null : e.toAt });
    }
    return { boxes, bands, edges };
  }

  const api = { route, fromBoard, smooth, countCrossings, PAD, HARD, NUDGE };
  root.LinenRouter = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof self !== "undefined" ? self : typeof globalThis !== "undefined" ? globalThis : this);
