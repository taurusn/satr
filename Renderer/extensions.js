// Linen's Markdown dialect on top of marked (PRD 6.2): wiki links and embeds, callouts and GitHub alerts,
// ==highlights==, %%comments%%, #tags, $math$ and footnotes. Loaded by the parser worker and by the page,
// so both read the same tokens. Math and diagrams render as placeholders here; the page fills them in
// after sanitising, because their output carries styles a document is not allowed to carry.
(function (root) {
  "use strict";

  const escapeHTML = (s) => String(s)
    .replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;").replaceAll("'", "&#39;");

  // Math and diagram sources wait in a side table, keyed by a number: the sanitiser drops attributes holding
  // text such as "-->", which every Mermaid arrow contains.
  const sources = new Map();
  let nextKey = 0;
  const stash = (text) => { const k = String(++nextKey); sources.set(k, text); return k; };

  // marked asks every extension where its next token may start, at every step, passing the rest of the text.
  // Scanning all of it each time is quadratic on long documents; the answer only matters near the current
  // point, because marked asks again after each token. So each scan looks at the next 4 KB only.
  const near = (src) => (src.length > 4096 ? src.slice(0, 4096) : src);

  const IMAGE_EXT = /\.(png|jpe?g|gif|webp|svg|avif|heic|bmp|tiff?)$/i;

  // The note name a wiki link reads as (REN-8): the last path segment without its extension, then the heading.
  const linkName = (target) => {
    const [path, heading] = target.split("#");
    const base = (path.split("/").pop() || path).replace(/\.md$/i, "");
    const shown = base || (heading || "").replace(/^\^/, "");
    return heading && base ? `${shown} › ${heading.replace(/^\^/, "")}` : shown;
  };

  const wikilink = {
    name: "wikilink",
    level: "inline",
    start(src) { const i = near(src).indexOf("[["); return i < 0 ? undefined : (i > 0 && src[i - 1] === "!" ? i - 1 : i); },
    tokenizer(src) {
      const m = /^(!?)\[\[([^\]\n|]+?)(?:\|([^\]\n]+?))?\]\]/.exec(src);
      if (!m) return undefined;
      const target = m[2].trim();
      return { type: "wikilink", raw: m[0], embed: m[1] === "!", target, label: m[3] ? m[3].trim() : null };
    },
    renderer(t) {
      const target = escapeHTML(t.target);
      if (t.embed && IMAGE_EXT.test(t.target.split("#")[0])) {
        return `<img class="embed" data-wiki-src="${target}" alt="${escapeHTML(t.label || t.target)}">`;
      }
      const label = escapeHTML(t.label || linkName(t.target));
      const cls = t.embed ? "wl embed-link" : "wl";
      return `<a class="${cls}" href="#" data-target="${target}" title="${target}">${label}</a>`;
    },
  };

  // Obsidian callouts and GitHub alerts share one syntax: a blockquote whose first line is [!type].
  const callout = {
    name: "callout",
    level: "block",
    start(src) { const m = /(^|\n) {0,3}>[ \t]*\[!/.exec(near(src)); return m ? m.index + m[1].length : undefined; },
    tokenizer(src) {
      const m = /^ {0,3}>[ \t]*\[!([A-Za-z][\w-]*)\]([+-]?)[ \t]*([^\n]*)(?:\n|$)((?: {0,3}>[^\n]*(?:\n|$))*)/.exec(src);
      if (!m) return undefined;
      const body = m[4].replace(/^ {0,3}> ?/gm, "");
      const token = {
        type: "callout", raw: m[0], kind: m[1].toLowerCase(), fold: m[2], title: m[3].trim(),
        tokens: [],
      };
      this.lexer.blockTokens(body, token.tokens);
      return token;
    },
    renderer(t) {
      const kind = escapeHTML(t.kind);
      const titleHTML = t.title ? escapeHTML(t.title) : escapeHTML(t.kind.charAt(0).toUpperCase() + t.kind.slice(1));
      const inner = this.parser.parse(t.tokens);
      if (t.fold) {
        return `<details class="callout" data-kind="${kind}"${t.fold === "+" ? " open" : ""}><summary class="ct">${titleHTML}</summary><div class="cb">${inner}</div></details>\n`;
      }
      return `<div class="callout" data-kind="${kind}"><div class="ct">${titleHTML}</div><div class="cb">${inner}</div></div>\n`;
    },
  };

  const highlight = {
    name: "highlight",
    level: "inline",
    start(src) { const i = near(src).indexOf("=="); return i < 0 ? undefined : i; },
    tokenizer(src) {
      const m = /^==(?=\S)([^\n]*?\S)==/.exec(src);
      if (!m) return undefined;
      return { type: "highlight", raw: m[0], tokens: this.lexer.inlineTokens(m[1]) };
    },
    renderer(t) { return `<mark class="hl">${this.parser.parseInline(t.tokens)}</mark>`; },
  };

  const commentBlock = {
    name: "commentBlock",
    level: "block",
    start(src) { const m = /(^|\n)%%/.exec(near(src)); return m ? m.index + m[1].length : undefined; },
    tokenizer(src) {
      const m = /^%%[\s\S]*?%%[ \t]*(?:\n|$)/.exec(src);
      return m ? { type: "commentBlock", raw: m[0] } : undefined;
    },
    renderer() { return ""; },
  };

  const commentInline = {
    name: "commentInline",
    level: "inline",
    start(src) { const i = near(src).indexOf("%%"); return i < 0 ? undefined : i; },
    tokenizer(src) {
      const m = /^%%[^\n]*?%%/.exec(src);
      return m ? { type: "commentInline", raw: m[0] } : undefined;
    },
    renderer() { return ""; },
  };

  // #tag after a space or at the start of a line; letters (any script), digits, _, - and /, not all digits.
  const tag = {
    name: "tag",
    level: "inline",
    start(src) {
      const m = /(^|[\s(])#(?=[\p{L}\p{N}_])/u.exec(near(src));
      return m ? m.index + m[1].length : undefined;
    },
    tokenizer(src) {
      const m = /^#([\p{L}\p{N}_][\p{L}\p{N}_\-/]*)/u.exec(src);
      if (!m || /^\d+$/.test(m[1])) return undefined;
      return { type: "tag", raw: m[0], name: m[1] };
    },
    renderer(t) { return `<span class="tag">#${escapeHTML(t.name)}</span>`; },
  };

  const mathBlock = {
    name: "mathBlock",
    level: "block",
    start(src) { const m = /(^|\n) {0,3}\$\$/.exec(near(src)); return m ? m.index + m[1].length : undefined; },
    tokenizer(src) {
      const m = /^ {0,3}\$\$([\s\S]+?)\$\$[ \t]*(?:\n|$)/.exec(src);
      return m ? { type: "mathBlock", raw: m[0], tex: m[1].trim() } : undefined;
    },
    renderer(t) { return `<div class="math display" data-k="${stash(t.tex)}"></div>\n`; },
  };

  const mathInline = {
    name: "mathInline",
    level: "inline",
    start(src) { const i = near(src).indexOf("$"); return i < 0 ? undefined : i; },
    tokenizer(src) {
      // $x$: no space just inside the dollars, and no digit right after the closing one ($5 and $10).
      const m = /^\$(?!\s)((?:\\\$|[^$\n])+?)(?<!\s)\$(?!\d)/.exec(src);
      return m ? { type: "mathInline", raw: m[0], tex: m[1] } : undefined;
    },
    renderer(t) { return `<span class="math" data-k="${stash(t.tex)}"></span>`; },
  };

  // Footnotes: references become superscript links; definitions are lifted out and listed at the end.
  const footnoteRef = {
    name: "footnoteRef",
    level: "inline",
    start(src) { const i = near(src).indexOf("[^"); return i < 0 ? undefined : i; },
    tokenizer(src) {
      const m = /^\[\^([^\]\s]+)\](?!:)/.exec(src);
      return m ? { type: "footnoteRef", raw: m[0], id: m[1] } : undefined;
    },
    renderer(t) {
      const ctx = root.LinenDialect.context;
      const n = (ctx && ctx.footnotes && ctx.footnotes[t.id]) || "?";
      const id = escapeHTML(t.id);
      return `<sup class="fnref"><a href="#fn-${id}" data-fn="${id}" id="fnref-${id}">${n}</a></sup>`;
    },
  };

  const footnoteDef = {
    name: "footnoteDef",
    level: "block",
    start(src) { const m = /(^|\n)\[\^[^\]\s]+\]:/.exec(near(src)); return m ? m.index + m[1].length : undefined; },
    tokenizer(src) {
      const m = /^\[\^([^\]\s]+)\]:[ \t]*([^\n]*(?:\n(?: {2,}|\t)[^\n]*)*)(?:\n|$)/.exec(src);
      if (!m) return undefined;
      const token = { type: "footnoteDef", raw: m[0], id: m[1], tokens: [] };
      this.lexer.inlineTokens(m[2].replace(/\n(?: {2,}|\t)/g, " "), token.tokens);
      return token;
    },
    renderer() { return ""; },
  };

  // Linen 2 (Lane F, BLK and NOTE): :w[Broken] is a status word; :note[term]{#id} opens the note with that id.
  // blocks.js dresses both on the page.
  const statusWord = {
    name: "statusWord",
    level: "inline",
    start(src) { const i = near(src).indexOf(":w["); return i < 0 ? undefined : i; },
    tokenizer(src) {
      const m = /^:w\[([^\]\n]{1,40})\]/.exec(src);
      return m && m[1].trim() ? { type: "statusWord", raw: m[0], word: m[1].trim() } : undefined;
    },
    renderer(t) { return `<span class="lw" data-w="${escapeHTML(t.word)}">${escapeHTML(t.word)}</span>`; },
  };
  const noteTerm = {
    name: "noteTerm",
    level: "inline",
    start(src) { const i = near(src).indexOf(":note["); return i < 0 ? undefined : i; },
    tokenizer(src) {
      const m = /^:note\[([^\]\n]+)\]\{#([^}\s]+)\}/.exec(src);
      return m ? { type: "noteTerm", raw: m[0], id: m[2], tokens: this.lexer.inlineTokens(m[1]) } : undefined;
    },
    renderer(t) { return `<span class="lnote" data-note="${escapeHTML(t.id)}" tabindex="0">${this.parser.parseInline(t.tokens)}</span>`; },
  };

  const extensions = [callout, mathBlock, commentBlock, footnoteDef, wikilink, highlight, commentInline, statusWord, noteTerm, tag, mathInline, footnoteRef];
  // Fenced Loom blocks (BLK-2 to BLK-6): placeholders like diagrams, filled by blocks.js after sanitising.
  const LOOM_BLOCKS = new Set(["tiles", "cards", "steps", "bar", "side"]);

  // A ```math fence is display math; a ```mermaid fence becomes a diagram placeholder; other code keeps
  // its language for the highlighter, which runs later and only near the screen.
  const renderer = {
    code(token) {
      const lang = (token.lang || "").trim().split(/\s+/)[0].toLowerCase();
      if (lang === "math") return `<div class="math display" data-k="${stash(token.text)}"></div>\n`;
      if (lang === "mermaid") return `<div class="mermaid-src" data-k="${stash(token.text)}"></div>\n`;
      if (LOOM_BLOCKS.has(lang)) return `<div class="lblk-src" data-lang="${lang}" data-k="${stash(token.text)}"></div>\n`;
      const label = lang ? `<span class="lang">${escapeHTML(lang)}</span>` : "";
      return `<pre class="code" data-lang="${escapeHTML(lang)}">${label}<code>${escapeHTML(token.text)}</code></pre>\n`;
    },
  };

  root.LinenDialect = {
    extensions, renderer, escapeHTML, linkName, context: null, sources,
    configure(marked) {
      marked.use({ gfm: true, breaks: false, extensions, renderer });
      return marked;
    },
  };
})(typeof self !== "undefined" ? self : globalThis);
