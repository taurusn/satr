// The lexing half of Linen's renderer (PRD PERF-2), shared by the parser worker and the page's fallback: the
// whole document's top-level tokens with the document context the page needs to render them in any order.
(function (root) {
  "use strict";
  const marked = root.LinenDialect.configure(new root.marked.Marked());

  // FNV-1a over the block's source, as two 32-bit halves: a stable content hash for diffs and baselines.
  function hash(text) {
    let h1 = 0x811c9dc5, h2 = 0x01000193 ^ text.length;
    for (let i = 0; i < text.length; i++) {
      const c = text.charCodeAt(i);
      h1 = Math.imul(h1 ^ c, 0x01000193) >>> 0;
      h2 = Math.imul(h2 ^ c, 0x5bd1e995) >>> 0;
    }
    return h1.toString(16).padStart(8, "0") + h2.toString(16).padStart(8, "0");
  }

  function countLines(s) {
    let n = 0;
    for (let i = 0; i < s.length; i++) if (s.charCodeAt(i) === 10) n++;
    return n;
  }

  // Frontmatter: a leading --- block. Returns its text and how many source lines it takes.
  function splitFrontmatter(source) {
    const m = /^﻿?---[ \t]*\r?\n([\s\S]*?)\r?\n---[ \t]*(?:\r?\n|$)/.exec(source);
    if (!m) return { yaml: null, body: source, lines: 0 };
    return { yaml: m[1], body: source.slice(m[0].length), lines: countLines(m[0]) };
  }

  // Line ranges of list items and table rows inside a block, for Copy Reference (READ-6).
  function partLines(token, start) {
    const parts = [];
    if (token.type === "list") {
      let line = start;
      for (const item of token.items) {
        const n = countLines(item.raw.replace(/\n+$/, ""));
        parts.push([line, line + n]);
        line += countLines(item.raw);
      }
    } else if (token.type === "table") {
      const rows = token.raw.replace(/\n+$/, "").split("\n");
      rows.forEach((_, i) => parts.push([start + i, start + i]));
    }
    return parts;
  }

  // A huge list or table becomes consecutive chunks, each its own block, so no block takes more than one
  // render slice (SAFE-5). Each chunk keeps the line range of the items or rows it holds.
  const BIG = 64 * 1024, PIECE = 16 * 1024;
  // Text in pieces of at most 16 KB, never cutting a surrogate pair. Each piece carries its first line.
  function pieces(text, line) {
    const out = [];
    for (let i = 0; i < text.length;) {
      let end = Math.min(text.length, i + PIECE);
      const c = text.charCodeAt(end - 1);
      if (end < text.length && c >= 0xd800 && c <= 0xdbff) end--;
      const piece = text.slice(i, end);
      out.push({ text: piece, line });
      line += countLines(piece);
      i = end;
    }
    return out;
  }
  function chunk(t, start) {
    const body = (t.raw || "").replace(/\n+$/, "");
    if (body.length > BIG) {
      // Too large to typeset as one unit (SAFE-5): escaped plain text in 16 KB pieces, each its own block.
      return pieces(body, start).map((p, i) => ({ kind: "plain", text: p.text, big: i === 0, hash: hash("big\u0000" + p.text), lines: [p.line, p.line + countLines(p.text)] }));
    }
    const whole = () => [{ kind: "md", token: t, hash: hash(t.type + "\u0000" + body), lines: [start, start + countLines(body)], parts: partLines(t, start) }];
    if (t.type === "list" && t.items.length > 200) {
      const out = [];
      let line = start;
      for (let i = 0; i < t.items.length; i += 200) {
        const items = t.items.slice(i, i + 200);
        const raw = items.map((it) => it.raw).join("");
        const piece = { ...t, items, raw, start: t.ordered ? (Number(t.start) || 1) + i : t.start };
        const b = raw.replace(/\n+$/, "");
        out.push({ kind: "md", token: piece, hash: hash("list\u0000" + b), lines: [line, line + countLines(b)], parts: partLines(piece, line) });
        line += countLines(raw);
      }
      return out;
    }
    if (t.type === "table" && t.rows.length > 500) {
      const out = [];
      const rawRows = body.split("\n");
      for (let i = 0; i < t.rows.length; i += 500) {
        const rows = t.rows.slice(i, i + 500);
        const rawPart = [rawRows[0], rawRows[1], ...rawRows.slice(2 + i, 2 + i + rows.length)].join("\n");
        const piece = { ...t, rows, raw: rawPart };
        const first = i === 0 ? start : start + 2 + i;
        out.push({ kind: "md", token: piece, hash: hash("table\u0000" + rawPart + "\u0000" + i), lines: [first, start + 1 + i + rows.length], parts: [] });
      }
      return out;
    }
    return whole();
  }

  // JavaScriptCore copies the rest of the text at each step of marked's lexer, so a long document lexes in
  // quadratic time (log.md, 730 KB: 3.5 s, where V8 takes 43 ms). Long documents are therefore lexed in sections
  // of about 24 KB, split before an ATX heading outside fenced code (a heading always starts a new block), or after
  // 48 KB without one at a blank line before a plain paragraph,
  // with every link reference definition in the document shared by all sections.
  function lexInSections(body, budget) {
    if (body.length < 48 * 1024) return newLexer(budget).lex(body);
    const lines = body.split("\n");
    // Pieces: { text } to lex, or { big } for one block over 64 KB, which is never typeset (SAFE-5).
    const pieces = [];
    let start = 0, size = 0, fence = null, fenceStart = -1, blockStart = 0, blockSize = 0;
    const cut = (from, to, big) => {
      if (to <= from) return;
      const text = lines.slice(from, to).join("\n") + (to < lines.length ? "\n" : "");
      pieces.push(big ? { big: text } : { text });
    };
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const f = /^ {0,3}(`{3,}|~{3,})/.exec(line);
      if (f && !fence) { fence = f[1][0]; fenceStart = i; }
      else if (f && fence && line.trim().startsWith(fence.repeat(3))) {
        fence = null;
        let fenceBytes = 0;
        for (let k = fenceStart; k <= i; k++) fenceBytes += lines[k].length + 1;
        if (fenceBytes > BIG) { cut(start, fenceStart, false); cut(fenceStart, i + 1, true); start = i + 1; size = 0; blockStart = i + 1; blockSize = 0; continue; }
      }
      if (!fence) {
        if (line.trim() === "") {
          if (blockSize > BIG) { cut(start, blockStart, false); cut(blockStart, i, true); start = i; size = 0; }
          blockStart = i + 1;
          blockSize = 0;
        } else {
          blockSize += line.length + 1;
        }
        const atHeading = /^#{1,6}\s/.test(line);
        // A long stretch without headings also splits at a blank line before a line that starts a plain block.
        const atBlank = size > 48 * 1024 && line.trim() !== "" && !/^(\s|[-*+>|]|\d+[.)]\s)/.test(line);
        if (size > 24 * 1024 && i > start && (atHeading || atBlank) && lines[i - 1].trim() === "") {
          cut(start, i, false);
          start = i;
          size = 0;
        }
      }
      size += line.length + 1;
    }
    if (!fence && blockSize > BIG) { cut(start, blockStart, false); cut(blockStart, lines.length, true); }
    else cut(start, lines.length, false);

    const links = Object.create(null);
    const def = /^ {0,3}\[([^\]\n]+)\]:[ \t]*<?([^\s>]+)>?(?:[ \t]+(?:"([^"]*)"|'([^']*)'|\(([^)]*)\)))?[ \t]*$/gm;
    for (const m of body.matchAll(def)) {
      const label = m[1].trim().toLowerCase().replace(/\s+/g, " ");
      if (!(label in links) && !label.startsWith("^")) links[label] = { href: m[2], title: m[3] || m[4] || m[5] || "" };
    }
    const all = [];
    for (const piece of pieces) {
      if (piece.big !== undefined) { all.push({ type: "bigRaw", raw: piece.big }); continue; }
      const lexer = newLexer(budget);
      Object.assign(lexer.tokens.links, links);
      for (const t of lexer.lex(piece.text)) all.push(t);
    }
    all.links = links;
    return all;
  }

  // Bounded work (SAFE-5). Tokens are counted while marked lexes, so a document past 200,000 stops at that point
  // instead of after a full parse; nesting past 100 levels is flattened, in the source first (so marked's
  // recursion stays shallow) and then in the tokens.
  const MAX_TOKENS = 200000, MAX_DEPTH = 100;
  const TOO_MANY = new Error("over 200,000 tokens");
  const proto = root.marked.Lexer.prototype;
  function newLexer(budget) {
    const lexer = new root.marked.Lexer(marked.defaults);
    const counted = (fn) => function (src, tokens, last) {
      const list = tokens || [];
      const before = list.length;
      fn.call(this, src, list, last);
      if ((budget.n += list.length - before) > MAX_TOKENS) throw TOO_MANY;
      return list;
    };
    lexer.blockTokens = counted(proto.blockTokens);
    lexer.inlineTokens = counted(proto.inlineTokens);
    return lexer;
  }
  // A line that opens more than 100 quotes or list items keeps its first 100; indentation past 400 columns
  // (which could nest lists 200 deep) is cut to 400. Neither changes the line count.
  const DEEP_PREFIX = /^[ \t]*(?:(?:>|(?:[-*+]|\d{1,9}[.)])[ \t])[ \t]*){101,}/gm;
  const ONE_PREFIX = /(?:>|(?:[-*+]|\d{1,9}[.)])[ \t])[ \t]*/g;
  const DEEP_INDENT = /^[ \t]{401,}/gm;
  function capNesting(body) {
    return body
      .replace(DEEP_PREFIX, (m) => { const lead = /^[ \t]*/.exec(m)[0]; return lead + m.slice(lead.length).match(ONE_PREFIX).slice(0, 100).join(""); })
      .replace(DEEP_INDENT, (m) => m.slice(0, 400));
  }
  const CONTAINERS = new Set(["blockquote", "list", "callout"]);
  const inside = (t) => (t.type === "list" ? t.items.flatMap((item) => item.tokens || []) : t.tokens || []);
  // Visits every token with its depth; at depth 100 a container gives its blocks to its parent and any other
  // token with children becomes its source as text.
  function scan(tokens, depth, visit) {
    for (let i = 0; i < tokens.length; i++) {
      let t = tokens[i];
      if (depth >= MAX_DEPTH && (t.tokens || t.items || t.rows)) {
        if (CONTAINERS.has(t.type)) { tokens.splice(i, 1, ...inside(t)); i--; continue; }
        tokens[i] = t = { type: "text", raw: t.raw || "", text: t.raw || "" };
      }
      visit(t);
      if (t.tokens) scan(t.tokens, depth + 1, visit);
      if (t.items) for (const item of t.items) scan(item.tokens || [], depth + 1, visit);
      if (t.header) for (const cell of t.header) scan(cell.tokens || [], depth + 1, visit);
      if (t.rows) for (const row of t.rows) for (const cell of row) scan(cell.tokens || [], depth + 1, visit);
    }
  }

  // Plain text in 200-line blocks (REN-10, SAFE-5), so huge logs stay a bounded page; a block over 64 KB (very
  // long lines) goes in 16 KB pieces.
  function lexPlain(source) {
    const lines = source.split("\n");
    const blocks = [];
    for (let i = 0; i < lines.length; i += 200) {
      const text = lines.slice(i, i + 200).join("\n");
      if (text.length <= BIG) { blocks.push({ kind: "plain", text, hash: hash(text), lines: [i + 1, Math.min(i + 200, lines.length)] }); continue; }
      for (const p of pieces(text, i + 1)) blocks.push({ kind: "plain", text: p.text, hash: hash(p.text), lines: [p.line, p.line + countLines(p.text)] });
    }
    let stamped = 0;
    for (const l of lines) if (/^\s*(\[?\d{4}-\d{2}-\d{2}|\[?\d{2}:\d{2}(:\d{2})?)/.test(l)) stamped++;
    return { blocks, yaml: null, links: {}, footnotes: {}, footnoteDefs: [], logLike: stamped > lines.length / 2 };
  }

  function lex(source, plain) {
    if (plain) return lexPlain(source);
    const fm = splitFrontmatter(source);
    let tokens;
    try {
      tokens = lexInSections(capNesting(fm.body), { n: 0 });
    } catch (_) {
      // Over the token cap, or deeper than marked's recursion allows: the whole document as plain text.
      const r = lexPlain(source);
      r.tooBig = true;
      return r;
    }
    const footnotes = {};
    const footnoteDefs = [];
    let order = 0;
    scan(tokens, 0, (t) => {
      if (t.type === "footnoteRef" && !(t.id in footnotes)) footnotes[t.id] = ++order;
      if (t.type === "footnoteDef") footnoteDefs.push(t);
    });
    for (const def of footnoteDefs) if (!(def.id in footnotes)) footnotes[def.id] = ++order;

    const blocks = [];
    let line = 1 + fm.lines;
    const fnDefs = [];
    for (const t of tokens) {
      const raw = t.raw || "";
      const start = line;
      line += countLines(raw);
      if (t.type === "footnoteDef") { fnDefs.push({ raw, start, end: start + countLines(raw.replace(/\n+$/, "")) }); continue; }
      if (t.type === "space" || t.type === "def" || t.type === "commentBlock") continue;
      for (const piece of chunk(t, start)) blocks.push(piece);
    }
    // The footnotes, lifted to the end of the page, are one source-backed block (Linen 2, BLK-1): its hash covers the
    // definitions and the order the text numbers them in, so an edited note is marked, a reader's place inside the
    // list holds, and `linen open --line` reaches a definition.
    if (footnoteDefs.length) {
      const order = footnoteDefs.map((d) => `${d.id}=${footnotes[d.id]}`).join(",");
      // Every definition counts, nested ones too, so editing any of them changes this block.
      const body = footnoteDefs.map((d) => d.raw || "").join("");
      const lines = fnDefs.length ? [fnDefs[0].start, fnDefs[fnDefs.length - 1].end] : [line, line];
      blocks.push({ kind: "md", token: { type: "footnoteList", raw: body }, hash: hash("footnotes\u0000" + order + "\u0000" + body), lines });
    }
    return { blocks, yaml: fm.yaml, links: tokens.links || {}, footnotes, footnoteDefs, logLike: false };
  }

  root.LinenLex = { lex };
})(typeof self !== "undefined" ? self : globalThis);
