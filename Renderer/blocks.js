// Loom blocks, words and notes in notes (PRD-2 BLK-0 to BLK-7, WORDS-1 to WORDS-3, NOTE-1 to NOTE-3; syntax in
// docs/FORMAT.md). Fenced blocks with YAML-subset bodies (tiles, cards, steps, bar, side) become Loom's components;
// :w[Word] draws a status pill; :note[term]{#id}, footnotes and noted tiles and cards open a solid paper note card. The
// page calls configure() with the frontmatter and the sidecar notes, expand() on each rendered block, header() for the
// note's eyebrow and lead, and finish() once the document is on the page. check() is pure (no DOM) so `linen check`
// can run it in JavaScriptCore; it and the renderer share one validator, so what checks clean renders as checked.
(function (root) {
  "use strict";

  const LANGS = new Set(["tiles", "cards", "steps", "bar", "side"]);
  const KEYS = {
    tiles: { top: ["size", "cols", "items"], item: ["label", "value", "note", "word"] },
    cards: { top: ["cols", "items"], item: ["eyebrow", "title", "body", "tone", "number", "word", "note", "link"] },
    steps: { top: ["kind", "items", "current", "value", "of", "label"], item: ["label", "title"] },
    bar: { top: ["items", "label"], item: ["word", "count"] },
  };
  const SHAPES = ["outline", "threads", "solid", "dashed", "dotted", "rust"];
  const TONES = ["paper", "tint", "ink", "dashed", "sticky"];
  const DEFAULT_WORDS = [
    { word: "Works", shape: "outline", quiet: true }, { word: "Partial", shape: "threads" }, { word: "Broken", shape: "rust" },
    { word: "Missing", shape: "dashed" }, { word: "Planned", shape: "dotted" },
  ];
  // A rust word must mean failure (WORDS-2); `linen check` warns when its meaning does not say so.
  const FAILS = /fail|broke|error|down|stops?|refus|block|crash|wrong|dead|لا يعمل|معطل|فشل|خطأ|متوقف|مرفوض/i;
  // Ids anywhere (notes, table rows): any run of characters that is not space or a brace, any script.
  const ID = "[^\\s{}]+";
  const hasOwn = (o, k) => o != null && Object.prototype.hasOwnProperty.call(o, k);
  const MAX_YAML = 64 * 1024, MAX_DEPTH = 32, MAX_NODES = 5000;

  // ---------- the page's words in English and Arabic (ARB-4), numbers in the interface's digits ----------
  const AR = {
    "Note {n}": "ملاحظة {n}", "Sources": "المصادر", "{a} of {b}": "{a} من {b}",
    "This block could not be read: {e}": "تعذّرت قراءة هذا الجزء: {e}", "Step {a} of {b}": "الخطوة {a} من {b}",
    "Copied": "نُسخ", "Level {a} of {b}": "المستوى {a} من {b}", "Words in this note": "كلمات هذه الملاحظة",
  };
  const isAr = () => typeof document !== "undefined" && document.documentElement.lang === "ar";
  const t = (key, vars) => {
    let out = (isAr() && AR[key]) || key;
    for (const [k, v] of Object.entries(vars || {})) out = out.replaceAll(`{${k}}`, v);
    return out;
  };
  // "ar" alone formats with Western digits in this WebKit; the numbering system is asked for by name.
  const num = (n) => Number(n).toLocaleString(isAr() ? "ar-u-nu-arab" : "en");
  const esc = (s) => String(s == null ? "" : s).replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;").replaceAll("'", "&#39;");
  const ARABIC = /[؀-ۿ]/;

  // ---------- the YAML subset (FORMAT.md): block maps and lists, flow maps and lists, quoted, plain (with
  // continuation lines) and block scalars. No anchors, aliases or tags. Bounded: 64 KB, 32 levels, 5,000 nodes. ----------
  class YAMLError extends Error { constructor(line, message) { super(message); this.line = line; } }

  function stripComment(s) {
    let q = null;
    for (let i = 0; i < s.length; i++) {
      const c = s[i];
      if (q) { if (c === "\\" && q === '"') i++; else if (c === q) q = null; continue; }
      if (c === '"' || c === "'") { if (i === 0 || /[\s:[{,-]/.test(s[i - 1])) q = c; continue; }
      if (c === "#" && (i === 0 || /\s/.test(s[i - 1]))) return s.slice(0, i);
    }
    return s;
  }
  function scalar(raw) {
    const s = raw.trim();
    if (s === "" || s === "~" || s === "null") return null;
    if (s === "true") return true;
    if (s === "false") return false;
    if (/^-?\d+(\.\d+)?$/.test(s)) return Number(s);
    if (/^[&*!]/.test(s)) throw new YAMLError(0, "anchors, aliases and tags are not read; quote the value");
    return s;
  }
  function unquoteDouble(s, line) {
    if (s.length < 2 || s[s.length - 1] !== '"') throw new YAMLError(line, "a quoted value does not close");
    let out = "";
    for (let i = 1; i < s.length - 1; i++) {
      const c = s[i];
      if (c !== "\\") { out += c; continue; }
      const n = s[++i];
      if (n === "u" || n === "x") { const len = n === "u" ? 4 : 2; out += String.fromCharCode(parseInt(s.slice(i + 1, i + 1 + len), 16)); i += len; }
      else out += { n: "\n", t: "\t", r: "\r", "0": "\0", "/": "/", "\\": "\\", '"': '"', " ": " " }[n] ?? n;
    }
    return out;
  }
  function parseYAML(text) {
    const src = String(text);
    if (src.length > MAX_YAML) throw new YAMLError(1, `more than ${MAX_YAML / 1024} KB in one block`);
    let nodes = 0;
    const count = (line) => { if (++nodes > MAX_NODES) throw new YAMLError(line, `more than ${MAX_NODES} values in one block`); };
    const deep = (d, line) => { if (d > MAX_DEPTH) throw new YAMLError(line, `nested more than ${MAX_DEPTH} levels deep`); };

    function parseFlow(s, line, depth0) {
      let i = 0;
      const fail = (m) => { throw new YAMLError(line, m); };
      const ws = () => { while (i < s.length && (s[i] === " " || s[i] === "\t")) i++; };
      function quoted() {
        const q = s[i];
        let j = i + 1;
        for (; j < s.length; j++) { if (q === '"' && s[j] === "\\") { j++; continue; } if (s[j] === q) { if (q === "'" && s[j + 1] === "'") { j++; continue; } break; } }
        if (j >= s.length) fail("a quoted value does not close");
        const tx = s.slice(i, j + 1);
        i = j + 1;
        return q === '"' ? unquoteDouble(tx, line) : tx.slice(1, -1).replaceAll("''", "'");
      }
      function plain(stops) {
        const start = i;
        while (i < s.length) {
          const c = s[i];
          if (stops.includes(c) && c !== ":") break;
          if (c === ":" && stops.includes(":") && (s[i + 1] === " " || s[i + 1] === undefined || s[i + 1] === "," || s[i + 1] === "}")) break;
          if ((c === "[" || c === "{") && i === start) break;
          i++;
        }
        return s.slice(start, i).trim();
      }
      function value(stops, depth) {
        deep(depth, line);
        count(line);
        ws();
        if (s.startsWith("[[", i)) { const j = s.indexOf("]]", i); if (j > i) { const v = s.slice(i, j + 2); i = j + 2; return v; } }
        if (s[i] === "{") {
          i++;
          const o = {};
          ws();
          if (s[i] === "}") { i++; return o; }
          for (;;) {
            ws();
            const k = s[i] === '"' || s[i] === "'" ? quoted() : plain([":", ",", "}"]);
            ws();
            if (s[i] !== ":") fail(`expected ":" after ${k || "a key"}`);
            i++;
            const v = value([",", "}"], depth + 1);
            if (hasOwn(o, k)) fail(`${k} is given twice`);
            o[k] = v;
            ws();
            if (s[i] === ",") { i++; continue; }
            if (s[i] === "}") { i++; return o; }
            fail('expected "," or "}"');
          }
        }
        if (s[i] === "[") {
          i++;
          const a = [];
          ws();
          if (s[i] === "]") { i++; return a; }
          for (;;) {
            a.push(value([",", "]"], depth + 1));
            ws();
            if (s[i] === ",") { i++; continue; }
            if (s[i] === "]") { i++; return a; }
            fail('expected "," or "]"');
          }
        }
        if (s[i] === '"' || s[i] === "'") return quoted();
        try { return scalar(plain(stops)); } catch (e) { e.line = line; throw e; }
      }
      const v = value([], depth0);
      ws();
      if (i < s.length) fail(`unexpected "${s.slice(i, i + 12)}"`);
      return v;
    }
    function inlineValue(textIn, line, depth) {
      const s = textIn.trim();
      if (/^\[\[[^\]]*\]\]$/.test(s)) return s;
      if (s[0] === "{" || s[0] === "[") return parseFlow(s, line, depth);
      if (s[0] === '"') return unquoteDouble(s, line);
      if (s[0] === "'") { if (s.length < 2 || s[s.length - 1] !== "'") throw new YAMLError(line, "a quoted value does not close"); return s.slice(1, -1).replaceAll("''", "'"); }
      try { return scalar(s); } catch (e) { e.line = line; throw e; }
    }

    const L = src.split(/\r?\n/).map((raw, k) => ({ raw, line: k + 1, indent: /^[ \t]*/.exec(raw)[0].replace(/\t/g, "  ").length, text: stripComment(raw).trimEnd() }));
    let pos = 0;
    const blank = () => { while (pos < L.length && L[pos].text.trim() === "") pos++; };
    const isSeq = (s) => s === "-" || s.startsWith("- ");
    const KEY = /^("(?:[^"\\]|\\.)*"|'(?:[^']|'')*'|[^\s"'{[\]},#:-][^:]*?|-[^\s:][^:]*?)\s*:(?:\s+(.*)|\s*$)/;
    const isKey = (s) => KEY.test(s) && s[0] !== "{" && s[0] !== "[";
    // A plain value may continue on lines indented further than its key (YAML folds them with spaces).
    function continued(first, parentIndent, line, depth) {
      const s = first.trim();
      if (!s || /^["'[{|>]/.test(s)) return inlineValue(s, line, depth);
      let out = s;
      while (pos < L.length) {
        const n = L[pos];
        // A key or a list item is never part of a plain value (YAML forbids ": " in one); it is left to fail as indented.
        if (n.text.trim() === "" || n.indent <= parentIndent || isKey(n.text.trim()) || isSeq(n.text.trim())) break;
        out += " " + n.text.trim();
        pos++;
      }
      return out === s ? inlineValue(s, line, depth) : out;
    }
    function node(indent, depth) {
      deep(depth, (L[pos] || {}).line || 0);
      blank();
      if (pos >= L.length || L[pos].indent < indent) return null;
      const ln = L[pos], s = ln.text.trim();
      if (isSeq(s)) return seq(ln.indent, depth);
      if (isKey(s)) return map(ln.indent, depth);
      pos++;
      count(ln.line);
      return continued(s, indent - 1, ln.line, depth);
    }
    function blockScalar(parent, style) {
      const out = [];
      let ind = -1;
      while (pos < L.length) {
        const ln = L[pos];
        if (ln.raw.trim() === "") { out.push(""); pos++; continue; }
        if (ln.indent <= parent) break;
        if (ind < 0) ind = ln.indent;
        out.push(ln.raw.replace(/\t/g, "  ").slice(ind));
        pos++;
      }
      const keep = style.includes("+"), strip = style.includes("-");
      let trail = 0;
      while (out.length && out[out.length - 1] === "") { out.pop(); trail++; }
      const body = style[0] === ">" ? out.join("\n").replace(/([^\n])\n(?=[^\n])/g, "$1 ") : out.join("\n");
      if (!body) return "";
      return strip ? body : keep ? body + "\n".repeat(trail + 1) : body + "\n";
    }
    function seq(indent, depth) {
      const out = [];
      for (;;) {
        blank();
        if (pos >= L.length) break;
        const ln = L[pos], s = ln.text.trim();
        if (ln.indent < indent) break;
        if (ln.indent > indent) throw new YAMLError(ln.line, "this line is indented further than the list around it");
        if (!isSeq(s)) break;
        count(ln.line);
        Object.defineProperty(out, `\u0000line:${out.length}`, { value: ln.line, enumerable: false });
        const rest = s === "-" ? "" : s.slice(2).trim();
        if (rest === "") { pos++; out.push(node(indent + 1, depth + 1)); continue; }
        if (isKey(rest)) {
          const col = ln.indent + (s.length - s.slice(1).trimStart().length);
          L[pos] = { ...ln, indent: col, text: " ".repeat(col) + rest };
          out.push(map(col, depth + 1));
          continue;
        }
        pos++;
        out.push(continued(rest, indent, ln.line, depth + 1));
      }
      return out;
    }
    function map(indent, depth) {
      deep(depth, (L[pos] || {}).line || 0);
      const out = {};
      for (;;) {
        blank();
        if (pos >= L.length) break;
        const ln = L[pos], s = ln.text.trim();
        if (ln.indent < indent) break;
        if (ln.indent > indent) throw new YAMLError(ln.line, "this line is indented further than the keys around it");
        if (isSeq(s)) break;
        const m = KEY.exec(s);
        if (!m) throw new YAMLError(ln.line, `expected "key: value", found "${s.slice(0, 30)}"`);
        count(ln.line);
        let key = m[1];
        if (key[0] === '"') key = unquoteDouble(key, ln.line); else if (key[0] === "'") key = key.slice(1, -1).replaceAll("''", "'");
        if (hasOwn(out, key)) throw new YAMLError(ln.line, `${key} is given twice`);
        const rest = (m[2] || "").trim();
        pos++;
        let v;
        if (rest === "") {
          blank();
          const next = L[pos];
          v = next && (next.indent > indent || (next.indent === indent && isSeq(next.text.trim()))) ? node(next.indent, depth + 1) : null;
        } else if (/^[|>](?:[1-9]?[+-]?|[+-][1-9])$/.test(rest)) v = blockScalar(indent, rest);
        else v = continued(rest, indent, ln.line, depth + 1);
        Object.defineProperty(out, key, { value: v, enumerable: true, writable: true, configurable: true });
        Object.defineProperty(out, `\u0000line:${key}`, { value: ln.line, enumerable: false });
      }
      return out;
    }
    blank();
    if (pos >= L.length) return null;
    const v = node(L[pos].indent, 0);
    blank();
    if (pos < L.length) throw new YAMLError(L[pos].line, `unexpected "${L[pos].text.trim().slice(0, 30)}"`);
    return v;
  }
  const lineOf = (obj, key) => (obj && obj[`\u0000line:${key}`]) || 0;

  // ---------- words (WORDS-1, WORDS-2) ----------
  function vocabulary(words) {
    const list = Array.isArray(words) && words.length ? words : DEFAULT_WORDS;
    const out = list.filter((w) => w && typeof w === "object" && w.word).map((w) => ({
      word: String(w.word), shape: SHAPES.includes(w.shape) ? w.shape : "outline", meaning: w.meaning ? String(w.meaning) : "", quiet: !!w.quiet,
    }));
    if (Array.isArray(words) && words.length && !out.some((w) => w.quiet) && !words.some((w) => w && hasOwn(w, "quiet"))) {
      const works = out.find((w) => w.word === "Works");
      if (works) works.quiet = true;
    }
    return out;
  }
  const fold = (s) => String(s).trim().toLowerCase();
  const isScalar = (v) => v == null || ["string", "number", "boolean"].includes(typeof v);
  const isMap = (v) => v != null && typeof v === "object" && !Array.isArray(v);
  const isInt = (v) => Number.isInteger(Number(v)) && v !== null && v !== "" && typeof v !== "boolean";

  // ---------- one validator for the renderer and check() (lines are 1-based within the block's YAML) ----------
  function validate(lang, y, vocab) {
    const errors = [], warnings = [];
    const err = (line, message) => errors.push({ line, message });
    const warn = (line, message) => warnings.push({ line, message });
    if (!isMap(y)) { err(1, `${lang} needs keys such as items`); return { errors, warnings }; }
    const spec = KEYS[lang];
    for (const k of Object.keys(y)) if (!spec.top.includes(k)) warn(lineOf(y, k), `${lang}: ${k} is not a key Linen reads (${spec.top.join(", ")})`);
    const known = new Set(vocab.map((w) => fold(w.word)));
    const words = [];
    const word = (w, line, where) => {
      if (w == null) return;
      if (!isScalar(w) || w === "") { err(line, `${where}: word must be a word`); return; }
      words.push({ word: String(w), line });
      if (!known.has(fold(w))) warn(line, `${String(w)} is not one of this note's words (${vocab.map((x) => x.word).join(", ")})`);
    };
    const kind = lang === "steps" ? (y.kind == null ? "steps" : y.kind) : null;
    if (lang === "steps" && !["steps", "level", "count"].includes(kind)) { err(lineOf(y, "kind"), `steps: kind must be steps, level or count, not ${kind}`); return { errors, warnings, words }; }
    if (lang === "steps" && kind !== "steps") {
      const v = Number(y.value), of = Number(y.of);
      const at = lineOf(y, "value") || lineOf(y, "of") || 1;
      if (!isScalar(y.value) || !Number.isFinite(v) || y.value === null || y.value === "") err(at, `steps: ${kind} needs a number value`);
      else if (!isScalar(y.of) || !Number.isFinite(of) || of <= 0) err(lineOf(y, "of") || at, `steps: ${kind} needs a number of, above zero`);
      else if (kind === "level" && (!isInt(y.value) || !isInt(y.of) || of > 12)) err(at, "steps: a level is whole threads, of at most 12");
      else if (v < 0 || v > of) err(at, `steps: value ${y.value} is outside 0 to ${y.of}`);
      if (y.items != null) warn(lineOf(y, "items"), `steps: items are not read for kind ${kind}`);
      return { errors, warnings, words };
    }
    const items = y.items;
    if (!Array.isArray(items) || !items.length) { err(lineOf(y, "items") || 1, `${lang} needs a list of items`); return { errors, warnings, words }; }
    if (y.cols != null && (!isInt(y.cols) || Number(y.cols) < 1 || Number(y.cols) > (lang === "tiles" ? 6 : 4))) err(lineOf(y, "cols"), `${lang}: cols must be a whole number from 1 to ${lang === "tiles" ? 6 : 4}`);
    if (lang === "tiles" && y.size != null && !["stat", "fact"].includes(y.size)) err(lineOf(y, "size"), `tiles: size must be stat or fact, not ${y.size}`);
    if (lang === "steps" && y.current != null && (!isInt(y.current) || Number(y.current) < 0 || Number(y.current) > items.length)) err(lineOf(y, "current"), `steps: current must be a whole number from 0 to ${items.length}`);
    let total = 0;
    items.forEach((it, i) => {
      const at = lineOf(items, i) || lineOf(y, "items");
      if (lang === "steps") {
        if (isScalar(it) && it !== null) return;
        if (isMap(it) && (it.label != null || it.title != null)) return;
        err(at, `steps: step ${i + 1} must be a word or {label: ...}`);
        return;
      }
      if (!isMap(it)) { err(at, `${lang}: item ${i + 1} must be a map such as ${lang === "bar" ? "{word: Works, count: 8}" : "{label: A, value: \"1\"}"}`); return; }
      for (const k of Object.keys(it)) if (!spec.item.includes(k)) warn(at, `${lang}: item ${i + 1} has ${k}, which Linen does not read (${spec.item.join(", ")})`);
      for (const k of spec.item) if (k !== "word" && it[k] != null && !isScalar(it[k])) err(at, `${lang}: item ${i + 1}: ${k} must be text, not a list or map`);
      word(it.word, at, `${lang} item ${i + 1}`);
      if (lang === "cards" && it.tone != null && !TONES.includes(it.tone)) err(at, `cards: tone must be one of ${TONES.join(", ")}, not ${it.tone}`);
      if (lang === "bar") {
        if (it.word == null) err(at, `bar: item ${i + 1} needs a word`);
        const c = Number(it.count);
        if (it.count == null || it.count === "" || !isScalar(it.count) || !Number.isFinite(c) || c < 0) err(at, `bar: item ${i + 1} needs a number count, not ${it.count == null ? "nothing" : it.count}`);
        else total += c;
      }
    });
    if (lang === "bar" && !errors.length && !total) err(lineOf(y, "items"), "bar: the counts add up to zero");
    return { errors, warnings, words };
  }

  // ---------- state for the document on the page ----------
  const st = { linen: {}, words: vocabulary(null), notes: Object.create(null), layout: "read", sig: "" };
  function wordInfo(w) {
    const f = fold(w);
    return st.words.find((x) => fold(x.word) === f) || { word: String(w), shape: "outline", quiet: false, meaning: "", unknown: true };
  }
  function configure(yamlText, sidecarText) {
    let linen = {};
    if (yamlText) {
      try { const fm = parseYAML(yamlText); if (isMap(fm) && isMap(fm.linen)) linen = fm.linen; } catch (_) { linen = {}; }
    }
    st.linen = linen;
    st.words = vocabulary(linen.words);
    st.layout = ["wide", "sheet"].includes(linen.layout) ? linen.layout : "read";
    st.notes = Object.create(null);
    if (typeof sidecarText === "string" && sidecarText.trim()) {
      try { const j = JSON.parse(sidecarText); if (isMap(j)) for (const k of Object.keys(j)) st.notes[k] = j[k]; } catch (_) { /* check() reports it */ }
    }
    // What a rendered block depends on besides its own source: when it changes, finish() renders kept blocks again.
    st.sig = JSON.stringify([st.words, st.layout]);
    if (typeof document !== "undefined") {
      const p = document.getElementById("pane");
      if (p) { p.classList.toggle("lb-wide", st.layout === "wide"); p.classList.toggle("lb-sheet", st.layout === "sheet"); }
    }
  }
  // A note by id from the sidecar (own keys only, NOTE-2).
  function noteById(id) {
    if (!hasOwn(st.notes, id)) return null;
    const n = st.notes[id];
    if (isMap(n)) return n;
    if (typeof n === "string") return { body: n };
    return null;
  }
  // A tile's or card's `note`: a sidecar key when there is one, else the note's own text (FORMAT.md).
  const noteOf = (v) => (v == null || v === "" ? null : noteById(String(v)) || { body: String(v) });

  // ---------- rendering (DOM only below this line, guarded for JavaScriptCore) ----------
  let mk = null;
  const md = () => {
    if (!mk && root.marked && root.LinenDialect) mk = root.LinenDialect.configure(new root.marked.Marked());
    return mk;
  };
  const PURE = {
    USE_PROFILES: { html: true },
    FORBID_TAGS: ["style", "form", "textarea", "select", "button", "iframe", "object", "embed", "link", "meta", "base", "img", "video", "audio", "source", "picture", "svg", "math", "template", "noscript"],
    FORBID_ATTR: ["style", "srcset", "formaction", "action", "ping", "background", "poster", "src"],
    ALLOWED_URI_REGEXP: /^(?:(?:https?|mailto|tel|obsidian):|[^a-z]|[a-z+.-]+(?:[^a-z+.\-:]|$))/i,
  };
  const clean = (h) => (root.DOMPurify ? root.DOMPurify.sanitize(h, PURE) : esc(h));
  function inline(text) {
    if (text == null || text === "") return "";
    const m = md();
    try { return clean(m ? m.parseInline(String(text)) : esc(text)); } catch (_) { return esc(text); }
  }
  function blockMd(text) {
    if (text == null || text === "") return "";
    const m = md();
    try { return clean(m ? m.parse(String(text)) : `<p>${esc(text)}</p>`); } catch (_) { return `<p>${esc(text)}</p>`; }
  }

  const SWATCH = (w) => `<i class="lb-sw s-${w.shape}" data-w="${esc(w.word)}" aria-hidden="true"></i>`;
  function pill(word) {
    const w = wordInfo(word);
    if (w.quiet) return `<span class="lw quiet" data-w="${esc(w.word)}">${esc(w.word)}</span>`;
    return `<span class="lw s-${w.shape}${ARABIC.test(w.word) ? " ar" : ""}" data-w="${esc(w.word)}">${esc(w.word)}</span>`;
  }
  const noteAttr = (v) => (v == null || v === "" ? "" : ` data-lnote="${esc(v)}" tabindex="0"`);

  function renderTiles(y) {
    const items = y.items;
    const stat = y.size !== "fact";
    const n = Math.min(6, y.cols != null ? Number(y.cols) : items.length);
    const tiles = items.map((item) => {
      const value = item.value == null ? "" : String(item.value);
      const label = item.label == null ? "" : String(item.label);
      const w = item.word != null ? wordInfo(item.word) : null;
      let v = `<b class="lt-v">${inline(value)}</b>`, l = label ? `<span class="lt-l">${inline(label)}</span>` : "";
      // A tile's word shows once (BLK-2): as its value when the value is the word, beside the label when the label is
      // the word, else as a pill beside the label.
      if (w && fold(value) === fold(w.word)) v = `<b class="lt-v lt-word">${pill(w.word)}</b>`;
      else if (w && fold(label) === fold(w.word)) l = `<span class="lt-l">${w.quiet ? "" : SWATCH(w)}${inline(label)}</span>`;
      else if (w && !w.quiet) l = `<span class="lt-l">${pill(w.word)} ${inline(label)}</span>`;
      return `<div class="lt"${noteAttr(item.note)}>${stat ? v + l : l + v}</div>`;
    }).join("");
    return { html: `<div class="lb lb-tiles ${stat ? "lb-stat" : "lb-fact"}" style="--cols:${n}">${tiles}</div>`, wide: false };
  }
  function renderCards(y) {
    const items = y.items;
    const n = Math.min(4, y.cols != null ? Number(y.cols) : Math.min(3, items.length));
    const cards = items.map((c) => {
      const tone = TONES.includes(c.tone) ? c.tone : "paper";
      const head = [c.number != null ? `<span class="lc-n">${esc(c.number)}</span>` : "", c.eyebrow ? `<span class="eyebrow lc-e">${esc(c.eyebrow)}</span>` : ""].join("");
      const w = c.word != null ? wordInfo(c.word) : null;
      return `<div class="lc tone-${tone}"${noteAttr(c.note)}>`
        + (head || (w && !w.quiet) ? `<div class="lc-top">${head}${w && !w.quiet ? pill(w.word) : ""}</div>` : "")
        + (c.title != null ? `<div class="lc-t">${inline(c.title)}</div>` : "")
        + (c.body != null ? `<div class="lc-b">${blockMd(c.body)}</div>` : "")
        + (c.link != null ? `<div class="lc-link">${inline(c.link)}</div>` : "") + "</div>";
    }).join("");
    return { html: `<div class="lb lb-cards" style="--cols:${n}">${cards}</div>`, wide: n >= 3 };
  }
  function renderSteps(y) {
    const kind = y.kind || "steps";
    if (kind === "steps") {
      const items = y.items.map((x) => (isMap(x) ? x.label ?? x.title : x));
      const cur = y.current != null ? Number(y.current) : 0;
      const lis = items.map((label, i) => {
        const k = i + 1 < cur ? "past" : i + 1 === cur ? "cur" : "todo";
        return `<li class="ls ${k}"${k === "cur" ? ' aria-current="step"' : ""}><span class="ls-l">${inline(label)}</span></li>`;
      }).join("");
      const aria = cur ? ` aria-label="${esc(t("Step {a} of {b}", { a: num(cur), b: num(items.length) }))}"` : "";
      return { html: `<ol class="lb lb-steps"${aria}>${lis}</ol>`, wide: false };
    }
    const value = Number(y.value), of = Number(y.of);
    const label = y.label ? `<span class="lv-l">${inline(y.label)}</span>` : "";
    if (kind === "level") {
      const threads = Array.from({ length: of }, (_, i) => `<i class="th ${i < value ? "done" : "todo"} ${i % 2 ? "v" : "h"}"></i>`).join("");
      return { html: `<div class="lb lb-level" role="img" aria-label="${esc(t("Level {a} of {b}", { a: num(value), b: num(of) }))}"><span class="lv-th">${threads}</span><span class="lv-n">${esc(t("{a} of {b}", { a: num(value), b: num(of) }))}</span>${label}</div>`, wide: false };
    }
    const parts = esc(t("{a} of {b}", { a: "\u0000", b: num(of) })).split("\u0000");
    return { html: `<div class="lb lb-count"><span class="lv-n">${parts[0]}<b>${esc(num(value))}</b>${parts[1] || ""}</span>${label}</div>`, wide: false };
  }
  function renderBar(y) {
    const items = y.items;
    const segs = items.map((x) => {
      const w = wordInfo(x.word), c = Number(x.count);
      return c ? `<span class="bs s-${w.shape}" style="flex-grow:${c}" data-k="${esc(w.word)}" data-w="${esc(w.word)}"><span class="bs-t">${esc(w.word)} ${esc(num(c))}</span></span>` : "";
    }).join("");
    const key = items.map((x) => {
      const w = wordInfo(x.word), c = Number(x.count);
      return c ? `<span class="bk" data-k="${esc(w.word)}" hidden>${SWATCH(w)}${esc(w.word)} ${esc(num(c))}</span>` : "";
    }).join("");
    const label = y.label ? `<div class="lb-cap">${inline(y.label)}</div>` : "";
    return { html: `<div class="lb lb-bar" role="img" aria-label="${esc(items.map((x) => `${x.word} ${num(x.count)}`).join(", "))}">${label}<div class="bar-row">${segs}</div><div class="bar-key">${key}</div></div>`, wide: false };
  }
  // A bar segment shows its word and count inside it when they fit, else in the key below (BLK-6).
  function fitBars(scope) {
    scope.querySelectorAll(".lb-bar").forEach((bar) => {
      bar.querySelectorAll(".bs").forEach((s) => {
        const tx = s.querySelector(".bs-t");
        tx.hidden = false;
        const cs = getComputedStyle(s);
        const fits = tx.getBoundingClientRect().width <= s.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight) + 0.5;
        tx.hidden = !fits;
        const k = [...bar.querySelectorAll(".bk")].find((b) => b.dataset.k === s.dataset.k);
        if (k) k.hidden = fits;
      });
      const key = bar.querySelector(".bar-key");
      key.hidden = ![...key.children].some((c) => !c.hidden);
    });
  }
  let barObserver = null;
  function failed(src, why) {
    return `<div class="render-failed lb-failed"><b>${esc(t("This block could not be read: {e}", { e: why }))}</b>${esc(src)}</div>`;
  }

  // One block's HTML from its source; `line0` is the fence's line in the file, so problems name the file's line.
  function renderSource(lang, src, line0) {
    if (lang === "side") return { html: `<div class="lb lb-side">${blockMd(src)}</div>`, wide: false };
    const at = (l) => (line0 && l ? `line ${line0 + l}: ` : "");
    let y;
    try { y = parseYAML(src); } catch (e) {
      return { html: failed(src, e instanceof YAMLError ? `${at(e.line)}${e.message}` : String(e.message || e)), wide: false };
    }
    const v = validate(lang, y, st.words);
    if (v.errors.length) return { html: failed(src, `${at(v.errors[0].line)}${v.errors[0].message}`), wide: false };
    try {
      const out = lang === "tiles" ? renderTiles(y) : lang === "cards" ? renderCards(y) : lang === "steps" ? renderSteps(y) : renderBar(y);
      out.words = (v.words || []).map((w) => w.word);
      return out;
    } catch (e) {
      return { html: failed(src, String(e.message || e)), wide: false };
    }
  }

  // Each Loom block's source, so finish() can render it again when the words or the layout change (a kept block
  // is reused by its source hash and would otherwise show the old words).
  const sources = new WeakMap();
  function place$(el, lang, out) {
    el.dataset.lblk = lang;
    el.dataset.lsig = st.sig;
    el.dataset.lwide = out.wide ? "1" : "";
    el.classList.toggle("side", lang === "side");
    el.classList.toggle("wide", lang !== "side" && (st.layout !== "read" || !!out.wide));
  }
  function expand(el, b) {
    if (typeof document === "undefined") return;
    const D = root.LinenDialect;
    el.querySelectorAll(".lblk-src").forEach((n) => {
      const lang = n.dataset.lang;
      const src = (D && D.sources.get(n.dataset.k)) || "";
      if (D) D.sources.delete(n.dataset.k);
      const line0 = b && b.lines ? b.lines[0] : 0;
      const out = renderSource(lang, src, line0);
      const box = document.createElement("div");
      box.innerHTML = out.html;
      n.replaceWith(...box.childNodes);
      sources.set(el, { lang, src, line0, words: out.words || [] });
      place$(el, lang, out);
    });
    dress(el);
    observeBars(el);
  }
  function observeBars(el) {
    if (!el.querySelector(".lb-bar")) return;
    if (!barObserver) barObserver = new ResizeObserver((entries) => { for (const e of entries) if (e.target.isConnected) fitBars(e.target); });
    el.querySelectorAll(".lb-bar").forEach((bar) => barObserver.observe(bar));
  }
  // A kept block whose words or layout changed is rendered again from its source, its direction set as the page does.
  function refresh(el) {
    const s = sources.get(el);
    if (!s || el.dataset.lsig === st.sig) return;
    const out = renderSource(s.lang, s.src, s.line0);
    el.innerHTML = out.html;
    s.words = out.words || [];
    place$(el, s.lang, out);
    dress(el);
    // The page's own decoration (directions, table wrappers, task boxes, Copy on code) and its media activation.
    const P = root.linenInternals || {};
    if (P.decorate) P.decorate(el, {}); else if (P.directionOf) el.querySelectorAll("p, li, td, th").forEach((n) => { const d = P.directionOf(n, el.getAttribute("dir") || "ltr"); if (d) n.setAttribute("dir", d); });
    observeBars(el);
  }

  // Words, note terms and table marks (BLK-7) in any block; safe to run again after the vocabulary changes.
  function dress(el) {
    el.querySelectorAll(".lw").forEach((p) => {
      const w = wordInfo(p.dataset.w || p.textContent);
      p.className = w.quiet ? "lw quiet" : `lw s-${w.shape}${ARABIC.test(w.word) ? " ar" : ""}`;
    });
    // Only tables that hold a mark are walked; a large plain table costs one text test.
    const withMarks = [];
    el.querySelectorAll("table").forEach((tb) => {
      if (tb.dataset.lbt) return;
      tb.dataset.lbt = "1";
      if (new RegExp(`\\{(?:#${ID}|good|bad)\\}`, "u").test(tb.textContent)) withMarks.push(tb);
    });
    const anchor = new RegExp(`\\s*\\{#(${ID})\\}\\s*$`, "u");
    for (const tb of withMarks) tb.querySelectorAll("tr").forEach((tr) => {
      const first = tr.firstElementChild;
      if (first) {
        const last = lastText(first);
        const m = last && anchor.exec(last.nodeValue);
        if (m) { last.nodeValue = last.nodeValue.slice(0, m.index); tr.id = m[1]; }
      }
      for (const cell of tr.children) {
        const last = lastText(cell);
        const m = last && /\s*\{(good|bad)\}\s*$/.exec(last.nodeValue);
        if (!m) continue;
        last.nodeValue = last.nodeValue.slice(0, m.index);
        cell.classList.add(`v-${m[1]}`);
        const mark = document.createElement("span");
        mark.className = `lb-v v-${m[1]}`;
        mark.setAttribute("aria-label", m[1]);
        cell.appendChild(mark);
      }
    });
  }
  function lastText(el) {
    const w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    let last = null;
    while (w.nextNode()) if (w.currentNode.nodeValue.trim()) last = w.currentNode;
    return last;
  }

  // The note's eyebrow and lead from `linen:` (BLK-0).
  function header(eyebrowEl, titleEl, headerEl) {
    if (typeof document === "undefined" || !headerEl) return;
    if (st.linen.eyebrow) eyebrowEl.innerHTML = String(st.linen.eyebrow).split("·").map((p) => `<span>${esc(p.trim())}</span>`).join("");
    let lead = document.getElementById("note-lead");
    if (st.linen.lead) {
      if (!lead) { lead = document.createElement("p"); lead.id = "note-lead"; lead.className = "lead"; headerEl.insertBefore(lead, document.getElementById("note-legend")); }
      lead.innerHTML = inline(st.linen.lead);
      lead.setAttribute("dir", ARABIC.test(String(st.linen.lead)) ? "rtl" : (titleEl.getAttribute("dir") || "ltr"));
    } else if (lead) lead.remove();
  }

  // The legend (WORDS-3): the words this note uses, each with its shape and meaning, once, under the header.
  function legend(docEl) {
    const headerEl = document.getElementById("note-header");
    let box = document.getElementById("note-legend");
    const used = [];
    const seen = new Set();
    const add = (word) => { const w = wordInfo(word); const k = fold(w.word); if (!seen.has(k)) { seen.add(k); used.push(w); } };
    // Words in prose and tables as drawn, and every word a block names in its source (quiet and zero-count ones too).
    docEl.querySelectorAll(".lw[data-w]").forEach((n) => add(n.dataset.w));
    docEl.querySelectorAll(":scope > [data-lblk]").forEach((el) => { const s = sources.get(el); if (s) for (const w of s.words || []) add(w); });
    if (!used.length || !headerEl) { if (box) box.remove(); return; }
    // In the vocabulary's order, then any word the vocabulary does not list.
    used.sort((a, b) => { const ia = st.words.findIndex((w) => fold(w.word) === fold(a.word)), ib = st.words.findIndex((w) => fold(w.word) === fold(b.word)); return (ia < 0 ? 99 : ia) - (ib < 0 ? 99 : ib); });
    if (!box) { box = document.createElement("div"); box.id = "note-legend"; box.className = "lb-legend"; headerEl.appendChild(box); }
    box.setAttribute("aria-label", t("Words in this note"));
    box.innerHTML = used.map((w) => `<span class="lg">${SWATCH(w)}<b>${esc(w.word)}</b>${w.meaning ? `<i>${esc(w.meaning)}</i>` : ""}</span>`).join("");
  }

  // After the document is on the page: footnote numbers as the current document counts them (a reused block may
  // carry old ones), kept blocks rendered again when words or layout changed, words dressed, noted items marked, the
  // legend, and the numbered sources that print and PDF carry (NOTE-3).
  function finish(docEl) {
    if (typeof document === "undefined") return;
    const ctx = (root.LinenDialect && root.LinenDialect.context) || {};
    const order = ctx.footnotes || {};
    docEl.querySelectorAll("sup.fnref a[data-fn]").forEach((a) => { const n = order[a.dataset.fn]; a.textContent = n ? String(n) : "?"; });
    docEl.querySelectorAll(":scope > [data-lblk]").forEach(refresh);
    dress(docEl);
    docEl.querySelectorAll(":scope > .lnotes-blk").forEach((n) => n.remove());
    docEl.querySelectorAll(".lnote-num").forEach((n) => n.remove());
    docEl.querySelectorAll("[data-lnote]").forEach((n) => n.classList.toggle("noted", !!noteOf(n.dataset.lnote)));
    docEl.querySelectorAll(".lnote[data-note]").forEach((n) => n.classList.toggle("noted", !!noteById(n.dataset.note)));
    fitBars(docEl);
    if (document.fonts && document.fonts.status !== "loaded") document.fonts.ready.then(() => fitBars(docEl));
    legend(docEl);
    const defs = new Set((ctx.footnoteDefs || []).map((d) => d.id));
    let next = Math.max(0, ...Object.values(order).map(Number).filter(Number.isFinite));
    const list = [];
    const seen = new Map();
    docEl.querySelectorAll(":scope > .blk [data-lnote], :scope > .blk .lnote[data-note], :scope > .blk sup.fnref a[data-fn]").forEach((n) => {
      if (n.matches("sup.fnref a")) {
        const id = n.dataset.fn;
        const note = defs.has(id) ? null : noteById(id);
        if (note && !seen.has(`fn:${id}`)) { seen.set(`fn:${id}`, Number(order[id]) || ++next); list.push([seen.get(`fn:${id}`), note]); }
        return;
      }
      const key = n.dataset.lnote != null ? `v:${n.dataset.lnote}` : `id:${n.dataset.note}`;
      const note = n.dataset.lnote != null ? noteOf(n.dataset.lnote) : noteById(n.dataset.note);
      if (!note) return;
      if (!seen.has(key)) { seen.set(key, ++next); list.push([next, note]); }
      const s = document.createElement("sup");
      s.className = "lnote-num";
      s.hidden = true; // print and PDF only (NOTE-3); find skips it
      s.textContent = String(seen.get(key));
      n.appendChild(s);
    });
    if (!list.length) return;
    list.sort((a, b) => a[0] - b[0]);
    const el = document.createElement("div");
    el.className = "blk lnotes-blk";
    el.hidden = true; // print and PDF only (NOTE-3); on screen the notes open on hover
    el.innerHTML = `<section class="lnotes"><div class="eyebrow">${esc(t("Sources"))}</div><ol>${list.map(([k, n]) => `<li value="${k}">${noteHTML(n)}</li>`).join("")}</ol></section>`;
    docEl.appendChild(el);
  }

  function noteHTML(n) {
    const fields = isMap(n.fields) ? Object.entries(n.fields) : [];
    const refs = Array.isArray(n.refs) ? n.refs : n.refs ? [n.refs] : [];
    return (n.area ? `<div class="eyebrow">${esc(n.area)}</div>` : "")
      + (n.title ? `<div class="ln-t">${inline(n.title)}</div>` : "")
      + (n.state ? `<div class="ln-s">${pill(n.state)}</div>` : "")
      + (n.body ? `<div class="ln-b">${blockMd(n.body)}</div>` : "")
      + (fields.length ? `<dl class="ln-f">${fields.map(([k, v]) => `<dt>${esc(k)}</dt><dd>${inline(v)}</dd>`).join("")}</dl>` : "")
      + (refs.length ? `<div class="ln-r"><div class="eyebrow">${esc(t("Sources"))}</div>${refs.map((r) => `<code class="ln-ref" tabindex="0">${esc(r)}</code>`).join("")}</div>` : "");
  }

  // The one note card (solid paper, NOTE-1): beside the block that holds the mark when there is room, else below it,
  // never over it, on every width. Hover opens after 300 ms, focus at once, a tap on touch.
  const card = { el: null, for: null, openT: 0, closeT: 0, touch: false };
  const TRIGGER = "sup.fnref a[data-fn], .lnote[data-note], [data-lnote]";
  function trigger(n) { const el = n && n.nodeType === 1 ? n : n && n.parentElement; return el && el.closest ? el.closest(TRIGGER) : null; }
  function docEl() { return document.getElementById("doc"); }
  function cardContent(trg) {
    if (trg.matches("sup.fnref a")) {
      const id = trg.dataset.fn;
      const li = document.getElementById(`fn-${id}`);
      if (li) {
        const body = li.cloneNode(true);
        body.querySelectorAll("a.back").forEach((a) => a.remove());
        return `<div class="eyebrow">${esc(t("Note {n}", { n: num(Number(trg.textContent) || 0) }))}</div><div class="ln-b">${body.innerHTML}</div>`;
      }
      const n = noteById(id);
      return n ? noteHTML(n) : "";
    }
    const n = trg.dataset.lnote != null ? noteOf(trg.dataset.lnote) : noteById(trg.dataset.note);
    return n ? noteHTML(n) : "";
  }
  function openCard(trg) {
    const html = cardContent(trg);
    if (!html) return;
    if (!card.el) {
      card.el = document.createElement("div");
      card.el.className = "lnote-card";
      card.el.setAttribute("role", "note");
      card.el.addEventListener("mouseenter", () => clearTimeout(card.closeT));
      card.el.addEventListener("mouseleave", () => scheduleClose());
      card.el.addEventListener("click", cardClick);
      document.body.appendChild(card.el);
    }
    card.for = trg;
    card.el.innerHTML = html;
    card.el.hidden = false;
    card.el.setAttribute("dir", trg.closest("[dir]") ? trg.closest("[dir]").getAttribute("dir") : "ltr");
    trg.classList.add("on");
    place(trg);
  }
  function place(trg) {
    const c = card.el;
    const blk = trg.closest(".blk") || trg;
    const br = blk.getBoundingClientRect(), tr = trg.getBoundingClientRect();
    const W = innerWidth;
    c.style.left = c.style.top = c.style.width = "";
    // A footnote card is narrow (the sketch's margin card); a note with sources wants more room. Either takes what the
    // margin gives down to its floor before it moves below the block.
    const fn = trg.matches("sup.fnref a");
    const width = fn ? 260 : 340, floor = fn ? 190 : 240;
    const rail = document.getElementById("outline");
    const railR = rail && !rail.hidden && !document.documentElement.classList.contains("outline-overlay") ? rail.getBoundingClientRect() : null;
    const rtl = getComputedStyle(blk).direction === "rtl";
    const room = { end: rtl ? br.left - (railR && railR.right < br.left ? railR.right : 0) : W - br.right, start: rtl ? W - br.right : br.left - (railR && railR.right <= br.left ? railR.right : 0) };
    const gap = 24, edge = 14;
    const fitEnd = Math.min(width, room.end - gap - edge), fitStart = Math.min(width, room.start - gap - edge);
    let left, top = tr.top - 8, w = width, below = false;
    if (fitEnd >= floor) { w = fitEnd; left = rtl ? br.left - gap - w : br.right + gap; }
    else if (fitStart >= floor) { w = fitStart; left = rtl ? br.right + gap : br.left - gap - w; }
    else {
      // Below the block, never over it: on a phone that is the block's own width.
      below = true;
      w = Math.min(W < 560 ? br.width : width + 80, br.width);
      left = rtl ? br.right - w : br.left;
      top = br.bottom + 8;
    }
    c.style.width = `${w}px`;
    c.style.left = `${left + scrollX}px`;
    c.style.top = `${Math.max(top, 8) + scrollY}px`;
    if (below) {
      // Bring the card into view without hiding the mark it explains.
      const r = c.getBoundingClientRect();
      const over = r.bottom - innerHeight + 12;
      if (over > 0) scrollBy(0, Math.min(over, Math.max(0, tr.top - 12)));
    }
  }
  function closeCard() {
    clearTimeout(card.openT);
    clearTimeout(card.closeT);
    if (card.for) card.for.classList.remove("on");
    card.for = null;
    if (card.el) card.el.hidden = true;
  }
  function scheduleClose() { clearTimeout(card.closeT); card.closeT = setTimeout(closeCard, 220); }
  function cardClick(e) {
    const ref = e.target.closest(".ln-ref");
    const post = (m) => { try { root.webkit.messageHandlers.linen.postMessage(m); } catch (_) { /* outside the app */ } };
    if (ref) { post({ type: "copyText", text: ref.textContent }); ref.dataset.copied = t("Copied"); setTimeout(() => delete ref.dataset.copied, 1200); return; }
    const a = e.target.closest("a");
    if (!a) return;
    e.preventDefault();
    const href = a.getAttribute("href") || "";
    if (a.classList.contains("wl")) post({ type: "openWiki", target: a.dataset.target, newTab: e.metaKey });
    else if (/^(https?|mailto|tel):/i.test(href)) post({ type: "openExternal", url: href });
    else if (href.startsWith("#")) { const d = document.getElementById(decodeURIComponent(href.slice(1))); if (d) d.scrollIntoView({ block: "center" }); }
  }
  if (typeof document !== "undefined") {
    document.addEventListener("mouseover", (e) => {
      if (card.touch) return;
      const trg = trigger(e.target);
      if (!trg || !docEl() || !docEl().contains(trg)) return;
      if (trg === card.for) { clearTimeout(card.closeT); return; }
      clearTimeout(card.openT);
      card.openT = setTimeout(() => { closeCard(); openCard(trg); }, 300);
    });
    document.addEventListener("mouseout", (e) => {
      const trg = trigger(e.target);
      if (!trg || (e.relatedTarget && trg.contains(e.relatedTarget))) return;
      clearTimeout(card.openT);
      if (trg === card.for && !(e.relatedTarget && card.el && card.el.contains(e.relatedTarget))) scheduleClose();
    });
    document.addEventListener("focusin", (e) => { const trg = trigger(e.target); if (trg && docEl() && docEl().contains(trg)) { closeCard(); openCard(trg); } });
    document.addEventListener("focusout", (e) => { if (trigger(e.target) === card.for) scheduleClose(); });
    document.addEventListener("keydown", (e) => { if (e.key === "Escape" && card.for) closeCard(); });
    document.addEventListener("pointerdown", (e) => {
      card.touch = e.pointerType === "touch";
      if (card.el && !card.el.hidden && !card.el.contains(e.target) && !trigger(e.target)) closeCard();
    }, true);
    // A tap opens the note instead of following the footnote link (BLK-1 on the iPhone).
    document.addEventListener("click", (e) => {
      if (!card.touch) return;
      const trg = trigger(e.target);
      if (!trg || !docEl() || !docEl().contains(trg)) return;
      e.preventDefault();
      e.stopPropagation();
      if (trg === card.for) closeCard(); else { closeCard(); openCard(trg); }
    }, true);
    addEventListener("resize", () => { if (card.for && card.for.isConnected) place(card.for); else closeCard(); });
  }

  // ---------- check (pure; `linen check` runs it in JavaScriptCore) ----------
  // Prose with what the renderer never reads as syntax taken out: code spans, %% comments %%, HTML comments and
  // backslash escapes, each replaced by spaces so columns and lines stay where they were.
  function proseOnly(text) {
    const blankOut = (m) => m.replace(/[^\n]/g, " ");
    return text
      .replace(/%%[\s\S]*?%%/g, blankOut)
      .replace(/<!--[\s\S]*?-->/g, blankOut)
      .replace(/(`+)(?!`)[\s\S]*?(?<!`)\1(?!`)/g, blankOut)
      .replace(/\\[\\`*_{}[\]()#+\-.!:]/g, "  ");
  }
  function check(source, sidecarText) {
    const out = [];
    const push = (severity, line, message) => out.push({ severity, line, message });
    const text = String(source || "");
    const fm = /^﻿?---[ \t]*\r?\n([\s\S]*?)\r?\n---[ \t]*(?:\r?\n|$)/.exec(text);
    let words = null, fmLines = 0;
    if (fm) {
      fmLines = fm[0].split("\n").length - 1;
      try {
        const y = parseYAML(fm[1]);
        const linen = isMap(y) ? y.linen : null;
        if (isMap(linen)) {
          const at = (k) => 1 + (lineOf(linen, k) || 0);
          if (linen.layout != null && !["read", "wide", "sheet"].includes(linen.layout)) push("error", at("layout"), `layout must be read, wide or sheet, not ${linen.layout}`);
          for (const k of Object.keys(linen)) if (!["layout", "eyebrow", "lead", "words", "notes", "glossary"].includes(k)) push("warning", at(k), `linen.${k} is not a page setting Linen reads`);
          if (linen.words != null) {
            if (!Array.isArray(linen.words)) push("error", at("words"), "linen.words must be a list");
            else {
              words = linen.words;
              const wl = (i) => 1 + (lineOf(words, i) || lineOf(linen, "words"));
              if (words.length > 6) push("error", at("words"), `${words.length} words; a note has at most six (WORDS-1)`);
              words.forEach((w, i) => {
                if (!isMap(w) || !w.word) { push("error", wl(i), `word ${i + 1} needs a word`); return; }
                if (w.shape != null && !SHAPES.includes(w.shape)) push("error", wl(i), `${w.word}: shape must be one of ${SHAPES.join(", ")}`);
                if (w.shape === "rust" && !FAILS.test(String(w.meaning || ""))) push("warning", wl(i), `${w.word} is rust, which means failure, but its meaning does not say it failed`);
              });
              if (words.filter((w) => w && w.quiet).length > 1) push("error", at("words"), "only one word may be quiet");
            }
          }
        }
      } catch (e) {
        push("error", 1 + (e.line || 0), `frontmatter: ${e.message}`);
      }
    }
    const vocab = vocabulary(words);
    const known = new Set(vocab.map((w) => fold(w.word)));
    const used = new Map();
    const useWord = (w, line) => { if (w == null) return; const k = fold(w); if (!used.has(k)) used.set(k, { word: String(w), line }); };
    const noteIds = [];   // ids that must be in the sidecar: :note{#id}
    const softIds = [];   // tile and card notes that look like ids
    const refs = new Set(); // every id something opens: :note ids, [^id] references, tile and card notes
    const defs = [];      // [^id]: definitions in the file
    const fnRefs = [];    // [^id] references, with their lines
    const lines = text.split("\n");
    // Prose to scan: fenced and indented code blanked first (a %% inside code must not pair with one outside), then
    // code spans, comments, escapes and link targets.
    const masked = [];
    let inFence = null, prevBlank = true;
    for (let i = 0; i < lines.length; i++) {
      const ln = lines[i], f = /^ {0,3}(`{3,}|~{3,})/.exec(ln);
      if (i < fmLines) { masked.push(""); continue; }
      if (!inFence && f) { inFence = f[1]; masked.push(""); continue; }
      if (inFence) { if (new RegExp(`^ {0,3}${inFence[0] === "`" ? "`" : "~"}{${inFence.length},}\\s*$`).test(ln)) inFence = null; masked.push(""); continue; }
      const indented = /^(?: {4}|\t)/.test(ln) && prevBlank;
      masked.push(indented ? "" : ln);
      prevBlank = indented || ln.trim() === "";
    }
    const prose = proseOnly(masked.join("\n")).replace(/\]\([^)\n]*\)/g, (m) => "]" + " ".repeat(m.length - 1)).split("\n");
    let fence = null;
    for (let i = fmLines; i < lines.length; i++) {
      const ln = lines[i];
      const f = /^ {0,3}(`{3,}|~{3,})\s*([^\s`]*)/.exec(ln);
      if (!fence && f) { fence = { mark: f[1], lang: f[2].toLowerCase(), start: i, body: [] }; continue; }
      if (fence) {
        if (new RegExp(`^ {0,3}${fence.mark[0] === "`" ? "`" : "~"}{${fence.mark.length},}\\s*$`).test(ln)) {
          if (LANGS.has(fence.lang) && fence.lang !== "side") checkBlock(fence, push, vocab, useWord, noteIds, softIds, refs);
          fence = null;
        } else fence.body.push(ln);
        continue;
      }
      const p = prose[i] || "";
      if (/^ {0,3}\[\^[^\]\s]+\]:/.test(p)) { const m = /\[\^([^\]\s]+)\]:/.exec(p); defs.push([m[1], i + 1]); }
      for (const m of p.matchAll(/:w\[([^\]\n]{1,40})\]/g)) if (m[1].trim()) useWord(m[1].trim(), i + 1);
      for (const m of p.matchAll(/:note\[[^\]\n]+\]\{#([^}\s]+)\}/g)) { noteIds.push([m[1], i + 1]); refs.add(m[1]); }
      for (const m of p.matchAll(/\[\^([^\]\s]+)\](?!:)/g)) { refs.add(m[1]); fnRefs.push([m[1], i + 1]); }
    }
    if (fence && LANGS.has(fence.lang)) push("error", fence.start + 1, `the ${fence.lang} block never closes`);
    for (const [k, u] of used) if (!known.has(k)) push("warning", u.line, `${u.word} is not one of this note's words (${vocab.map((w) => w.word).join(", ")})`);
    const distinct = new Set([...known, ...used.keys()]);
    if (distinct.size > 6) push("error", 1, `this note uses ${distinct.size} words; at most six (WORDS-1)`);
    // Notes (NOTE-2): checked against the sidecar, or against nothing when there is none.
    let notes = Object.create(null), hasSidecar = false;
    if (sidecarText != null) {
      let j;
      try { j = JSON.parse(String(sidecarText)); } catch (e) { push("error", 0, `the notes file is not JSON: ${e.message}`); }
      if (j !== undefined && !isMap(j)) push("error", 0, "the notes file must be an object of notes keyed by id");
      else if (j !== undefined) { hasSidecar = true; for (const k of Object.keys(j)) notes[k] = j[k]; }
    }
    for (const [id, line] of noteIds) if (!hasOwn(notes, id)) push("warning", line, hasSidecar ? `no note called ${id} in the notes file` : `no note called ${id}: this note has no notes file beside it`);
    for (const [id, line] of softIds) if (!hasOwn(notes, id)) push("warning", line, `${id} is not in the notes file, so it shows as the note's text`);
    for (const [id, line] of defs) if (hasOwn(notes, id)) push("error", line, `${id} has a note here and in the notes file; the file's note is shown`);
    const defined = new Set(defs.map(([id]) => id));
    for (const [id, line] of fnRefs) if (!defined.has(id) && !hasOwn(notes, id)) push("warning", line, `[^${id}] opens nothing: no definition here and no note called ${id}`);
    for (const id of Object.keys(notes)) if (!refs.has(id)) push("warning", 0, `the notes file has ${id}, which nothing in this note opens`);
    return out.sort((a, b) => (a.line || 0) - (b.line || 0));
  }
  function checkBlock(fence, push, vocab, useWord, noteIds, softIds, refs) {
    const base = fence.start + 1; // the fence line; YAML line 1 is the next one
    let y;
    try { y = parseYAML(fence.body.join("\n")); } catch (e) {
      push("error", base + (e.line || 1), `${fence.lang}: ${e.message}`);
      return;
    }
    const v = validate(fence.lang, y, vocab);
    for (const e of v.errors) push("error", base + (e.line || 1), e.message.startsWith(fence.lang) ? e.message : `${fence.lang}: ${e.message}`);
    // Unknown words are counted once for the whole note, below; other warnings as they are.
    for (const w of v.warnings) if (!/is not one of this note's words/.test(w.message)) push("warning", base + (w.line || 1), w.message);
    for (const w of v.words || []) useWord(w.word, base + w.line);
    if (isMap(y) && Array.isArray(y.items)) y.items.forEach((it, i) => {
      if (!isMap(it) || it.note == null || it.note === "") return;
      const s = String(it.note);
      refs.add(s);
      // An id-looking note (no spaces, a hyphen or a digit) that is not in the sidecar shows as its own text: warn.
      if (/^[^\s]+$/.test(s) && /[-_\d]/.test(s)) softIds.push([s, base + (lineOf(y.items, i) || 1)]);
    });
  }

  root.LinenBlocks = { configure, expand, header, finish, check, validate, parseYAML, YAMLError, LANGS, words: () => st.words, notes: () => st.notes, close: closeCard };
})(typeof self !== "undefined" ? self : globalThis);
