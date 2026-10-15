/* Linen's board model (PRD-2 sections 6.1 and 9.1): reads a JSON Canvas 1.0 file with Linen's `linen` objects into
   one plain structure the renderer, the List view and `linen check` share. Pure script, no DOM and no modules, so it
   runs in the page, in a Web Worker, in node and in bare JavaScriptCore; it sets `LinenCanvas` on the global.

   Problems never blank a board (BRD-1): only a file that is not JSON, whose root is not an object, whose `nodes` or
   `edges` is present but not a list, or that is past BRD-20's limits is fatal; everything else is drawn and listed
   with its JSON path and the line of the offending field. JSON Canvas 1.0 makes both lists optional, so an empty
   file and `{}` are empty boards. */
(function (root) {
  "use strict";

  const SPEC_TYPES = ["text", "file", "link", "group"];
  const TEXT_KINDS = ["card", "sticky", "shape", "text"];
  const SHAPES = ["rect", "rounded", "ellipse", "diamond", "pill", "cylinder", "hexagon"];
  const WORD_SHAPES = ["outline", "threads", "solid", "dashed", "dotted", "rust"];
  const EDGE_KINDS = ["works", "main", "code", "plan", "fail"];
  const ROUTES = ["straight", "elbow", "curved"];
  const LAYOUTS = ["lanes", "grid", "stack", "layered"];
  const SIDES = ["top", "right", "bottom", "left"];
  const ENDS = ["none", "arrow"];
  const NOTE_EXT = ["md", "markdown", "txt"];
  const IMAGE_EXT = ["png", "jpg", "jpeg", "gif", "webp", "svg"];
  const DEFAULT_WORDS = [
    { word: "Works", shape: "outline", meaning: null, quiet: true },
    { word: "Partial", shape: "threads", meaning: null, quiet: false },
    { word: "Broken", shape: "rust", meaning: null, quiet: false },
    { word: "Missing", shape: "dashed", meaning: null, quiet: false },
    { word: "Planned", shape: "dotted", meaning: null, quiet: false },
  ];
  const LIMITS = { maxNodes: 2000, maxEdges: 3000, maxBytes: 2000000, maxNodeBytes: 65536 };
  const MAX_COORD = 1e7; // board px; anything further out cannot be drawn or indexed
  const MAX_SIZE = 1e6;
  const MAX_FATAL_SHOWN = 10;
  const CELL = 512;
  const MAX_CELLS_PER_ITEM = 256; // bigger items (over about 8,000 px square) go to the overflow list every query checks
  const STUB = 48; // board px of a connector whose other end is missing or unplaced, ending at its gap mark (BRD-4)
  // Linen 1's direction rule (ARB-1; Renderer/page.js directionOf and documentDirection), counting the same letters
  // as its RTL_RE and LTR_RE (the tests compare `letters` with those regexes over every BMP character).
  const DOC_DIR_CHARS = 200000;
  const FAILURE_WORDS = /fail|broken|break|error|down|crash|not work|doesn.t work|does not work|blocked|outage|عطل|معطل|فشل|خطأ|خلل|متوقف|لا يعمل|متعثر|تعثر|عالق|مسدود/i;

  // ---------- small helpers ----------

  const isObject = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
  const isNum = (v) => typeof v === "number" && isFinite(v);
  const describe = (v) => (v === null ? "null" : Array.isArray(v) ? "an array" : typeof v === "string" ? "a string" : typeof v === "number" ? "a number" : typeof v === "boolean" ? "a boolean" : "an object");
  const quote = (s) => JSON.stringify(String(s));

  function pathOf(parts) {
    let s = "$";
    for (const p of parts) s += typeof p === "number" ? "[" + p + "]" : /^[A-Za-z_$][\w$]*$/.test(p) ? "." + p : "[" + JSON.stringify(p) + "]";
    return s;
  }

  /** FNV-1a over UTF-16 code units, as 8 hex digits. */
  function hashString(s) {
    let h = 0x811c9dc5;
    for (let i = 0; i < s.length; i++) {
      h ^= s.charCodeAt(i);
      h = Math.imul(h, 0x01000193);
    }
    return (h >>> 0).toString(16).padStart(8, "0");
  }

  /**
   * UTF-8 length as an encoder writes it: a surrogate pair is 4 bytes, a lone surrogate becomes U+FFFD (3 bytes).
   * Pairs are removed first, by regex, so a lone surrogate is never paired with whatever follows it; the ASCII runs
   * go next, natively, so mostly-English text costs almost nothing.
   */
  function utf8Length(s) {
    const noPairs = s.replace(/[\ud800-\udbff][\udc00-\udfff]/g, "");
    let n = s.length + (s.length - noPairs.length); // each unit of a pair: 1 + 1 = 4 bytes per pair
    const wide = noPairs.replace(/[\x00-\x7f]+/g, "");
    for (let i = 0; i < wide.length; i++) n += wide.charCodeAt(i) < 0x800 ? 1 : 2;
    return n;
  }

  /** The longest prefix of s whose UTF-8 form fits in maxBytes, never splitting a surrogate pair. */
  function cutUtf8(s, maxBytes) {
    if (s.length * 3 <= maxBytes) return s;
    let n = 0;
    for (let i = 0; i < s.length; i++) {
      const c = s.charCodeAt(i);
      const pair = c >= 0xd800 && c <= 0xdbff && i + 1 < s.length && (s.charCodeAt(i + 1) & 0xfc00) === 0xdc00;
      const w = c < 0x80 ? 1 : c < 0x800 ? 2 : pair ? 4 : 3;
      if (n + w > maxBytes) return s.slice(0, i);
      n += w;
      if (pair) i++;
    }
    return s;
  }

  // ---------- direction (ARB-1, BRD-27) ----------

  /** Letters counted as RTL_RE and LTR_RE count them, without building match arrays: [rtl, ltr]. */
  function letters(s) {
    let r = 0, l = 0;
    for (let i = 0; i < s.length; i++) {
      const c = s.charCodeAt(i);
      if (c < 0x80) { if ((c >= 65 && c <= 90) || (c >= 97 && c <= 122)) l++; }
      else if ((c >= 0x0590 && c <= 0x08ff) || (c >= 0xfb1d && c <= 0xfdff) || (c >= 0xfe70 && c <= 0xfeff)) r++;
      else if ((c >= 0xc0 && c <= 0x24f) || (c >= 0x370 && c <= 0x4ff)) l++;
    }
    return [r, l];
  }
  const MARKUP = /[`[<~@]|https?:|www\.|^(?: {4}|\t)/im;
  /**
   * Code blocks as marked finds them, line by line. A fence opens at a line start (up to 3 spaces) with 3 or more
   * backticks or tildes and closes at a line holding at least as many of the same, or runs to the end; it ends a
   * list and leaves a non-blank placeholder with no letters. Indented code is indented lines after a blank line (or
   * at the start), until a line that is neither indented nor blank; inside a list item the same lines continue the
   * item instead, so they stay.
   */
  function dropCodeBlocks(md) {
    if (!/^(?: {0,3}(?:```|~~~)| {4}|\t)/m.test(md)) return md;
    const lines = md.split("\n");
    let inList = false, prevBlank = true, inCode = false, fence = null;
    for (let i = 0; i < lines.length; i++) {
      const s = lines[i];
      if (fence) {
        if (fence.test(s)) fence = null;
        lines[i] = "\u0000";
        continue;
      }
      const open = /^ {0,3}(`{3,}|~{3,})(.*)$/.exec(s);
      if (open && !(open[1][0] === "`" && open[2].indexOf("`") !== -1)) {
        fence = new RegExp("^ {0,3}" + (open[1][0] === "`" ? "`" : "~") + "{" + open[1].length + ",}[ \\t]*$");
        lines[i] = "\u0000";
        inCode = false; inList = false; prevBlank = false;
        continue;
      }
      const blank = /^[ \t]*$/.test(s);
      const indented = /^(?: {4}|\t)/.test(s);
      if (inCode) {
        if (indented || blank) { if (!blank) lines[i] = " "; continue; }
        inCode = false;
      }
      if (!blank && indented && prevBlank && !inList) { inCode = true; lines[i] = " "; continue; }
      if (!blank && !indented) inList = /^ {0,3}(?:[-*+]|\d{1,9}[.)])(?:[ \t]|$)/.test(s);
      prevBlank = blank;
    }
    return lines.join("\n");
  }
  /**
   * What Linen 1 counts in a block: the prose. Its renderer skips CODE, PRE, A, KBD and SUP elements, so this leaves
   * out what Markdown turns into them: fenced and indented code, inline code, wiki links, inline, reference and
   * auto links (with reference definitions, which render nothing), keys and footnote marks.
   */
  function proseOf(md) {
    if (!MARKUP.test(md)) return md;
    const refs = new Set();
    let t = dropCodeBlocks(md.replace(/\r\n?/g, "\n"))
      // A definition needs a destination; `[x]:` alone is text.
      .replace(/^ {0,3}\[([^\]\n]+)\]:[ \t]*\S[^\n]*$/gm, (m, label) => { refs.add(label.trim().toLowerCase()); return " "; })
      // Code spans of any backtick run length, as CommonMark matches them; an escaped backtick opens none.
      .replace(/(?<![\\`])(`+)(?!`)([\s\S]*?[^`])\1(?!`)/g, " ")
      .replace(/\\[!-\/:-@\[-`{-~]/g, " ")
      .replace(/<!--[\s\S]*?(?:-->|$)/g, " ")
      .replace(/<(a|code|pre|kbd|sup)\b[^>]*>[\s\S]*?<\/\1>/gi, " ")
      .replace(/<\/?[A-Za-z][^>]*>/g, " ")
      .replace(/!?\[\[[^\]\n]*\]\]/g, " ")
      .replace(/!?\[(?:[^\]\n]|\n(?![ \t]*\n))*\]\([^)\n]*\)/g, " ")
      .replace(/<https?:[^>\s]*>/gi, " ")
      .replace(/\bhttps?:\/\/\S+/gi, " ")
      .replace(/\bwww\.\S+/gi, " ")
      .replace(/<?\b[\w.+-]+@[\w-]+(?:\.[\w-]+)+\b>?/g, " ")
      .replace(/\[\^[^\]\n]*\]/g, " ");
    // Reference links render as links only when their label is defined; otherwise marked prints them as text.
    t = t.replace(/!?\[([^\]\n]*)\]\[([^\]\n]*)\]/g, (m, text, label) => (refs.has((label || text).trim().toLowerCase()) ? " " : m));
    if (refs.size) t = t.replace(/!?\[([^\]\n]+)\](?![[(])/g, (m, label) => (refs.has(label.trim().toLowerCase()) ? " " : m));
    return t;
  }
  // ---- the exact path: marked's own tokens, where the renderer has loaded marked and Linen's dialect ----
  // Linen 1's directionOf counts the rendered DOM's text outside CODE, PRE, A, KBD and SUP. These tokens render to
  // those elements or to no text at all (extensions.js): skipped. tag and statusWord render their name as text.
  const SKIP_TOKENS = new Set(["code", "codespan", "link", "image", "def", "space", "hr", "br", "wikilink", "footnoteRef",
    "footnoteDef", "commentBlock", "commentInline", "mathBlock", "mathInline"]);
  const SKIP_TAG = /^<\s*(\/?)\s*(a|code|pre|kbd|sup)\b/i;
  const htmlText = (raw) => raw.replace(/<!--[\s\S]*?(?:-->|$)/g, " ").replace(/<(a|code|pre|kbd|sup)\b[^>]*>[\s\S]*?<\/\1>/gi, " ").replace(/<[^>]*>/g, " ");
  function tokenText(tokens, st) {
    let out = "";
    for (const t of tokens) {
      if (!t || SKIP_TOKENS.has(t.type)) continue;
      if (t.type === "html") {
        if (t.block) { if (!st.skip) out += " " + htmlText(t.text || t.raw || ""); continue; }
        const m = SKIP_TAG.exec(t.raw || "");
        if (m) st.skip = Math.max(0, st.skip + (m[1] ? -1 : 1));
        continue;
      }
      if (st.skip) continue;
      if (t.type === "tag") { out += " #" + (t.name || ""); continue; }
      if (t.type === "statusWord") { out += " " + (t.word || ""); continue; }
      if (t.type === "callout" && typeof t.title === "string") out += " " + t.title;
      if (t.type === "table") {
        for (const c of t.header || []) out += " " + tokenText(c.tokens || [], st);
        for (const row of t.rows || []) for (const c of row) out += " " + tokenText(c.tokens || [], st);
        continue;
      }
      if (t.type === "list") { for (const it of t.items || []) out += " " + tokenText(it.tokens || [], st); continue; }
      if (t.tokens && t.tokens.length) { out += " " + tokenText(t.tokens, st); continue; }
      if (typeof t.text === "string") out += " " + t.text;
    }
    return out;
  }
  // One Marked instance with Linen's dialect, as page.js and lexer.js make theirs; without the dialect, plain GFM with
  // wiki links read as the links they render to. Built on first use, after every script has loaded.
  let lexerBox = null;
  function lexer() {
    if (lexerBox === null) {
      lexerBox = false;
      const m = root.marked;
      if (m && typeof m.Marked === "function") {
        try { lexerBox = root.LinenDialect ? { inst: root.LinenDialect.configure(new m.Marked()), dialect: true } : { inst: new m.Marked({ gfm: true }), dialect: false }; } catch (_) { lexerBox = false; }
      }
    }
    return lexerBox || null;
  }
  const hasLexer = () => !!lexer();
  /** The source-level mirror, used where marked is not loaded (node, the `linen` command's JavaScriptCore). */
  function proseDirection(md, fallback) {
    if (!md) return null;
    return ratioDirection(letters(proseOf(md)), fallback);
  }
  function ratioDirection([r, l], fallback) {
    if (r + l === 0) return null;
    const ratio = r / (r + l);
    return ratio > 0.6 ? "rtl" : ratio < 0.4 ? "ltr" : fallback;
  }
  /** directionOf: over 60 percent Arabic is rtl, under 40 percent ltr, between takes the board's direction. */
  function blockDirection(md, fallback) {
    if (!md) return null;
    const L = lexer();
    if (!L) return proseDirection(md, fallback);
    let tokens;
    try { tokens = L.inst.lexer(L.dialect ? md : md.replace(/!?\[\[[^\]\n]*\]\]/g, "[wiki](x)")); } catch (_) { return proseDirection(md, fallback); }
    return ratioDirection(letters(tokenText(tokens, { skip: 0 })), fallback);
  }
  /** documentDirection: the majority of letters over the whole text. */
  function documentDirection(text) {
    const [r, l] = letters(text);
    return r > l ? "rtl" : "ltr";
  }

  // ---------- line numbers ----------

  function lineIndex(text) {
    const starts = [0];
    let i = text.indexOf("\n");
    while (i !== -1) { starts.push(i + 1); i = text.indexOf("\n", i + 1); }
    return {
      line(offset) {
        if (offset == null || offset < 0) return null;
        let lo = 0, hi = starts.length - 1;
        while (lo < hi) {
          const mid = (lo + hi + 1) >> 1;
          if (starts[mid] <= offset) lo = mid; else hi = mid - 1;
        }
        return lo + 1;
      },
      column(offset) { const l = this.line(offset); return offset - starts[l - 1] + 1; },
    };
  }

  // ---------- offsets of every key and element, a few levels deep (only after JSON.parse accepted the text) ----------

  /**
   * Containers: objects { s, e, k: key -> key offset, c: key -> child container }, arrays { s, e, a: element
   * offsets, ae: element ends, c: index -> child container }. Children are built while depth < maxDepth.
   */
  function scanTree(text, maxDepth) {
    const n = text.length;
    const ws = (p) => {
      while (p < n) {
        const c = text.charCodeAt(p);
        if (c === 32 || c === 10 || c === 13 || c === 9) p++; else break;
      }
      return p;
    };
    const skipString = (p) => {
      let q = p + 1;
      for (;;) {
        const i = text.indexOf('"', q);
        if (i < 0) return n;
        let b = i - 1, k = 0;
        while (text.charCodeAt(b) === 92) { k++; b--; }
        if ((k & 1) === 0) return i + 1;
        q = i + 1;
      }
    };
    const skipValue = (p) => {
      const c = text.charCodeAt(p);
      if (c === 34) return skipString(p);
      if (c === 123 || c === 91) {
        let depth = 0;
        while (p < n) {
          const d = text.charCodeAt(p);
          if (d === 34) { p = skipString(p); continue; }
          if (d === 123 || d === 91) depth++;
          else if (d === 125 || d === 93) { depth--; if (depth === 0) return p + 1; }
          p++;
        }
        return n;
      }
      while (p < n) {
        const d = text.charCodeAt(p);
        if (d === 44 || d === 125 || d === 93 || d === 32 || d === 10 || d === 13 || d === 9) break;
        p++;
      }
      return p;
    };
    const readKey = (p) => {
      const end = skipString(p);
      const raw = text.slice(p + 1, end - 1);
      return [raw.indexOf("\\") === -1 ? raw : JSON.parse(text.slice(p, end)), end];
    };
    // Iterative, so deep nesting cannot overflow the stack.
    const open = (p) => (text.charCodeAt(p) === 123
      ? { s: p, e: p, k: Object.create(null), c: Object.create(null), obj: true }
      : { s: p, e: p, a: [], ae: [], c: [], obj: false });
    const p0 = ws(0);
    const c0 = text.charCodeAt(p0);
    if (c0 !== 123 && c0 !== 91) return null;
    const top = open(p0);
    const stack = [{ box: top, depth: 0, p: ws(p0 + 1), first: true, key: null, at: 0 }];
    while (stack.length) {
      const f = stack[stack.length - 1];
      let p = f.p;
      const close = f.box.obj ? 125 : 93;
      if (f.first) {
        f.first = false;
        if (text.charCodeAt(p) === close) { f.box.e = p + 1; stack.pop(); if (stack.length) resume(stack[stack.length - 1], f.box.e); continue; }
      }
      p = ws(p);
      let key = null, at = p;
      if (f.box.obj) {
        const r = readKey(p);
        key = r[0];
        f.box.k[key] = p;
        p = ws(ws(r[1]) + 1);
        at = p;
      }
      const c = text.charCodeAt(p);
      if ((c === 123 || c === 91) && f.depth < maxDepth) {
        const child = open(p);
        if (f.box.obj) f.box.c[key] = child; else { f.box.c[f.box.a.length] = child; f.box.a.push(at); f.box.ae.push(-1); }
        f.p = -1;
        stack.push({ box: child, depth: f.depth + 1, p: ws(p + 1), first: true, key: null, at });
        continue;
      }
      const end = skipValue(p);
      if (!f.box.obj) { f.box.a.push(at); f.box.ae.push(end); }
      if (!advance(f, end)) { stack.pop(); if (stack.length) resume(stack[stack.length - 1], f.box.e); }
    }
    return top;

    // After a member ends at `end`: a comma continues the container, anything else closes it.
    function advance(f, end) {
      const p = ws(end);
      if (text.charCodeAt(p) === 44) { f.p = p + 1; return true; }
      f.box.e = p + 1;
      return false;
    }
    function resume(parent, childEnd) {
      if (!parent.box.obj) parent.box.ae[parent.box.ae.length - 1] = childEnd;
      if (!advance(parent, childEnd)) { stack.pop(); if (stack.length) resume(stack[stack.length - 1], parent.box.e); }
    }
  }

  /** The offset of the deepest part of `parts` that exists, from a scanTree container. */
  function resolve(box, parts) {
    if (!box) return null;
    let off = box.s, cur = box;
    for (const part of parts) {
      if (!cur) break;
      if (typeof part === "number") {
        if (cur.obj || cur.a[part] == null) break;
        off = cur.a[part];
        cur = cur.c[part];
      } else {
        if (!cur.obj || cur.k[part] == null) break;
        off = cur.k[part];
        cur = cur.c[part];
      }
    }
    return off;
  }

  /** Finds where a text that JSON.parse refused first goes wrong (JavaScriptCore's errors carry no position). */
  function findJSONError(t) {
    const n = t.length;
    let p = 0;
    const fail = (message) => { throw { offset: Math.min(p, n), message }; };
    const ws = () => {
      while (p < n) {
        const c = t.charCodeAt(p);
        if (c === 32 || c === 9 || c === 10 || c === 13) p++; else break;
      }
    };
    const NUM = /-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/y;
    const str = () => {
      p++;
      for (;;) {
        if (p >= n) fail("A string is never closed");
        const c = t.charCodeAt(p);
        if (c === 34) { p++; return; }
        if (c === 92) {
          const e = t[p + 1];
          if ('"\\/bfnrt'.indexOf(e) !== -1) p += 2;
          else if (e === "u" && /^[0-9a-fA-F]{4}$/.test(t.substr(p + 2, 4))) p += 6;
          else { p++; fail("A bad escape in a string"); }
          continue;
        }
        if (c < 32) fail("A line break or control character inside a string");
        p++;
      }
    };
    const value = (depth) => {
      if (depth > 512) fail("Nested too deeply");
      ws();
      if (p >= n) fail("The file ends too early");
      const c = t[p];
      if (c === "{") {
        p++; ws();
        if (t[p] === "}") { p++; return; }
        for (;;) {
          ws();
          if (t[p] !== '"') fail("Expected a property name in double quotes");
          str(); ws();
          if (t[p] !== ":") fail("Expected ':' after a property name");
          p++;
          value(depth + 1); ws();
          if (t[p] === ",") { p++; continue; }
          if (t[p] === "}") { p++; return; }
          fail("Expected ',' or '}'");
        }
      }
      if (c === "[") {
        p++; ws();
        if (t[p] === "]") { p++; return; }
        for (;;) {
          value(depth + 1); ws();
          if (t[p] === ",") { p++; continue; }
          if (t[p] === "]") { p++; return; }
          fail("Expected ',' or ']'");
        }
      }
      if (c === '"') return str();
      for (const lit of ["true", "false", "null"]) if (t.startsWith(lit, p)) { p += lit.length; return; }
      NUM.lastIndex = p;
      const m = NUM.exec(t);
      if (m && m[0].length && m[0] !== "-") { p += m[0].length; return; }
      fail("Unexpected " + quote(c));
    };
    try {
      value(0); ws();
      if (p < n) fail("Unexpected text after the end of the board");
      return null;
    } catch (e) {
      if (e && typeof e.offset === "number") return e;
      throw e;
    }
  }

  // ---------- geometry ----------

  /**
   * Obsidian 1.13.7's rule for a missing side ($7 in app.js, docs/research/raw/boards/
   * obsidian-1.13.7-canvas-code-excerpts-2026-10-14.txt): the angle from a's centre to b's centre against a's own
   * diagonal, so a board keeps its shape after a save in Obsidian.
   */
  function sideFor(a, b) {
    const ax = a.x + a.w / 2, ay = a.y + a.h / 2, bx = b.x + b.w / 2, by = b.y + b.h / 2;
    const r = Math.atan2(by - ay, bx - ax), o = Math.atan2(a.h, a.w);
    if (r > -o && r <= o) return "right";
    if (r > o && r <= Math.PI - o) return "bottom";
    if (r > Math.PI - o || r <= -(Math.PI - o)) return "left";
    return "top";
  }

  function sidePoint(n, side) {
    switch (side) {
      case "top": return { x: n.x + n.w / 2, y: n.y };
      case "bottom": return { x: n.x + n.w / 2, y: n.y + n.h };
      case "left": return { x: n.x, y: n.y + n.h / 2 };
      default: return { x: n.x + n.w, y: n.y + n.h / 2 };
    }
  }
  const OUTWARD = { top: [0, -1], bottom: [0, 1], left: [-1, 0], right: [1, 0] };

  function makeGrid(cellSize) {
    const cells = new Map();
    const boxes = new Map();
    const overflow = [];
    const key = (cx, cy) => (cx + 1048576) * 2097152 + (cy + 1048576);
    return {
      cellSize,
      size: 0,
      overflow,
      insert(id, x, y, w, h) {
        if (!isNum(x) || !isNum(y) || !isNum(w) || !isNum(h)) return;
        boxes.set(id, [x, y, w, h]);
        this.size++;
        const x0 = Math.floor(x / cellSize), x1 = Math.floor((x + w) / cellSize);
        const y0 = Math.floor(y / cellSize), y1 = Math.floor((y + h) / cellSize);
        if ((x1 - x0 + 1) * (y1 - y0 + 1) > MAX_CELLS_PER_ITEM) { overflow.push(id); return; }
        for (let cx = x0; cx <= x1; cx++) {
          for (let cy = y0; cy <= y1; cy++) {
            const k = key(cx, cy);
            const list = cells.get(k);
            if (list) list.push(id); else cells.set(k, [id]);
          }
        }
      },
      box(id) { return boxes.get(id) || null; },
      query(x, y, w, h) {
        const out = new Set();
        const hit = (id) => {
          if (out.has(id)) return;
          const b = boxes.get(id);
          if (b[0] <= x + w && b[0] + b[2] >= x && b[1] <= y + h && b[1] + b[3] >= y) out.add(id);
        };
        for (let i = 0; i < overflow.length; i++) hit(overflow[i]);
        if (!isNum(x) || !isNum(y) || !isNum(w) || !isNum(h)) return out;
        let x0 = Math.floor(x / cellSize), x1 = Math.floor((x + w) / cellSize);
        let y0 = Math.floor(y / cellSize), y1 = Math.floor((y + h) / cellSize);
        // A query larger than the indexed world scans the boxes instead of walking empty cells.
        if ((x1 - x0 + 1) * (y1 - y0 + 1) > cells.size + 64) { for (const id of boxes.keys()) hit(id); return out; }
        for (let cx = x0; cx <= x1; cx++) {
          for (let cy = y0; cy <= y1; cy++) {
            const list = cells.get(key(cx, cy));
            if (!list) continue;
            for (let i = 0; i < list.length; i++) hit(list[i]);
          }
        }
        return out;
      },
    };
  }

  // ---------- reading order (BRD-27) ----------

  /** Rows are overlapping vertical bands; a row is read from the leading side. */
  function orderItems(ids, byId, dir) {
    const items = ids.map((id) => byId.get(id));
    items.sort((a, b) => a.y - b.y || (dir === "rtl" ? (b.x + b.w) - (a.x + a.w) : a.x - b.x));
    const rows = [];
    let row = null, bottom = -Infinity;
    for (const it of items) {
      if (!row || it.y >= bottom) { row = []; rows.push(row); bottom = it.y + it.h; }
      else bottom = Math.max(bottom, it.y + it.h);
      row.push(it);
    }
    const out = [];
    for (const r of rows) {
      r.sort(dir === "rtl" ? (a, b) => (b.x + b.w) - (a.x + a.w) || a.y - b.y : (a, b) => a.x - b.x || a.y - b.y);
      for (const it of r) out.push(it.id);
    }
    return out;
  }

  // ---------- notes ----------

  /** report(severity, subParts, message) adds a problem at the note's own sub-path. */
  function readNote(v, report) {
    if (!isObject(v)) { report("error", [], "A note is an object with area, title, body, state, refs and fields; this is " + describe(v)); return null; }
    const note = {};
    for (const k of ["area", "title", "body", "state"]) {
      if (v[k] == null) continue;
      if (typeof v[k] === "string") note[k] = v[k];
      else report("warning", [k], "The note's " + k + " should be text; ignored");
    }
    if (v.refs != null) {
      if (Array.isArray(v.refs)) {
        note.refs = [];
        v.refs.forEach((r, i) => {
          if (typeof r === "string") note.refs.push(r);
          else report("warning", ["refs", i], "A reference should be text; ignored");
        });
      } else report("warning", ["refs"], "refs should be a list of references; ignored");
    }
    if (v.fields != null) {
      if (isObject(v.fields)) {
        note.fields = Object.create(null); // a field may be called anything, __proto__ included
        for (const k of Object.keys(v.fields).sort()) {
          const f = v.fields[k];
          if (typeof f === "string" || typeof f === "number" || typeof f === "boolean") note.fields[k] = String(f);
          else report("warning", ["fields", k], "A field's value should be text; ignored");
        }
      } else report("warning", ["fields"], "fields should be an object of labelled values; ignored");
    }
    return note;
  }

  function canonicalNote(note) {
    if (!note) return "";
    return JSON.stringify([note.area || "", note.title || "", note.body || "", note.state || "", note.refs || [], note.fields ? Object.keys(note.fields).sort().map((k) => [k, note.fields[k]]) : []]);
  }

  /**
   * Keeps a note's serialised form within budget bytes: cuts the body, then drops refs and fields, then cuts the
   * title, area and state; null when not even an empty note fits. Escapes make JSON longer than the text, so each
   * cut is measured again.
   */
  function fitNote(note, budget) {
    const size = (n) => utf8Length(JSON.stringify(n));
    if (size(note) <= budget) return note;
    const out = Object.assign({}, note);
    const cut = (k) => {
      for (let guard = 0; out[k] && guard < 32; guard++) {
        const over = size(out) - budget;
        if (over <= 0) return true;
        out[k] = cutUtf8(out[k], Math.max(0, utf8Length(out[k]) - over));
      }
      if (out[k] === "") delete out[k];
      return size(out) <= budget;
    };
    if (cut("body")) return out;
    delete out.refs;
    delete out.fields;
    if (size(out) <= budget) return out;
    for (const k of ["title", "area", "state"]) if (cut(k)) return out;
    return size(out) <= budget ? out : null;
  }

  function problem(severity, path, line, message, id, file) {
    const p = { severity, path, line: line == null ? null : line, message };
    if (id != null) p.id = id;
    if (file) p.file = file;
    return p;
  }

  // ---------- parse ----------

  function emptyBoard() {
    return {
      fatal: null, dir: "ltr", title: null, eyebrow: null, words: [], tours: [],
      nodes: [], byId: new Map(), children: new Map([[null, []]]), roots: [], edges: [], edgesById: new Map(), edgesOf: new Map(),
      order: [], unplaced: [], problems: [], checkProblems: [], bounds: { x: 0, y: 0, w: 0, h: 0 }, hasLayout: false,
      grid: makeGrid(CELL), edgeGrid: makeGrid(CELL), sidecarIds: [],
    };
  }

  function fatalBoard(board, reason, list) {
    board.fatal = { reason, problems: list.slice(0, MAX_FATAL_SHOWN) };
    board.problems = list.slice();
    return board;
  }

  /**
   * parse(text, opts) -> Board. opts: { sidecarText, maxNodes, maxEdges, maxBytes, maxNodeBytes }.
   * See docs/research/raw/l2-build-plan.md ("Board model") for the shape.
   */
  function parse(text, opts) {
    const o = Object.assign({}, LIMITS, opts || {});
    if (typeof text !== "string") text = text == null ? "" : String(text);
    const sideText = typeof o.sidecarText === "string" ? o.sidecarText : null;
    const board = emptyBoard();
    const problems = board.problems;
    const lines = lineIndex(text);

    // The byte limit counts the board and its notes file together (BRD-20).
    const totalBytes = utf8Length(text) + (sideText ? utf8Length(sideText) : 0);
    const overBytes = totalBytes > o.maxBytes ? totalBytes : null;
    if (overBytes && overBytes > o.maxBytes * 10) {
      return fatalBoard(board, "limits", [problem("error", "$", 1, "This board and its notes are " + Math.round(overBytes / 1e6) + " MB; Linen reads boards up to " + Math.round(o.maxBytes / 1e6) + " MB")]);
    }

    // A new Obsidian canvas can be an empty file, and JSON Canvas makes both lists optional: an empty board.
    let data = {};
    let tree = null;
    if (/\S/.test(text)) {
      try {
        data = JSON.parse(text);
      } catch (e) {
        const err = findJSONError(text) || { offset: 0, message: String((e && e.message) || e) };
        const pr = problem("error", "$", lines.line(err.offset), "Not valid JSON: " + err.message);
        pr.column = lines.column(err.offset);
        return fatalBoard(board, "json", [pr]);
      }
      if (!isObject(data)) {
        return fatalBoard(board, "shape", [problem("error", "$", 1, "A board is a JSON object with nodes and edges; this file holds " + describe(data))]);
      }
      tree = scanTree(text, 5);
    }
    const lineAt = (parts) => lines.line(resolve(tree, parts));
    const P = (severity, parts, message, id) => problems.push(problem(severity, pathOf(parts), lineAt(parts), message, id));
    const PC = (severity, parts, message, id) => board.checkProblems.push(problem(severity, pathOf(parts), lineAt(parts), message, id));

    const shapeProblems = [];
    for (const k of ["nodes", "edges"]) {
      if (data[k] !== undefined && !Array.isArray(data[k])) {
        shapeProblems.push(problem("error", "$." + k, lineAt([k]), k + " should be a list; this is " + describe(data[k])));
      }
    }
    if (shapeProblems.length) return fatalBoard(board, "shape", shapeProblems);
    const rawNodes = data.nodes || [];
    const rawEdges = data.edges || [];

    // ----- the canvas's own linen object -----
    const L = data.linen;
    let customWords = null;
    let explicitDir = null;
    if (L !== undefined && !isObject(L)) P("warning", ["linen"], "linen should be an object; ignored");
    else if (L) {
      if (L.dir != null) {
        if (L.dir === "ltr" || L.dir === "rtl") explicitDir = L.dir;
        else P("warning", ["linen", "dir"], "dir is ltr or rtl; ignored " + quote(L.dir));
      }
      for (const k of ["title", "eyebrow"]) {
        if (L[k] == null) continue;
        if (typeof L[k] === "string") board[k] = L[k];
        else P("warning", ["linen", k], k + " should be text; ignored");
      }
      if (L.tours != null) {
        if (Array.isArray(L.tours)) board.tours = L.tours.filter((t, i) => {
          if (isObject(t)) return true;
          P("warning", ["linen", "tours", i], "A tour is an object with a title and steps; ignored");
          return false;
        });
        else P("warning", ["linen", "tours"], "tours should be a list; ignored");
      }
      if (L.words != null) {
        if (!Array.isArray(L.words)) P("error", ["linen", "words"], "words should be a list of at most six words; the default words are used");
        else customWords = L.words;
      }
    }

    // ----- words (WORDS-1 to WORDS-3) -----
    if (customWords) {
      const seen = new Set();
      let quietSeen = false;
      customWords.forEach((w, i) => {
        const at = ["linen", "words", i];
        if (!isObject(w) || typeof w.word !== "string" || !w.word.trim()) {
          P("error", at, "A word is an object with a word, a shape and an optional meaning; skipped");
          return;
        }
        const word = w.word.trim();
        if (seen.has(word.toLowerCase())) { P("warning", at, "The word " + quote(word) + " is listed twice; the first is kept"); return; }
        if (board.words.length >= 6) { P("error", at, "A board has at most six words; " + quote(word) + " is not used"); return; }
        let shape = w.shape;
        if (WORD_SHAPES.indexOf(shape) === -1) {
          P("error", at.concat("shape"), "A word's shape is one of " + WORD_SHAPES.join(", ") + "; " + quote(word) + " is drawn as an outline");
          shape = "outline";
        }
        let quiet = false;
        if (w.quiet != null) {
          if (typeof w.quiet !== "boolean") P("warning", at.concat("quiet"), "quiet is true or false; " + quote(word) + " shows its pill");
          else if (w.quiet && quietSeen) P("warning", at.concat("quiet"), "Only one word may be quiet; " + quote(word) + " shows its pill");
          else quiet = w.quiet;
        }
        if (quiet) quietSeen = true;
        let meaning = null;
        if (w.meaning != null) {
          if (typeof w.meaning === "string") meaning = w.meaning;
          else P("warning", at.concat("meaning"), "A word's meaning should be text; ignored");
        }
        if (shape === "rust" && !((meaning && FAILURE_WORDS.test(meaning)) || FAILURE_WORDS.test(String(word)))) PC("warning", at, "Rust is for failures; the meaning of " + quote(word) + " does not say it failed");
        seen.add(word.toLowerCase());
        board.words.push({ word, shape, meaning, quiet, count: 0 });
      });
    } else {
      board.words = DEFAULT_WORDS.map((w) => Object.assign({ count: 0 }, w));
    }
    const wordIndex = new Map();
    board.words.forEach((w) => { wordIndex.set(w.word, w); wordIndex.set(w.word.toLowerCase(), w); });

    // ----- sidecar notes (NOTE-2) -----
    const sidecar = new Map();
    let sideTree = null, sideLines = null;
    const SP = (severity, parts, message, id) => {
      problems.push(problem(severity, pathOf(parts), sideLines ? sideLines.line(resolve(sideTree, parts)) : 1, message, id, "sidecar"));
    };
    if (sideText && /\S/.test(sideText)) {
      sideLines = lineIndex(sideText);
      let sd = null;
      try { sd = JSON.parse(sideText); } catch (e) {
        const err = findJSONError(sideText) || { offset: 0, message: String(e) };
        const pr = problem("error", "$", sideLines.line(err.offset), "The notes file is not valid JSON: " + err.message + "; its notes are not shown", null, "sidecar");
        pr.column = sideLines.column(err.offset);
        problems.push(pr);
      }
      if (sd !== null) {
        if (!isObject(sd)) SP("error", [], "The notes file is an object keyed by node or edge id; its notes are not shown");
        else {
          sideTree = scanTree(sideText, 3);
          for (const id of Object.keys(sd)) {
            const note = readNote(sd[id], (sev, sub, msg) => SP(sev, [id].concat(sub), msg, id));
            if (note) sidecar.set(id, note);
          }
        }
      }
    }
    board.sidecarIds = Array.from(sidecar.keys());

    // ----- nodes -----
    const byId = board.byId;
    const nodesBox = tree && tree.obj ? tree.c.nodes : null;
    let dirSource = board.title || "";
    rawNodes.forEach((raw, i) => {
      const at = (...parts) => ["nodes", i].concat(parts);
      const line = nodesBox && nodesBox.a[i] != null ? [lines.line(nodesBox.a[i]), lines.line(Math.max(nodesBox.a[i], nodesBox.ae[i] - 1))] : null;
      if (!isObject(raw)) { P("error", at(), "Not a node: " + describe(raw) + "; skipped"); return; }
      if (typeof raw.id !== "string" || raw.id === "") { P("error", at("id"), "A node without an id; skipped"); return; }
      const id = raw.id;
      if (byId.has(id)) { P("error", at("id"), "Duplicate id " + quote(id) + "; the first is kept", id); return; }
      const type = raw.type;
      const known = typeof type === "string" && SPEC_TYPES.indexOf(type) !== -1;
      // Fields that carry the content must have the right type, or the entry is skipped (BRD-1).
      for (const field of ["text", "file", "url"]) {
        if (raw[field] !== undefined && typeof raw[field] !== "string") {
          P("error", at(field), field + " should be text; this is " + describe(raw[field]) + "; node skipped", id);
          return;
        }
      }
      if (type === "file" && typeof raw.file !== "string") { P("error", at("file"), "A file node without a file; skipped", id); return; }
      if (type === "link" && typeof raw.url !== "string") { P("error", at("url"), "A link node without a url; skipped", id); return; }

      const node = {
        id, type: known ? type : (typeof type === "string" ? type : null), kind: "card", shape: null,
        x: null, y: null, w: null, h: null, placed: false,
        title: null, body: null, text: null, file: null, subpath: null, url: null, label: null, color: null, eyebrow: null,
        background: null, backgroundStyle: null,
        word: null, note: null, noteFrom: null, parent: null, depth: 0, layout: null, cols: null, gap: null,
        dir: null, hash: null, line, jsonPath: pathOf(at()), index: i, truncated: false,
      };
      if (!known) {
        node.kind = "unknown";
        P("error", at("type"), (type == null ? "A node without a type" : "Unknown type " + quote(type)) + "; Obsidian drops it, so Linen does not place it", id);
      }

      // Position and size: without them, or out of all reason, the node is listed as unplaced (BRD-1).
      let placeOK = known;
      if (known) {
        for (const [k, name] of [["x", "position"], ["y", "position"], ["width", "size"], ["height", "size"]]) {
          if (!isNum(raw[k])) {
            P("error", at(k), "A node without its " + name + " (" + k + "); run `linen layout` on this board", id);
            placeOK = false;
            break;
          }
        }
        if (placeOK && (raw.width <= 0 || raw.height <= 0)) {
          P("error", at(raw.width <= 0 ? "width" : "height"), "A node with no size; not placed", id);
          placeOK = false;
        }
        if (placeOK) {
          const far = [["x", raw.x, MAX_COORD], ["y", raw.y, MAX_COORD], ["width", raw.width, MAX_SIZE], ["height", raw.height, MAX_SIZE]].find((f) => Math.abs(f[1]) > f[2]);
          if (far) {
            P("error", at(far[0]), "A " + (far[0] === "x" || far[0] === "y" ? "position" : "size") + " of " + far[1] + " is too far out to draw; not placed", id);
            placeOK = false;
          }
        }
        if (placeOK && [raw.x, raw.y, raw.width, raw.height].some((v) => v !== Math.round(v))) {
          PC("warning", at(), "Positions and sizes are whole numbers in JSON Canvas; Obsidian rounds them", id);
        }
      }
      if (placeOK) { node.x = raw.x; node.y = raw.y; node.w = raw.width; node.h = raw.height; node.placed = true; }

      // Cosmetic fields of the wrong type are ignored with a warning.
      if (raw.color != null) {
        if (typeof raw.color === "string" && /^([1-6]|#[0-9a-fA-F]{3}|#[0-9a-fA-F]{6}|#[0-9a-fA-F]{8})$/.test(raw.color)) node.color = raw.color;
        else P("warning", at("color"), "A colour is a preset 1 to 6 or a hex like #A1B2C3; ignored", id);
      }

      const NL = raw.linen;
      let ln = {};
      if (NL !== undefined) {
        if (isObject(NL)) ln = NL;
        else P("warning", at("linen"), "linen should be an object; ignored", id);
      }
      const lnString = (k) => {
        if (ln[k] == null) return null;
        if (typeof ln[k] === "string") return ln[k];
        P("warning", at("linen", k), k + " should be text; ignored", id);
        return null;
      };

      // The board's direction reads the text as written, before any cut (documentDirection reads the source).
      if (dirSource.length < DOC_DIR_CHARS) {
        for (const s of [raw.text, raw.label, ln.title]) if (typeof s === "string") dirSource += "\n" + s;
      }

      // The note, wherever it lives (BRD-6, NOTE-2).
      if (ln.note !== undefined) {
        const note = readNote(ln.note, (sev, sub, msg) => P(sev, at("linen", "note", ...sub), msg, id));
        if (note) { node.note = note; node.noteFrom = "board"; }
      }
      if (sidecar.has(id)) {
        if (node.note) P("error", at("linen", "note"), "The note for " + quote(id) + " is in the board and in the notes file; the board's note is shown", id);
        else { node.note = sidecar.get(id); node.noteFrom = "sidecar"; }
      }

      // Bytes per node (BRD-20): the text and the note together, cut on UTF-8 boundaries.
      let t = type === "text" ? raw.text : undefined;
      const noteLen = node.note ? JSON.stringify(node.note).length : 0;
      if (((t ? t.length : 0) + noteLen) * 3 > o.maxNodeBytes) {
        const tb = t ? utf8Length(t) : 0, nb = node.note ? utf8Length(JSON.stringify(node.note)) : 0;
        if (tb + nb > o.maxNodeBytes) {
          P("error", at(), "This node is " + Math.round((tb + nb) / 1024) + " KB; Linen draws its first " + Math.round(o.maxNodeBytes / 1024) + " KB", id);
          node.truncated = true;
          // The note may keep up to half the budget and the text the rest, so a long text never pushes a short note out.
          const noteShare = Math.min(nb, Math.floor(o.maxNodeBytes / 2));
          if (t && tb > o.maxNodeBytes - noteShare) t = cutUtf8(t, o.maxNodeBytes - noteShare);
          if (node.note) {
            node.note = fitNote(node.note, o.maxNodeBytes - (t ? utf8Length(t) : 0));
            if (!node.note) node.noteFrom = null;
          }
        }
      }

      if (type === "text") {
        if (t === undefined) { P("warning", at("text"), "A text node without text", id); t = ""; }
        node.text = t;
        const kind = lnString("kind");
        if (kind != null) {
          if (TEXT_KINDS.indexOf(kind) !== -1) node.kind = kind;
          else P("warning", at("linen", "kind"), "kind is one of " + TEXT_KINDS.join(", ") + "; drawn as a card", id);
        }
        if (node.kind === "shape") {
          const sh = lnString("shape");
          node.shape = sh && SHAPES.indexOf(sh) !== -1 ? sh : "rect";
          if (sh && SHAPES.indexOf(sh) === -1) P("warning", at("linen", "shape"), "shape is one of " + SHAPES.join(", ") + "; drawn as a rectangle", id);
        }
        const title = lnString("title");
        if (title != null) { node.title = title; node.body = t; }
        else if (node.kind === "card") {
          const nl = t.indexOf("\n");
          const first = (nl === -1 ? t : t.slice(0, nl)).replace(/\r$/, "");
          const m = /^#{1,2}[ \t]+(.*?)[ \t]*#*[ \t]*$/.exec(first);
          if (m && m[1]) { node.title = m[1]; node.body = nl === -1 ? "" : t.slice(nl + 1).replace(/^(?:[ \t]*\r?\n)+/, ""); }
          else node.body = t;
        } else node.body = t;
      } else if (type === "file") {
        node.file = raw.file;
        if (raw.subpath != null) {
          if (typeof raw.subpath === "string") node.subpath = raw.subpath;
          else P("warning", at("subpath"), "subpath should be text; ignored", id);
        }
        const base = raw.file.split("/").pop();
        const dot = base.lastIndexOf(".");
        const ext = dot > 0 ? base.slice(dot + 1).toLowerCase() : "";
        node.kind = NOTE_EXT.indexOf(ext) !== -1 ? "note" : ext === "canvas" ? "board" : ext === "html" || ext === "htm" ? "page" : IMAGE_EXT.indexOf(ext) !== -1 ? "image" : "file";
        node.title = lnString("title") || (dot > 0 ? base.slice(0, dot) : base);
      } else if (type === "link") {
        node.kind = "link";
        node.url = raw.url;
        node.title = lnString("title");
      } else if (type === "group") {
        node.kind = "section";
        if (raw.label != null) {
          if (typeof raw.label === "string") node.label = raw.label;
          else P("warning", at("label"), "label should be text; ignored", id);
        }
        if (typeof raw.background === "string") node.background = raw.background;
        if (typeof raw.backgroundStyle === "string") node.backgroundStyle = raw.backgroundStyle;
        node.title = lnString("title");
        const lay = lnString("layout");
        if (lay != null) {
          if (LAYOUTS.indexOf(lay) !== -1) { node.layout = lay; board.hasLayout = true; }
          else P("warning", at("linen", "layout"), "layout is one of " + LAYOUTS.join(", ") + "; ignored", id);
        }
        for (const k of ["cols", "gap"]) {
          if (ln[k] == null) continue;
          if (Number.isInteger(ln[k]) && ln[k] >= (k === "cols" ? 1 : 0) && ln[k] <= MAX_SIZE) node[k] = ln[k];
          else P("warning", at("linen", k), k + " should be a whole number" + (k === "cols" ? " of 1 or more" : "") + "; ignored", id);
        }
      }
      if (type !== "text" && ln.kind != null) P("warning", at("linen", "kind"), "kind applies to text nodes only; ignored", id);
      if (type !== "group" && ln.layout != null) P("warning", at("linen", "layout"), "layout applies to sections only; ignored", id);
      node.eyebrow = lnString("eyebrow");

      const word = lnString("word");
      if (word != null && word.trim()) {
        const w = wordIndex.get(word.trim()) || wordIndex.get(word.trim().toLowerCase());
        if (w) { node.word = w.word; w.count++; }
        else {
          node.word = word.trim();
          P("warning", at("linen", "word"), "The word " + quote(word) + " is not one of this board's words", id);
        }
      }

      byId.set(id, node);
      board.nodes.push(node);
      if (!node.placed) board.unplaced.push(id);
    });

    // ----- edges -----
    const edgesById = board.edgesById;
    const edgesBox = tree && tree.obj ? tree.c.edges : null;
    rawEdges.forEach((raw, i) => {
      const at = (...parts) => ["edges", i].concat(parts);
      const line = edgesBox && edgesBox.a[i] != null ? [lines.line(edgesBox.a[i]), lines.line(Math.max(edgesBox.a[i], edgesBox.ae[i] - 1))] : null;
      if (!isObject(raw)) { P("error", at(), "Not an edge: " + describe(raw) + "; skipped"); return; }
      if (typeof raw.id !== "string" || raw.id === "") { P("error", at("id"), "An edge without an id; skipped"); return; }
      const id = raw.id;
      if (edgesById.has(id)) { P("error", at("id"), "Duplicate edge id " + quote(id) + "; the first is kept", id); return; }
      // Ids are one namespace in Linen: change marks, notes files and references are keyed by id alone.
      if (byId.has(id)) { P("error", at("id"), "An edge uses the id " + quote(id) + " of a node; ids are unique across nodes and edges; skipped", id); return; }
      for (const k of ["fromNode", "toNode"]) {
        if (typeof raw[k] !== "string") {
          P("error", at(k), raw[k] === undefined ? "An edge without " + k + "; skipped" : k + " should be a node id; skipped", id);
          return;
        }
      }
      const edge = {
        id, from: raw.fromNode, to: raw.toNode, fromSide: null, toSide: null, sidesFilled: false,
        fromEnd: "none", toEnd: "arrow", label: null, color: null, kind: "works", route: "curved", note: null, noteFrom: null,
        hash: null, missing: null, drawable: false, stub: null, p1: null, p2: null, box: null, line, jsonPath: pathOf(at()), index: i, truncated: false,
      };
      for (const k of ["fromSide", "toSide"]) {
        if (raw[k] == null) continue;
        if (SIDES.indexOf(raw[k]) !== -1) edge[k] = raw[k];
        else P("warning", at(k), k + " is top, right, bottom or left; picked by angle instead", id);
      }
      for (const k of ["fromEnd", "toEnd"]) {
        if (raw[k] == null) continue;
        if (ENDS.indexOf(raw[k]) !== -1) edge[k] = raw[k];
        else P("warning", at(k), k + " is none or arrow; the default is used", id);
      }
      if (raw.label != null) {
        if (typeof raw.label === "string") edge.label = raw.label;
        else P("warning", at("label"), "label should be text; ignored", id);
      }
      if (raw.color != null) {
        if (typeof raw.color === "string" && /^([1-6]|#[0-9a-fA-F]{3}|#[0-9a-fA-F]{6}|#[0-9a-fA-F]{8})$/.test(raw.color)) edge.color = raw.color;
        else P("warning", at("color"), "A colour is a preset 1 to 6 or a hex like #A1B2C3; ignored", id);
      }
      const EL = raw.linen;
      if (EL !== undefined) {
        if (!isObject(EL)) P("warning", at("linen"), "linen should be an object; ignored", id);
        else {
          if (EL.kind != null) {
            if (EDGE_KINDS.indexOf(EL.kind) !== -1) edge.kind = EL.kind;
            else P("warning", at("linen", "kind"), "A connector's kind is one of " + EDGE_KINDS.join(", ") + "; drawn as works", id);
          }
          if (EL.route != null) {
            if (ROUTES.indexOf(EL.route) !== -1) edge.route = EL.route;
            else P("warning", at("linen", "route"), "route is one of " + ROUTES.join(", ") + "; drawn curved", id);
          }
          if (EL.note !== undefined) {
            const note = readNote(EL.note, (sev, sub, msg) => P(sev, at("linen", "note", ...sub), msg, id));
            if (note) { edge.note = note; edge.noteFrom = "board"; }
          }
        }
      }
      if (sidecar.has(id)) {
        if (edge.note) P("error", at("linen", "note"), "The note for " + quote(id) + " is in the board and in the notes file; the board's note is shown", id);
        else { edge.note = sidecar.get(id); edge.noteFrom = "sidecar"; }
      }
      if (edge.note && JSON.stringify(edge.note).length * 3 > o.maxNodeBytes && utf8Length(JSON.stringify(edge.note)) > o.maxNodeBytes) {
        P("error", at(), "This edge's note is over " + Math.round(o.maxNodeBytes / 1024) + " KB; Linen shows its first part", id);
        edge.note = fitNote(edge.note, o.maxNodeBytes);
        if (!edge.note) edge.noteFrom = null;
        edge.truncated = true;
      }
      const a = byId.get(edge.from), b = byId.get(edge.to);
      if (!a || !b) {
        edge.missing = !a && !b ? "both" : !a ? "from" : "to";
        const which = !a && !b ? quote(edge.from) + " and " + quote(edge.to) : !a ? quote(edge.from) : quote(edge.to);
        const where = !a ? "fromNode" : "toNode";
        P("error", at(where), "This edge ends at " + (!a && !b ? "missing nodes " : "a missing node ") + which + "; Obsidian drops it", id);
      }
      const aP = !!(a && a.placed), bP = !!(b && b.placed);
      if (aP && bP) {
        if (!edge.fromSide) { edge.fromSide = sideFor(a, b); edge.sidesFilled = true; }
        if (!edge.toSide) { edge.toSide = sideFor(b, a); edge.sidesFilled = true; }
        edge.p1 = sidePoint(a, edge.fromSide);
        edge.p2 = sidePoint(b, edge.toSide);
        edge.drawable = true;
      } else if (aP || bP) {
        // One end on the board: a short stub out of its side to the gap mark (BRD-4), so it is drawn and indexed.
        const n = aP ? a : b;
        const side = aP ? edge.fromSide || "right" : edge.toSide || "left";
        if (aP) edge.fromSide = side; else edge.toSide = side;
        const p = sidePoint(n, side), d = OUTWARD[side];
        const q = { x: p.x + d[0] * STUB, y: p.y + d[1] * STUB };
        edge.p1 = aP ? p : q;
        edge.p2 = aP ? q : p;
        edge.stub = aP ? "to" : "from";
      }
      edgesById.set(id, edge);
      board.edges.push(edge);
    });

    // Sidecar ids that match nothing (NOTE-2).
    for (const id of sidecar.keys()) {
      if (!byId.has(id) && !edgesById.has(id)) SP("warning", [id], "A note for " + quote(id) + ", which is not on this board", id);
    }

    // ----- connections and hashes (BRD-13: content only, never position or size) -----
    const conns = new Map();
    const edgesOf = board.edgesOf;
    const addTo = (map, k, v) => { const l = map.get(k); if (l) l.push(v); else map.set(k, [v]); };
    for (const e of board.edges) {
      const lab = e.label || "";
      // Each end that exists records the connection, even when the other end is missing.
      if (byId.has(e.from)) { addTo(conns, e.from, ">" + e.kind + ":" + e.to + ":" + lab); addTo(edgesOf, e.from, e.id); }
      if (byId.has(e.to)) { addTo(conns, e.to, "<" + e.kind + ":" + e.from + ":" + lab); if (e.to !== e.from) addTo(edgesOf, e.to, e.id); }
      e.hash = hashString([e.from, e.to, e.kind, lab, e.color || "", e.fromEnd, e.toEnd, canonicalNote(e.note)].join("\u0001"));
    }
    for (const n of board.nodes) {
      const c = conns.get(n.id);
      n.hash = hashString([
        n.kind, n.type || "", n.shape || "", n.title || "", n.body == null ? n.text || "" : n.body, n.file || "", n.subpath || "", n.url || "",
        n.label || "", n.word || "", canonicalNote(n.note), n.color || "", n.eyebrow || "", n.background || "", c ? c.sort().join("\u0002") : "",
      ].join("\u0001"));
    }

    // ----- direction (BRD-27 with Linen 1's ARB-1): the board's from all its text, then each node's -----
    board.dir = explicitDir || documentDirection(dirSource.slice(0, DOC_DIR_CHARS));
    // With marked loaded each node's direction is read from its tokens when first asked for (lexing every card up
    // front would cost the parse its budget); without it, from the source-level mirror, at once.
    const lexer = hasLexer();
    for (const n of board.nodes) {
      const src = [n.title, n.body, n.label].filter(Boolean).join("\n");
      if (!lexer) { n.dir = proseDirection(src, board.dir); continue; }
      let cached;
      Object.defineProperty(n, "dir", {
        enumerable: true, configurable: true,
        get() { if (cached === undefined) cached = blockDirection(src, board.dir); return cached; },
        set(v) { cached = v; },
      });
    }

    // ----- sections: the smallest section holding a node's centre; a section's parent always ranks above it -----
    const placed = board.nodes.filter((n) => n.placed);
    // Rank: smaller area first; between equal areas the later node (drawn on top) first, so the earlier one contains it.
    const groups = placed.filter((n) => n.kind === "section").sort((a, b) => a.w * a.h - b.w * b.h || b.index - a.index);
    const rank = new Map(groups.map((g, k) => [g.id, k]));
    for (const n of placed) {
      const cx = n.x + n.w / 2, cy = n.y + n.h / 2;
      for (let k = rank.has(n.id) ? rank.get(n.id) + 1 : 0; k < groups.length; k++) {
        const g = groups[k];
        if (cx >= g.x && cx <= g.x + g.w && cy >= g.y && cy <= g.y + g.h) { n.parent = g.id; break; }
      }
    }
    // Parents rank above their sections, so walking from the top rank down gives every depth in one pass.
    const depth = new Map();
    for (let k = groups.length - 1; k >= 0; k--) {
      const g = groups[k];
      g.depth = g.parent ? depth.get(g.parent) + 1 : 0;
      depth.set(g.id, g.depth);
    }
    for (const n of placed) if (n.kind !== "section") n.depth = n.parent ? depth.get(n.parent) + 1 : 0;
    const kids = new Map([[null, []]]);
    for (const n of placed) addTo(kids, n.parent, n.id);
    const children = board.children;
    for (const [k, ids] of kids) children.set(k, orderItems(ids, byId, board.dir));
    for (const g of groups) if (!children.has(g.id)) children.set(g.id, []);
    board.roots = children.get(null);
    const order = board.order;
    const stack = [[board.roots, 0]];
    while (stack.length) {
      const top = stack[stack.length - 1];
      if (top[1] >= top[0].length) { stack.pop(); continue; }
      const id = top[0][top[1]++];
      order.push(id);
      const sub = children.get(id);
      if (sub && sub.length && byId.get(id).kind === "section") stack.push([sub, 0]);
    }
    for (const id of board.unplaced) order.push(id);

    // ----- bounds and spatial indexes (BRD-20) -----
    if (placed.length) {
      let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
      for (const n of placed) {
        if (n.x < x0) x0 = n.x;
        if (n.y < y0) y0 = n.y;
        if (n.x + n.w > x1) x1 = n.x + n.w;
        if (n.y + n.h > y1) y1 = n.y + n.h;
        board.grid.insert(n.id, n.x, n.y, n.w, n.h);
      }
      board.bounds = { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
    }
    for (const e of board.edges) {
      if (!e.p1) continue;
      const len = Math.hypot(e.p2.x - e.p1.x, e.p2.y - e.p1.y);
      const pad = e.stub ? 24 : Math.min(250, 40 + 0.25 * len);
      const x = Math.min(e.p1.x, e.p2.x) - pad, y = Math.min(e.p1.y, e.p2.y) - pad;
      e.box = { x, y, w: Math.abs(e.p2.x - e.p1.x) + 2 * pad, h: Math.abs(e.p2.y - e.p1.y) + 2 * pad };
      board.edgeGrid.insert(e.id, e.box.x, e.box.y, e.box.w, e.box.h);
    }

    // ----- limits (BRD-20) on what was accepted: past them the canvas is fatal, but all stays parsed for List view -----
    const limitProblems = [];
    if (overBytes) limitProblems.push(problem("error", "$", 1, "This board and its notes are " + (overBytes / 1e6).toFixed(1) + " MB; Linen draws boards up to " + (o.maxBytes / 1e6).toFixed(0) + " MB"));
    if (board.nodes.length > o.maxNodes) limitProblems.push(problem("error", "$.nodes", lineAt(["nodes"]), "This board has " + board.nodes.length + " nodes; Linen draws up to " + o.maxNodes));
    if (board.edges.length > o.maxEdges) limitProblems.push(problem("error", "$.edges", lineAt(["edges"]), "This board has " + board.edges.length + " edges; Linen draws up to " + o.maxEdges));
    if (limitProblems.length) {
      board.problems = limitProblems.concat(problems);
      board.fatal = { reason: "limits", problems: board.problems.slice(0, MAX_FATAL_SHOWN) };
    }
    return board;
  }

  /** `linen check` for a board (CLI-2): the parse problems plus the check-only rules, by line. */
  function check(board) {
    if (board.fatal && board.fatal.reason !== "limits") return board.problems.slice();
    const all = board.problems.concat(board.checkProblems || []);
    const rank = (p) => (p.file === "sidecar" ? 1 : 0);
    return all.map((p, i) => [p, i]).sort((a, b) => rank(a[0]) - rank(b[0]) || (a[0].line || 0) - (b[0].line || 0) || a[1] - b[1]).map((x) => x[0]);
  }

  root.LinenCanvas = {
    parse, check, hashString, sideFor, sidePoint, findJSONError, blockDirection, proseDirection, documentDirection, letters, utf8Length, cutUtf8,
    DEFAULT_WORDS: DEFAULT_WORDS.map((w) => Object.assign({}, w)),
    SPEC_TYPES, TEXT_KINDS, SHAPES, WORD_SHAPES, EDGE_KINDS, ROUTES, LAYOUTS, LIMITS,
  };
})(typeof self !== "undefined" ? self : globalThis);
