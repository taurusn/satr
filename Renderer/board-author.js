/* Linen's board author (PRD-2 MCP rows): what lets an agent make a good board without placing a single box by hand.
   - compose(spec): sections of boxes, edges and words in, a valid JSON Canvas board (with linen fields) and its notes
     sidecar out. Ids are kept as given, so references and change marks follow them.
   - edit(canvas, notes, ops): changes a board by box id (set, add, remove, move, connect, disconnect, add_section,
     remove_section, set_board), so Hatim's change marks show exactly what the agent changed.
   - reflow(canvas): after layout has sized every section, places composed boards' sections in rows again, far enough
     apart (BRD-25) that section names stay legible zoomed out. Only boards made by compose carry linen.rows; hand-placed
     boards are never moved.
   Pure: no DOM, runs in the page, in node and in JavaScriptCore. Serialising is LinenCanvasWriter's job. */
(function (root) {
  "use strict";

  const CARD_W = 280, GAP = 20, PAD = 20, HEAD = 40, ROW_GAP = 180, COL_GAP = 60;
  const KINDS = new Set(["card", "sticky", "shape", "text", "file", "link"]);
  const EDGE_KINDS = new Set(["works", "main", "code", "plan", "fail"]);
  const SHAPES = new Set(["rect", "rounded", "ellipse", "diamond", "pill", "cylinder", "hexagon"]);

  /** More Arabic letters than Latin ones across the given strings. */
  function arabicMajority(texts) {
    let ar = 0, lat = 0;
    for (const t of texts) for (const ch of String(t || "")) {
      if (/[؀-ۿݐ-ݿﭐ-﷿ﹰ-﻿]/.test(ch)) ar++;
      else if (/[A-Za-z]/.test(ch)) lat++;
    }
    return ar > lat;
  }

  const DEFAULT_WORDS = ["Works", "Partial", "Broken", "Missing", "Planned"];

  const slug = (s) => String(s || "").toLowerCase().normalize("NFKD").replace(/[^\p{L}\p{N}]+/gu, "-").replace(/^-+|-+$/g, "").slice(0, 40) || "box";
  const str = (v) => (typeof v === "string" ? v : v == null ? "" : String(v));

  /** A rough height before measuring: layout replaces it with the real one. */
  function guessHeight(title, body, width) {
    const perLine = Math.max(18, Math.floor((width - 28) / 8));
    const lines = (title ? Math.ceil(title.length / (perLine * 0.8)) * 1.4 : 0) + (body ? str(body).split("\n").reduce((n, l) => n + Math.max(1, Math.ceil(l.length / perLine)), 0) : 0);
    return Math.max(80, Math.round(28 + lines * 22 + (body ? 8 : 0)));
  }

  function noteOf(n) {
    if (!n) return null;
    if (typeof n === "string") return { body: n };
    if (typeof n !== "object") return null;
    const out = {};
    for (const k of ["area", "title", "body", "state"]) if (n[k] != null) out[k] = str(n[k]);
    if (Array.isArray(n.refs)) out.refs = n.refs.map(str);
    if (n.fields && typeof n.fields === "object") out.fields = n.fields;
    return out;
  }

  /** A box's fields, typed: anything else is an error, never coerced into the file (Codex verification 2). */
  function checkCard(c, problems, where) {
    const bad = (f, want) => problems.push({ severity: "error", path: `${where}.${f}`, message: `${f} must be ${want}` });
    if (!c || typeof c !== "object" || Array.isArray(c)) { problems.push({ severity: "error", path: where, message: "A box is an object such as {id, title, body, word}" }); return; }
    for (const f of ["id", "title", "body", "word", "file", "url", "eyebrow"]) if (c[f] !== undefined && c[f] !== null && typeof c[f] !== "string") bad(f, "text");
    if (c.color !== undefined && c.color !== null && !(typeof c.color === "string" && /^([1-6]|#[0-9a-fA-F]{6})$/.test(c.color))) bad("color", "\"1\" to \"6\" or #RRGGBB");
    if (c.kind !== undefined && !KINDS.has(c.kind)) bad("kind", [...KINDS].join(", "));
    if (c.shape !== undefined && !SHAPES.has(c.shape)) bad("shape", [...SHAPES].join(", "));
    if (c.note !== undefined && c.note !== null && typeof c.note !== "string") {
      if (typeof c.note !== "object" || Array.isArray(c.note)) bad("note", "{title, body, refs} or text");
      else {
        for (const f of ["area", "title", "body", "state"]) if (c.note[f] !== undefined && typeof c.note[f] !== "string") bad(`note.${f}`, "text");
        if (c.note.refs !== undefined && !(Array.isArray(c.note.refs) && c.note.refs.every((r) => typeof r === "string"))) bad("note.refs", "a list of path:line texts");
      }
    }
  }

  /** One box from an agent's description to a JSON Canvas node (without position). */
  function nodeOf(c, problems, where) {
    checkCard(c, problems, where);
    const kind = KINDS.has(c.kind) ? c.kind : c.file ? "file" : c.url ? "link" : "card";
    const id = str(c.id) || slug(c.title || c.body || c.file || c.url);
    const node = { id };
    const linen = {};
    if (kind === "file") {
      if (!c.file) problems.push({ severity: "error", path: where, message: "A file box needs file: a path relative to the board (a .md, .canvas, .html or image)" });
      node.type = "file"; node.file = str(c.file);
    } else if (kind === "link") {
      if (!c.url) problems.push({ severity: "error", path: where, message: "A link box needs url" });
      node.type = "link"; node.url = str(c.url);
    } else {
      node.type = "text";
      const title = str(c.title).trim(), body = str(c.body).trim();
      if (kind === "card") node.text = title ? `# ${title}${body ? "\n" + body : ""}` : body;
      else node.text = title && body ? `${title}\n${body}` : title || body;
      if (kind !== "card") linen.kind = kind;
      if (kind === "shape") linen.shape = SHAPES.has(c.shape) ? c.shape : "rounded";
      if (!node.text) problems.push({ severity: "warning", path: where, message: "This box has no title or body" });
    }
    if (c.color != null) node.color = str(c.color);
    if (c.word) linen.word = str(c.word);
    if (c.eyebrow) linen.eyebrow = str(c.eyebrow);
    const note = noteOf(c.note);
    if (Object.keys(linen).length) node.linen = linen;
    return { node, note, kind };
  }

  function edgeOf(e, i, ids, problems) {
    const from = str(e.from), to = str(e.to);
    const where = `edges[${i}]`;
    if (!ids.has(from)) problems.push({ severity: "error", path: where + ".from", message: `No box with id "${from}"` });
    if (!ids.has(to)) problems.push({ severity: "error", path: where + ".to", message: `No box with id "${to}"` });
    const edge = { id: str(e.id) || `e-${slug(from)}-${slug(to)}`, fromNode: from, toNode: to };
    if (e.from_side) edge.fromSide = str(e.from_side);
    if (e.to_side) edge.toSide = str(e.to_side);
    if (e.two_way) edge.fromEnd = "arrow";
    if (e.label) edge.label = str(e.label);
    if (e.color != null) edge.color = str(e.color);
    const linen = {};
    if (e.kind && EDGE_KINDS.has(e.kind)) linen.kind = e.kind; else if (e.kind) problems.push({ severity: "warning", path: where + ".kind", message: "kind is one of works, main, code, plan, fail" });
    if (e.route) linen.route = str(e.route);
    if (e.note) linen.note = noteOf(e.note);
    if (Object.keys(linen).length) edge.linen = linen;
    return edge;
  }

  /** Places a section's cards in a grid, roughly, so the file is valid before layout measures it. */
  function placeSection(sec, cards, x, y) {
    const cols = Math.max(1, Math.min(6, sec.cols || (cards.length > 8 ? 2 : cards.length > 3 ? 2 : 1)));
    const heights = cards.map((c) => guessHeight(c.title, c.body, CARD_W));
    const rowH = [];
    cards.forEach((c, i) => { const r = Math.floor(i / cols); rowH[r] = Math.max(rowH[r] || 0, heights[i]); });
    const tops = []; let acc = y + HEAD;
    rowH.forEach((h, r) => { tops[r] = acc; acc += h + GAP; });
    const width = PAD * 2 + cols * CARD_W + (cols - 1) * GAP;
    const height = Math.max(HEAD + 120, acc - y - GAP + PAD);
    return {
      width, height, cols,
      pos: cards.map((c, i) => ({ x: x + PAD + (i % cols) * (CARD_W + GAP), y: tops[Math.floor(i / cols)], width: CARD_W, height: heights[i] })),
    };
  }

  /**
   * spec: { title, dir, words, columns, sections: [{ id, title, layout, cols, cards: [box] }], cards: [box], edges: [edge] }
   * box: { id, title, body, word, note, kind, shape, color, file, url, eyebrow }
   * edge: { from, to, label, kind, two_way, route, from_side, to_side, note }
   * Returns { canvas, notes (object or null), problems }.
   */
  function compose(spec) {
    const problems = [];
    spec = spec && typeof spec === "object" ? spec : {};
    const sections = Array.isArray(spec.sections) ? spec.sections : [];
    const loose = Array.isArray(spec.cards) ? spec.cards : [];
    if (!sections.length && !loose.length) problems.push({ severity: "error", path: "sections", message: "A board needs at least one section with cards, or cards" });
    const nodes = [], notes = {}, ids = new Set();
    // One id namespace for sections, boxes and connectors. An id the agent wrote is kept or the spec is refused, since
    // connectors and references name it; an id Linen makes up takes a free suffix.
    const claim = (id, where, explicit) => {
      if (explicit && ids.has(id)) {
        problems.push({ severity: "error", path: where, message: `The id "${id}" is used twice; ids name one box, section or connector each` });
        return id;
      }
      let out = id, n = 2;
      while (ids.has(out)) out = `${id}-${n++}`;
      ids.add(out);
      return out;
    };
    const columns = Math.max(1, Math.min(8, spec.columns || Math.min(5, sections.length || 1)));
    let x = 0, y = 0, rowHeight = 0, col = 0;
    sections.forEach((s, si) => {
      const where = `sections[${si}]`;
      const cards = Array.isArray(s.cards) ? s.cards : [];
      const sid = claim(str(s.id) || "s-" + slug(s.title), where + ".id", !!s.id);
      if (col === columns) { col = 0; x = 0; y += rowHeight + ROW_GAP; rowHeight = 0; }
      const built = cards.map((c, ci) => nodeOf(c, problems, `${where}.cards[${ci}]`));
      const place = placeSection(s, cards, x, y);
      const group = { id: sid, type: "group", x, y, width: place.width, height: place.height, label: str(s.title) || sid };
      const glinen = { layout: ["grid", "stack", "lanes", "layered"].includes(s.layout) ? s.layout : "grid" };
      if (glinen.layout === "grid") glinen.cols = place.cols;
      if (s.word) glinen.word = str(s.word);
      group.linen = glinen;
      if (s.color != null) group.color = str(s.color);
      nodes.push(group);
      built.forEach((b, ci) => {
        b.node.id = claim(b.node.id, `${where}.cards[${ci}].id`, !!(cards[ci] && cards[ci].id));
        Object.assign(b.node, place.pos[ci]);
        nodes.push(b.node);
        if (b.note) notes[b.node.id] = b.note;
      });
      x += place.width + COL_GAP;
      rowHeight = Math.max(rowHeight, place.height);
      col++;
    });
    if (loose.length) {
      const ly = sections.length ? y + rowHeight + ROW_GAP : 0;
      loose.forEach((c, ci) => {
        const b = nodeOf(c, problems, `cards[${ci}]`);
        b.node.id = claim(b.node.id, `cards[${ci}].id`, !!(c && c.id));
        const h = guessHeight(c.title, c.body, CARD_W);
        Object.assign(b.node, { x: (ci % 4) * (CARD_W + COL_GAP), y: ly + Math.floor(ci / 4) * 260, width: CARD_W, height: h });
        nodes.push(b.node);
        if (b.note) notes[b.node.id] = b.note;
      });
    }
    const boxIds = new Set(ids);
    const edges = (Array.isArray(spec.edges) ? spec.edges : []).map((e, i) => {
      const edge = edgeOf(e, i, boxIds, problems);
      edge.id = claim(edge.id, `edges[${i}].id`, !!(e && e.id));
      return edge;
    });
    // Every box's word is one the board defines (its own list, else Linen's five), caught before anything is written.
    const allowed = Array.isArray(spec.words) && spec.words.length ? spec.words.map((w) => (w && typeof w === "object" ? w.word : w)) : DEFAULT_WORDS;
    for (const n of nodes) {
      const w = n.linen && n.linen.word;
      if (w && !allowed.includes(w)) {
        problems.push({ severity: "error", path: `box "${n.id}".word`, message: `"${w}" is not one of this board's words (${allowed.join(", ")}). Use one of them, or add it to board.words.` });
      }
    }
    // A heavy shape on most boxes makes the board shout; the usual state should be the calmest (found in an evaluation).
    if (Array.isArray(spec.words)) {
      const boxes = nodes.filter((n) => n.type !== "group");
      for (const w of spec.words) {
        if (!w || typeof w !== "object" || !["solid", "rust"].includes(w.shape)) continue;
        const used = boxes.filter((n) => n.linen && n.linen.word === w.word).length;
        if (boxes.length >= 6 && used / boxes.length > 1 / 3) {
          problems.push({ severity: "warning", path: "words", message: `"${w.word}" is ${w.shape}, the heaviest look, and on ${used} of ${boxes.length} boxes. Give the most common word the outline shape and quiet: true, and keep ${w.shape} for the few that must stand out.` });
        }
      }
    }
    // A right-to-left board reads from the right (BRD-27): the first section of each row goes at the right.
    const rtl = spec.dir === "rtl" || (spec.dir !== "ltr" && arabicMajority([spec.title, ...sections.map((s) => s.title), ...sections.flatMap((s) => (s.cards || []).map((c) => c && c.title))]));
    if (rtl && nodes.length) {
      const right = Math.max(...nodes.map((n) => n.x + n.width));
      for (const n of nodes) n.x = right - (n.x + n.width);
    }
    const canvas = { nodes, edges };
    const linen = { rows: { columns } };
    if (rtl && !spec.dir) linen.dir = "rtl";
    if (spec.title) linen.title = str(spec.title);
    if (spec.eyebrow) linen.eyebrow = str(spec.eyebrow);
    if (spec.dir === "rtl" || spec.dir === "ltr") linen.dir = spec.dir;
    if (Array.isArray(spec.words) && spec.words.length) linen.words = spec.words.map((w) => (typeof w === "string" ? { word: w } : w));
    canvas.linen = linen;
    return { canvas, notes: Object.keys(notes).length ? notes : null, problems };
  }

  const childrenOf = (canvas, gid) => {
    const g = canvas.nodes.find((n) => n.id === gid);
    if (!g) return [];
    return canvas.nodes.filter((n) => n !== g && n.type !== "group" && n.x + n.width / 2 >= g.x && n.x + n.width / 2 <= g.x + g.width && n.y + n.height / 2 >= g.y && n.y + n.height / 2 <= g.y + g.height);
  };

  /** Places a new card at the end of a section (layout then puts it in its grid slot). */
  function appendTo(canvas, gid, node) {
    const g = canvas.nodes.find((n) => n.id === gid && n.type === "group");
    const kids = childrenOf(canvas, gid);
    const bottom = kids.reduce((b, n) => Math.max(b, n.y + n.height), g.y + HEAD);
    Object.assign(node, { x: g.x + PAD, y: bottom + GAP, width: CARD_W, height: guessHeight("", node.text, CARD_W) });
    g.height = Math.max(g.height, node.y + node.height + PAD - g.y);
  }

  /**
   * ops: [{ op: "set", id, title, body, word, note, color, kind, shape, eyebrow }
   *       { op: "add", section, card } | { op: "remove", id } | { op: "move", id, section }
   *       { op: "connect", from, to, label, kind, two_way } | { op: "disconnect", from, to } | { op: "disconnect", id }
   *       { op: "add_section", section: {id, title, cols, layout, cards} } | { op: "remove_section", id, keep_cards }
   *       { op: "set_board", title, words, dir }]
   * notes: the sidecar object or null. A note given in an op goes where that box's note already lives, else to the
   * sidecar when the board has one, else into the board.
   * Returns { canvas, notes, changed: [ids], problems }.
   */
  const OPS = ["set", "add", "remove", "move", "connect", "disconnect", "add_section", "remove_section", "set_board"];
  const isStr = (v) => typeof v === "string";
  const optStr = (v) => v === undefined || isStr(v);
  const nullStr = (v) => v === undefined || v === null || isStr(v);

  /** Every op's fields checked before anything changes, so a wrong type never deletes data (MCP-5). */
  function validate(ops) {
    const out = [];
    if (!Array.isArray(ops) || !ops.length) { out.push({ severity: "error", path: "ops", message: "ops is a non-empty list of operations" }); return out; }
    ops.forEach((o, i) => {
      const at = `ops[${i}]`;
      const bad = (field, want) => out.push({ severity: "error", path: `${at}.${field}`, message: `${field} must be ${want}` });
      if (!o || typeof o !== "object") { out.push({ severity: "error", path: at, message: "Each op is an object such as {op: \"set\", id: \"x\", word: \"Works\"}" }); return; }
      if (!OPS.includes(o.op)) { out.push({ severity: "error", path: at + ".op", message: "op is one of " + OPS.join(", ") }); return; }
      switch (o.op) {
        case "set":
          if (!isStr(o.id)) bad("id", "a box or section id");
          if (!nullStr(o.title)) bad("title", "text"); if (!nullStr(o.body)) bad("body", "text"); if (!nullStr(o.word)) bad("word", "a status word or null");
          if (!nullStr(o.eyebrow)) bad("eyebrow", "text or null"); if (!nullStr(o.color)) bad("color", "\"1\" to \"6\", #RRGGBB, or null");
          if (o.note !== undefined && o.note !== null && !isStr(o.note) && (typeof o.note !== "object" || Array.isArray(o.note))) bad("note", "{title, body, refs} or null");
          if (o.kind !== undefined && !["card", "sticky", "shape", "text"].includes(o.kind)) bad("kind", "card, sticky, shape or text");
          if (o.shape !== undefined && !SHAPES.has(o.shape)) bad("shape", [...SHAPES].join(", "));
          break;
        case "add": {
          if (!o.card || typeof o.card !== "object" || Array.isArray(o.card)) { bad("card", "a box {id, title, body, word, note}"); break; }
          if (!optStr(o.section)) bad("section", "a section id");
          const c = o.card;
          const cbad = (f, want) => out.push({ severity: "error", path: `${at}.card.${f}`, message: `${f} must be ${want}` });
          if (!optStr(c.id)) cbad("id", "text"); if (!optStr(c.title)) cbad("title", "text"); if (!optStr(c.body)) cbad("body", "text");
          if (!optStr(c.word)) cbad("word", "a status word");
          if (c.kind !== undefined && !KINDS.has(c.kind)) cbad("kind", [...KINDS].join(", "));
          if (c.shape !== undefined && !SHAPES.has(c.shape)) cbad("shape", [...SHAPES].join(", "));
          if (c.note !== undefined && c.note !== null && !isStr(c.note) && (typeof c.note !== "object" || Array.isArray(c.note))) cbad("note", "{title, body, refs}");
          break;
        }
        case "remove": if (!isStr(o.id)) bad("id", "a box id"); break;
        case "move": if (!isStr(o.id)) bad("id", "a box id"); if (!isStr(o.section)) bad("section", "a section id"); break;
        case "connect":
          if (!isStr(o.from)) bad("from", "a box id"); if (!isStr(o.to)) bad("to", "a box id");
          if (!optStr(o.label)) bad("label", "text"); if (o.kind !== undefined && !EDGE_KINDS.has(o.kind)) bad("kind", [...EDGE_KINDS].join(", "));
          if (o.two_way !== undefined && typeof o.two_way !== "boolean") bad("two_way", "true or false");
          break;
        case "disconnect": if (!isStr(o.id) && !(isStr(o.from) && isStr(o.to))) bad("id", "a connector id, or from and to"); break;
        case "add_section": if (!o.section || typeof o.section !== "object") bad("section", "a section {id, title, cols, cards}"); break;
        case "remove_section": if (!isStr(o.id)) bad("id", "a section id"); if (o.keep_cards !== undefined && typeof o.keep_cards !== "boolean") bad("keep_cards", "true or false"); break;
        case "set_board":
          if (!optStr(o.title)) bad("title", "text"); if (o.words !== undefined && !Array.isArray(o.words)) bad("words", "a list of words");
          if (o.dir !== undefined && o.dir !== "ltr" && o.dir !== "rtl") bad("dir", "ltr or rtl");
          break;
      }
    });
    return out;
  }

  /** Every descendant of a section: nested sections and their boxes, by the containment tree. */
  function descendants(canvas, gid) {
    const parent = membership(canvas);
    const out = new Set();
    for (const n of canvas.nodes) {
      let p = parent[n.id], hops = 0;
      while (p && hops++ < 64) { if (p === gid) { out.add(n.id); break; } p = parent[p]; }
    }
    return out;
  }

  function edit(canvas, notes, ops) {
    const early = validate(ops);
    if (early.length) return { canvas, notes, changed: [], boardChanged: false, problems: early, rejected: true };
    const original = { canvas, notes };
    const problems = [], changed = new Set();
    let boardChanged = false;
    canvas = JSON.parse(JSON.stringify(canvas || { nodes: [], edges: [] }));
    if (!Array.isArray(canvas.nodes)) canvas.nodes = [];
    if (!Array.isArray(canvas.edges)) canvas.edges = [];
    notes = notes ? JSON.parse(JSON.stringify(notes)) : null;
    const useSidecar = !!notes;
    const byId = () => new Map(canvas.nodes.map((n) => [n.id, n]));
    const setNote = (id, note, holder) => {
      const inBoard = holder.linen && holder.linen.note;
      if (note === null) { if (holder.linen) delete holder.linen.note; if (notes) delete notes[id]; return; }
      if (!inBoard && useSidecar) notes[id] = note;
      else { holder.linen = holder.linen || {}; holder.linen.note = note; }
    };
    // Words a box may carry: the board's own list, else Linen's defaults; a set_board earlier in the same call counts.
    const boardWords = () => (canvas.linen && Array.isArray(canvas.linen.words) && canvas.linen.words.length
      ? canvas.linen.words.map((w) => (w && typeof w === "object" ? w.word : w)) : DEFAULT_WORDS);
    const checkWord = (word, where) => {
      if (word == null || word === "" || boardWords().includes(word)) return true;
      problems.push({ severity: "error", path: where, message: `"${word}" is not one of this board's words (${boardWords().join(", ")}). Use one of them, or add it first with set_board words.` });
      return false;
    };
    (Array.isArray(ops) ? ops : []).forEach((o, i) => {
      const where = `ops[${i}]`;
      const map = byId();
      if (o && o.op === "set" && o.word !== undefined && !checkWord(o.word, where + ".word")) return;
      if (o && o.op === "add" && o.card && o.card.word && !checkWord(o.card.word, where + ".card.word")) return;
      switch (o && o.op) {
        case "set": {
          const n = map.get(str(o.id));
          if (!n) { problems.push({ severity: "error", path: where, message: `No box with id "${o.id}"; call read_outline for the ids` }); return; }
          if (n.type === "group") {
            if (o.title != null) n.label = str(o.title);
          } else if (n.type === "text" && (o.title != null || o.body != null)) {
            const kind = (n.linen && n.linen.kind) || "card";
            let title = "", body = str(n.text);
            if (kind === "card") { const m = /^#{1,6}\s+(.*)(?:\n|$)/.exec(body); if (m) { title = m[1]; body = body.slice(m[0].length); } }
            else { const parts = body.split("\n"); title = parts.shift(); body = parts.join("\n"); }
            if (o.title != null) title = str(o.title);
            if (o.body != null) body = str(o.body);
            n.text = kind === "card" ? (title ? `# ${title}${body ? "\n" + body : ""}` : body) : (title && body ? `${title}\n${body}` : title || body);
          }
          if (o.word !== undefined) { n.linen = n.linen || {}; if (o.word === null || o.word === "") delete n.linen.word; else n.linen.word = str(o.word); }
          if (o.eyebrow !== undefined) { n.linen = n.linen || {}; if (!o.eyebrow) delete n.linen.eyebrow; else n.linen.eyebrow = str(o.eyebrow); }
          if (o.color !== undefined) { if (o.color === null) delete n.color; else n.color = str(o.color); }
          if (o.kind && n.type === "text" && ["card", "sticky", "shape", "text"].includes(o.kind)) { n.linen = n.linen || {}; if (o.kind === "card") delete n.linen.kind; else n.linen.kind = o.kind; }
          if (o.shape && SHAPES.has(o.shape)) { n.linen = n.linen || {}; n.linen.shape = o.shape; }
          if (o.note !== undefined) setNote(n.id, o.note === null ? null : noteOf(o.note), n);
          if (n.linen && !Object.keys(n.linen).length) delete n.linen;
          changed.add(n.id);
          return;
        }
        case "add": {
          const g = map.get(str(o.section));
          if (o.section && (!g || g.type !== "group")) { problems.push({ severity: "error", path: where, message: `No section with id "${o.section}"` }); return; }
          const b = nodeOf(o.card || {}, problems, where + ".card");
          if (map.has(b.node.id)) { problems.push({ severity: "error", path: where + ".card.id", message: `The id "${b.node.id}" is already on this board; pick a new one` }); return; }
          if (g) appendTo(canvas, g.id, b.node);
          else { const maxY = canvas.nodes.reduce((m, n) => Math.max(m, n.y + n.height), 0); Object.assign(b.node, { x: 0, y: maxY + ROW_GAP, width: CARD_W, height: guessHeight("", b.node.text, CARD_W) }); }
          canvas.nodes.push(b.node);
          if (b.note) setNote(b.node.id, b.note, b.node);
          changed.add(b.node.id);
          return;
        }
        case "remove": {
          const n = map.get(str(o.id));
          if (!n) { problems.push({ severity: "error", path: where, message: `No box with id "${o.id}"` }); return; }
          if (n.type === "group") { problems.push({ severity: "error", path: where, message: `"${o.id}" is a section; use remove_section (with keep_cards to keep its boxes)` }); return; }
          canvas.nodes = canvas.nodes.filter((x) => x !== n);
          canvas.edges = canvas.edges.filter((e) => e.fromNode !== n.id && e.toNode !== n.id);
          if (notes) delete notes[n.id];
          changed.add(n.id);
          return;
        }
        case "move": {
          const n = map.get(str(o.id)), g = map.get(str(o.section));
          if (!n || !g || g.type !== "group") { problems.push({ severity: "error", path: where, message: `move needs an existing box id and section id` }); return; }
          if (n.type === "group") { problems.push({ severity: "error", path: where, message: `"${o.id}" is a section; move takes a box (sections keep their place)` }); return; }
          appendTo(canvas, g.id, n);
          changed.add(n.id);
          return;
        }
        case "connect": {
          const ids = new Set(map.keys());
          const e = edgeOf(o, i, ids, problems);
          if (!ids.has(e.fromNode) || !ids.has(e.toNode)) return;
          const taken = new Set([...ids, ...canvas.edges.map((x) => x.id)]);
          if (o.id && taken.has(e.id)) { problems.push({ severity: "error", path: where + ".id", message: `The id "${e.id}" is already on this board` }); return; }
          const base = e.id; let n = 2;
          while (taken.has(e.id)) e.id = `${base}-${n++}`;
          canvas.edges.push(e);
          changed.add(e.fromNode); changed.add(e.toNode);
          return;
        }
        case "disconnect": {
          const before = canvas.edges.length;
          canvas.edges = canvas.edges.filter((e) => {
            const hit = o.id ? e.id === o.id : (e.fromNode === o.from && e.toNode === o.to) || (!o.directed && e.fromNode === o.to && e.toNode === o.from);
            if (hit) { changed.add(e.fromNode); changed.add(e.toNode); }
            return !hit;
          });
          // A removal that matches nothing is an error, so a batch never half-applies on a wrong id.
          if (canvas.edges.length === before) problems.push({ severity: "error", path: where, message: "No connector matched; read_outline lists the board's boxes, and connector ids are e-<from>-<to> unless named" });
          return;
        }
        case "add_section": {
          const s = o.section || {};
          // The new section speaks the board's own words and direction.
          const r = compose({ sections: [s], words: canvas.linen && canvas.linen.words, dir: canvas.linen && canvas.linen.dir });
          r.problems.forEach((p) => problems.push({ ...p, path: where + "." + p.path }));
          const taken = new Set(canvas.nodes.map((n) => n.id));
          if (r.canvas.nodes.some((n) => taken.has(n.id))) { problems.push({ severity: "error", path: where, message: "An id in this section is already on the board" }); return; }
          const maxY = canvas.nodes.filter((n) => n.type === "group").reduce((m, n) => Math.max(m, n.y + n.height), -ROW_GAP);
          r.canvas.nodes.forEach((n) => { n.y += maxY + ROW_GAP; canvas.nodes.push(n); changed.add(n.id); });
          if (r.notes) for (const [k, v] of Object.entries(r.notes)) { const n = canvas.nodes.find((x) => x.id === k); setNote(k, v, n); }
          return;
        }
        case "remove_section": {
          const g = map.get(str(o.id));
          if (!g || g.type !== "group") { problems.push({ severity: "error", path: where, message: `No section with id "${o.id}"` }); return; }
          // The whole subtree goes (nested sections, their boxes, notes and connectors); keep_cards keeps the boxes and
          // removes only the section frames.
          const below = descendants(canvas, g.id);
          const kids = new Set([...below].filter((id) => !o.keep_cards || (map.get(id) && map.get(id).type === "group")));
          kids.add(g.id);
          canvas.nodes = canvas.nodes.filter((n) => !kids.has(n.id));
          canvas.edges = canvas.edges.filter((e) => !kids.has(e.fromNode) && !kids.has(e.toNode));
          kids.forEach((k) => { changed.add(k); if (notes) delete notes[k]; });
          return;
        }
        case "set_board": {
          canvas.linen = canvas.linen || {};
          if (o.title != null) canvas.linen.title = str(o.title);
          if (Array.isArray(o.words)) {
            // A word given by name keeps its existing definition (shape, meaning); a new one starts as an outline.
            const before = new Map((Array.isArray(canvas.linen.words) ? canvas.linen.words : []).filter((w) => w && typeof w === "object").map((w) => [w.word, w]));
            canvas.linen.words = o.words.map((w) => (typeof w === "string" ? before.get(w) || { word: w, shape: "outline" } : w));
          }
          if (o.dir === "rtl" || o.dir === "ltr") canvas.linen.dir = o.dir;
          boardChanged = true;
          return;
        }
        default:
          problems.push({ severity: "error", path: where + ".op", message: "op is one of " + OPS.join(", ") });
      }
    });
    // All or nothing: one failing op leaves the board as it was (MCP-5).
    if (problems.some((p) => p.severity === "error")) {
      return { canvas: original.canvas, notes: original.notes, changed: [], boardChanged: false, problems, rejected: true };
    }
    return { canvas, notes, changed: [...changed], boardChanged, problems, rejected: false };
  }

  /** Which section holds each node, by containment of its centre in the smallest section: taken BEFORE layout grows
      sections, since a grown section's box can cover the next row and make geometry lie. */
  function membership(canvas) {
    const groups = canvas.nodes.filter((n) => n.type === "group");
    const parent = {};
    for (const n of canvas.nodes) {
      const cx = n.x + n.width / 2, cy = n.y + n.height / 2;
      let best = null;
      for (const g of groups) {
        if (g === n || cx < g.x || cx > g.x + g.width || cy < g.y || cy > g.y + g.height) continue;
        if (n.type === "group" && g.width * g.height <= n.width * n.height) continue;
        if (!best || g.width * g.height < best.width * best.height) best = g;
      }
      if (best) parent[n.id] = best.id;
    }
    return parent;
  }

  /** Composed boards keep their sections in tidy rows after layout grows them (BRD-25). Moves never mark changes.
      parents: membership(canvas) taken before layout; without it, membership is read from the current geometry. */
  function reflow(canvas, parents) {
    const rows = canvas && canvas.linen && canvas.linen.rows;
    if (!rows) return { canvas, moved: 0 };
    const columns = Math.max(1, rows.columns || 5);
    parents = parents || membership(canvas);
    const groups = canvas.nodes.filter((n) => n.type === "group");
    const top = groups.filter((g) => !parents[g.id]);
    top.sort((a, b) => (Math.abs(a.y - b.y) < 40 ? a.x - b.x : a.y - b.y));
    const topOf = (id) => { let p = parents[id], seen = 0; while (p && parents[p] && seen++ < 64) p = parents[p]; return p; };
    const kidsOf = new Map(top.map((g) => [g.id, []]));
    for (const n of canvas.nodes) { const t = topOf(n.id); if (t && kidsOf.has(t)) kidsOf.get(t).push(n); }
    void columns;
    // Push apart, never re-grid: a section keeps where it is (where compose put it, or where someone dragged it) unless
    // layout made it overlap a neighbour. Sections starting at the same height form a row and move together, so rows
    // stay level; within a row a section moves right only as far as the one before it now reaches.
    const shift = (g, dx, dy) => { g.x += dx; g.y += dy; for (const k of kidsOf.get(g.id)) { k.x += dx; k.y += dy; } };
    const rowsOf = [];
    for (const g of top) {
      const r = rowsOf.find((row) => Math.abs(row.y - g.y) < 40);
      if (r) r.items.push(g); else rowsOf.push({ y: g.y, items: [g] });
    }
    rowsOf.sort((a, b) => a.y - b.y);
    let moved = 0;
    const placed = [];
    for (const row of rowsOf) {
      // Along the row first, from its start (the left, or the right on a right-to-left board): no section begins
      // before the previous one ends. Then down, against every earlier row, at the row's final positions, so a sideways
      // move can never land on an earlier row (Codex verification, 2026-10-15).
      const rtl = canvas.linen && canvas.linen.dir === "rtl";
      row.items.sort(rtl ? (a, b) => b.x + b.width - (a.x + a.width) : (a, b) => a.x - b.x);
      for (let i = 1; i < row.items.length; i++) {
        const prev = row.items[i - 1], g = row.items[i];
        const dx = rtl ? (prev.x - COL_GAP) - (g.x + g.width) : prev.x + prev.width + COL_GAP - g.x;
        if (rtl ? dx < 0 : dx > 0) { for (let j = i; j < row.items.length; j++) shift(row.items[j], dx, 0); moved++; }
      }
      let dy = 0;
      for (const g of row.items) for (const p of placed) {
        if (g.x < p.x + p.width && p.x < g.x + g.width) dy = Math.max(dy, p.y + p.height + ROW_GAP - g.y);
      }
      if (dy > 0) { row.items.forEach((g) => shift(g, 0, dy)); moved += row.items.length; }
      placed.push(...row.items);
    }
    // Loose boxes below every section they now overlap.
    for (const n of canvas.nodes.filter((x) => x.type !== "group" && !parents[x.id])) {
      for (const p of placed) {
        if (n.x < p.x + p.width && p.x < n.x + n.width && n.y < p.y + p.height && p.y < n.y + n.height) { n.y = p.y + p.height + ROW_GAP; moved++; }
      }
    }
    return { canvas, moved };
  }

  const api = { compose, edit, reflow, membership, slug };
  root.LinenAuthor = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof self !== "undefined" ? self : typeof globalThis !== "undefined" ? globalThis : this);
