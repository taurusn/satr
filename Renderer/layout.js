/* Linen's board layout (PRD-2 BRD-17, BRD-25, section 9.2). A plain script: it sets self.LinenLayout in the page,
   in a worker, in node (module.exports) and in JavaScriptCore. It lays out the sections that ask for it
   (`linen.layout`: grid, stack, lanes, layered) one at a time inside their hand-placed frames, deepest first for
   heights and top first for widths; hand-placed nodes are never moved; a laid-out section takes the height its
   contents need; rows of top-level sections are kept `rowGap` apart so their names stay readable zoomed out.

   Measuring is the caller's: opts.measureBatch(items) -> [{w, h}] (preferred: one DOM layout for every card) or
   opts.measure(item) -> {w, h}, where an item is { id, kind, width, text, title, eyebrow, word, node } and kind
   "section-title" asks for the height of a section's serif title. Results are cached by content and width.

   Layered sections run ELK.js (Renderer/vendor/elk) in a Web Worker (layout-worker.js), started only when a board
   has one; opts.elk (an ELK instance) replaces the worker in node and in tests. */
(function (root) {
  "use strict";

  // Shared with the renderer: a section's frame is drawn with these paddings so laid-out contents sit where the
  // renderer expects them. Board pixels.
  const METRICS = {
    sectionPad: 24, // inside a top-level section
    groupPad: 14, // inside a nested group
    titleGap: 14, // under a section's serif title
    labelBand: 26, // above a nested group in a flow, for its label (eyebrow) drawn outside its box
    gapSection: 16, // between items in a top-level section
    gapGroup: 8, // between items in a nested group
    rowGap: 180, // BRD-25: between rows of top-level sections
    cardMin: 140, // a card in a layered section is never narrower
    cardDefault: 260,
    layeredNode: 48, // ELK spacing between nodes in a layer
    layeredLayer: 72, // ELK spacing between layers
  };
  const LAYOUTS = new Set(["grid", "stack", "lanes", "layered"]);
  const cache = new Map();
  let worker = null, workerSeq = 0;
  const pending = new Map();
  const scriptBase = (typeof document !== "undefined" && document.currentScript && document.currentScript.src)
    || (typeof self !== "undefined" && self.location && self.location.href) || "";

  function hashString(s) {
    let h = 0x811c9dc5;
    for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193); }
    return (h >>> 0).toString(16);
  }

  const now = () => (typeof performance !== "undefined" ? performance.now() : Date.now());

  // One accessor for both shapes: a raw JSON Canvas node ({width, height, linen: {...}}) or a board-model node
  // ({w, h, layout, cols, ...}).
  function norm(n, i) {
    const L = (n && typeof n.linen === "object" && n.linen) || {};
    const pick = (k) => (L[k] !== undefined ? L[k] : n[k]);
    const num = (v) => (typeof v === "number" && isFinite(v) ? v : null);
    const isGroup = n.type === "group";
    return {
      i, id: String(n.id), type: n.type, raw: n,
      x: num(n.x), y: num(n.y), w: num(n.width !== undefined ? n.width : n.w), h: num(n.height !== undefined ? n.height : n.h),
      layout: isGroup && LAYOUTS.has(pick("layout")) ? pick("layout") : null,
      cols: Math.max(1, Math.floor(num(pick("cols")) || 0)) || null,
      ratios: Array.isArray(pick("ratios")) && pick("ratios").every((r) => typeof r === "number" && r > 0) ? pick("ratios") : null,
      gap: num(pick("gap")),
      span: pick("span"),
      direction: pick("direction"),
      label: typeof n.label === "string" ? n.label : null,
      title: isGroup ? (typeof L.title === "string" ? L.title : null) : null,
      kind: isGroup ? "section" : (L.kind || n.kind || (n.type === "text" ? "card" : n.type)),
      text: typeof n.text === "string" ? n.text : (typeof n.body === "string" ? n.body : ""),
      cardTitle: !isGroup ? (typeof L.title === "string" ? L.title : (typeof n.title === "string" ? n.title : null)) : null,
      eyebrow: typeof L.eyebrow === "string" ? L.eyebrow : (typeof n.eyebrow === "string" ? n.eyebrow : null),
      word: typeof L.word === "string" ? L.word : (typeof n.word === "string" ? n.word : null),
      file: typeof n.file === "string" ? n.file : null,
      url: typeof n.url === "string" ? n.url : null,
      parent: null, depth: 0, kids: [],
      // ENG-8, ENG-11: placed by Hatim's hand; never moved by layout
      pinned: L.pinned === true,
    };
  }

  const placed = (n) => n.x !== null && n.y !== null && n.w !== null && n.h !== null;
  const area = (n) => n.w * n.h;
  const inside = (g, x, y) => x >= g.x && x <= g.x + g.w && y >= g.y && y <= g.y + g.h;

  // The smallest group holding a node's centre is its parent; a group's parent must also be larger than it.
  function buildTree(nodes) {
    const groups = nodes.filter((n) => n.type === "group" && placed(n)).sort((a, b) => area(a) - area(b) || a.i - b.i);
    for (const n of nodes) {
      if (!placed(n)) continue;
      const cx = n.x + n.w / 2, cy = n.y + n.h / 2;
      for (const g of groups) {
        if (g === n) continue;
        if (n.type === "group" && (area(g) < area(n) || (area(g) === area(n) && g.i > n.i))) continue;
        if (inside(g, cx, cy)) { n.parent = g; break; }
      }
    }
    for (const n of nodes) if (n.parent) n.parent.kids.push(n);
    const depth = (n) => { let d = 0; for (let p = n.parent; p; p = p.parent) d++; return d; };
    for (const n of nodes) n.depth = depth(n);
  }

  // Reading order (BRD-27): rows of items whose vertical extents overlap, top to bottom, then from the leading side.
  function readingOrder(items, rtl) {
    const sorted = items.slice().sort((a, b) => a.y - b.y || a.i - b.i);
    const rows = [];
    for (const n of sorted) {
      const row = rows[rows.length - 1];
      if (row && n.y < row.bottom - Math.min(row.minH, n.h) * 0.3) { row.items.push(n); row.bottom = Math.max(row.bottom, n.y + n.h); row.minH = Math.min(row.minH, n.h); }
      else rows.push({ items: [n], bottom: n.y + n.h, minH: n.h });
    }
    const out = [];
    for (const r of rows) out.push(...r.items.sort((a, b) => (rtl ? (b.x + b.w) - (a.x + a.w) : a.x - b.x) || a.i - b.i));
    return out;
  }

  function measureKey(item) {
    return hashString([item.kind, item.width, item.text, item.title || "", item.eyebrow || "", item.word || "", item.file || "", item.url || ""].join("\u0001"));
  }

  function estimate(item) {
    // Used only when the caller gives no measure: about 8 px per character of Sans 15 at 1.5 line height.
    const perLine = Math.max(8, Math.floor((item.width - 28) / 8));
    const lines = (item.title ? Math.ceil(item.title.length / Math.max(6, perLine * 0.8)) + 0.4 : 0)
      + String(item.text || "").split("\n").reduce((s, l) => s + Math.max(l.trim() ? 1 : 0.4, Math.ceil(l.length / perLine)), 0);
    if (item.kind === "section-title") return { w: item.width, h: Math.ceil(item.text.length / Math.max(6, item.width / 12)) * 30 };
    return { w: item.width, h: Math.ceil(28 + lines * 23 + (item.word ? 22 : 0) + (item.eyebrow ? 18 : 0)) };
  }

  async function measureAll(items, opts, stats) {
    const out = new Map(), todo = [];
    for (const it of items) {
      const k = (opts.cacheToken || "") + ":" + measureKey(it);
      if (cache.has(k)) { out.set(it, cache.get(k)); stats.cached++; } else todo.push([it, k]);
    }
    if (todo.length) {
      let sizes;
      if (typeof opts.measureBatch === "function") sizes = await opts.measureBatch(todo.map(([it]) => it));
      else if (typeof opts.measure === "function") sizes = await Promise.all(todo.map(([it]) => opts.measure(it)));
      else sizes = todo.map(([it]) => estimate(it));
      todo.forEach(([it, k], i) => {
        const s = sizes[i] || estimate(it);
        const v = { w: Math.ceil(s.w || it.width), h: Math.ceil(s.h) };
        cache.set(k, v); out.set(it, v); stats.measured++;
      });
    }
    return out;
  }

  // ---------- ELK through a worker ----------
  function runElk(graph, opts) {
    if (opts.elk) return opts.elk.layout(graph);
    if (typeof Worker === "undefined") return Promise.reject(new Error("No ELK: layered layout needs a worker or opts.elk"));
    if (!worker) {
      const url = new URL("layout-worker.js", scriptBase || "linen-app://renderer/").href;
      worker = new Worker(url);
      worker.onmessage = (e) => {
        const p = pending.get(e.data.id);
        if (!p) return;
        pending.delete(e.data.id);
        if (e.data.error) p.reject(new Error(e.data.error)); else p.resolve(e.data.result);
      };
      worker.onerror = (e) => { for (const p of pending.values()) p.reject(new Error("layout worker: " + (e.message || "failed"))); pending.clear(); worker = null; };
    }
    const id = ++workerSeq;
    return new Promise((resolve, reject) => {
      // A worker that never answers fails the section instead of hanging the board (or `linen layout`).
      const timer = setTimeout(() => {
        if (!pending.has(id)) return;
        pending.delete(id);
        reject(new Error("the layout worker did not answer in 20 s"));
        if (worker) { worker.terminate(); worker = null; }
      }, 20000);
      pending.set(id, { resolve: (v) => { clearTimeout(timer); resolve(v); }, reject: (e) => { clearTimeout(timer); reject(e); } });
      worker.postMessage({ id, graph });
    });
  }

  // ---------- the layout ----------
  async function layout(canvas, opts = {}) {
    const t0 = now();
    const stats = { ms: 0, measured: 0, cached: 0, elkMs: 0, sections: 0 };
    const problems = [];
    const list = Array.isArray(canvas && canvas.nodes) ? canvas.nodes : [];
    const nodes = list.filter((n) => n && typeof n === "object" && n.id !== undefined && n.id !== null).map(norm);
    const byId = new Map(nodes.map((n) => [n.id, n]));
    const rtl = (opts.dir || (canvas && canvas.linen && canvas.linen.dir)) === "rtl";
    buildTree(nodes);

    const laid = nodes.filter((n) => n.layout && placed(n));
    // Shallow roots first, so a root inside a hand-placed group that a flow moves is settled after the move.
    const roots = laid.filter((g) => !g.parent || !g.parent.layout).sort((a, b) => a.depth - b.depth || a.i - b.i);
    for (const n of nodes) if (n.layout && !placed(n)) problems.push({ severity: "error", id: n.id, message: "A section with a layout needs a position and a width" });
    // A layered section keeps file order: it is the flow's order, and where its boxes sit after a layout (ends
    // stacked in one column) is not. Reading order there would make a second layout reverse the flow.
    for (const g of laid) g.kids = g.layout === "layered" ? g.kids.slice().sort((a, b) => a.i - b.i) : readingOrder(g.kids, rtl);
    const orig = new Map(nodes.map((n) => [n, { x: n.x, y: n.y, w: n.w, h: n.h }]));
    // ENG-11: a laid-out section that holds a box Hatim placed is arranged by hand: its boxes keep their places and
    // widths and are sized to their text, a box moves down only where a taller box above it now overlaps it, a pinned
    // box never moves, and the section grows to hold everything.
    for (const g of laid) g.byHand = g.kids.some((k) => k.pinned);

    // 1. Widths, top down. A flowed child takes its cell's width; a hand-placed group keeps its size.
    const pad = (g) => (g.depth === 0 || !g.parent ? METRICS.sectionPad : METRICS.groupPad);
    const gapOf = (g) => (g.gap !== null ? g.gap : (g.depth === 0 ? METRICS.gapSection : METRICS.gapGroup));
    const spanOf = (n, cols) => (n.span === "all" ? cols : Math.max(1, Math.min(cols, Math.floor(Number(n.span) || 1))));
    const cells = new Map(); // node -> {w}

    // Round 10, finding 1: a gap that lines pass along is widened by the channel pass (run): extra px per gap.
    const extraOf = (g, axis, i) => { const x = opts.extraGaps && opts.extraGaps[g.id]; return (x && x[axis] && x[axis][i]) || 0; };
    function columns(g, count) {
      const inner = g.w - 2 * pad(g);
      const ratios = g.ratios && g.ratios.length === count ? g.ratios : new Array(count).fill(1);
      const sum = ratios.reduce((a, b) => a + b, 0);
      let free = inner - gapOf(g) * (count - 1);
      for (let c = 0; c < count - 1; c++) free -= extraOf(g, "col", c);
      return ratios.map((r) => (free * r) / sum);
    }

    function widths(g) {
      const kids = g.kids;
      if (g.byHand) {
        for (const k of kids) { cells.set(k, { w: k.w, col: 0, span: 1 }); if (k.layout) widths(k); }
        return;
      }
      if (g.layout === "layered") {
        for (const k of kids) {
          const w = k.type === "group" ? (k.w || METRICS.cardDefault * 2) : Math.max(METRICS.cardMin, k.w || METRICS.cardDefault);
          cells.set(k, { w });
          if (k.layout) { k.w = w; widths(k); }
        }
        return;
      }
      const cols = g.layout === "stack" ? 1 : g.layout === "lanes" ? Math.max(1, kids.length) : Math.max(1, g.cols || 2);
      const colW = columns(g, cols);
      let c = 0;
      for (const k of kids) {
        let span = g.layout === "grid" ? spanOf(k, cols) : 1;
        if (g.layout === "grid" && c + span > cols) c = 0;
        const start = g.layout === "stack" ? 0 : c;
        let w = colW.slice(start, start + span).reduce((a, b) => a + b, 0) + gapOf(g) * (span - 1);
        for (let x = start; x < start + span - 1; x++) w += extraOf(g, "col", x);
        cells.set(k, { w, col: start, span });
        if (k.type !== "group" || k.layout) k.w = w;
        if (k.layout) widths(k);
        c = g.layout === "grid" ? (c + span) % cols : c + 1;
      }
    }
    for (const r of roots) widths(r);

    // 2. Measure every flowed card and every laid-out section's title, in one batch.
    const items = [];
    const itemOf = new Map();
    for (const g of laid) {
      if (g.title) {
        const it = { id: "#title:" + g.id, kind: "section-title", width: Math.max(40, g.w - 2 * pad(g)), text: g.title, depth: g.depth };
        items.push(it); itemOf.set("#title:" + g.id, it);
      }
      for (const k of g.kids) {
        if (k.type === "group") continue;
        const it = { id: k.id, kind: k.kind, width: Math.round(cells.get(k).w), text: k.text, title: k.cardTitle, eyebrow: k.eyebrow, word: k.word, file: k.file, url: k.url, node: k.raw };
        items.push(it); itemOf.set(k.id, it);
      }
    }
    const sizes = await measureAll(items, opts, stats);
    const sizeOf = (id) => sizes.get(itemOf.get(id));

    // 3. Heights and positions, bottom up, relative to each section's top-left; roots are then placed in place.
    const rel = new Map(); // node -> {x, y} relative to its laid-out parent
    const routes = {};
    const grids = new Map(); // grid, stack and lanes sections -> their columns and rows, relative

    async function place(g) {
      stats.sections++;
      const p = pad(g);
      const titleH = g.title ? (sizeOf("#title:" + g.id) || { h: 0 }).h : 0;
      let top = p + (titleH ? titleH + METRICS.titleGap : 0);
      const kids = g.kids;
      for (const k of kids) if (k.layout) await place(k);
      const labelOff = (k) => (k.type === "group" && k.label ? METRICS.labelBand : 0);
      const height = (k) => (k.type === "group" ? k.h : Math.max(1, (sizeOf(k.id) || { h: k.h || 60 }).h));

      if (g.byHand) {
        const og = orig.get(g), gap = gapOf(g);
        const list = kids.map((k) => { const o = orig.get(k); if (k.type !== "group") k.h = height(k); return { k, x: o.x - og.x, y: o.y - og.y }; });
        list.sort((u, v) => u.y - v.y || u.x - v.x);
        for (let i = 0; i < list.length; i++) {
          const u = list[i];
          if (u.k.pinned) continue;
          // below every box above it that it now overlaps, and below a pinned box it would land on
          for (let pass = 0, moved = true; moved && pass <= list.length; pass++) {
            moved = false;
            for (let j = 0; j < list.length; j++) {
              const v = list[j];
              if (v === u || !(j < i || v.k.pinned)) continue;
              const ox = Math.min(u.x + u.k.w, v.x + v.k.w) - Math.max(u.x, v.x);
              if (ox > 0 && u.y < v.y + v.k.h && u.y + u.k.h > v.y && (v.y <= u.y || v.k.pinned)) { u.y = v.y + v.k.h + gap; moved = true; }
            }
          }
        }
        let w = og.w, h = og.h;
        for (const u of list) { rel.set(u.k, { x: u.x, y: u.y }); w = Math.max(w, u.x + u.k.w + p); h = Math.max(h, u.y + u.k.h + p); }
        g.w = Math.ceil(w); g.h = Math.ceil(h);
        return;
      }

      if (g.layout === "layered") {
        const t = now();
        const ids = new Set(kids.map((k) => k.id));
        const directChild = (id) => { let n = byId.get(id); while (n && n.parent && n.parent !== g) n = n.parent; return n && n.parent === g ? n.id : null; };
        const edges = [];
        for (const e of (canvas.edges || [])) {
          if (!e || typeof e !== "object") continue;
          const a = directChild(String(e.fromNode)), b = directChild(String(e.toNode));
          if (a && b && a !== b && ids.has(a) && ids.has(b)) edges.push({ id: String(e.id), sources: [a], targets: [b], direct: a === String(e.fromNode) && b === String(e.toNode) });
        }
        const dir = { down: "DOWN", right: rtl ? "LEFT" : "RIGHT", up: "UP", left: "LEFT" }[g.direction] || (rtl ? "LEFT" : "RIGHT");
        const graph = {
          id: g.id,
          layoutOptions: {
            "elk.algorithm": "layered", "elk.direction": dir, "elk.edgeRouting": "ORTHOGONAL",
            "elk.spacing.nodeNode": String(METRICS.layeredNode), "elk.layered.spacing.nodeNodeBetweenLayers": String(METRICS.layeredLayer),
            "elk.spacing.edgeNode": "24", "elk.spacing.edgeEdge": "14",
            "elk.padding": `[top=${top},left=${p},bottom=${p},right=${p}]`,
            "elk.layered.nodePlacement.strategy": "NETWORK_SIMPLEX",
            "elk.layered.considerModelOrder.strategy": "NODES_AND_EDGES",
            // A flow with loops (return, retry) ranks in box order: an edge to an earlier box is the loop.
            // ELK's default greedy breaking can reverse the main path instead and scatter the flow.
            "elk.layered.cycleBreaking.strategy": "MODEL_ORDER",
          },
          children: kids.map((k) => ({ id: k.id, width: Math.round(k.type === "group" ? k.w : cells.get(k).w), height: Math.round(height(k) + labelOff(k)) })),
          edges: edges.map((e) => ({ id: e.id, sources: e.sources, targets: e.targets })),
        };
        let res;
        try { res = await runElk(graph, opts); } catch (err) {
          problems.push({ severity: "error", id: g.id, message: "Layered layout failed: " + err.message });
          return;
        }
        stats.elkMs += now() - t;
        const at = new Map((res.children || []).map((c) => [c.id, c]));
        for (const k of kids) {
          const c = at.get(k.id);
          if (!c) continue;
          rel.set(k, { x: c.x, y: c.y + labelOff(k) });
          if (k.type !== "group") { k.w = Math.round(cells.get(k).w); k.h = height(k); }
        }
        for (const e of (res.edges || [])) {
          const s = e.sections && e.sections[0];
          const src = edges.find((x) => x.id === e.id);
          if (!s || !src || !src.direct) continue;
          routes[e.id] = { section: g.id, points: [s.startPoint, ...(s.bendPoints || []), s.endPoint].map((q) => [q.x, q.y]) };
        }
        g.w = Math.max(g.w, Math.round(res.width || g.w));
        g.h = Math.ceil(res.height || g.h);
        return;
      }

      const gap = gapOf(g);
      const cols = g.layout === "stack" ? 1 : g.layout === "lanes" ? Math.max(1, kids.length) : Math.max(1, g.cols || 2);
      const colW = columns(g, cols);
      const colX = []; let acc = p;
      for (let c = 0; c < cols; c++) { colX.push(acc); acc += colW[c] + gap + extraOf(g, "col", c); }
      if (rtl) for (let c = 0; c < cols; c++) colX[c] = g.w - colX[c] - colW[c];
      let y = top;
      let row = [];
      const info = { cols: colX.map((x, c) => [x, x + colW[c]]), rows: [] };
      grids.set(g, info);
      const flush = () => {
        if (!row.length) return;
        const rowH = Math.max(...row.map((k) => labelOff(k) + height(k)));
        info.rows.push([y, y + rowH]);
        for (const k of row) {
          const cell = cells.get(k);
          let x = rtl ? colX[cell.col + cell.span - 1] : colX[cell.col];
          if (k.type === "group" && !k.layout && k.w > cell.w + 0.5) problems.push({ severity: "warning", id: k.id, message: "A hand-sized group is wider than its cell" });
          rel.set(k, { x, y: y + labelOff(k) });
          // Cards in a row share its height; lanes stretch groups too.
          if (k.type !== "group") k.h = rowH;
          else if (g.layout === "lanes" && k.layout) k.h = rowH - labelOff(k);
          if (k.type !== "group") k.w = cell.w;
        }
        y += rowH + gap + extraOf(g, "row", info.rows.length - 1);
        row = [];
      };
      let c = 0;
      for (const k of kids) {
        const cell = cells.get(k);
        if (g.layout === "stack") { row = [k]; flush(); continue; }
        if (g.layout === "grid" && cell.col < c) flush();
        if (g.layout === "grid" && cell.col === 0 && row.length) flush();
        row.push(k);
        c = cell.col + cell.span;
      }
      flush();
      g.h = Math.ceil((kids.length ? y - gap - extraOf(g, "row", info.rows.length - 1) : top) + p);
    }

    for (const r of roots) await place(r);

    // 4. Absolute positions: each root stays where it was placed by hand; contents follow their sections. A
    // hand-placed group inside a flow carries its own contents along.
    const moveSubtree = (n, dx, dy) => {
      for (const k of n.kids) {
        if (rel.has(k)) continue;
        k.x += dx; k.y += dy;
        moveSubtree(k, dx, dy);
      }
    };
    function settle(g) {
      for (const k of g.kids) {
        const r = rel.get(k);
        if (!r) continue;
        const ox = k.x, oy = k.y;
        k.x = g.x + r.x; k.y = g.y + r.y;
        if (k.type === "group" && !k.layout) moveSubtree(k, k.x - ox, k.y - oy);
        if (k.layout) settle(k);
      }
    }
    for (const r of roots) settle(r);
    for (const id of Object.keys(routes)) {
      const g = byId.get(routes[id].section);
      routes[id].points = routes[id].points.map(([x, y]) => [g.x + x, g.y + y]);
    }

    // 5. BRD-25: rows of top-level sections at least rowGap apart. Only top-level groups move, and only down.
    // Sections that started on one row (tops within ROW_TOLERANCE) move together, so a row of sections stays a row.
    const top = nodes.filter((n) => !n.parent && placed(n));
    const gapRow = opts.rowGap !== undefined ? opts.rowGap : METRICS.rowGap;
    const moved = new Set();
    if (gapRow > 0) {
      const ROW_TOLERANCE = 24;
      const secs = top.filter((n) => n.type === "group").sort((a, b) => orig.get(a).y - orig.get(b).y || a.i - b.i);
      const rows = [];
      for (const g of secs) {
        const row = rows[rows.length - 1];
        if (row && orig.get(g).y - orig.get(row[0]).y <= ROW_TOLERANCE) row.push(g); else rows.push([g]);
      }
      const free = top.filter((n) => n.type !== "group");
      const done = [];
      for (const row of rows) {
        // What sits above a row: the rows already settled, and hand-placed boxes that started above it.
        const rowTop = orig.get(row[0]).y;
        const above = done.concat(free.filter((f) => orig.get(f).y < rowTop));
        // The row's new top: the lowest any member needs; members then share it, so a moved row is level.
        let target = -Infinity;
        for (const t of row) {
          for (const s of above) {
            const overlap = Math.min(s.x + s.w, t.x + t.w) - Math.max(s.x, t.x);
            if (overlap <= 0) continue;
            target = Math.max(target, s.y + s.h + gapRow);
          }
        }
        done.push(...row);
        if (!row.some((t) => target > t.y && !t.pinned)) continue;
        target = Math.max(target, ...row.map((t) => t.y));
        for (const t of row) {
          const dy = target - t.y;
          if (dy <= 0 || t.pinned) continue; // ENG-11: a section Hatim placed stays where he put it
          t.y = target; moved.add(t.id);
          const shift = (n) => { for (const k of n.kids) { k.y += dy; shift(k); } };
          shift(t);
          for (const id of Object.keys(routes)) if (isInside(byId.get(routes[id].section), t)) routes[id].points = routes[id].points.map(([x, y]) => [x, y + dy]);
        }
      }
      for (const t of top) {
        if (t.type === "group") continue;
        for (const s of top) {
          if (s === t || s.type !== "group") continue;
          if (t.x < s.x + s.w && t.x + t.w > s.x && t.y < s.y + s.h && t.y + t.h > s.y) problems.push({ severity: "warning", id: t.id, message: `Overlaps the section "${s.label || s.id}" after layout` });
        }
      }
    }
    function isInside(n, anc) { for (let p = n; p; p = p.parent) if (p === anc) return true; return false; }

    // 6. Elbow routes for edges inside one laid-out root (grid, stack, lanes); layered routes came from ELK.
    const rootOf = (n) => { let r = null; for (let p = n; p; p = p.parent) if (p.layout) r = p; return r; };
    for (const e of (canvas.edges || [])) {
      if (!e || typeof e !== "object" || routes[e.id]) continue;
      const a = byId.get(String(e.fromNode)), b = byId.get(String(e.toNode));
      if (!a || !b || !placed(a) || !placed(b)) continue;
      const ra = rootOf(a), rb = rootOf(b);
      if (!ra || ra !== rb) continue;
      routes[e.id] = { section: ra.id, points: elbow(a, b, e.fromSide, e.toSide) };
    }

    // 7. What changed, in whole numbers.
    const positions = {};
    for (const n of nodes) {
      if (!placed(n)) continue;
      const o = orig.get(n);
      const v = { x: Math.round(n.x), y: Math.round(n.y), width: Math.round(n.w), height: Math.ceil(n.h - 1e-6) };
      if (v.x !== o.x || v.y !== o.y || v.width !== o.w || v.height !== o.h) positions[n.id] = v;
    }
    // 8. The inner gaps of grid, stack and lanes sections, in board units, for the channel pass (run).
    const gaps = [];
    const pinned = (n) => !!(n.raw && n.raw.linen && n.raw.linen.pinned === true);
    for (const [g, info] of grids) {
      const cs = info.cols, rs = info.rows;
      if (!rs.length) continue;
      // a section Hatim placed, or one holding a box he placed, keeps its gaps (ENG-11)
      if (pinned(g) || g.kids.some(pinned)) continue;
      const y0 = g.y + rs[0][0], y1 = g.y + rs[rs.length - 1][1];
      const xs = cs.flat(), x0 = g.x + Math.min(...xs), x1 = g.x + Math.max(...xs);
      const usedCols = g.layout === "lanes" ? g.kids.length : cs.length;
      for (let c = 0; c + 1 < Math.min(cs.length, usedCols); c++) {
        const a = cs[c], b = cs[c + 1];
        gaps.push({ section: g.id, axis: "col", index: c, x0: g.x + Math.min(a[1], b[1]), x1: g.x + Math.max(a[0], b[0]), y0, y1 });
      }
      for (let r = 0; r + 1 < rs.length; r++) gaps.push({ section: g.id, axis: "row", index: r, x0, x1, y0: g.y + rs[r][1], y1: g.y + rs[r + 1][0] });
    }
    stats.ms = now() - t0;
    return { positions, routes, gaps, moved: [...moved], problems, stats, metrics: METRICS };
  }

  // Obsidian's side rule (PRD 9.1 rule 3): the larger of the horizontal and vertical offsets between centres.
  function sideFor(a, b) {
    const dx = (b.x + b.w / 2) - (a.x + a.w / 2), dy = (b.y + b.h / 2) - (a.y + a.h / 2);
    if (Math.abs(dx) > Math.abs(dy)) return dx > 0 ? ["right", "left"] : ["left", "right"];
    return dy > 0 ? ["bottom", "top"] : ["top", "bottom"];
  }
  function anchor(n, side) {
    switch (side) {
      case "top": return [n.x + n.w / 2, n.y];
      case "bottom": return [n.x + n.w / 2, n.y + n.h];
      case "left": return [n.x, n.y + n.h / 2];
      default: return [n.x + n.w, n.y + n.h / 2];
    }
  }
  const OUT = { top: [0, -1], bottom: [0, 1], left: [-1, 0], right: [1, 0] };
  function elbow(a, b, fs, ts) {
    const [f0, t0] = sideFor(a, b);
    const f = OUT[fs] ? fs : f0, t = OUT[ts] ? ts : t0;
    const p = anchor(a, f), q = anchor(b, t), s = 16;
    const p1 = [p[0] + OUT[f][0] * s, p[1] + OUT[f][1] * s], q1 = [q[0] + OUT[t][0] * s, q[1] + OUT[t][1] * s];
    const pts = [p, p1];
    const horizontalFirst = OUT[f][0] !== 0;
    if (horizontalFirst) { const mx = (p1[0] + q1[0]) / 2; pts.push([mx, p1[1]], [mx, q1[1]]); }
    else { const my = (p1[1] + q1[1]) / 2; pts.push([p1[0], my], [q1[0], my]); }
    pts.push(q1, q);
    return pts.map(([x, y]) => [Math.round(x), Math.round(y)]);
  }

  // ---------- measuring in the page ----------
  // With the renderer's own card (LinenBoard.measureCards / measureCard, Lane B) what is measured is what is drawn.
  // Until then, and for section titles, an offscreen element with the same metrics (PRD-2 section 8: padding 14,
  // title Serif Display Light 19, body Sans 15, the status pill on top).
  let host = null, boardCss = null, measuredWith = new Set();
  const escHTML = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  function mdHTML(src) {
    let html = null;
    try { if (root.marked) html = root.marked.parse(String(src || "")); } catch (_) { html = null; }
    if (html !== null && root.DOMPurify) return root.DOMPurify.sanitize(html);
    return html !== null ? html : `<p>${escHTML(src || "")}</p>`;
  }
  // When board.css is in the page, a card is built the way the board view builds it (board.js readContent), with
  // its classes, so the measure is the drawn size; the model node gives title, body, eyebrow and word.
  function boardElement(item, model, words) {
    const n = model || {};
    const kind = n.kind || item.kind || "card";
    const w = (n.word || item.word) ? words.find((x) => x.word === (n.word || item.word)) : null;
    const pill = w && !w.quiet ? `<span class="st s-${w.shape}">${escHTML(w.word)}</span>` : "";
    const title = n.title !== undefined ? n.title : item.title;
    const body = n.body !== undefined ? n.body : item.text;
    const eb = (n.eyebrow || item.eyebrow) ? `<div class="b-eb">${escHTML(n.eyebrow || item.eyebrow)}</div>` : "";
    let inner;
    if (kind === "sticky") inner = `<div class="b-body">${mdHTML(body || "")}</div>`;
    else if (kind === "text") inner = `<div class="b-body">${mdHTML(title ? `# ${title}\n\n${body || ""}` : body || "")}</div>`;
    else inner = `${pill}${eb}${title ? `<h4${pill || eb ? "" : ' class="q"'}>${escHTML(title)}</h4>` : ""}${body ? `<div class="b-body">${mdHTML(body)}</div>` : ""}`;
    const el = document.createElement("div");
    el.className = `b-node k-${kind} lv-read` + (w ? ` s-${w.shape}` : "");
    el.style.cssText = `position:absolute;left:0;top:0;width:${item.width}px;height:auto;font:400 15px/1.45 "Linen Sans", -apple-system, sans-serif`;
    el.innerHTML = inner;
    return el;
  }
  function hasBoardCss() {
    if (boardCss !== null) return boardCss;
    const probe = document.createElement("div");
    probe.className = "b-node";
    probe.style.cssText = "position:absolute;visibility:hidden";
    document.body.append(probe);
    boardCss = getComputedStyle(probe).paddingTop === "12px";
    probe.remove();
    return boardCss;
  }
  function fallbackElement(item, quiet) {
    const el = document.createElement("div");
    el.style.cssText = `position:absolute;left:0;top:0;box-sizing:border-box;width:${item.width}px;`;
    if (item.kind === "section-title") {
      el.style.font = '300 24px/1.2 "Linen Serif Display", Georgia, serif';
      el.style.overflowWrap = "break-word";
      el.textContent = item.text;
      return el;
    }
    let title = item.title, body = String(item.text || "");
    if (!title) {
      const m = /^(#{1,3})[ \t]+(.+)\n?/.exec(body);
      if (m && item.kind !== "text") { title = m[2].trim(); body = body.slice(m[0].length); }
    }
    const big = item.kind === "text";
    el.style.padding = big ? "0" : "14px";
    el.style.font = (item.kind === "sticky" ? "400" : "400") + ' 15px/1.5 "Linen Sans", -apple-system, sans-serif';
    el.style.overflowWrap = "break-word";
    if (item.word && !quiet.has(item.word) && !big) {
      const pill = document.createElement("div");
      pill.style.cssText = 'display:inline-block;font:500 10px/1 "Linen Sans",sans-serif;letter-spacing:.12em;text-transform:uppercase;padding:4px 6px 3px;border:1px solid;margin:0 0 8px';
      pill.textContent = item.word;
      el.append(pill);
    }
    if (item.eyebrow) {
      const eb = document.createElement("div");
      eb.style.cssText = 'font:500 11px/1.3 "Linen Sans",sans-serif;letter-spacing:.14em;text-transform:uppercase;margin:0 0 6px';
      eb.textContent = item.eyebrow;
      el.append(eb);
    }
    if (title) {
      const h = document.createElement("div");
      h.style.cssText = 'font:300 19px/1.25 "Linen Serif Display", Georgia, serif;margin:0 0 6px';
      h.textContent = title;
      el.append(h);
    }
    const b = document.createElement("div");
    let html = null;
    try { if (root.marked) html = root.marked.parse(body); } catch (_) { html = null; }
    if (html !== null && root.DOMPurify) html = root.DOMPurify.sanitize(html);
    if (html !== null) b.innerHTML = html; else b.textContent = body;
    if (big) { const m = /^(#+)\s/.exec(String(item.text || "")); b.style.font = m && m[1].length === 1 ? '300 40px/1.15 "Linen Serif Display", Georgia, serif' : '300 24px/1.2 "Linen Serif Display", Georgia, serif'; }
    for (const c of b.querySelectorAll("p, ul, ol, pre, blockquote, table, h1, h2, h3, h4")) c.style.margin = "0 0 8px";
    // Headings take the card's (or the title text's) own face and size, not the browser's 2em.
    for (const c of b.querySelectorAll("h1, h2, h3, h4, h5, h6")) c.style.font = "inherit";
    for (const c of b.querySelectorAll("ul, ol")) c.style.paddingInlineStart = "20px";
    for (const c of b.querySelectorAll("pre, code")) c.style.font = '400 12.5px/1.45 "SF Mono", ui-monospace, Menlo, monospace';
    for (const c of b.querySelectorAll("pre")) c.style.whiteSpace = "pre-wrap";
    const last = b.lastElementChild; if (last) last.style.marginBottom = "0";
    el.append(b);
    return el;
  }
  function domMeasurer(quiet, modelById, words) {
    const board = root.LinenBoard;
    return async (items) => {
      const out = new Array(items.length);
      const fallback = [];
      for (let i = 0; i < items.length; i++) {
        const it = items[i];
        const model = modelById.get(it.id) || it.node;
        // The board's own words go with every measure: a fresh page has no board loaded, and a card measured without
        // its status pill comes out short (found by an agent's evaluation run, 2026-10-15).
        if (it.kind !== "section-title" && board && typeof board.measureCard === "function" && typeof board.measureCards !== "function") {
          try { out[i] = await board.measureCard(model, it.width, { words }); measuredWith.add("LinenBoard.measureCard"); continue; } catch (_) { /* falls back below */ }
        }
        fallback.push(i);
      }
      if (board && typeof board.measureCards === "function") {
        const cardIdx = fallback.filter((i) => items[i].kind !== "section-title");
        try {
          const got = await board.measureCards(cardIdx.map((i) => ({ node: modelById.get(items[i].id) || items[i].node, width: items[i].width })), { words });
          cardIdx.forEach((i, j) => { out[i] = got[j]; });
          if (cardIdx.length) measuredWith.add("LinenBoard.measureCards");
        } catch (_) { /* falls back below */ }
      }
      const rest = fallback.filter((i) => !out[i]);
      if (rest.length) {
        if (!host) {
          host = document.createElement("div");
          host.setAttribute("aria-hidden", "true");
          host.style.cssText = "position:absolute;left:-100000px;top:0;width:0;height:0;overflow:hidden;visibility:hidden;contain:strict";
          document.body.append(host);
        }
        const css = hasBoardCss();
        const els = rest.map((i) => (css && items[i].kind !== "section-title"
          ? boardElement(items[i], modelById.get(items[i].id), words)
          : fallbackElement(items[i], quiet)));
        for (const i of rest) measuredWith.add(items[i].kind === "section-title" ? "title element" : css ? "board.css card" : "fallback card");
        host.replaceChildren(...els);
        // A face the cards use for the first time (bold, say) starts loading at this layout; measuring before it
        // arrives would size cards in the fallback face, so wait for every face the layout asked for.
        host.getBoundingClientRect();
        if (document.fonts && document.fonts.status !== "loaded") await document.fonts.ready;
        rest.forEach((i, j) => { out[i] = { w: items[i].width, h: Math.ceil(els[j].getBoundingClientRect().height) }; });
        host.replaceChildren();
      }
      return out;
    };
  }

  /** The `linen layout` entry point (CLI-3): lays out a board file's text and returns the new text.
      Resolves { text, changed, normalised, ms, overflow, problems, moved, message, stats }; rejects when the file
      cannot be read as a board. */
  async function run(text, opts = {}) {
    const t0 = now();
    measuredWith = new Set();
    const modelById = new Map();
    let boardWords = null;
    if (root.LinenCanvas && typeof root.LinenCanvas.parse === "function") {
      const board = root.LinenCanvas.parse(text, { sidecarText: opts.sidecarText || null });
      if (board.fatal) {
        const first = board.fatal.problems && board.fatal.problems[0];
        throw new Error(first ? `${first.path}: ${first.message}` : "Not a board");
      }
      for (const n of board.nodes || []) modelById.set(String(n.id), n);
      boardWords = board.words || null;
    }
    const canvas = JSON.parse(text);
    const words = (canvas.linen && Array.isArray(canvas.linen.words)) ? canvas.linen.words : null;
    const quiet = new Set(words ? words.filter((w) => w && w.quiet).map((w) => w.word) : ["Works"]);
    const wordList = boardWords || (words || []).filter((w) => w && typeof w.word === "string");
    const measureBatch = opts.measureBatch || (typeof document !== "undefined" ? domMeasurer(quiet, modelById, wordList) : null);
    if (!opts.measureBatch && typeof document !== "undefined" && document.fonts) {
      // The faces cards are set in, loaded before anything is measured (a no-op once they are).
      await Promise.all(['400 15px "Linen Sans"', '500 15px "Linen Sans"', '700 15px "Linen Sans"', '300 19px "Linen Serif Display"']
        .map((f) => document.fonts.load(f).catch(() => null)));
    }
    const lopts = { measureBatch, cacheToken: opts.cacheToken || "page", rowGap: opts.rowGap, elk: opts.elk };
    let res = await layout(canvas, lopts);
    if (!root.LinenCanvasWriter) throw new Error("canvas-writer.js is not loaded");
    let written = root.LinenCanvasWriter.write(text, res.positions);
    // Round 10, finding 1, and gate 4.0 (room for lines): where k routed lines run along an inner gap of a laid-out
    // section, the gap becomes max(16, 12 + 8k) wide, by one more layout. Only lines the router draws count (boards that
    // set a route), so older boards lay out as before. A wider gap can draw more lines into it, so the lines are
    // measured again on the new layout and a gap that now needs more grows again (a gap never shrinks), until none
    // does, at most three times: the result depends only on the file, so running it again changes nothing.
    if (opts.channels !== false) {
      let acc = null, passes = 0;
      for (let pass = 0; pass < (opts.channelPasses || 3); pass++) {
        const extra = channelDemand(written.text, res.gaps, opts.sidecarText, acc);
        if (!extra) break;
        acc = extra.gaps; passes++;
        res = await layout(JSON.parse(text), Object.assign({}, lopts, { extraGaps: acc }));
        written = root.LinenCanvasWriter.write(text, res.positions);
      }
      if (passes) {
        // gaps widened (each once, however many passes it took)
        res.stats.widened = Object.values(acc).reduce((n, g) => n + g.col.filter(Boolean).length + g.row.filter(Boolean).length, 0);
        res.stats.channelPasses = passes;
      }
    }

    // Every text node, laid out or hand-placed, measured at its final width against its final height.
    const after = JSON.parse(written.text);
    const items = [];
    for (const n of after.nodes || []) {
      if (!n || n.type !== "text" || typeof n.width !== "number" || typeof n.height !== "number") continue;
      const v = norm(n, 0);
      items.push({ id: v.id, kind: v.kind, width: Math.round(v.w), text: v.text, title: v.cardTitle, eyebrow: v.eyebrow, word: v.word, node: n, height: v.h });
    }
    const sizes = measureBatch ? await measureAll(items, { measureBatch, cacheToken: opts.cacheToken || "page" }, { measured: 0, cached: 0 }) : new Map();
    const overflow = items.filter((it) => sizes.has(it) && sizes.get(it).h > it.height + 1).map((it) => it.id);
    return {
      text: written.text, changed: written.changed, normalised: written.normalised, message: written.message,
      ms: Math.round(res.stats.ms), totalMs: Math.round(now() - t0), overflow, problems: res.problems, moved: res.moved, stats: res.stats,
      measuredWith: [...measuredWith],
    };
  }

  /** The extra width each inner gap needs for the routed lines that run along it, or null when none does. */
  function channelDemand(text, gaps, sidecarText, prev) {
    const R = root.LinenRouter, C = root.LinenCanvas;
    if (!R || !C || !gaps || !gaps.length) return null;
    let board;
    try { board = C.parse(text, { sidecarText: sidecarText || null }); } catch (_) { return null; }
    if (!board || board.fatal) return null;
    const input = R.fromBoard(board);
    if (!input.edges.length) return null;
    const { routes } = R.route(input);
    const out = {};
    let count = 0;
    for (const gp of gaps) {
      const col = gp.axis === "col", width = col ? gp.x1 - gp.x0 : gp.y1 - gp.y0;
      const lines = new Set();
      for (const [id, r] of routes) {
        for (let i = 1; i < r.pts.length; i++) {
          const a = r.pts[i - 1], b = r.pts[i];
          if (col ? a[0] !== b[0] : a[1] !== b[1]) continue;
          const c = col ? a[0] : a[1], lo = Math.min(col ? a[1] : a[0], col ? b[1] : b[0]), hi = Math.max(col ? a[1] : a[0], col ? b[1] : b[0]);
          const g0 = col ? gp.x0 : gp.y0, g1 = col ? gp.x1 : gp.y1, e0 = col ? gp.y0 : gp.x0, e1 = col ? gp.y1 : gp.x1;
          if (c > g0 && c < g1 && Math.min(hi, e1) - Math.max(lo, e0) > 8) { lines.add(id); break; }
        }
      }
      if (!lines.size) continue;
      // a line crossing a section that holds neither of its ends counts three times, so it passes 18 px clear of the
      // cards there (ENG-1's 16 px) rather than 10 (E1 polish, with the title-strip cost in router.js)
      const inSec = (id) => { for (let n = board.byId.get(id); n; n = n.parent ? board.byId.get(n.parent) : null) if (n.parent === gp.section) return true; return false; };
      let k = 0;
      for (const id of lines) { const e = board.edgesById.get(id); k += e && !inSec(e.from) && !inSec(e.to) ? 3 : 1; }
      // the gap's width before any widening, and what it has been given so far (a gap only ever grows)
      const had = (prev && prev[gp.section] && prev[gp.section][gp.axis] && prev[gp.section][gp.axis][gp.index]) || 0;
      const add = Math.max(0, Math.max(16, 12 + 8 * k) - (width - had));
      if (add < had + 1) continue;
      const g = (out[gp.section] = out[gp.section] || { col: [], row: [] });
      g[gp.axis][gp.index] = Math.ceil(add);
      count++;
    }
    if (!count) return null;
    // the earlier passes' widths stay
    if (prev) for (const sec of Object.keys(prev)) for (const axis of ["col", "row"]) (prev[sec][axis] || []).forEach((v, i) => {
      const g = (out[sec] = out[sec] || { col: [], row: [] });
      if (v && !(g[axis][i] > v)) g[axis][i] = v;
    });
    return { gaps: out, count };
  }

  const api = { layout, run, channelDemand, sideFor, elbow, METRICS, LAYOUTS: [...LAYOUTS], clearCache: () => cache.clear(), hashString };
  root.LinenLayout = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof self !== "undefined" ? self : typeof globalThis !== "undefined" ? globalThis : this);
