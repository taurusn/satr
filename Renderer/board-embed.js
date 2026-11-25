/* Boards in notes (PRD-2 BRD-19, BLK-8; gate 4E). A board, or one of its sections, drawn as one SVG string from the
   same model (board-model.js) and router (router.js) as the board view: section washes and names, cards with their
   status shapes and words, routed lines with heads and label chips. Static: a note can hold several, print and PDF
   draw them, and live pan and zoom only move the view box (page.js). Text is escaped; nothing from the file becomes
   markup. A plain script: self.LinenBoardEmbed in the page, module.exports in node. */
(function (root) {
  "use strict";

  const esc = (s) => String(s == null ? "" : s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
  const MAX_BYTES = 2 * 1024 * 1024, MAX_INLINE = 64 * 1024, PAD = 28;
  const NORMAL = { top: [0, -1], bottom: [0, 1], left: [-1, 0], right: [1, 0] };
  const num = (v) => Math.round(v * 10) / 10;

  function sidePt(n, side, t) {
    const k = t == null ? 0.5 : t;
    switch (side) {
      case "top": return [n.x + n.w * k, n.y];
      case "bottom": return [n.x + n.w * k, n.y + n.h];
      case "left": return [n.x, n.y + n.h * k];
      default: return [n.x + n.w, n.y + n.h * k];
    }
  }
  /** A section by its id or its name (case and spaces ignored), or null. */
  function findSection(board, want) {
    const w = String(want || "").trim().toLowerCase();
    if (!w) return null;
    return board.nodes.find((n) => n.kind === "section" && (String(n.id).toLowerCase() === w || String(n.label || "").trim().toLowerCase() === w)) || null;
  }
  /** Splits an embed target `name.canvas#Section` into the file and the section. */
  function splitTarget(target) {
    const s = String(target || "");
    const i = s.indexOf("#");
    return i < 0 ? { file: s.trim(), section: null } : { file: s.slice(0, i).trim(), section: s.slice(i + 1).trim() || null };
  }

  /** text: the board file; opts: { section, sidecar, inline }. Returns { svg, w, h, title, boxes } or { error }. */
  function render(text, opts) {
    opts = opts || {};
    const C = root.LinenCanvas, R = root.LinenRouter;
    if (!C) return { error: "The board model is not loaded" };
    if (typeof text !== "string") return { error: "No board" };
    if (text.length > (opts.inline ? MAX_INLINE : MAX_BYTES)) return { error: opts.inline ? "This inline board is over 64 KB; save it as a .canvas file and embed it" : "This board is over 2 MB" };
    let board;
    try { board = C.parse(text, { sidecarText: opts.sidecar || null }); } catch (e) { return { error: "Not a board: " + (e && e.message || e) }; }
    if (board.fatal) { const p = (board.fatal.problems || [])[0]; return { error: p ? `${p.path ? p.path + ": " : ""}${p.message}` : "Not a board" }; }
    let keep = null, sec = null;
    if (opts.section) {
      sec = findSection(board, opts.section);
      if (!sec) return { error: `No section called “${opts.section}” on this board` };
      keep = new Set([sec.id]);
      let grew = true;
      while (grew) { grew = false; for (const n of board.nodes) if (n.parent && keep.has(n.parent) && !keep.has(n.id)) { keep.add(n.id); grew = true; } }
    }
    const nodes = board.nodes.filter((n) => n.placed && n.kind !== "unknown" && (!keep || keep.has(n.id)));
    if (!nodes.length) return { error: "This board has no boxes to show" };
    const ids = new Set(nodes.map((n) => n.id));
    const edges = board.edges.filter((e) => !e.missing && ids.has(e.from) && ids.has(e.to));

    // bounds, with room for section names above their sections
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    for (const n of nodes) {
      const top = n.kind === "section" && n.label ? n.y - 34 : n.y;
      x0 = Math.min(x0, n.x); y0 = Math.min(y0, top); x1 = Math.max(x1, n.x + n.w); y1 = Math.max(y1, n.y + n.h);
    }

    // lines: routed where the board routes (ENG-2), else today's curves
    const routes = new Map();
    const routed = board.routeGiven || edges.some((e) => e.routeGiven);
    if (R && routed && edges.length) {
      const sub = Object.assign({}, board, { nodes, edges });
      try { for (const [id, rt] of R.route(R.fromBoard(sub), { labelWidth: (t) => String(t).length * 6.6 + 20 }).routes) routes.set(id, rt); } catch (_) { /* curves below */ }
    }
    const words = new Map((board.words || []).map((w) => [w.word, w]));
    const parts = { wash: [], names: [], lines: [], heads: [], chips: [], cards: [] };
    for (const n of nodes) {
      if (n.kind === "section") {
        parts.wash.push(`<rect class="bs" data-id="${esc(n.id)}" x="${num(n.x)}" y="${num(n.y)}" width="${num(n.w)}" height="${num(n.h)}" rx="2"/>`);
        if (n.label) {
          const rtl = board.dir === "rtl";
          parts.names.push(`<text class="bn${n.depth > 0 ? " nested" : ""}" x="${num(rtl ? n.x + n.w : n.x)}" y="${num(n.y - 9)}" text-anchor="${rtl ? "end" : "start"}">${esc(n.label)}</text>`);
        }
        continue;
      }
      const w = n.word ? words.get(n.word) : null, shape = w ? w.shape : "outline";
      const title = n.title || (n.kind === "text" ? "" : n.label || n.file || n.url || "");
      const body = n.body != null ? n.body : n.text || "";
      const plainBody = String(body).replace(/^#+\s.*$/m, "").replace(/[*_`>#]/g, "").trim();
      const tip = [title || plainBody.split("\n")[0], w ? w.word : ""].filter(Boolean).join(" · ");
      const dir = n.dir || board.dir || "ltr";
      parts.cards.push(`<g class="bc ${esc(shape)}" data-id="${esc(n.id)}"><title>${esc(tip)}</title>` +
        `<rect x="${num(n.x)}" y="${num(n.y)}" width="${num(n.w)}" height="${num(n.h)}" rx="2"/>` +
        (shape === "threads" ? `<rect class="thr" x="${num(n.x + 1)}" y="${num(n.y + n.h - 12)}" width="${num(n.w - 2)}" height="11"/>` : "") +
        `<foreignObject x="${num(n.x)}" y="${num(n.y)}" width="${num(n.w)}" height="${num(n.h - (shape === "threads" ? 12 : 0))}">` +
        `<div xmlns="http://www.w3.org/1999/xhtml" class="bct" dir="${esc(dir)}">` +
        (w && !w.quiet ? `<span class="bw">${esc(w.word)}</span>` : "") +
        (title ? `<b>${esc(title)}</b>` : "") + (plainBody ? `<p>${esc(plainBody)}</p>` : "") + `</div></foreignObject></g>`);
    }
    const head = (p, into, cls) => {
      const len = Math.hypot(into[0], into[1]) || 1, ux = into[0] / len, uy = into[1] / len;
      const tx = p[0] - ux, ty = p[1] - uy;
      const at = (b, s) => `${num(tx - ux * b - uy * s)},${num(ty - uy * b + ux * s)}`;
      return `<polygon class="bh ${cls}" points="${num(tx)},${num(ty)} ${at(10, 4.6)} ${at(8.2, 0)} ${at(10, -4.6)}"/>`;
    };
    for (const e of edges) {
      const a = board.byId.get(e.from), b = board.byId.get(e.to);
      if (!a || !b || a === b) continue;
      // e.line can also be the edge's place in the file (an array); only a pattern name is a class
      const cls = `bl ${esc(e.kind || "works")}${typeof e.line === "string" ? " " + esc(e.line) : ""}${typeof e.weight === "string" ? " " + esc(e.weight) : ""}`;
      let d, p1, p2, end1, end2, mid;
      const rt = routes.get(e.id);
      if (rt && rt.pts && rt.pts.length >= 2) {
        const pts = R.smooth(rt.pts, e.route === "curved" ? 48 : rt.how === "straight" ? 0 : 8);
        d = "M" + pts.map((q) => `${num(q[0])} ${num(q[1])}`).join("L");
        const n = pts.length;
        p1 = pts[0]; p2 = pts[n - 1];
        end1 = [p1[0] - pts[1][0], p1[1] - pts[1][1]]; end2 = [p2[0] - pts[n - 2][0], p2[1] - pts[n - 2][1]];
        mid = rt.label ? [rt.label.x, rt.label.y] : pts[Math.floor(n / 2)];
      } else {
        p1 = sidePt(a, e.fromSide, e.fromSideGiven ? e.fromAt : null); p2 = sidePt(b, e.toSide, e.toSideGiven ? e.toAt : null);
        const n1 = NORMAL[e.fromSide] || [1, 0], n2 = NORMAL[e.toSide] || [-1, 0];
        const k = Math.max(24, Math.min(260, Math.hypot(p2[0] - p1[0], p2[1] - p1[1]) * 0.42));
        const c1 = [p1[0] + n1[0] * k, p1[1] + n1[1] * k], c2 = [p2[0] + n2[0] * k, p2[1] + n2[1] * k];
        d = `M${num(p1[0])} ${num(p1[1])}C${num(c1[0])} ${num(c1[1])} ${num(c2[0])} ${num(c2[1])} ${num(p2[0])} ${num(p2[1])}`;
        end1 = [-n1[0], -n1[1]]; end2 = [-n2[0], -n2[1]];
        mid = [0.125 * p1[0] + 0.375 * c1[0] + 0.375 * c2[0] + 0.125 * p2[0], 0.125 * p1[1] + 0.375 * c1[1] + 0.375 * c2[1] + 0.125 * p2[1]];
      }
      parts.lines.push(`<path class="${cls}" data-from="${esc(e.from)}" data-to="${esc(e.to)}" d="${d}"/>`);
      if (e.toEnd !== "none" && (e.headTo || "arrow") !== "none") parts.heads.push(head(p2, end2, esc(e.kind || "works")));
      if (e.fromEnd === "arrow" || (e.headFrom && e.headFrom !== "none")) parts.heads.push(head(p1, end1, esc(e.kind || "works")));
      if (e.label) {
        const w = String(e.label).length * 6.6 + 18;
        parts.chips.push(`<g class="bk"><rect x="${num(mid[0] - w / 2)}" y="${num(mid[1] - 11)}" width="${num(w)}" height="22" rx="2"/><text x="${num(mid[0])}" y="${num(mid[1] + 4.5)}" text-anchor="middle">${esc(e.label)}</text></g>`);
      }
      x0 = Math.min(x0, p1[0], p2[0]); x1 = Math.max(x1, p1[0], p2[0]);
      if (rt) for (const q of rt.pts) { x0 = Math.min(x0, q[0]); y0 = Math.min(y0, q[1]); x1 = Math.max(x1, q[0]); y1 = Math.max(y1, q[1]); }
    }
    x0 -= PAD; y0 -= PAD; x1 += PAD; y1 += PAD;
    const w = Math.max(1, x1 - x0), h = Math.max(1, y1 - y0);
    const title = sec ? sec.label || sec.id : board.title || null;
    const svg = `<svg class="bsvg" xmlns="http://www.w3.org/2000/svg" viewBox="${num(x0)} ${num(y0)} ${num(w)} ${num(h)}" preserveAspectRatio="xMidYMid meet" role="img" aria-label="${esc(title || "Board")}">` +
      `<defs><pattern id="bthr" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><line x1="0" y1="0" x2="0" y2="6" class="thl"/></pattern></defs>` +
      parts.wash.join("") + parts.names.join("") + parts.lines.join("") + parts.heads.join("") + parts.chips.join("") + parts.cards.join("") + `</svg>`;
    return { svg, w, h, view: [x0, y0, w, h], title, boxes: new Map(nodes.filter((n) => n.kind !== "section").map((n) => [n.id, n.title || n.label || n.id])) };
  }

  /** The height a frame takes in a column of the given width: the board's shape, at most 600 px. */
  function frameHeight(w, h, column) { return Math.round(Math.min(600, Math.max(120, column * h / w))); }

  /** `touches: [a, b]` in a table cell: the ids, or null. */
  function touchesOf(cellText) {
    const m = /^\s*touches\s*:\s*\[([^\]]*)\]\s*$/i.exec(String(cellText || ""));
    if (!m) return null;
    return m[1].split(",").map((s) => s.trim().replace(/^["']|["']$/g, "")).filter(Boolean);
  }

  /** Problems with a note's boards, for `linen check`: inline boards that are not valid, `touches:` ids not on the
      board above. Embedded files are checked by the app or the CLI, which may read them. */
  function check(noteText) {
    const out = [];
    const lines = String(noteText || "").split("\n");
    let fence = null, fenceLang = "", start = 0, buf = [], lastBoard = null;
    for (let i = 0; i < lines.length; i++) {
      const l = lines[i];
      const m = /^\s*(```+|~~~+)\s*([A-Za-z0-9_-]*)/.exec(l);
      if (fence) {
        if (m && l.trim().startsWith(fence)) {
          if (fenceLang === "board") {
            const r = render(buf.join("\n"), { inline: true });
            if (r.error) out.push({ severity: "error", line: start + 1, message: "Inline board: " + r.error });
            else lastBoard = r;
          }
          fence = null; buf = [];
        } else buf.push(l);
        continue;
      }
      if (m) { fence = m[1].slice(0, 3); fenceLang = m[2].toLowerCase(); start = i; buf = []; continue; }
      if (/^\s*\|/.test(l)) {
        for (const cell of l.split("|")) {
          const ids = touchesOf(cell);
          if (!ids || !lastBoard) continue;
          const miss = ids.filter((id) => !lastBoard.boxes.has(id));
          if (miss.length) out.push({ severity: "warning", line: i + 1, message: `touches: no box called ${miss.join(", ")} on the board above` });
        }
      }
    }
    return out;
  }

  const api = { render, frameHeight, findSection, splitTarget, touchesOf, check, MAX_BYTES, MAX_INLINE };
  root.LinenBoardEmbed = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof self !== "undefined" ? self : typeof globalThis !== "undefined" ? globalThis : this);
