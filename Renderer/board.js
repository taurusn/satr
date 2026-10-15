// Linen's boards (PRD-2 sections 6.1, 8 and 9.2). A JSON Canvas board, read by board-model.js, is drawn as DOM and
// SVG in two transformed layers (sections, connectors and their labels under; cards over) with one screen canvas
// between them for the shapes of cards that are in view but not in the DOM, and one behind them for the weave.
// Spike B(a)'s four rules hold: mid-gesture only the transform changes (and the two canvases redraw); cards in view
// that are not mounted are drawn as their shapes on the canvas, which is the whole board at the areas level; at rest
// cards mount 24 per frame, nearest the centre first; the card layer is composited only while cards are mounted above
// the areas level. Nothing here touches the network or a file; the app hears through post().
(() => {
  "use strict";

  const html = document.documentElement;
  const X = () => window.linenInternals || {};
  const post = (m) => { const p = X().post; if (p) p(m); else try { window.webkit.messageHandlers.linen.postMessage(m); } catch (_) { /* outside the app */ } };
  const lang = () => (X().lang ? X().lang() : "en");
  const AR = {
    "Sections": "الأقسام", "Filter": "تصفية", "Show": "اعرض", "Hide": "أخفِ", "Fit": "ملاءمة", "Next": "التالي", "Previous": "السابق",
    "1 problem": "مشكلة واحدة", "{n} problems": "المشكلات: {n}", "{n} changed since {d}": "تغيّر {n} منذ {d}", "{n} changed": "تغيّر {n}",
    "Rewritten since you read it": "أعيدت كتابتها منذ قرأتها", "Rewritten since you read it on {d}": "أعيدت كتابتها منذ قرأتها في {d}",
    "This version has {n} problems · showing the last good board": "في هذه النسخة مشكلات ({n}) · تُعرض آخر نسخة سليمة",
    "This version has 1 problem · showing the last good board": "في هذه النسخة مشكلة واحدة · تُعرض آخر نسخة سليمة",
    "Leads to {x}": "يؤدي إلى {x}", "Read as list": "اقرأها قائمة", "Show on board": "اعرض على اللوحة", "Copied a reference to {x}": "نُسخ مرجع {x}",
    "That box is no longer on this board": "هذا الصندوق لم يعد على هذه اللوحة", "Linen could not read this board": "تعذّر على سطر قراءة هذه اللوحة",
    "Done": "تم", "Not found": "لا توجد نتائج", "{a} of {b}": "{a} من {b}", "Note": "ملاحظة", "Board": "لوحة", "Page": "صفحة", "Link": "رابط",
    "Image": "صورة", "File": "ملف", "Sources": "المصادر", "Not placed": "غير موضوع", "Canvas": "اللوحة", "List": "قائمة", "Find on board": "ابحث في اللوحة",
    "{n} removed": "حُذف {n}", "{n} boxes": "صناديق: {n}", "Board {name}, {n} boxes": "لوحة {name}، صناديق: {n}", "In view: {s}": "المعروض: {s}",
    "Zoom out": "صغّر", "Zoom in": "كبّر", "Problems": "المشكلات", "Not drawn": "لم يُرسم", "These boxes have no position": "هذه الصناديق بلا موضع",
    "Too large to draw here; showing it as a list": "أكبر من أن تُرسم هنا؛ تُعرض قائمة", "Colour {n}": "اللون {n}", "Close": "أغلق",
    "Tours": "الجولات", "Tour": "جولة", "Draw it anyway": "ارسمها رغم ذلك", "Laid out again for this view · run linen layout to save it": "أعيد ترتيبها لهذا العرض · شغّل linen layout لحفظ الترتيب",
  };
  const t = (k, v) => { let o = (lang() === "ar" && AR[k]) || k; for (const [a, b] of Object.entries(v || {})) o = o.replaceAll(`{${a}}`, b); return o; };
  // One digit system per screen: Arabic-Indic throughout an Arabic interface (section 8).
  const num = (n) => Number(n).toLocaleString(lang() === "ar" ? "ar-u-nu-arab" : "en");
  const esc = (s) => String(s == null ? "" : s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const clamp = (v, a, b) => Math.max(a, Math.min(b, v));

  // Semantic zoom (BRD-8), in numbers for the 15 px card body: read at 0.73 or more, map from 0.30, areas below.
  const READ = 0.73, MAP = 0.30, MIN_S = 0.02, MAX_S = 4;
  const BUDGET = 24, REST_MS = 140, ACK_MS = 3000, FLY_MS = 340;
  const levelOf = (s) => (s >= READ - 1e-9 ? "read" : s >= MAP ? "map" : "areas");
  const reduceMotion = window.matchMedia ? window.matchMedia("(prefers-reduced-motion: reduce)") : { matches: false };
  const FILE_KINDS = new Set(["note", "board", "page", "image", "file", "link"]);

  const S = {
    active: false, board: null, good: null, path: "", name: "", refPath: "", docId: null, version: 0, dir: "ltr",
    view: { s: 1, tx: 0, ty: 0 }, W: 800, H: 600, ox: 0, oy: 0, level: "read", moving: false, hideCards: false, restTimer: 0,
    mounted: new Map(), secs: new Map(), edgesOn: new Map(), chipsOn: new Map(), queue: [], pumping: false, mountToken: 0,
    mode: "canvas", rail: true, railOverlay: false, selected: null, focus: null, hover: null, lit: null,
    find: { open: false, q: "", hits: [], cur: -1 }, legend: { word: null, hits: [], cur: -1 },
    base: null, baseDate: null, changed: new Set(), removed: [], rewritten: false, chgCur: -1, seen: new Map(),
    history: [], note: null, noteTimer: 0, problemsOpen: false, badVersion: null, firstPaintPending: null, place: null,
    colors: null, ord: new Map(), out: new Map(), contentCache: new Map(), fitTitle: new Map(), roomAbove: new Map(),
    flight: 0, space: false, list: null, listBuiltFor: null, bgs: new Map(), previews: {}, changedEdges: new Set(),
  };

  // ---------- the board's elements ----------
  let R = null;
  function dom() {
    if (R) return R;
    const root = document.createElement("div");
    root.id = "board";
    root.hidden = true;
    root.innerHTML = `
<nav class="b-rail" aria-label="Board outline">
  <div class="b-meta"><div class="b-btitle" hidden></div><div class="legend b-legend" role="list"></div>
    <div class="b-probline" hidden><b></b><button type="button" class="b-link"></button></div><ul class="b-probs" hidden></ul></div>
  <input class="b-filter" type="search" autocomplete="off" spellcheck="false">
  <div class="b-otitle"></div>
  <div class="b-secs" role="list"></div>
  <button class="b-readlist" type="button"></button>
</nav>
<div class="b-canvas" tabindex="0" role="application"><button class="b-readlist2" type="button"></button>
  <canvas class="b-weave" aria-hidden="true"></canvas>
  <canvas class="b-shapes" aria-hidden="true"></canvas>
  <div class="b-layer b-under"><div class="b-secl"></div></div>
  <div class="b-layer b-over"><div class="b-chips"></div></div>
  <div class="b-line" hidden><span></span><button type="button" class="b-link"></button></div>
  <div class="b-hlabel" hidden><b></b><span></span></div>
  <div class="b-notecard" role="dialog" hidden></div>
  <div class="b-zpanel b-glass"><div class="legend compact b-zlegend" hidden></div>
    <div class="b-zoomrow"><button type="button" class="b-zout">−</button><span class="b-zpct"></span><button type="button" class="b-zin">+</button><button type="button" class="b-fit"></button></div></div>
  <div class="b-chip b-glass" hidden><span class="b-chiptext"></span><button type="button" class="b-chipnext"></button></div>
  <div class="b-toast" hidden></div>
</div>
<div class="b-list" hidden></div>
<div class="b-honest" hidden></div>
<div class="b-find" hidden><span class="fi" aria-hidden="true"></span><input class="b-findq" type="search" autocomplete="off" spellcheck="false">
  <span class="b-findn" aria-live="polite"></span><button type="button" class="b-findp" aria-label="Previous match"></button><button type="button" class="b-findx" aria-label="Next match"></button><button type="button" class="b-findd"></button></div>
<div class="b-status vh" role="status" aria-live="polite"></div>`;
    document.body.appendChild(root);
    const q = (c) => root.querySelector(c);
    R = {
      root, rail: q(".b-rail"), btitle: q(".b-btitle"), legend: q(".b-legend"), probline: q(".b-probline"), probs: q(".b-probs"),
      filter: q(".b-filter"), otitle: q(".b-otitle"), secsList: q(".b-secs"), readlist: q(".b-readlist"),
      canvas: q(".b-canvas"), weave: q(".b-weave"), under: q(".b-under"), secl: q(".b-secl"),
      chips: q(".b-chips"), shapes: q(".b-shapes"), over: q(".b-over"), line: q(".b-line"), hlabel: q(".b-hlabel"), notecard: q(".b-notecard"),
      zpanel: q(".b-zpanel"), zlegend: q(".b-zlegend"), zpct: q(".b-zpct"), chip: q(".b-chip"), chiptext: q(".b-chiptext"), chipnext: q(".b-chipnext"),
      toast: q(".b-toast"), list: q(".b-list"), honest: q(".b-honest"), find: q(".b-find"), findq: q(".b-findq"), findn: q(".b-findn"),
      status: q(".b-status"),
    };
    R.wctx = R.weave.getContext("2d");
    R.sctx = R.shapes.getContext("2d");
    wire();
    return R;
  }

  // ---------- colours (read from the page's tokens, so the canvases match the CSS in both looks) ----------
  function hexRGB(h) {
    h = (h || "").trim().replace("#", "");
    if (h.length === 3) h = h.split("").map((c) => c + c).join("");
    const n = parseInt(h.slice(0, 6), 16);
    return isNaN(n) ? [0, 0, 0] : [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }
  const rgba = (c, a) => `rgba(${c[0]},${c[1]},${c[2]},${a})`;
  function readColors() {
    const cs = getComputedStyle(html);
    const v = (k) => hexRGB(cs.getPropertyValue(k));
    const night = html.dataset.theme === "night";
    const paper = v("--paper"), paper2 = v("--paper-2"), ink = v("--ink"), ink2 = v("--ink-2"), rule = v("--rule"), rust = v("--rust");
    const t1 = v("--tint-1"), t2 = v("--tint-2"), sage = v("--sage");
    const c = {
      night, ground: rgba(night ? ink2 : paper, 1), card: rgba(night ? ink : paper2, 1), ink: rgba(night ? paper : ink, 1),
      ink2: night ? rgba(paper, 0.86) : rgba(ink2, 1), rule: night ? rgba(paper, 0.14) : rgba(rule, 1), rust: rgba(rust, 1),
      sec: night ? rgba(paper, 0.04) : rgba(t1, 0.42), weave: night ? rgba(paper, 0.09) : rgba(ink, 0.13), paperText: rgba(paper, 1),
      // JSON Canvas's six presets as flat Loom washes (section 8): tokens with alpha, never a new hue.
      washes: night
        ? [rgba(paper, 0.2), rgba(paper, 0.13), rgba(paper, 0.07), rgba(sage, 0.32), rgba(sage, 0.5), rgba(paper, 0.3)]
        : [rgba(rule, 1), rgba(rule, 0.6), rgba(paper2, 1), rgba(t1, 1), rgba(t2, 1), rgba(ink, 0.18)],
    };
    S.colors = c;
    if (R) c.washes.forEach((w, i) => R.root.style.setProperty(`--c${i + 1}`, w));
    S.hatch = null;
    S.weaveTile = null;
    return c;
  }
  const COLOUR_NAMES = ["red", "orange", "yellow", "green", "cyan", "purple"];
  function washIndex(color) {
    if (!color) return -1;
    if (/^[1-6]$/.test(color)) return Number(color) - 1;
    const [r, g, b] = hexRGB(color).map((x) => x / 255);
    const mx = Math.max(r, g, b), mn = Math.min(r, g, b), d = mx - mn;
    if (d < 0.08) return 2;
    let h = mx === r ? ((g - b) / d) % 6 : mx === g ? (b - r) / d + 2 : (r - g) / d + 4;
    h = (h * 60 + 360) % 360;
    return h < 20 || h >= 340 ? 0 : h < 50 ? 1 : h < 70 ? 2 : h < 160 ? 3 : h < 250 ? 4 : 5;
  }

  // ---------- words (WORDS-1, WORDS-2) ----------
  const findWord = (n, words) => (n && n.word && words ? words.find((w) => w.word === n.word) || null : null);
  const wordOf = (n) => findWord(n, S.board && S.board.words);
  const shapeOf = (n) => { const w = wordOf(n); return w ? w.shape : null; };
  const swatch = (shape) => `<i class="sw6 s-${shape || "none"}"></i>`;
  // `words` is given when a card is built outside the loaded board (measuring for `linen layout`).
  const pillOf = (n, words) => {
    const w = words ? findWord(n, words) : wordOf(n);
    if (!w || w.quiet) return "";
    return `<span class="st s-${w.shape}">${esc(w.word)}</span>`;
  };

  // ---------- rendering card content ----------
  function md(src) {
    const x = X();
    if (!x.marked || !window.DOMPurify) return `<p>${esc(src)}</p>`;
    let out;
    try { out = x.marked.parse(String(src || "")); } catch (_) { out = `<p>${esc(src)}</p>`; }
    return window.DOMPurify.sanitize(out, x.PURIFY);
  }
  function directionise(el) {
    const x = X();
    if (!x.directionOf) return;
    el.querySelectorAll("p, h1, h2, h3, h4, h5, h6, li, blockquote, td, th, .callout").forEach((n) => {
      const d = x.directionOf(n, S.dir);
      if (d) n.setAttribute("dir", d);
    });
  }
  const hostOf = (u) => { try { return new URL(u).host; } catch (_) { return u; } };
  const baseName = (p) => String(p || "").split("/").pop();
  const titleOf = (n) => {
    if (!n) return "";
    if (n.kind === "section") return n.label || n.title || "";
    if (n.title) return n.title;
    if (n.kind === "link") return n.url || "";
    const b = (n.body || n.text || "").trim().split("\n")[0] || "";
    return b.replace(/^#+\s*/, "").replace(/[*_`[\]]/g, "").slice(0, 80);
  };
  const plainText = (n) => [titleOf(n), n.body || "", n.label || "", n.file || "", n.url || "", n.word || "",
    n.note ? [n.note.area, n.note.title, n.note.body, (n.note.refs || []).join(" "), Object.values(n.note.fields || {}).join(" ")].join(" ") : ""].join("\n");

  const SHAPE_SVG = {
    rect: (w, h) => `<rect x="1" y="1" width="${w - 2}" height="${h - 2}" rx="2"/>`,
    rounded: (w, h) => `<rect x="1" y="1" width="${w - 2}" height="${h - 2}" rx="${Math.min(18, h / 4)}"/>`,
    ellipse: (w, h) => `<ellipse cx="${w / 2}" cy="${h / 2}" rx="${w / 2 - 1}" ry="${h / 2 - 1}"/>`,
    diamond: (w, h) => `<path d="M${w / 2} 1L${w - 1} ${h / 2}L${w / 2} ${h - 1}L1 ${h / 2}Z"/>`,
    pill: (w, h) => `<rect x="1" y="1" width="${w - 2}" height="${h - 2}" rx="${h / 2 - 1}"/>`,
    cylinder: (w, h) => { const e = Math.min(14, h / 6); return `<path d="M1 ${e}V${h - e}A${w / 2 - 1} ${e} 0 0 0 ${w - 1} ${h - e}V${e}A${w / 2 - 1} ${e} 0 0 0 1 ${e}Z"/><path d="M1 ${e}A${w / 2 - 1} ${e} 0 0 0 ${w - 1} ${e}"/>`; },
    hexagon: (w, h) => { const k = Math.min(w / 4, h / 2); return `<path d="M${k} 1H${w - k}L${w - 1} ${h / 2}L${w - k} ${h - 1}H${k}L1 ${h / 2}Z"/>`; },
  };

  // Reading-level content, cached by the node's content hash.
  function readContent(n, words) {
    const c = words ? null : S.contentCache.get(n.id);
    if (c && c.hash === n.hash) return c.html;
    const pill = (m) => pillOf(m, words);
    let h = "";
    const eb = n.eyebrow ? `<div class="b-eb">${esc(n.eyebrow)}</div>` : "";
    switch (n.kind) {
      case "sticky": h = `${eb}<div class="b-body">${md(n.body || n.text || "")}</div>`; break;
      case "shape": {
        const sh = SHAPE_SVG[n.shape] || SHAPE_SVG.rect;
        h = `<svg class="b-sh" viewBox="0 0 ${n.w} ${n.h}" preserveAspectRatio="none" aria-hidden="true">${sh(n.w, n.h)}</svg><div class="b-sht">${pill(n)}${md(n.title ? `**${n.title}**\n\n${n.body || ""}` : n.body || n.text || "")}</div>`;
        break;
      }
      case "text": h = `<div class="b-body">${md(n.title ? `# ${n.title}\n\n${n.body || ""}` : n.body || n.text || "")}</div>`; break;
      case "image": h = `<img data-file="${esc(n.file)}" alt="${esc(titleOf(n))}">`; break;
      case "note": case "board": case "page": case "file": {
        const k = { note: t("Note"), board: t("Board"), page: t("Page"), file: t("File") }[n.kind];
        const pv = S.previews && S.previews[n.origId || n.id]; // the note's first screen, read by the app through the vault gate
        h = `<div class="b-eb">${esc(k)} · <span class="b-path">${esc(baseName(n.file) + (n.subpath || ""))}</span></div>${pill(n)}<h4>${esc(titleOf(n))}</h4>${pv ? `<div class="b-body b-preview">${md(String(pv).slice(0, 4000))}</div>` : n.body ? `<div class="b-body">${md(n.body)}</div>` : ""}`;
        break;
      }
      case "link": h = `<div class="b-eb">${esc(t("Link"))} · <span class="b-path">${esc(hostOf(n.url))}</span></div>${pill(n)}<h4 class="b-lt">${esc(n.title || n.url)}</h4>`; break;
      case "unknown": h = `<div class="b-body"><p>${esc(n.title || n.text || "")}</p></div>`; break;
      default: {
        const p = pill(n);
        h = `${p}${eb}${n.title ? `<h4${p || eb ? "" : ' class="q"'}>${esc(n.title)}</h4>` : ""}${n.body ? `<div class="b-body">${md(n.body)}</div>` : ""}`;
      }
    }
    if (!words) S.contentCache.set(n.id, { hash: n.hash, html: h });
    return h;
  }

  // Titles at the map level: Sans 500 that shrinks to fit two lines before it would fall under 9 px on screen (BRD-8).
  let measureCtx = null;
  function textWidth(text, px, weight) {
    if (!measureCtx) measureCtx = document.createElement("canvas").getContext("2d");
    measureCtx.font = `${weight || 500} ${px}px "Linen Sans", -apple-system, sans-serif`;
    return measureCtx.measureText(text).width;
  }
  function linesFor(text, width, px) {
    const words = String(text).split(/\s+/).filter(Boolean);
    if (!words.length) return 0;
    let lines = 1, cur = 0;
    const space = textWidth(" ", px);
    for (const w of words) {
      const ww = textWidth(w, px);
      if (ww > width) return 99;
      if (cur === 0) cur = ww;
      else if (cur + space + ww <= width) cur += space + ww;
      else { lines++; cur = ww; }
    }
    return lines;
  }
  // On-screen font size for a map-level title, or 0 when it cannot fit at 9 px.
  function mapTitleSize(n, s) {
    const title = titleOf(n);
    if (!title) return 0;
    const key = `${n.id}|${n.hash}|${s.toFixed(3)}`;
    const hit = S.fitTitle.get(key);
    if (hit !== undefined) return hit;
    const pad = 8;
    const w = n.w * s - 2 * pad, h = n.h * s - 2 * 4;
    let out = 0;
    // From 15 px on screen down to the 9 px floor, two lines at most (BRD-8).
    for (let px = 15; px >= 9; px--) {
      const l = linesFor(title, w, px);
      if (l <= 2 && l * px * 1.12 <= h) { out = px; break; }
    }
    if (S.fitTitle.size > 20000) S.fitTitle.clear();
    S.fitTitle.set(key, out);
    return out;
  }

  // A text node's size on the board: a "# " title at 40, "## " at 28, else 19 (board.css .k-text).
  function textNodeSize(n) { const t0 = String(n.title ? "# " + n.title : n.body || n.text || ""); return /^#\s/.test(t0) ? 40 : /^##\s/.test(t0) ? 28 : 19; }
  function textNodeLine(n) { return String(n.title || (n.body || n.text || "").split("\n").find((l) => l.trim()) || "").replace(/^#+\s*/, "").replace(/[*_`]/g, ""); }

  // ---------- mounting cards ----------
  function cardClass(n) {
    const sh = shapeOf(n);
    const cls = ["b-node", `k-${n.kind}`, `lv-${S.level}`];
    if (sh) cls.push(`s-${sh}`);
    if (n.note) cls.push("noted");
    const wi = washIndex(n.color);
    if (wi >= 0) cls.push(`c${wi + 1}`);
    if (S.changed.has(n.id) && !S.rewritten) cls.push("chg");
    if (S.selected === n.id) cls.push("sel");
    if (S.focus === n.id) cls.push("focus");
    const fi = S.find.open && S.find.q ? S.find.hits.indexOf(n.id) : -1;
    const li = S.legend.word ? S.legend.hits.indexOf(n.id) : -1;
    if (fi >= 0 || li >= 0) cls.push("hit");
    if ((fi >= 0 && fi === S.find.cur) || (li >= 0 && li === S.legend.cur)) cls.push("cur");
    return cls.join(" ");
  }
  // Card bodies render Linen's blocks and words (BRD-2): tiles, steps, bar, tables, :w[Word] pills.
  function expandBlocks(el) {
    const B = window.LinenBlocks;
    if (B && typeof B.expand === "function") { try { B.expand(el); } catch (_) { /* the plain Markdown stays */ } }
  }
  function fillCard(el, n) {
    el.className = cardClass(n);
    if (S.level === "read") {
      el.innerHTML = readContent(n);
      expandBlocks(el);
      el.querySelectorAll("img").forEach(prepImg);
      directionise(el);
      const x = X();
      if (x.fill) el.querySelectorAll(".math, .mermaid-src").forEach((m) => { try { x.fill(m); } catch (_) { /* drawn later */ } });
      el.dataset.lv = "read";
    } else {
      const s = S.view.s;
      if (n.kind === "text") { // its own words when they stay at 9 px, else nothing (never a blank box)
        const ts = textNodeSize(n) * s;
        el.innerHTML = ts >= 9 ? `<div class="b-tline" style="font-size:${(ts / s).toFixed(2)}px" dir="${n.dir || "auto"}">${esc(textNodeLine(n))}</div>` : "";
        el.dataset.lv = "map";
        el.dataset.px = "t";
        return;
      }
      const px = mapTitleSize(n, s);
      const outline = n.kind === "shape" ? `<svg class="b-sh" viewBox="0 0 ${n.w} ${n.h}" preserveAspectRatio="none" aria-hidden="true">${(SHAPE_SVG[n.shape] || SHAPE_SVG.rect)(n.w, n.h)}</svg>` : "";
      el.innerHTML = outline + (px ? `<h4 style="font-size:${(px / s).toFixed(2)}px"><span>${esc(titleOf(n))}</span></h4>` : "");
      el.dataset.lv = "map";
      el.dataset.px = String(px);
    }
    if (S.level !== "read" && S.changed.has(n.id) && !S.rewritten) el.insertAdjacentHTML("beforeend", '<i class="cdot"></i>');
  }
  function prepImg(img) {
    const x = X();
    if (img.dataset.file) { img.setAttribute("src", img.dataset.file); img.removeAttribute("data-file"); }
    if (x.prepareImage) { try { x.prepareImage(img); } catch (_) { /* a broken source stays broken */ } }
    S.wantImages = true;
  }
  // VoiceOver reads the mounted boxes in the board's reading order, whatever order they mounted in (BRD-18).
  let ariaTimer = 0;
  function ariaOrder() {
    clearTimeout(ariaTimer);
    ariaTimer = setTimeout(() => {
      if (!S.board) return;
      const ids = S.board.order.filter((id) => S.mounted.has(id)).map((id) => S.mounted.get(id).id);
      R.canvas.setAttribute("aria-owns", ids.join(" "));
    }, 60);
  }
  let domSeq = 0;
  function mountCard(n) {
    const el = document.createElement("div");
    el.id = `bn-${++domSeq}`;
    el.dataset.id = n.id;
    el.style.cssText = `left:${n.x}px;top:${n.y}px;width:${n.w}px;height:${n.h}px`;
    el.setAttribute("dir", S.dir); // threads and corners follow the board (BRD-27); text inside takes its own direction
    el.setAttribute("role", "group");
    el.setAttribute("aria-label", ariaFor(n));
    fillCard(el, n);
    R.over.appendChild(el);
    S.mounted.set(n.id, el);
    return el;
  }
  function ariaFor(n) {
    const w = wordOf(n);
    const outs = (S.out.get(n.id) || []).map((id) => titleOf(S.board.byId.get(id))).filter(Boolean);
    return [titleOf(n), w ? w.word : "", (n.body || "").slice(0, 300), outs.length ? t("Leads to {x}", { x: outs.slice(0, 3).join(", ") + (outs.length > 3 ? ` +${outs.length - 3}` : "") }) : ""].filter(Boolean).join(". ");
  }
  // A card whose text runs past its box fades out at the bottom; read after a batch, so layout runs once.
  function markOverflow(els) {
    const over = els.map((el) => el.dataset.lv === "read" && el.scrollHeight > el.clientHeight + 2);
    els.forEach((el, i) => el.classList.toggle("over", over[i]));
  }
  function unmountCard(id) {
    const el = S.mounted.get(id);
    if (el) { el.remove(); S.mounted.delete(id); }
  }
  function unmountAll() {
    for (const el of S.mounted.values()) el.remove();
    S.mounted.clear();
    S.queue = [];
  }

  // At rest: which cards should be in the DOM, and the queue for the ones that are not yet.
  function viewRect(marginScreens) {
    const { s, tx, ty } = S.view;
    const m = (marginScreens || 0) * Math.max(S.W, S.H) / s;
    return { x: -tx / s - m, y: -ty / s - m, w: S.W / s + 2 * m, h: S.H / s + 2 * m };
  }
  function cull() {
    const b = S.board;
    if (!b) return;
    const want = new Set();
    if (S.level !== "areas") {
      const r = viewRect(0.5);
      for (const id of b.grid.query(r.x, r.y, r.w, r.h)) {
        const n = b.byId.get(id);
        if (n && n.kind !== "section") want.add(id);
      }
    }
    for (const id of [...S.mounted.keys()]) if (!want.has(id)) unmountCard(id);
    // Mounted cards from the other level change their content in place, nearest first, in the same budget.
    const { s, tx, ty } = S.view;
    const cx = (S.W / 2 - tx) / s, cy = (S.H / 2 - ty) / s;
    const dist = (n) => Math.hypot(n.x + n.w / 2 - cx, n.y + n.h / 2 - cy);
    const lv = S.level === "read" ? "read" : "map";
    const q = [];
    for (const id of want) {
      const n = b.byId.get(id);
      const el = S.mounted.get(id);
      if (!el) q.push(n);
      else if (el.dataset.lv !== lv || (lv === "map" && el.dataset.px !== "t" && Number(el.dataset.px) !== mapTitleSize(n, s)) || (lv === "map" && el.dataset.px === "t")) q.push(n);
    }
    q.sort((a, c) => dist(a) - dist(c));
    S.queue = q;
    S.mountToken++;
    if (q.length) pump();
  }
  function pump() {
    if (S.pumping) return;
    S.pumping = true;
    const token = S.mountToken;
    const step = () => { try { slice(); } catch (err) { S.pumping = false; S.queue = []; post({ type: "error", during: "board mount", message: String(err && err.message || err) }); } };
    const slice = () => {
      if (token !== S.mountToken && !S.queue.length) { S.pumping = false; return; }
      const fresh = [];
      for (let k = 0; k < BUDGET && S.queue.length; k++) {
        const n = S.queue.shift();
        if (!S.board || S.board.byId.get(n.id) !== n) continue;
        try {
          const el = S.mounted.get(n.id);
          if (el) { fillCard(el, n); fresh.push(el); } else fresh.push(mountCard(n));
        } catch (err) { unmountCard(n.id); post({ type: "error", during: "board card", message: `${n.id}: ${String(err && err.message || err)}` }); }
      }
      markOverflow(fresh);
      ariaOrder();
      if (S.wantImages) { S.wantImages = false; const x = X(); if (x.requestImages) x.requestImages(); }
      drawShapes();
      if (S.queue.length) next(step);
      else {
        S.pumping = false;
        if (S.firstPaintPending) firstPaintDone();
      }
    };
    next(step);
  }
  // Animation frames nearly stop in hidden windows; a message channel does not (Linen 1's build log).
  // A timer races the frame, since offscreen windows (the command, the harness) get no frames at all.
  const next = (fn) => {
    if (document.hidden && X().nextFrame) { X().nextFrame().then(fn); return; }
    let done = false;
    const go = () => { if (!done) { done = true; fn(); } };
    requestAnimationFrame(go);
    setTimeout(go, 34);
  };

  // ---------- sections ----------
  function roomAbove(sec) {
    if (S.roomAbove.has(sec.id)) return S.roomAbove.get(sec.id);
    let room = 220;
    const b = S.board;
    for (const id of b.grid.query(sec.x, sec.y - 260, sec.w, 260)) {
      const o = b.byId.get(id);
      if (!o || o === sec || o.parent === sec.id || o.y >= sec.y) continue;
      if (sec.parent && o.id === sec.parent) continue;
      if (o.x + o.w <= sec.x || o.x >= sec.x + sec.w) continue;
      room = Math.min(room, sec.y - (o.y + o.h));
    }
    if (sec.parent) { const p = b.byId.get(sec.parent); if (p) room = Math.min(room, Math.max(0, sec.y - p.y)); }
    room = Math.max(0, room);
    S.roomAbove.set(sec.id, room);
    return room;
  }
  function mountSections() {
    const b = S.board;
    const r = viewRect(0.25);
    const want = new Set();
    for (const id of b.grid.query(r.x, r.y - 200 / S.view.s, r.w, r.h + 200 / S.view.s)) { const n = b.byId.get(id); if (n && n.kind === "section") want.add(id); }
    for (const [id, el] of S.secs) if (!want.has(id)) { el.label.remove(); if (el.title) el.title.remove(); S.secs.delete(id); }
    for (const id of want) {
      const n = b.byId.get(id);
      let e = S.secs.get(id);
      if (!e) {
        // The wash itself is drawn on the ground canvas (large translucent boxes in a layer that moves every frame
        // cost 80 to 90 ms hitches on the Mac); only the name is DOM.
        const label = document.createElement("div");
        label.className = `b-slbl${n.depth > 0 ? " nested" : ""}`;
        label.dataset.id = id;
        label.setAttribute("dir", S.dir);
        e = { label, key: "", title: null };
        R.secl.appendChild(label);
        // A section's serif title sits inside its top padding, where `linen layout` leaves room for it
        // (LinenLayout.METRICS: sectionPad 24 at the top level, groupPad 14 nested).
        if (n.title && n.label) {
          const tt = document.createElement("div");
          tt.className = "b-stitle";
          tt.setAttribute("dir", S.dir);
          const pad = n.depth > 0 ? 14 : 24;
          tt.style.cssText = `left:${n.x + pad}px;top:${n.y + pad}px;width:${Math.max(10, n.w - 2 * pad)}px`;
          tt.innerHTML = `<span>${esc(n.title)}</span>`;
          R.secl.appendChild(tt);
          e.title = tt;
        }
        S.secs.set(id, e);
      }
      if (e.title) e.title.hidden = 24 * S.view.s < 9;
      sizeLabel(n, e);
    }
  }
  // Section names sit above their sections and keep 15 px on screen while they fit; one that would collide drops its
  // eyebrow first, then sits tighter inside its section's top padding, then shrinks to its floor (BRD-8).
  function sizeLabel(n, e) {
    const s = S.view.s;
    const name = n.label || (n.title ? "" : ""), sub = n.eyebrow || "";
    const key = `${s.toFixed(4)}|${name}|${sub}|${n.x},${n.y},${n.w}`;
    if (e.key === key) return;
    e.key = key;
    if (!name && !sub) { e.label.innerHTML = ""; return; }
    const nested = n.depth > 0;
    const avail = (n.w + roomRight(n)) * s - 4; // its own width and the free room beside it
    let room = roomAbove(n) * s - 6;
    // Names keep at least 15 px on screen (BRD-8): top-level names at 24 scaled, never under 15; nested names at 15.
    const ns = nested ? Math.max(15 * s, 15) : Math.max(24 * s, 15);
    let lh = 1.15, gap = nested ? 6 : 8;
    if (ns * lh + gap > room) { lh = 1.0; gap = 2; room += (nested ? 14 : 24) * s; } // sit tighter, in its own top padding
    const nameW = (px) => textWidth(name, px, nested ? 500 : 300) * 1.04;
    const eb = Math.max(11 * s, 9);
    const showName = !!name && nameW(ns) <= avail && ns * lh + gap <= room + 2 && !(nested && S.level === "areas");
    const showEb = showName && !!sub && textWidth(sub.toUpperCase(), eb, 500) * 1.18 <= avail && eb * 1.2 + 2 + ns * lh + gap <= room;
    const sink = Math.max(0, ns * lh + gap - (roomAbove(n) * s - 6)) / s;
    e.label.innerHTML = (showEb ? `<span class="eyebrow" style="font-size:${(eb / s).toFixed(2)}px">${esc(sub)}</span>` : "") +
      (showName ? `<b style="font-size:${(ns / s).toFixed(2)}px;line-height:${lh}">${esc(name)}</b>` : "");
    // The label spans its section's width; an Arabic section sets it from the top-right corner (BRD-27).
    e.label.style.cssText = `left:${S.dir === "rtl" ? n.x - roomRight(n) : n.x}px;top:${(n.y + sink).toFixed(1)}px;width:${n.w + roomRight(n)}px;padding-bottom:${(gap / s).toFixed(2)}px`;
    e.shown = showName ? { size: ns, sink } : null;
  }
  // Free board room beside a section's top edge, on its trailing side, up to the next box or section.
  function roomRight(sec) {
    const key = "r:" + sec.id;
    if (S.roomAbove.has(key)) return S.roomAbove.get(key);
    const b = S.board, rtl = S.dir === "rtl";
    let room = 400;
    const qx = rtl ? sec.x - 400 : sec.x + sec.w;
    for (const id of b.grid.query(qx, sec.y - 80, 400, 100)) {
      const o = b.byId.get(id);
      if (!o || o === sec || o.parent === sec.id || o.y > sec.y + 20 || o.y + o.h < sec.y - 80) continue;
      const gap = rtl ? sec.x - (o.x + o.w) : o.x - (sec.x + sec.w);
      if (gap >= 0) room = Math.min(room, gap - 12);
    }
    room = Math.max(0, room);
    S.roomAbove.set(key, room);
    return room;
  }

  // ---------- connectors ----------
  const NORMAL = { top: [0, -1], bottom: [0, 1], left: [-1, 0], right: [1, 0] };
  function sidePt(n, side) {
    switch (side) {
      case "top": return [n.x + n.w / 2, n.y];
      case "bottom": return [n.x + n.w / 2, n.y + n.h];
      case "left": return [n.x, n.y + n.h / 2];
      default: return [n.x + n.w, n.y + n.h / 2];
    }
  }
  // An edge's geometry in board units: the path, the point and direction at each end, and the label's place.
  function edgeGeom(e) {
    const b = S.board;
    const a = b.byId.get(e.from), c = b.byId.get(e.to);
    if (e.missing) {
      const n = a && a.placed ? a : c && c.placed ? c : null;
      if (!n || e.missing === "both") return null;
      const side = (a === n ? e.fromSide : e.toSide) || "bottom";
      const p = sidePt(n, side), nv = NORMAL[side];
      const q = [p[0] + nv[0] * 70, p[1] + nv[1] * 70];
      return { d: `M${p[0]} ${p[1]}L${q[0]} ${q[1]}`, gap: q, gapDir: nv, mid: [q[0] + nv[1] * 0 + 12, q[1]], missingId: a === n ? e.to : e.from };
    }
    if (!e.drawable || !a || !c) return null;
    const p1 = sidePt(a, e.fromSide), p2 = sidePt(c, e.toSide);
    const n1 = NORMAL[e.fromSide] || [1, 0], n2 = NORMAL[e.toSide] || [-1, 0];
    let d, mid, end2;
    if (e.route === "straight") {
      d = `M${p1[0]} ${p1[1]}L${p2[0]} ${p2[1]}`;
      mid = [(p1[0] + p2[0]) / 2, (p1[1] + p2[1]) / 2];
      end2 = [p2[0] - p1[0], p2[1] - p1[1]];
      var at = polyAt([p1, p2]);
    } else if (e.route === "elbow") {
      const o = 22;
      const a1 = [p1[0] + n1[0] * o, p1[1] + n1[1] * o], a2 = [p2[0] + n2[0] * o, p2[1] + n2[1] * o];
      const horiz1 = n1[0] !== 0;
      const pts = [p1, a1];
      if (horiz1) { const mx = (a1[0] + a2[0]) / 2; pts.push([mx, a1[1]], [mx, a2[1]]); }
      else { const my = (a1[1] + a2[1]) / 2; pts.push([a1[0], my], [a2[0], my]); }
      pts.push(a2, p2);
      d = "M" + pts.map((p) => `${p[0]} ${p[1]}`).join("L");
      mid = [(pts[2][0] + pts[3][0]) / 2, (pts[2][1] + pts[3][1]) / 2];
      end2 = [-n2[0], -n2[1]];
      var at = polyAt(pts);
    } else {
      const dist = Math.hypot(p2[0] - p1[0], p2[1] - p1[1]);
      const k = clamp(dist * 0.42, 24, 260);
      const c1 = [p1[0] + n1[0] * k, p1[1] + n1[1] * k], c2 = [p2[0] + n2[0] * k, p2[1] + n2[1] * k];
      d = `M${p1[0]} ${p1[1]}C${c1[0]} ${c1[1]} ${c2[0]} ${c2[1]} ${p2[0]} ${p2[1]}`;
      mid = [0.125 * p1[0] + 0.375 * c1[0] + 0.375 * c2[0] + 0.125 * p2[0], 0.125 * p1[1] + 0.375 * c1[1] + 0.375 * c2[1] + 0.125 * p2[1]];
      end2 = [-n2[0], -n2[1]];
      var at = (t) => { const u = 1 - t; return [u * u * u * p1[0] + 3 * u * u * t * c1[0] + 3 * u * t * t * c2[0] + t * t * t * p2[0], u * u * u * p1[1] + 3 * u * u * t * c1[1] + 3 * u * t * t * c2[1] + t * t * t * p2[1]]; };
    }
    const end1 = e.route === "straight" ? [p1[0] - p2[0], p1[1] - p2[1]] : [-n1[0], -n1[1]];
    return { d, mid, p1, p2, end1, end2, at };
  }
  function polyAt(pts) {
    const seg = [];
    let total = 0;
    for (let i = 1; i < pts.length; i++) { const l = Math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]); seg.push(l); total += l; }
    return (t) => {
      let want = t * total;
      for (let i = 0; i < seg.length; i++) {
        if (want <= seg[i] || i === seg.length - 1) { const k = seg[i] ? Math.min(1, want / seg[i]) : 0; return [pts[i][0] + (pts[i + 1][0] - pts[i][0]) * k, pts[i][1] + (pts[i + 1][1] - pts[i][1]) * k]; }
        want -= seg[i];
      }
      return pts[pts.length - 1];
    };
  }
  function gapChipPlace(g, label) {
    const b = S.board;
    const w = textWidth(label, 12.5, 500) + 18, h = 22, [gx, gy] = g.gap;
    for (const p of [[gx + 14 + w / 2, gy], [gx - 14 - w / 2, gy], [gx, gy + 22], [gx, gy - 22]]) {
      let ok = true;
      for (const id of b.grid.query(p[0] - w / 2, p[1] - h / 2, w, h)) { const n = b.byId.get(id); if (n && n.kind !== "section" && n.placed) { ok = false; break; } }
      if (ok) return { p, top: false };
    }
    return { p: [gx + 14 + w / 2, gy], top: true };
  }
  // A label chip is never hidden under a card: the point along the path nearest its middle that is clear of every
  // card, else near the target's end, drawn above the cards.
  function chipPlace(g, label) {
    const b = S.board;
    const w = textWidth(label, 12.5, 500) + 20, h = 22;
    const clear = (p) => {
      for (const id of b.grid.query(p[0] - w / 2, p[1] - h / 2, w, h)) { const n = b.byId.get(id); if (n && n.kind !== "section" && n.placed) return false; }
      return true;
    };
    if (g.at) for (const t of [0.5, 0.44, 0.56, 0.38, 0.62, 0.32, 0.68, 0.26, 0.74, 0.2, 0.8, 0.14, 0.86, 0.08, 0.92]) { const p = g.at(t); if (clear(p)) return { p, top: false }; }
    else if (clear(g.mid)) return { p: g.mid, top: false };
    // A short gap between two cards: just beside the middle of the line, across it.
    if (g.at) {
      const a = g.at(0.45), z = g.at(0.55), dx = z[0] - a[0], dy = z[1] - a[1], l = Math.hypot(dx, dy) || 1;
      const nx = -dy / l, ny = dx / l, m = g.at(0.5);
      for (const k of [h * 0.75, -h * 0.75, h * 1.4, -h * 1.4]) { const p = [m[0] + nx * k, m[1] + ny * k]; if (clear(p)) return { p, top: false }; }
    }
    return { p: g.at ? g.at(0.9) : g.mid, top: true };
  }
  function arrow(p, dirv, s) {
    const len = Math.hypot(dirv[0], dirv[1]) || 1;
    const ux = dirv[0] / len, uy = dirv[1] / len;
    const L = 8 / s, W = 4.6 / s;
    const bx = p[0] - ux * L, by = p[1] - uy * L;
    return `M${bx + uy * W} ${by - ux * W}L${p[0]} ${p[1]}L${bx - uy * W} ${by + ux * W}`;
  }
  // Connectors are drawn on the screen canvas under the cards, every frame, from geometry cached per edge (an SVG of
  // 700 paths repainted at every zoom step cost 100 to 300 ms hitches on the Mac); only their label chips are DOM,
  // mounted at rest under the cards.
  function edgesInView(r) {
    const b = S.board;
    const ids = b.edgeGrid ? b.edgeGrid.query(r.x, r.y, r.w, r.h) : new Set();
    for (const e of S.missingEdges) {
      const n = b.byId.get(e.missing === "from" ? e.to : e.from);
      if (n && n.placed && n.x - 90 < r.x + r.w && n.x + n.w + 90 > r.x && n.y - 90 < r.y + r.h && n.y + n.h + 90 > r.y) ids.add(e.id);
    }
    return ids;
  }
  function mountEdges() {
    const b = S.board;
    const s = S.view.s;
    const showLabels = 12.5 * s >= 9;
    const want = new Set();
    if (S.level !== "areas" && showLabels) for (const id of edgesInView(viewRect(0.25))) {
      const e = b.edgesById.get(id);
      if (e && (e.missing ? e.missing !== "both" : e.label)) want.add(id);
    }
    for (const [id, o] of S.edgesOn) if (!want.has(id)) { o.chip.remove(); S.edgesOn.delete(id); }
    for (const id of want) {
      if (S.edgesOn.has(id)) continue;
      const e = b.edgesById.get(id);
      const g = geomCache(e);
      if (!g) continue;
      const chip = document.createElement("div");
      chip.className = `b-elbl${g.gap ? " gap" : ""}${e.note ? " noted" : ""}`;
      chip.dataset.edge = id;
      chip.textContent = g.gap ? `${g.missingId}?` : e.label;
      const place = g.gap ? gapChipPlace(g, chip.textContent) : chipPlace(g, e.label);
      g.chipAt = place.p;
      if (place.top) chip.classList.add("hid"); // no clear spot: shown only while its box is lit
      chip.style.cssText = `left:${place.p[0]}px;top:${place.p[1]}px;transform:translate(-50%,-50%)`;
      R.chips.appendChild(chip);
      S.edgesOn.set(id, { chip, g });
    }
    lightEdges();
  }
  const geoms = new Map();
  function geomCache(e) {
    const c = geoms.get(e.id);
    if (c && c.hash === e.hash && c.board === S.board) return c.g;
    const g = edgeGeom(e);
    if (g) sample(g);
    geoms.set(e.id, { hash: e.hash, board: S.board, g });
    return g;
  }
  // Each connector as a polyline in board units, with cumulative lengths, so a frame strokes only the stretches in
  // view and draws dashes anchored to the edge's start (a long dashed curve stroked whole cost 10 ms a frame).
  function sample(g) {
    let pts;
    if (g.gap) pts = [g.d.match(/M([-\d.e]+) ([-\d.e]+)/).slice(1).map(Number), g.gap];
    else if (g.at && /C/.test(g.d)) {
      const est = Math.hypot(g.p2[0] - g.p1[0], g.p2[1] - g.p1[1]) * 1.3 + 40;
      const n = clamp(Math.ceil(est / 24), 12, 240);
      pts = [];
      for (let i = 0; i <= n; i++) pts.push(g.at(i / n));
    } else {
      pts = g.d.slice(1).split("L").map((q) => q.trim().split(/\s+/).map(Number));
    }
    const cum = [0];
    for (let i = 1; i < pts.length; i++) cum.push(cum[i - 1] + Math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]));
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    for (const q of pts) { if (q[0] < x0) x0 = q[0]; if (q[0] > x1) x1 = q[0]; if (q[1] < y0) y0 = q[1]; if (q[1] > y1) y1 = q[1]; }
    g.pts = pts;
    g.cum = cum;
    g.bbox = [x0, y0, x1, y1];
  }
  function lightEdges() {
    const id = S.lit;
    const ends = new Set([id, S.selected, S.focus, S.find.open ? S.find.hits[S.find.cur] : null, S.legend.word ? S.legend.hits[S.legend.cur] : null].filter(Boolean));
    const tucked = [];
    for (const [eid, o] of S.edgesOn) {
      const e = S.board.edgesById.get(eid);
      const on = !!(e && (ends.has(e.from) || ends.has(e.to)));
      o.chip.classList.toggle("on", on);
      o.chip.classList.toggle("dim", !!(id && e && e.from !== id && e.to !== id));
      // a label with no clear spot never draws over a card: while an end is lit it is read beside that box instead
      if (on && o.chip.classList.contains("hid")) tucked.push(e);
    }
    showTucked(tucked);
    drawShapes();
  }
  function showTucked(edges) {
    const host = S.lit || S.selected || S.focus;
    const n = host && S.board.byId.get(host);
    if (!edges.length || !n || S.level !== "read" || S.moving) { if (R.hlabel.dataset.tucked) { R.hlabel.hidden = true; delete R.hlabel.dataset.tucked; } return; }
    const other = (e) => titleOf(S.board.byId.get(e.from === n.id ? e.to : e.from)) || "";
    R.hlabel.querySelector("b").textContent = edges.map((e) => e.label).join(" · ");
    R.hlabel.querySelector("span").textContent = edges.map((e) => `${e.from === n.id ? "→" : "←"} ${other(e)}`).join(" · ");
    R.hlabel.dataset.tucked = "1";
    R.hlabel.hidden = false;
    const { s, tx, ty } = S.view;
    const lw = R.hlabel.offsetWidth, lh = R.hlabel.offsetHeight;
    let x = (n.x + n.w) * s + tx + 8;
    if (x + lw > S.W - 8) x = n.x * s + tx - 8 - lw;
    R.hlabel.style.left = `${clamp(x, 4, S.W - lw - 4)}px`;
    R.hlabel.style.top = `${clamp(n.y * s + ty, 4, S.H - lh - 4)}px`;
  }
  // Batched by style: one path per colour and weight, solid stretches as lines and dashes as short segments.
  function drawEdges(ctx, r) {
    const b = S.board, c = S.colors;
    const { s, tx, ty } = S.view;
    const dpr = window.devicePixelRatio || 1;
    const lv = levelOf(s);
    const base = lv === "read" ? 0.85 : lv === "map" ? 0.55 : 0.35;
    const lit = S.lit;
    const m = 24 / s;
    const vx0 = r.x - m, vy0 = r.y - m, vx1 = r.x + r.w + m, vy1 = r.y + r.h + m;
    const groups = new Map();
    let washed = 0;
    const dots = [];
    const group = (key, color, width, alpha, cap) => {
      let gr = groups.get(key);
      if (!gr) { gr = { color, width, alpha, cap, path: new Path2D() }; groups.set(key, gr); }
      return gr;
    };
    for (const id of edgesInView(r)) {
      const e = b.edgesById.get(id);
      if (!e) continue;
      const g = geomCache(e);
      if (!g || !g.pts) continue;
      const bb = g.bbox;
      if (bb[2] < vx0 || bb[0] > vx1 || bb[3] < vy0 || bb[1] > vy1) continue;
      const changed = S.changedEdges && S.changedEdges.has(e.id) && !S.rewritten;
      const on = !!(lit && (e.from === lit || e.to === lit)) || changed;
      const alpha = lit && !changed ? (on ? 1 : 0.22) : changed ? 1 : e.kind === "plan" ? base * 0.8 : base;
      const color = e.kind === "fail" ? (c.night ? c.ink : c.rust) : e.kind === "main" || changed ? c.ink : c.ink2;
      const width = (e.kind === "main" ? 2.4 : on ? 2.2 : 1.5) / s;
      const wi = washIndex(e.color);
      if (wi >= 0) { washed++; const u = group(`wash|${wi}`, c.washes[wi], 7 / s, 1, "round"); u.under = true; addRun(u.path, g, vx0, vy0, vx1, vy1); }
      if (changed && g.at) { const mp = g.at(0.5); dots.push(mp); }
      const dash = e.missing ? [4, 3] : e.kind === "code" ? [5, 4] : e.kind === "plan" ? [1.5, 3.5] : e.kind === "fail" && c.night ? [6, 2, 1, 2] : null;
      const gr = group(`${color}|${width}|${alpha}|${e.kind === "plan" ? "r" : "b"}`, color, width, alpha, e.kind === "plan" ? "round" : "butt");
      const pts = g.pts, cum = g.cum;
      // the stretches inside the view
      let pen = false;
      const period = dash ? dash.reduce((x, y) => x + y, 0) / s : 0;
      for (let i = 1; i < pts.length; i++) {
        const a = pts[i - 1], z = pts[i];
        const inV = !(Math.max(a[0], z[0]) < vx0 || Math.min(a[0], z[0]) > vx1 || Math.max(a[1], z[1]) < vy0 || Math.min(a[1], z[1]) > vy1);
        if (!inV) { pen = false; continue; }
        if (!dash) {
          if (!pen) { gr.path.moveTo(a[0], a[1]); pen = true; }
          gr.path.lineTo(z[0], z[1]);
          continue;
        }
        // dashes along this segment, phase from the edge's start
        const segLen = cum[i] - cum[i - 1];
        if (!segLen) continue;
        const ux = (z[0] - a[0]) / segLen, uy = (z[1] - a[1]) / segLen;
        let pos = cum[i - 1];
        const end = cum[i];
        let k = Math.floor(pos / period) * period;
        let guard = 0;
        while (k < end && guard++ < 4000) {
          let off = k;
          for (let j = 0; j < dash.length; j += 2) {
            const on0 = off, on1 = off + dash[j] / s;
            const s0 = Math.max(on0, pos), s1 = Math.min(on1, end);
            if (s1 > s0) { const t0 = s0 - cum[i - 1], t1 = s1 - cum[i - 1]; gr.path.moveTo(a[0] + ux * t0, a[1] + uy * t0); gr.path.lineTo(a[0] + ux * t1, a[1] + uy * t1); }
            off = on1 + (dash[j + 1] || 0) / s;
          }
          k += period;
        }
      }
      // arrowheads and gap marks, solid
      const hp = group(`${color}|${(e.kind === "main" ? 2.4 : 1.5) / s}|${alpha}|h`, color, (e.kind === "main" ? 2.4 : 1.5) / s, alpha, "butt").path;
      if (g.gap) {
        const [gx, gy] = g.gap, nv = g.gapDir, hw = 7 / s, kk = 4 / s, px = nv[1], py = -nv[0];
        const gp = group(`${c.ink}|${2 / s}|${alpha}|g`, c.ink, 2 / s, alpha, "butt").path;
        gp.moveTo(gx - px * hw, gy - py * hw); gp.lineTo(gx + px * hw, gy + py * hw);
        gp.moveTo(gx - px * hw + nv[0] * kk, gy - py * hw + nv[1] * kk); gp.lineTo(gx + px * hw + nv[0] * kk, gy + py * hw + nv[1] * kk);
      } else {
        if (e.toEnd !== "none") pathArrow(hp, g.p2, g.end2.map((v) => -v), s);
        if (e.fromEnd === "arrow") pathArrow(hp, g.p1, g.end1.map((v) => -v), s);
      }
    }
    S.lastEdgeWashes = washed;
    ctx.save();
    ctx.setTransform(dpr * s, 0, 0, dpr * s, dpr * tx, dpr * ty);
    ctx.lineJoin = "round";
    const ordered = [...groups.values()].sort((a, z) => (z.under ? 1 : 0) - (a.under ? 1 : 0));
    for (const gr of ordered) {
      ctx.globalAlpha = gr.alpha;
      ctx.strokeStyle = gr.color;
      ctx.lineWidth = gr.width;
      ctx.lineCap = gr.cap;
      ctx.stroke(gr.path);
    }
    if (dots.length) { // a changed connector's mark: a fixed 6 px dot at its middle
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.globalAlpha = 1;
      for (const [x, y] of dots) { const X0 = x * s + tx, Y0 = y * s + ty; ctx.beginPath(); ctx.arc(X0, Y0, 4.5, 0, Math.PI * 2); ctx.fillStyle = c.ground; ctx.fill(); ctx.beginPath(); ctx.arc(X0, Y0, 3, 0, Math.PI * 2); ctx.fillStyle = c.ink; ctx.fill(); }
    }
    ctx.restore();
    ctx.globalAlpha = 1;
  }
  function addRun(p2d, g, vx0, vy0, vx1, vy1) {
    let pen = false;
    for (let i = 1; i < g.pts.length; i++) {
      const a = g.pts[i - 1], z = g.pts[i];
      if (Math.max(a[0], z[0]) < vx0 || Math.min(a[0], z[0]) > vx1 || Math.max(a[1], z[1]) < vy0 || Math.min(a[1], z[1]) > vy1) { pen = false; continue; }
      if (!pen) { p2d.moveTo(a[0], a[1]); pen = true; }
      p2d.lineTo(z[0], z[1]);
    }
  }
  function pathArrow(p2d, p, dirv, s) {
    const len = Math.hypot(dirv[0], dirv[1]) || 1;
    const ux = dirv[0] / len, uy = dirv[1] / len;
    const L = 8 / s, W = 4.6 / s;
    const bx = p[0] - ux * L, by = p[1] - uy * L;
    p2d.moveTo(bx + uy * W, by - ux * W);
    p2d.lineTo(p[0], p[1]);
    p2d.lineTo(bx - uy * W, by + ux * W);
  }

  // ---------- the two canvases ----------
  function sizeCanvases() {
    const dpr = window.devicePixelRatio || 1;
    for (const c of [R.weave, R.shapes]) {
      const w = Math.round(S.W * dpr), h = Math.round(S.H * dpr);
      if (c.width !== w || c.height !== h) { c.width = w; c.height = h; c.style.width = `${S.W}px`; c.style.height = `${S.H}px`; }
    }
  }
  // The weave (Loom's ground): one tile of four short strokes every 44 board px, scaling with zoom and fading out
  // where it would grow too dense (section 8).
  function weaveTile(px) {
    const dpr = window.devicePixelRatio || 1;
    const size = Math.max(4, Math.round(px * dpr));
    if (S.weaveTile && S.weaveTile.size === size && S.weaveTile.color === S.colors.weave) return S.weaveTile;
    const c = document.createElement("canvas");
    c.width = c.height = size;
    const g = c.getContext("2d");
    const k = size / 44;
    g.strokeStyle = S.colors.weave;
    g.lineWidth = 1.3 * Math.max(k, 0.5);
    g.lineCap = "round";
    g.beginPath();
    g.moveTo(8.5 * k, 11 * k); g.lineTo(13.5 * k, 11 * k);
    g.moveTo(33 * k, 8.5 * k); g.lineTo(33 * k, 13.5 * k);
    g.moveTo(11 * k, 30.5 * k); g.lineTo(11 * k, 35.5 * k);
    g.moveTo(30.5 * k, 33 * k); g.lineTo(35.5 * k, 33 * k);
    g.stroke();
    S.weaveTile = { size, color: S.colors.weave, pattern: R.wctx.createPattern(c, "repeat"), px: size / dpr };
    return S.weaveTile;
  }
  function drawWeave(atRest) {
    const ctx = R.wctx;
    const dpr = window.devicePixelRatio || 1;
    const { s, tx, ty } = S.view;
    const px = 44 * s;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, R.weave.width, R.weave.height);
    const alpha = clamp((px - 7) / 9, 0, 1);
    if (alpha > 0) {
      const tile = weaveTile(atRest || !S.weaveTile ? Math.min(px, 176) : S.weaveTile.px);
      const k = px / tile.px;
      const m = new DOMMatrix([k, 0, 0, k, tx * dpr, ty * dpr]);
      tile.pattern.setTransform(m);
      ctx.globalAlpha = alpha;
      ctx.fillStyle = tile.pattern;
      ctx.fillRect(0, 0, R.weave.width, R.weave.height);
      ctx.globalAlpha = 1;
    }
    drawSections(ctx);
  }
  function sectionBackground(n) {
    let img = S.bgs.get(n.id);
    if (img && img.dataset.src === n.background) return img;
    img = new Image();
    img.dataset.src = n.background;
    img.onload = () => { drawWeave(true); };
    img.setAttribute("src", n.background);
    prepImg(img); // the vault gate decides how it loads, exactly as for a card's image
    S.bgs.set(n.id, img);
    const x = X(); if (S.wantImages && x.requestImages) { S.wantImages = false; x.requestImages(); }
    return img;
  }
  // Sections (BRD-3): a faint wash with a rule border, drawn on the ground, with the change bar on the leading edge.
  function drawSections(ctx) {
    const b = S.board, c = S.colors;
    if (!b || S.mode !== "canvas" || (S.exp && S.exp.noWash)) return;
    const dpr = window.devicePixelRatio || 1;
    const { s, tx, ty } = S.view;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    const r = viewRect(0);
    const list = [];
    for (const id of b.grid.query(r.x, r.y, r.w, r.h)) { const n = b.byId.get(id); if (n && n.kind === "section") list.push(n); }
    list.sort((a, z) => a.depth - z.depth);
    ctx.lineWidth = 1;
    for (const n of list) {
      const x = Math.round(n.x * s + tx) + 0.5, y = Math.round(n.y * s + ty) + 0.5, w = Math.round(n.w * s), h = Math.round(n.h * s);
      const wi = washIndex(n.color);
      ctx.fillStyle = wi >= 0 ? c.washes[wi] : c.sec;
      ctx.strokeStyle = c.rule;
      ctx.beginPath();
      if (ctx.roundRect && w > 6 && h > 6) ctx.roundRect(x, y, w, h, 2); else ctx.rect(x, y, w, h);
      ctx.fill();
      ctx.stroke();
      const bg = n.background ? sectionBackground(n) : null;
      if (bg && bg.complete && bg.naturalWidth) {
        ctx.save(); ctx.beginPath(); ctx.rect(x, y, w, h); ctx.clip();
        const iw = bg.naturalWidth, ih = bg.naturalHeight, st = n.backgroundStyle || "cover";
        if (st === "repeat") { const pat = ctx.createPattern(bg, "repeat"); pat.setTransform(new DOMMatrix([s, 0, 0, s, x, y])); ctx.fillStyle = pat; ctx.fillRect(x, y, w, h); }
        else { const k = st === "ratio" ? Math.min(w / iw, h / ih) : Math.max(w / iw, h / ih); ctx.drawImage(bg, x + (w - iw * k) / 2, y + (h - ih * k) / 2, iw * k, ih * k); }
        ctx.restore();
        ctx.strokeStyle = c.rule; ctx.strokeRect(x, y, w, h);
      }
      if (S.changed.has(n.id) && !S.rewritten) { ctx.fillStyle = c.ink; ctx.fillRect(S.dir === "rtl" ? x + w - 3 : x, y, 3, h); }
    }
    if (S.moving) drawNamesMoving(ctx, list);
  }
  // While a gesture runs the DOM names are hidden (they would scale with the board); the canvas draws each top-level
  // name at its on-screen size, 15 px or more, where it fits, and nothing else (BRD-8, section 9.2 rule 1).
  function drawNamesMoving(ctx, list) {
    const c = S.colors, { s, tx, ty } = S.view;
    for (const n of list) {
      const name = n.label;
      if (!name || (n.depth > 0 && s < MAP)) continue;
      const px = n.depth > 0 ? Math.max(15 * s, 15) : Math.max(24 * s, 15);
      ctx.font = `${n.depth > 0 ? 500 : 300} ${px}px ${n.depth > 0 ? '"Linen Sans"' : '"Linen Serif Display"'}, Georgia, serif`;
      const w = ctx.measureText(name).width;
      if (w > (n.w + roomRight(n)) * s) continue;
      const rtl = S.dir === "rtl";
      const x = rtl ? (n.x + n.w) * s + tx - w : n.x * s + tx, y = n.y * s + ty - 4 - px;
      ctx.fillStyle = c.ground; ctx.fillRect(x - 3, y - 2, w + 6, px + 4);
      ctx.fillStyle = c.ink; ctx.textBaseline = "top"; ctx.fillText(name, x, y);
    }
  }
  function hatch() {
    if (S.hatch) return S.hatch;
    const dpr = window.devicePixelRatio || 1;
    const L = Math.round(8 * dpr);
    const c = document.createElement("canvas");
    c.width = c.height = L;
    const g = c.getContext("2d");
    g.strokeStyle = S.colors.ink;
    g.lineWidth = 1.2 * dpr;
    g.beginPath();
    for (const o of [-L, 0, L]) { g.moveTo(o, L); g.lineTo(o + L, 0); }
    g.stroke();
    S.hatch = R.sctx.createPattern(c, "repeat");
    return S.hatch;
  }
  // Every card in view that is not in the DOM, as its status shape in ink (WORDS-2), at fixed screen weights, batched
  // into one fill or stroke per style (2,000 shapes drawn one by one cost about 15 ms a frame).
  function drawShapes() {
    if (!R || !S.board) return;
    const ctx = R.sctx, c = S.colors, b = S.board;
    const dpr = window.devicePixelRatio || 1;
    const { s, tx, ty } = S.view;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, R.shapes.width, R.shapes.height);
    if (S.mode !== "canvas") return;
    const r = viewRect(0);
    if (!(S.exp && S.exp.noEdges)) drawEdges(ctx, r);
    if (S.exp && S.exp.noNodes) return;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    const all = S.hideCards || S.level === "areas";
    const P = () => new Path2D();
    const fills = new Map(); // colour -> path
    const fillOf = (col) => { let p = fills.get(col); if (!p) { p = P(); fills.set(col, p); } return p; };
    const threads = P(), inkFill = P(), rustFill = P(), outline = P(), rule = P(), dashed = P(), dotted = P(), hair = P(), bars = P();
    const findOn = S.find.open && S.find.q ? new Set(S.find.hits) : null;
    const legendOn = S.legend.word ? new Set(S.legend.hits) : null;
    const curFind = S.find.open ? S.find.hits[S.find.cur] : null, curLegend = S.legend.word ? S.legend.hits[S.legend.cur] : null;
    const dots = [], rings = [], texts = [];
    for (const id of b.grid.query(r.x, r.y, r.w, r.h)) {
      if (!all && S.mounted.has(id)) continue;
      const n = b.byId.get(id);
      if (!n || n.kind === "section" || !n.placed) continue;
      const x = n.x * s + tx, y = n.y * s + ty, w = n.w * s, h = n.h * s;
      if (w < 0.6 || h < 0.6) continue;
      const sh = shapeOf(n);
      const wi = washIndex(n.color);
      if (n.kind === "text") { const ts = textNodeSize(n) * s; if (ts >= 9) texts.push([n, x, y, w, ts]); }
      else if (n.kind === "sticky") fillOf(wi >= 0 ? c.washes[wi] : c.washes[2]).rect(x, y, w, h);
      else if (w <= 2.2 || h <= 2.2) (sh === "rust" ? rustFill : sh ? inkFill : fillOf(c.rule)).rect(x, y, Math.max(w, 1), Math.max(h, 1));
      else if (sh === "rust") { rustFill.rect(x, y, w, h); if (c.night) hair.rect(x + 0.5, y + 0.5, w - 1, h - 1); }
      else if (sh === "solid") inkFill.rect(x, y, w, h);
      else {
        const i = 0.75;
        // a box with no word is a quiet rule outline at these levels (no paper fill that reads as an empty bar)
        if (sh !== "dashed" && sh !== "dotted" && (sh || wi >= 0)) fillOf(wi >= 0 ? c.washes[wi] : c.ground).rect(x, y, w, h);
        if (sh === "threads") threads.rect(x, y, w, h);
        (sh === "dashed" ? dashed : sh === "dotted" ? dotted : sh ? outline : rule).rect(x + i, y + i, w - 2 * i, h - 2 * i);
      }
      if (S.changed.has(id) && !S.rewritten) dots.push([S.dir === "rtl" ? x + w - 5 : x + 5, y + 5]);
      const hit = (findOn && findOn.has(id)) || (legendOn && legendOn.has(id));
      const strong = curFind === id || curLegend === id || S.selected === id || S.focus === id;
      if (hit || strong) rings.push([x, y, w, h, strong ? 3 : 1.5]);
    }
    for (const [col, p] of fills) { ctx.fillStyle = col; ctx.fill(p); }
    ctx.fillStyle = hatch(); ctx.fill(threads);
    ctx.fillStyle = c.ink; ctx.fill(inkFill);
    ctx.fillStyle = c.rust; ctx.fill(rustFill);
    ctx.fillStyle = c.ink;
    ctx.textBaseline = "top";
    for (const [n, x, y, w, ts] of texts) { ctx.font = `300 ${ts}px "Linen Serif Display", Georgia, serif`; ctx.direction = n.dir === "rtl" ? "rtl" : "ltr"; ctx.textAlign = n.dir === "rtl" ? "right" : "left"; ctx.fillText(textNodeLine(n), n.dir === "rtl" ? x + w : x, y, w); }
    ctx.textAlign = "left"; ctx.direction = "ltr";
    S.lastTextBars = 0;
    ctx.strokeStyle = c.ink; ctx.lineWidth = 1.5; ctx.stroke(outline);
    ctx.setLineDash([4, 3]); ctx.stroke(dashed);
    ctx.setLineDash([1, 3]); ctx.lineCap = "round"; ctx.lineWidth = 2; ctx.stroke(dotted);
    ctx.setLineDash([]); ctx.lineCap = "butt";
    ctx.lineWidth = 1; ctx.stroke(hair);
    ctx.strokeStyle = c.rule; ctx.stroke(rule);
    ctx.strokeStyle = c.ink;
    for (const [x, y, w, h, lwid] of rings) { ctx.lineWidth = lwid; ctx.strokeRect(x - 3.5, y - 3.5, w + 7, h + 7); }
    if (dots.length) {
      const ring = P(), dot = P();
      for (const [x, y] of dots) { ring.moveTo(x + 4.5, y); ring.arc(x, y, 4.5, 0, Math.PI * 2); dot.moveTo(x + 3, y); dot.arc(x, y, 3, 0, Math.PI * 2); }
      ctx.fillStyle = c.ground; ctx.fill(ring);
      ctx.fillStyle = c.ink; ctx.fill(dot);
    }
    // Removed boxes keep a faint outline for the session (BRD-13).
    if (S.removed.length) {
      ctx.strokeStyle = c.ink; ctx.globalAlpha = 0.3; ctx.setLineDash([2, 3]); ctx.lineWidth = 1;
      for (const n of S.removed) ctx.strokeRect(n.x * s + tx + 0.5, n.y * s + ty + 0.5, n.w * s - 1, n.h * s - 1);
      ctx.setLineDash([]); ctx.globalAlpha = 1;
    }
  }

  // ---------- frames and rest ----------
  let rafId = 0;
  (function beat() { requestAnimationFrame((t) => { S.lastRaf = performance.now(); beat(); }); })();
  function schedule() { if (!rafId) rafId = requestAnimationFrame(() => { rafId = 0; frame(); }); }
  function frame() {
    if (!R || !S.board) return;
    const { s, tx, ty } = S.view;
    const tr = `translate(${tx}px, ${ty}px) scale(${s})`;
    R.under.style.transform = tr;
    R.over.style.transform = tr;
    // Crossing into the areas level mid-gesture swaps the cards for their shapes at once (BRD-8, rule 4).
    const areas = s < MAP;
    if (areas !== S.hideCards) {
      S.hideCards = areas;
      R.over.classList.toggle("hide", areas);
      if (areas) R.over.classList.remove("moving");
    }
    const pct = Math.round(s * 100);
    if (pct !== S.pctShown) { S.pctShown = pct; R.zpct.textContent = lang() === "ar" ? `${num(pct)}٪` : `${pct}%`; }
    const ex = S.exp || {};
    if (!ex.noWeave) drawWeave(false);
    if (!ex.noShapes) drawShapes();
  }
  function gesture() {
    S.flight++;
    if (!S.moving) {
      // a manual pan or zoom is one Back step, coalesced over the gesture: the view where it last rested (BRD-7)
      if (S.restView) { S.history.push({ ...S.restView }); if (S.history.length > 50) S.history.shift(); S.openingUntouched = false; } else pushHistory();
      R.under.classList.add("gesturing");
      S.moving = true;
      if (S.view.s >= MAP && S.mounted.size) R.over.classList.add("moving");
      hideHover();
    }
    schedule();
    clearTimeout(S.restTimer);
    S.restTimer = setTimeout(rest, REST_MS);
  }
  function rest() {
    if (!R || !S.board) return;
    clearTimeout(S.restTimer);
    S.moving = false;
    R.over.classList.remove("moving");
    R.under.classList.remove("gesturing");
    S.restView = { ...S.view };
    const s = S.view.s;
    const lv = levelOf(s);
    if (lv !== S.level) {
      S.level = lv;
      R.canvas.dataset.level = lv;
    }
    R.under.style.setProperty("--px", `${(1 / s).toFixed(4)}px`);
    R.over.style.setProperty("--px", `${(1 / s).toFixed(4)}px`);
    frame();
    drawWeave(true);
    mountSections();
    mountEdges();
    cull();
    ariaOrder();
    drawShapes();
    updatePanel();
    updateCurrentSection();
    schedulePlace();
    scheduleSeen();
    scheduleView();
  }

  // ---------- the view ----------
  function measure() {
    const r = R.canvas.getBoundingClientRect();
    S.W = Math.max(1, r.width);
    S.H = Math.max(1, r.height);
    S.ox = r.left;
    S.oy = r.top;
    sizeCanvases();
  }
  function local(e) { return { x: e.clientX - S.ox, y: e.clientY - S.oy }; }
  function zoomAt(k, px, py) {
    const v = S.view;
    const s = clamp(v.s * k, MIN_S, MAX_S);
    v.tx = px - (px - v.tx) * s / v.s;
    v.ty = py - (py - v.ty) * s / v.s;
    v.s = s;
  }
  function fitView(box, pad, maxS, ins) {
    const p = pad == null ? 24 : pad;
    const i = ins || { top: 0, bottom: 0, left: 0, right: 0 };
    const W = S.W - i.left - i.right, H = S.H - i.top - i.bottom;
    const s = clamp(Math.min((W - 2 * p) / Math.max(1, box.w), (H - 2 * p) / Math.max(1, box.h)), MIN_S, maxS || MAX_S);
    return { s, tx: i.left + (W - box.w * s) / 2 - box.x * s, ty: i.top + (H - box.h * s) / 2 - box.y * s };
  }
  // What floating chrome covers at the edges of the canvas: the zoom panel (with its legend when the rail is hidden),
  // the change chip, and the rail when it floats over the board. Fit keeps the board out from under them.
  function chromeInsets(level) {
    const ins = { top: 0, bottom: 0, left: 0, right: 0 };
    if (!R) return ins;
    const legend = !S.rail && level !== "read";
    const was = R.zlegend.hidden;
    R.zlegend.hidden = !legend;
    const zp = R.zpanel.offsetHeight;
    R.zlegend.hidden = was;
    ins.bottom = Math.max(ins.bottom, zp + 14 - 18);
    if (!R.chip.hidden) ins.bottom = Math.max(ins.bottom, R.chip.offsetHeight + 18 - 18);
    if (S.rail && S.railOverlay) ins[S.dir === "rtl" ? "right" : "left"] = R.rail.offsetWidth;
    if (!R.line.hidden) ins.top = R.line.offsetHeight;
    return ins;
  }
  function fitBoard(pad) {
    let v = fitView(boardBox(), pad == null ? 32 : pad);
    for (let k = 0; k < 2; k++) v = fitView(boardBox(), pad == null ? 32 : pad, MAX_S, chromeInsets(levelOf(v.s)));
    return v;
  }
  const boardBox = () => { const b = S.board.bounds; return b && b.w ? b : { x: 0, y: 0, w: 800, h: 600 }; };
  // A section at reading zoom, anchored at its leading top corner (BRD-24).
  function sectionView(n) {
    const pad = 28;
    let s = 1;
    if (n.w * s > S.W - 2 * pad) s = Math.max(READ, (S.W - 2 * pad) / n.w);
    const top = 44 + 15;
    const rtl = S.dir === "rtl";
    const tx = rtl ? S.W - pad - (n.x + n.w) * s : pad - n.x * s;
    return { s, tx, ty: top - n.y * s };
  }
  function nodeView(n, reading) {
    const s0 = S.view.s;
    let s = reading ? clamp(Math.max(s0, 1), READ, 1.25) : s0;
    if (n.kind === "section") return fitView(n, 40, Math.max(READ, Math.min(1.25, s0 < READ ? 1 : s0)));
    const pad = 60;
    if (n.w * s > S.W - 2 * pad || n.h * s > S.H - 2 * pad) s = Math.max(READ, Math.min((S.W - 2 * pad) / n.w, (S.H - 2 * pad) / n.h));
    return { s, tx: S.W / 2 - (n.x + n.w / 2) * s, ty: S.H / 2 - (n.y + n.h / 2) * s };
  }
  function pushHistory() {
    S.openingUntouched = false;
    const v = S.view;
    S.history.push({ s: v.s, tx: v.tx, ty: v.ty });
    if (S.history.length > 50) S.history.shift();
  }
  const ease = (x) => { // Loom's brand curve, cubic-bezier(.22, .8, .2, 1), solved for y at x
    let lo = 0, hi = 1;
    for (let i = 0; i < 18; i++) { const m = (lo + hi) / 2; const bx = 3 * m * (1 - m) * (1 - m) * 0.22 + 3 * m * m * (1 - m) * 0.2 + m * m * m; if (bx < x) lo = m; else hi = m; }
    const m = (lo + hi) / 2;
    return 3 * m * (1 - m) * (1 - m) * 0.8 + 3 * m * m * (1 - m) * 1 + m * m * m;
  };
  function flyTo(v, opts) {
    if (!v) return;
    if (!opts || opts.history !== false) pushHistory();
    const tok = ++S.flight;
    const noFrames = performance.now() - (S.lastRaf || 0) > 250;
    if (reduceMotion.matches || (opts && opts.cut) || noFrames) { Object.assign(S.view, v); frame(); rest(); return; }
    const a = { ...S.view };
    // Fly in log-scale so zoom changes feel even.
    const t0 = performance.now();
    S.moving = true;
    R.under.classList.add("gesturing"); // names go to the canvas for the flight
    if (Math.min(a.s, v.s) >= MAP && S.mounted.size) R.over.classList.add("moving");
    hideHover();
    const step = (now) => {
      const k = clamp((now - t0) / FLY_MS, 0, 1), e = ease(k);
      const s = Math.exp(Math.log(a.s) + (Math.log(v.s) - Math.log(a.s)) * e);
      // keep the centre moving on a straight line in board space
      const ca = { x: (S.W / 2 - a.tx) / a.s, y: (S.H / 2 - a.ty) / a.s }, cb = { x: (S.W / 2 - v.tx) / v.s, y: (S.H / 2 - v.ty) / v.s };
      const cx = ca.x + (cb.x - ca.x) * e, cy = ca.y + (cb.y - ca.y) * e;
      S.view.s = s; S.view.tx = S.W / 2 - cx * s; S.view.ty = S.H / 2 - cy * s;
      frame();
      if (k < 1) next(() => { if (tok === S.flight) step(performance.now()); });
      else { Object.assign(S.view, v); rest(); }
    };
    next(() => { if (tok === S.flight) step(performance.now()); });
  }
  function back() {
    const v = S.history.pop();
    if (!v) return false;
    flyTo(v, { history: false });
    return true;
  }

  // ---------- opening (BRD-24) and holding (BRD-12) ----------
  function firstSection() {
    const b = S.board;
    for (const id of b.order) { const n = b.byId.get(id); if (n && n.kind === "section" && n.placed) return n; }
    return null;
  }
  function openingView(place) {
    if (place && place.kind === "board" && isFinite(place.zoom) && isFinite(place.cx) && isFinite(place.cy)) {
      const s = clamp(place.zoom, MIN_S, MAX_S);
      S.view = { s, tx: S.W / 2 - place.cx * s, ty: S.H / 2 - place.cy * s };
      if (place.mode === "list") S.mode = "list";
      return;
    }
    const fit = fitBoard(32);
    if (fit.s >= MAP || !firstSection()) { S.view = fit; return; }
    const sec = firstSection();
    S.view = sectionView(sec);
    // On a narrow window (the phone), a first section that does not fit at reading zoom opens as a list (BRD-24).
    if (phoneList(sec)) S.mode = "list";
  }
  function phoneList(sec) { return S.W < 600 && sec.w * READ > S.W - 2 * 28; } // the margins sectionView uses

  function centreNode() {
    const b = S.board;
    if (!b) return null;
    const { s, tx, ty } = S.view;
    const cx = (S.W / 2 - tx) / s, cy = (S.H / 2 - ty) / s;
    let best = null, bd = Infinity;
    const r = viewRect(0);
    const scan = (ids) => { for (const id of ids) { const n = b.byId.get(id); if (!n || n.kind === "section" || !n.placed) continue; const d = Math.hypot(n.x + n.w / 2 - cx, n.y + n.h / 2 - cy); if (d < bd) { bd = d; best = n; } } };
    scan(b.grid.query(r.x, r.y, r.w, r.h));
    if (!best) scan(b.nodes.map((n) => n.id)); // the view sits in a gap: the nearest box on the whole board
    else scan(b.grid.query(cx - bd, cy - bd, 2 * bd, 2 * bd)); // an off-screen box can still be nearer than any in view
    return best;
  }

  // ---------- change marks (BRD-13) ----------
  function readBaseline(list) {
    if (!Array.isArray(list) || !list.length) return null;
    const m = new Map();
    for (const e of list) {
      const s = String(e);
      const i = s.lastIndexOf(":");
      if (i <= 0) return null; // a note's block hashes, from before this file was a board
      m.set(s.slice(0, i), s.slice(i + 1));
    }
    return m;
  }
  // Boxes as "id:hash", connectors as "~id:hash" (BRD-13: per node and edge).
  const edgeKey = (id) => `~${id}`;
  function currentHashes() {
    const m = new Map(S.board.nodes.map((n) => [n.id, n.hash]));
    for (const e of S.board.edges) if (!e.missing) m.set(edgeKey(e.id), e.hash);
    return m;
  }
  function postBaseline() {
    if (!S.base) return;
    const cur = currentHashes();
    const out = [];
    for (const [id, h] of S.base) if (cur.has(id)) out.push(`${id}:${h}`);
    post({ type: "baseline", hashes: out, docId: S.docId });
  }
  function computeChanges(prev) {
    const b = S.board;
    S.changed = new Set();
    S.rewritten = false;
    S.changedEdges = new Set();
    if (!S.base) {
      // The first time a board arrives on a device is its baseline there.
      S.base = currentHashes();
      postBaseline();
    } else {
      for (const e of b.edges) if (!e.missing && S.base.get(edgeKey(e.id)) !== e.hash) {
        // a connector of a changed or new box is part of that box's mark; on its own it is marked itself
        if (!S.base.has(edgeKey(e.id)) && (!S.base.has(e.from) || !S.base.has(e.to))) continue;
        S.changedEdges.add(e.id);
      }
      let count = 0;
      for (const n of b.nodes) {
        if (n.kind === "section") { if (S.base.has(n.id) && S.base.get(n.id) !== n.hash) S.changed.add(n.id); continue; }
        count++;
        if (S.base.get(n.id) !== n.hash) S.changed.add(n.id);
      }
      const cards = [...S.changed].filter((id) => b.byId.get(id).kind !== "section").length;
      if (count > 4 && cards > count / 2) S.rewritten = true;
      for (const id of S.changed) if (!b.byId.has(id)) S.changed.delete(id);
    }
    if (prev) {
      const ids = new Set(b.nodes.map((n) => n.id));
      for (const n of prev.nodes) if (!ids.has(n.id) && n.placed && n.kind !== "section") S.removed.push({ id: n.id, x: n.x, y: n.y, w: n.w, h: n.h });
      S.removed = S.removed.filter((r) => !ids.has(r.id));
      if (S.removed.length > 200) { S.removedMore = (S.removedMore || 0) + S.removed.length - 200; S.removed = S.removed.slice(-200); } // the rest are counted, not drawn
    }
    for (const k of [...S.seen.keys()]) if (!b.byId.has(k) && !(b.edgesById && b.edgesById.has(k.slice(1)))) S.seen.delete(k);
    S.chgCur = -1;
  }
  const changedCards = () => S.board.order.filter((id) => S.changed.has(id) && S.board.byId.get(id).kind !== "section");
  // What Next and Previous Change walk: changed boxes in reading order, each followed by its own changed connectors.
  function changeList() {
    const out = changedCards().map((id) => ({ id, edge: false }));
    const seen = new Set();
    const at = new Map(S.board.order.map((id, i) => [id, i]));
    const edges = [...(S.changedEdges || [])].map((id) => S.board.edgesById.get(id)).filter(Boolean).sort((a, b) => (at.get(a.from) || 0) - (at.get(b.from) || 0));
    for (const e of edges) { if (seen.has(e.id)) continue; seen.add(e.id); out.push({ id: e.id, edge: true }); }
    return out;
  }
  function goChange(dir) {
    if (S.rewritten) return false;
    const list = changeList();
    if (!list.length) return false;
    S.chgCur = S.chgCur < 0 ? (dir > 0 ? 0 : list.length - 1) : (S.chgCur + dir + list.length) % list.length;
    const it = list[S.chgCur];
    const e = it.edge ? S.board.edgesById.get(it.id) : null;
    if (S.mode === "list") {
      const row = R.list.querySelector(`[data-id="${CSS.escape(e ? e.from : it.id)}"]`);
      if (row) row.scrollIntoView({ block: "center", behavior: reduceMotion.matches ? "auto" : "smooth" });
      return true;
    }
    if (e) {
      const g = geomCache(e);
      const m = g && g.at ? g.at(0.5) : g ? g.mid : [0, 0];
      const s = clamp(Math.max(S.view.s, 1), READ, 1.25);
      flyTo({ s, tx: S.W / 2 - m[0] * s, ty: S.H / 2 - m[1] * s });
      S.lit = e.from;
    } else {
      flyTo(nodeView(S.board.byId.get(it.id), true));
      S.focus = it.id;
    }
    refreshMarks();
    return true;
  }
  // A mark is acknowledged after 3 s at reading zoom, mostly in view, in the key window.
  let seenTimer = 0;
  function scheduleSeen() { clearTimeout(seenTimer); seenTimer = setTimeout(tickSeen, 500); }
  // Exposure counts per item and per version: a mark that changes again starts over (BRD-13, LIVE-5).
  function expose(key, hash) {
    const e = S.seen.get(key);
    const ms = (e && e.hash === hash ? e.ms : 0) + 500;
    S.seen.set(key, { hash, ms });
    return ms >= ACK_MS;
  }
  function tickSeen() {
    if (!S.active || !S.board || S.moving) return;
    const key = X().keyWindow ? X().keyWindow() : true;
    if (!key || document.hidden) return;
    const reading = S.mode === "canvas" && S.level === "read";
    const { s, tx, ty } = S.view;
    const meaningful = (x, y, w, h) => { // half of it on screen, or half the screen for something taller
      const x0 = Math.max(0, x * s + tx), x1 = Math.min(S.W, (x + w) * s + tx), y0 = Math.max(0, y * s + ty), y1 = Math.min(S.H, (y + h) * s + ty);
      return Math.max(0, x1 - x0) * Math.max(0, y1 - y0) >= 0.5 * Math.min(w * h * s * s, S.W * S.H);
    };
    const rowShown = (id) => { const r = R.list.querySelector(`.brow[data-id="${CSS.escape(id)}"]`); if (!r) return false; const b = r.getBoundingClientRect(), L = R.list.getBoundingClientRect(); return Math.min(b.bottom, L.bottom) - Math.max(b.top, L.top) >= Math.min(b.height, L.height) / 2; };
    if (S.rewritten) {
      // The "Rewritten" line is read where boxes can be read: at reading zoom, or in the List.
      if (!(reading || S.mode === "list")) { scheduleSeen(); return; }
      if (expose("*", S.version)) { S.base = currentHashes(); S.changed.clear(); S.changedEdges.clear(); S.rewritten = false; S.seen.clear(); postBaseline(); refreshMarks(); return; }
      scheduleSeen();
      return;
    }
    if (!S.changed.size && !(S.changedEdges && S.changedEdges.size)) return;
    let acked = false;
    for (const id of [...S.changed]) {
      const n = S.board.byId.get(id);
      if (!n) continue;
      let shown;
      if (n.kind === "section") {
        const e = S.secs.get(id);
        if (S.mode === "list") { const h = R.list.querySelector(`.lsec[data-id="${CSS.escape(id)}"]`); const b0 = h && h.getBoundingClientRect(), L = R.list.getBoundingClientRect(); shown = !!h && b0.bottom > L.top && b0.top < L.bottom; }
        else shown = S.mode === "canvas" && S.level !== "areas" && !!(e && e.shown && e.label.querySelector("b")) && meaningful(n.x, n.y - 40 / s, Math.min(n.w, 300), 40 / s); // its name, drawn and read
      }
      else shown = reading ? meaningful(n.x, n.y, n.w, n.h) : S.mode === "list" && rowShown(id);
      if (shown && expose(id, n.hash)) { S.base.set(id, n.hash); S.changed.delete(id); S.seen.delete(id); acked = true; }
    }
    for (const id of [...(S.changedEdges || [])]) {
      const e = S.board.edgesById.get(id);
      const g = e && geomCache(e);
      if (!g) continue;
      const m = g.at ? g.at(0.5) : g.mid;
      if (reading && meaningful(m[0] - 20, m[1] - 20, 40, 40) && expose(edgeKey(id), e.hash)) { S.base.set(edgeKey(id), e.hash); S.changedEdges.delete(id); S.seen.delete(edgeKey(id)); acked = true; }
    }
    if (acked) { postBaseline(); refreshMarks(); }
    if (S.changed.size || S.changedEdges.size) scheduleSeen();
  }
  function refreshMarks() {
    for (const [id, el] of S.mounted) {
      const n = S.board.byId.get(id);
      if (!n) continue;
      el.className = cardClass(n);
      const dot = el.querySelector(":scope > .cdot");
      const want = S.level !== "read" && S.changed.has(id) && !S.rewritten;
      if (want && !dot) el.insertAdjacentHTML("beforeend", '<i class="cdot"></i>');
      if (!want && dot) dot.remove();
    }
    drawShapes();
    drawWeave(true);
    updateChip();
    renderOutline();
    if (S.mode === "list") markList();
    scheduleView();
  }
  function updateChip() {
    const list = S.board ? changeList() : [];
    if (S.rewritten) {
      R.chip.hidden = false;
      R.chiptext.textContent = S.baseDate ? t("Rewritten since you read it on {d}", { d: S.baseDate }) : t("Rewritten since you read it");
      R.chipnext.hidden = true;
      return;
    }
    if (!list.length && !S.removed.length) { R.chip.hidden = true; return; }
    R.chip.hidden = false;
    const parts = [];
    if (list.length) parts.push(S.baseDate ? t("{n} changed since {d}", { n: num(list.length), d: S.baseDate }) : t("{n} changed", { n: num(list.length) }));
    if (S.removed.length) parts.push(t("{n} removed", { n: num(S.removed.length + (S.removedMore || 0)) }));
    R.chiptext.textContent = parts.join(" · ");
    R.chipnext.hidden = !list.length;
    R.chipnext.textContent = t("Next");
  }

  // ---------- the rail: legend, problems and sections (BRD-5, BRD-9, BRD-1) ----------
  function renderLegend() {
    const b = S.board;
    const rows = b.words.map((w) => {
      const on = S.legend.word === w.word;
      const step = on && S.legend.hits.length ? `<em class="lstep">${esc(t("{a} of {b}", { a: num(Math.max(1, S.legend.cur + 1)), b: num(S.legend.hits.length) }))}<button type="button" class="lprev" aria-label="${esc(t("Previous"))}">‹</button><button type="button" class="lnext" aria-label="${esc(t("Next"))}">›</button></em>` : `<i>${num(w.count)}</i>`;
      return `<div class="lg${on ? " on" : ""}" role="listitem" data-word="${esc(w.word)}" title="${esc(w.meaning || "")}">${swatch(w.shape)}<b>${esc(w.word)}</b>${step}</div>`;
    }).join("");
    R.legend.innerHTML = rows;
    R.zlegend.innerHTML = rows; // the same control: counts, "1 of N", Previous and Next (BRD-5)
  }
  function renderProblems() {
    const b = S.board;
    const probs = (S.badVersion ? S.badVersion.problems : b.problems) || [];
    R.probline.hidden = !probs.length;
    R.probs.hidden = !probs.length || !S.problemsOpen;
    if (!probs.length) return;
    R.probline.querySelector("b").textContent = probs.length === 1 ? t("1 problem") : t("{n} problems", { n: num(probs.length) });
    R.probline.querySelector("button").textContent = S.problemsOpen ? t("Hide") : t("Show");
    R.probs.innerHTML = probs.slice(0, 40).map((p) => `<li data-pid="${esc(p.id || "")}"><code>${esc(p.path || "")}${p.line ? ` · ${num(p.line)}` : ""}</code><span>${esc(p.message)}</span></li>`).join("");
  }
  function sectionCounts() {
    const b = S.board, out = new Map();
    const count = (id) => {
      if (out.has(id)) return out.get(id);
      let c = 0;
      for (const k of b.children.get(id) || []) { const n = b.byId.get(k); c += n.kind === "section" ? count(k) : 1; }
      out.set(id, c);
      return c;
    };
    for (const n of b.nodes) if (n.kind === "section") count(n.id);
    return out;
  }
  function renderOutline() {
    const b = S.board;
    if (!b) return;
    const counts = S.secCounts || (S.secCounts = sectionCounts());
    const f = (R.filter.value || "").trim();
    const fold = X().fold || ((x) => x.toLowerCase());
    const fq = f ? fold(f) : "";
    const hasChange = (id) => S.changed.has(id) || (b.children.get(id) || []).some((k) => S.changed.has(k) || (b.byId.get(k).kind === "section" && hasChange(k)));
    let h = "";
    for (const id of b.order) {
      const n = b.byId.get(id);
      if (!n) continue;
      if (n.kind === "section") {
        const name = n.label || n.title || id;
        if (fq && !fold(name).includes(fq)) continue;
        h += `<a role="listitem" class="d${Math.min(n.depth, 3)}${S.curSection === id ? " cur" : ""}${!S.rewritten && hasChange(id) ? " chgd" : ""}" data-id="${esc(id)}">${esc(name)}<span class="cnt">${num(counts.get(id) || 0)}</span></a>`;
      } else {
        const tt = n.title || (n.kind !== "card" && n.kind !== "sticky" && n.kind !== "text" ? titleOf(n) : "");
        if (tt && (!fq || fold(tt).includes(fq))) h += `<a role="listitem" class="nd d${Math.min(n.depth, 3)}${S.changed.has(id) && !S.rewritten ? " chgd" : ""}" data-id="${esc(id)}">${esc(tt)}</a>`;
      }
    }
    // Tours are kept and listed at L2; choosing a step flies to what it lights (BRD-14).
    const tours = Array.isArray(b.tours) ? b.tours : [];
    if (tours.length && !fq) {
      h += `<div class="b-otitle">${esc(t("Tours"))}</div>`;
      tours.forEach((tour, ti) => {
        h += `<a role="listitem" class="tour" data-tour="${ti}" data-step="0">${esc(tour.title || t("Tour"))}</a>`;
        (tour.steps || []).forEach((st, si) => { h += `<a role="listitem" class="nd d1 step" data-tour="${ti}" data-step="${si}">${num(si + 1)}. ${esc(st.text || st.title || "")}</a>`; });
      });
    }
    R.secsList.innerHTML = h || (fq ? `<div class="b-empty">${esc(t("Not found"))}</div>` : "");
    R.otitle.textContent = t("Sections");
    R.otitle.hidden = !b.nodes.some((n) => n.kind === "section");
    const meta = R.rail.querySelector(".b-meta");
    meta.hidden = R.legend.hidden && R.btitle.hidden && R.probline.hidden;
  }
  function updateCurrentSection() {
    const b = S.board;
    const { s, tx, ty } = S.view;
    const cx = (S.W / 2 - tx) / s, cy = (S.H / 2 - ty) / s;
    let best = null, area = Infinity;
    for (const n of b.nodes) {
      if (n.kind !== "section" || !n.placed) continue;
      if (cx >= n.x && cx <= n.x + n.w && cy >= n.y && cy <= n.y + n.h && n.w * n.h < area) { best = n; area = n.w * n.h; }
    }
    const id = best ? best.id : null;
    if (id !== S.curSection) {
      S.curSection = id;
      R.secsList.querySelectorAll("a.cur").forEach((a) => a.classList.remove("cur"));
      if (id) { const a = R.secsList.querySelector(`a[data-id="${CSS.escape(id)}"]`); if (a) { a.classList.add("cur"); a.scrollIntoView({ block: "nearest" }); } }
      R.canvas.setAttribute("aria-label", `${t("Board {name}, {n} boxes", { name: S.board.title || S.name, n: num(S.board.nodes.length) })}${best ? `. ${t("In view: {s}", { s: best.label || best.title || "" })}` : ""}`);
    }
  }
  function updatePanel() {
    const pct = Math.round(S.view.s * 100);
    S.pctShown = pct;
    R.zpct.textContent = lang() === "ar" ? `${num(pct)}٪` : `${pct}%`;
    // One legend at a time: the rail's when it is shown, else the zoom panel's at the map and areas levels (BRD-5).
    R.zlegend.hidden = !(S.mode === "canvas" && !S.rail && S.level !== "read");
  }

  // ---------- legend and find (BRD-5, BRD-10) ----------
  function chooseWord(word) {
    if (S.legend.word === word || !word) { S.legend = { word: null, hits: [], cur: -1 }; }
    else {
      const hits = S.board.order.filter((id) => { const n = S.board.byId.get(id); return n && n.word === word && n.placed; });
      S.legend = { word, hits, cur: -1 };
      if (S.find.open) closeFind();
    }
    renderLegend();
    refreshMarks();
  }
  function stepLegend(dir) {
    const L = S.legend;
    if (!L.word || !L.hits.length) return false;
    L.cur = L.cur < 0 ? (dir > 0 ? 0 : L.hits.length - 1) : (L.cur + dir + L.hits.length) % L.hits.length;
    const n = S.board.byId.get(L.hits[L.cur]);
    renderLegend();
    if (S.mode === "list") scrollListTo(n.id); else flyTo(nodeView(n, true));
    refreshMarks();
    return true;
  }
  function openFind(useSelection) {
    S.find.open = true;
    R.find.hidden = false;
    if (useSelection) { const sel = String(getSelection() || "").trim(); if (sel) R.findq.value = sel; }
    R.findq.focus();
    R.findq.select();
    runFind(R.findq.value);
  }
  function closeFind() {
    S.find = { open: false, q: "", hits: [], cur: -1 };
    R.find.hidden = true;
    refreshMarks();
    R.canvas.focus({ preventScroll: true });
  }
  function runFind(q) {
    const fold = X().fold || ((x) => x.toLowerCase());
    const fq = fold(String(q || "").trim());
    S.find.q = fq;
    S.find.hits = [];
    S.find.cur = -1;
    if (fq) {
      const b = S.board;
      const edgeText = new Map();
      for (const e of b.edges) if (e.label || e.note) {
        const txt = fold([e.label || "", e.note ? [e.note.title, e.note.body].join(" ") : ""].join(" "));
        if (txt.includes(fq)) { for (const id of [e.from, e.to]) edgeText.set(id, true); }
      }
      for (const id of b.order) {
        const n = b.byId.get(id);
        if (!n || !n.placed) continue;
        if (fold(plainText(n)).includes(fq) || edgeText.has(id)) S.find.hits.push(id);
      }
      // Start from the first match at or after the view's centre in reading order.
      const c = centreNode();
      const ci = c ? b.order.indexOf(c.id) : 0;
      const k = S.find.hits.findIndex((id) => b.order.indexOf(id) >= ci);
      S.find.cur = S.find.hits.length ? (k >= 0 ? k : 0) : -1;
    }
    findCount();
    refreshMarks();
  }
  function findCount() {
    const n = S.find.hits.length;
    R.findn.textContent = !S.find.q ? "" : n ? t("{a} of {b}", { a: num(S.find.cur + 1), b: num(n) }) : t("Not found");
  }
  function stepFind(dir) {
    if (!S.find.open || !S.find.hits.length) return stepLegend(dir);
    S.find.cur = (S.find.cur + dir + S.find.hits.length) % S.find.hits.length;
    findCount();
    const n = S.board.byId.get(S.find.hits[S.find.cur]);
    if (S.mode === "list") scrollListTo(n.id); else flyTo(nodeView(n, true));
    refreshMarks();
    return true;
  }

  // ---------- notes with sources (BRD-6) ----------
  function openNote(id, edge) {
    const b = S.board;
    const n = edge ? (b.edgesById ? b.edgesById.get(id) : null) : b.byId.get(id);
    if (!n || !n.note) return;
    const note = n.note;
    const owner = edge ? n.label || "" : titleOf(n);
    const eb = [note.area, owner].filter(Boolean).map(esc).join(" · ");
    const fields = note.fields ? `<dl>${Object.entries(note.fields).map(([k, v]) => `<dt>${esc(k)}</dt><dd>${esc(v)}</dd>`).join("")}</dl>` : "";
    const refs = note.refs && note.refs.length ? `<div class="refs"><div class="eyebrow">${esc(t("Sources"))}</div>${note.refs.map((r) => `<code data-ref="${esc(r)}">${esc(r)}</code>`).join("")}</div>` : "";
    const st = note.state ? `<span class="st s-${(S.board.words.find((w) => w.word === note.state) || {}).shape || "outline"}">${esc(note.state)}</span>` : "";
    R.notecard.innerHTML = `<div class="eyebrow">${eb}</div>${st}${note.title ? `<div class="nt">${esc(note.title)}</div>` : ""}<div class="b-nbody">${md(note.body || "")}</div>${fields}${refs}`;
    directionise(R.notecard);
    R.notecard.setAttribute("dir", S.dir);
    R.notecard.hidden = false;
    S.note = { id, edge: !!edge };
    placeNote(n, edge);
  }
  function placeNote(n, edge) {
    const { s, tx, ty } = S.view;
    let r;
    if (edge) { const o = S.edgesOn.get(n.id); const m = o ? o.g.chipAt || o.g.mid : [0, 0]; r = { x: m[0] * s + tx - 20, y: m[1] * s + ty - 10, w: 40, h: 20 }; }
    else r = { x: n.x * s + tx, y: n.y * s + ty, w: n.w * s, h: n.h * s };
    const cw = Math.min(340, S.W - 24), ch = R.notecard.offsetHeight || 200;
    const gap = 14;
    const rightRoom = S.W - (r.x + r.w), leftRoom = r.x;
    const preferLeft = S.dir === "rtl";
    let x;
    if (preferLeft ? leftRoom >= cw + gap + 8 : !(rightRoom >= cw + gap + 8) && leftRoom >= cw + gap + 8) x = r.x - gap - cw;
    else if (rightRoom >= cw + gap + 8 || !(leftRoom >= cw + gap + 8)) x = r.x + r.w + gap;
    else x = r.x - gap - cw;
    let y = r.y;
    if (x + cw > S.W - 8 || x < 8) { x = clamp(r.x, 8, S.W - cw - 8); y = r.y + r.h + gap; if (y + ch > S.H - 8) y = Math.max(8, r.y - gap - ch); }
    y = clamp(y, 8, Math.max(8, S.H - ch - 8));
    R.notecard.style.width = `${cw}px`;
    R.notecard.style.left = `${x}px`;
    R.notecard.style.top = `${y}px`;
  }
  function closeNote() {
    clearTimeout(S.noteTimer);
    if (!S.note) return false;
    S.note = null;
    R.notecard.hidden = true;
    return true;
  }

  // ---------- hover labels at the map and areas levels (BRD-5) ----------
  function hideHover() { R.hlabel.hidden = true; }
  function showHover(n) {
    if (!n || S.level === "read" || S.moving) { hideHover(); return; }
    const { s, tx, ty } = S.view;
    const w = wordOf(n);
    R.hlabel.querySelector("b").textContent = titleOf(n);
    R.hlabel.querySelector("span").textContent = w ? w.word : "";
    R.hlabel.hidden = false;
    const lw = R.hlabel.offsetWidth, lh = R.hlabel.offsetHeight;
    let x = (n.x + n.w) * s + tx + 8;
    if (x + lw > S.W - 8) x = n.x * s + tx - 8 - lw;
    R.hlabel.style.left = `${clamp(x, 4, S.W - lw - 4)}px`;
    R.hlabel.style.top = `${clamp(n.y * s + ty - 4, 4, S.H - lh - 4)}px`;
  }
  function nodeAt(px, py) {
    const b = S.board;
    const { s, tx, ty } = S.view;
    const x = (px - tx) / s, y = (py - ty) / s;
    let best = null;
    for (const id of b.grid.query(x - 2 / s, y - 2 / s, 4 / s, 4 / s)) {
      const n = b.byId.get(id);
      if (!n || n.kind === "section") continue;
      if (!best || n.depth >= best.depth) best = n;
    }
    return best;
  }
  function sectionAt(px, py) {
    const b = S.board;
    const { s, tx, ty } = S.view;
    const x = (px - tx) / s, y = (py - ty) / s;
    let best = null;
    for (const id of b.grid.query(x, y, 1 / s, 1 / s)) { const n = b.byId.get(id); if (n && n.kind === "section" && (!best || n.w * n.h < best.w * best.h)) best = n; }
    return best;
  }

  // ---------- selection, focus and keys (BRD-7, BRD-18) ----------
  function select(id) {
    S.selected = id;
    refreshMarks();
  }
  function focusNode(id, fly) {
    const n = S.board.byId.get(id);
    if (!n) return;
    S.focus = id;
    S.selected = id;
    S.lit = id;
    if (fly) {
      const { s, tx, ty } = S.view;
      const inView = n.x * s + tx >= 0 && (n.x + n.w) * s + tx <= S.W && n.y * s + ty >= 0 && (n.y + n.h) * s + ty <= S.H;
      if (!inView || S.level !== "read") flyTo(nodeView(n, true), { cut: reduceMotion.matches });
    }
    refreshMarks();
    lightEdges();
    R.status.textContent = ariaFor(n);
    if (n.note) setTimeout(() => { if (S.focus === n.id) openNote(n.id); }, reduceMotion.matches ? 0 : FLY_MS + 30); // focus opens a note (BRD-6)
  }
  function tabStep(dir) {
    const list = S.board.order.filter((id) => { const n = S.board.byId.get(id); return n && n.placed; });
    if (!list.length) return;
    let i = list.indexOf(S.focus);
    i = i < 0 ? (dir > 0 ? 0 : list.length - 1) : (i + dir + list.length) % list.length;
    focusNode(list[i], true);
  }
  function openNode(n, newTab) {
    if (!n) return false;
    if (n.kind === "link" && n.url) { post({ type: "openExternal", url: n.url }); return true; }
    if (FILE_KINDS.has(n.kind) && n.file) { post({ type: "openLocal", href: n.file + (n.subpath || ""), newTab: !!newTab, place: placeNow() }); return true; }
    return false;
  }
  function onKey(e) {
    if (!S.active || S.mode !== "canvas") {
      if (S.active && S.mode === "list" && e.key === "Escape" && closeNote()) e.preventDefault();
      return;
    }
    const tag = (e.target && e.target.tagName) || "";
    if (tag === "INPUT" || tag === "TEXTAREA") return;
    const mod = e.metaKey || e.ctrlKey;
    const v = S.view;
    const pan = (dx, dy) => { v.tx += dx; v.ty += dy; gesture(); };
    switch (e.key) {
      case "Tab": e.preventDefault(); tabStep(e.shiftKey ? -1 : 1); return;
      case "Escape":
        if (closeNote()) break;
        if (S.find.open) { closeFind(); break; }
        if (S.legend.word) { chooseWord(null); break; }
        if (S.selected || S.focus) { S.selected = S.focus = S.lit = null; refreshMarks(); lightEdges(); break; }
        return;
      case "Enter": { const n = S.board.byId.get(S.focus || S.selected); if (!openNode(n, e.metaKey)) { if (n) flyTo(nodeView(n, true)); else return; } break; }
      case "ArrowDown":
        if (e.metaKey) { if (!openNode(S.board.byId.get(S.focus || S.selected))) return; break; }
        pan(0, -(e.shiftKey ? 240 : 60)); break;
      case "ArrowUp": pan(0, e.shiftKey ? 240 : 60); break;
      case "ArrowLeft": pan(e.shiftKey ? 240 : 60, 0); break;
      case "ArrowRight": pan(-(e.shiftKey ? 240 : 60), 0); break;
      case " ": if (!S.space) { S.space = true; R.canvas.classList.add("grab"); } break;
      case "=": case "+": if (!mod) return; zoomBy(1.25); break;
      case "-": if (!mod) return; zoomBy(0.8); break;
      case "0": if (!mod) return; fit(); break;
      case "1": if (!mod) return; zoom100(); break;
      case "[": if (!mod) return; if (!back()) return; break;
      case "g": case "G": if (!e.metaKey) return; stepFind(e.shiftKey ? -1 : 1); break;
      default: return;
    }
    e.preventDefault();
  }
  function zoomBy(k) { pushHistory(); const v = S.view; const target = { ...v }; const s = clamp(v.s * k, MIN_S, MAX_S); target.tx = S.W / 2 - (S.W / 2 - v.tx) * s / v.s; target.ty = S.H / 2 - (S.H / 2 - v.ty) * s / v.s; target.s = s; flyTo(target, { history: false }); }
  function fit() { flyTo(fitBoard(32)); }
  function zoom100() { const v = S.view; const s = 1; flyTo({ s, tx: S.W / 2 - (S.W / 2 - v.tx) * s / v.s, ty: S.H / 2 - (S.H / 2 - v.ty) * s / v.s }); }

  // ---------- pointer and wheel ----------
  let drag = null, hoverRaf = 0, lastMove = null, inPinch = null;
  function wire() {
    const C = R.canvas;
    C.addEventListener("wheel", (e) => {
      if (!S.active || S.mode !== "canvas") return;
      if (e.target.closest && e.target.closest(".b-notecard")) return;
      e.preventDefault();
      if (inPinch) return;
      const p = local(e);
      if (e.ctrlKey || e.metaKey) zoomAt(Math.exp(-e.deltaY * (e.ctrlKey ? 0.01 : 0.0025)), p.x, p.y);
      else { S.view.tx -= e.deltaX; S.view.ty -= e.deltaY; }
      gesture();
    }, { passive: false });
    // Safari's own pinch events, when WebKit sends them instead of ctrl-wheels.
    C.addEventListener("gesturestart", (e) => { e.preventDefault(); const p = local(e); inPinch = { s: S.view.s, x: p.x, y: p.y }; });
    C.addEventListener("gesturechange", (e) => {
      if (!inPinch) return;
      e.preventDefault();
      zoomAt(clamp(inPinch.s * e.scale, MIN_S, MAX_S) / S.view.s, inPinch.x, inPinch.y);
      gesture();
    });
    C.addEventListener("gestureend", (e) => { e.preventDefault(); inPinch = null; });
    C.addEventListener("pointerdown", (e) => {
      if (!S.active || e.button !== 0) return;
      const onUI = e.target.closest(".b-zpanel, .b-chip, .b-notecard, .b-line, .b-toast");
      if (onUI) return;
      const card = e.target.closest(".b-node");
      drag = { x: e.clientX, y: e.clientY, tx: S.view.tx, ty: S.view.ty, moved: false, card, pan: S.space || !card, id: e.pointerId };
      if (drag.pan) { C.setPointerCapture(e.pointerId); C.classList.add("grabbing"); }
    });
    C.addEventListener("pointermove", (e) => {
      if (drag && drag.pan) {
        const dx = e.clientX - drag.x, dy = e.clientY - drag.y;
        if (!drag.moved && Math.hypot(dx, dy) > 3) drag.moved = true;
        if (drag.moved) { S.view.tx = drag.tx + dx; S.view.ty = drag.ty + dy; gesture(); }
        return;
      }
      if (drag && Math.hypot(e.clientX - drag.x, e.clientY - drag.y) > 3) drag.moved = true;
      lastMove = e;
      if (!hoverRaf) hoverRaf = requestAnimationFrame(hoverFrame);
    });
    const end = (e) => {
      if (!drag) return;
      const d = drag;
      drag = null;
      C.classList.remove("grabbing");
      try { C.releasePointerCapture(e.pointerId); } catch (_) { /* not captured */ }
      if (d.moved) return;
      // A click: select the box under the pointer, or clear the selection on empty board.
      const p = local(e);
      const n = d.card ? S.board.byId.get(d.card.dataset.id) : nodeAt(p.x, p.y);
      if (n) { S.focus = null; select(n.id); S.lit = n.id; lightEdges(); if (n.note && e.pointerType === "touch") openNote(n.id); } // a tap opens a note
      else if (S.selected) { S.selected = null; S.lit = null; refreshMarks(); lightEdges(); }
      R.canvas.focus({ preventScroll: true });
    };
    C.addEventListener("pointerup", end);
    C.addEventListener("pointercancel", end);
    C.addEventListener("pointerleave", () => { hideHover(); if (!S.selected && !S.focus) { S.lit = null; lightEdges(); } clearTimeout(S.noteTimer); });
    C.addEventListener("dblclick", (e) => {
      if (e.target.closest(".b-zpanel, .b-chip, .b-notecard, .b-line")) return;
      const p = local(e);
      const n = nodeAt(p.x, p.y) || sectionAt(p.x, p.y);
      if (n) flyTo(n.kind === "section" ? fitView(n, 40) : fitView(n, 60, Math.max(1, S.view.s)));
    });
    C.addEventListener("click", (e) => {
      const a = e.target.closest("a");
      if (a && a.closest(".b-node, .b-notecard")) { e.preventDefault(); followLink(a, e); return; }
      const ref = e.target.closest("[data-ref]");
      if (ref) openRef(ref.dataset.ref, e.altKey);
    });
    document.addEventListener("keyup", (e) => { if (e.key === " " && S.space) { S.space = false; R.canvas.classList.remove("grab"); } });
    document.addEventListener("keydown", onKey);
    R.zpanel.querySelector(".b-zin").addEventListener("click", () => zoomBy(1.25));
    R.zpanel.querySelector(".b-zout").addEventListener("click", () => zoomBy(0.8));
    R.zpanel.querySelector(".b-fit").addEventListener("click", fit);
    R.chipnext.addEventListener("click", () => goChange(1));
    R.legend.addEventListener("click", (e) => {
      if (e.target.closest(".lnext")) { stepLegend(1); return; }
      if (e.target.closest(".lprev")) { stepLegend(-1); return; }
      const row = e.target.closest(".lg");
      if (row) chooseWord(row.dataset.word);
    });
    R.zlegend.addEventListener("click", (e) => {
      if (e.target.closest(".lnext")) { stepLegend(1); return; }
      if (e.target.closest(".lprev")) { stepLegend(-1); return; }
      const row = e.target.closest(".lg");
      if (row) chooseWord(row.dataset.word); // choosing marks the boxes; Next flies (BRD-5)
    });
    R.probline.querySelector("button").addEventListener("click", () => { S.problemsOpen = !S.problemsOpen; renderProblems(); });
    R.line.querySelector("button").addEventListener("click", () => {
      if (R.line.dataset.action === "large") { command({ type: "command", name: "toggleList", allowLarge: true }); return; } // BRD-20: on the Mac, one explicit click away
      S.problemsOpen = true; if (!S.rail) setRail(true, S.railOverlay); renderProblems();
    });
    R.probs.addEventListener("click", (e) => { const li = e.target.closest("li[data-pid]"); const n = li && S.board.byId.get(li.dataset.pid); if (n && n.placed) flyTo(nodeView(n, true)); });
    R.secsList.addEventListener("click", (e) => {
      const st = e.target.closest("a[data-tour]");
      if (st) {
        const tour = (S.board.tours || [])[Number(st.dataset.tour)] || {};
        const step = (tour.steps || [])[Number(st.dataset.step)] || {};
        const ids = [...(step.nodes || []), ...(step.edges || []).map((id) => { const ed = S.board.edgesById.get(id); return ed ? ed.from : null; })].filter((id) => S.board.byId.has(id));
        if (ids.length) {
          const ns = ids.map((id) => S.board.byId.get(id));
          const x0 = Math.min(...ns.map((n) => n.x)), y0 = Math.min(...ns.map((n) => n.y)), x1 = Math.max(...ns.map((n) => n.x + n.w)), y1 = Math.max(...ns.map((n) => n.y + n.h));
          flyTo(fitView({ x: x0, y: y0, w: x1 - x0, h: y1 - y0 }, 60, 1.25));
        }
        return;
      }
      const a = e.target.closest("a[data-id]");
      if (!a) return;
      const n = S.board.byId.get(a.dataset.id);
      if (!n) return;
      if (S.mode === "list") { scrollListTo(n.id); return; }
      if (n.kind === "section") flyTo(fitView(n, 40, 1.25)); else { flyTo(nodeView(n, true)); select(n.id); }
    });
    R.filter.addEventListener("input", renderOutline);
    R.readlist.addEventListener("click", () => setMode("list"));
    R.canvas.querySelector(".b-readlist2").addEventListener("click", () => setMode("list"));
    R.findq.addEventListener("input", () => runFind(R.findq.value));
    R.findq.addEventListener("keydown", (e) => {
      if (e.key === "Enter") { e.preventDefault(); stepFind(e.shiftKey ? -1 : 1); }
      else if (e.key === "Escape") { e.preventDefault(); closeFind(); }
      else if (e.key === "g" && e.metaKey) { e.preventDefault(); stepFind(e.shiftKey ? -1 : 1); }
    });
    R.find.querySelector(".b-findp").addEventListener("click", () => stepFind(-1));
    R.find.querySelector(".b-findx").addEventListener("click", () => stepFind(1));
    R.find.querySelector(".b-findd").addEventListener("click", closeFind);
    R.notecard.addEventListener("pointerleave", () => { if (S.note && !S.focus) S.noteTimer = setTimeout(closeNote, 250); });
    R.notecard.addEventListener("pointerenter", () => clearTimeout(S.noteTimer));
    R.list.addEventListener("click", (e) => {
      const a = e.target.closest("a");
      if (a && !a.classList.contains("b-onboard")) { e.preventDefault(); followLink(a, e); return; }
      const ob = e.target.closest(".b-onboard");
      const rf = e.target.closest("[data-ref]");
      if (rf) { e.preventDefault(); openRef(rf.dataset.ref, e.altKey); return; }
      if (ob) { e.preventDefault(); setMode("canvas"); const n = S.board.byId.get(ob.dataset.id); if (n) { flyTo(nodeView(n, true), { cut: true }); select(n.id); } }
    });
    window.addEventListener("resize", () => { if (!S.active) return; const c = centreNode(); const { s, tx, ty } = S.view; const cx = (S.W / 2 - tx) / s, cy = (S.H / 2 - ty) / s; measure(); S.view.tx = S.W / 2 - cx * s; S.view.ty = S.H / 2 - cy * s; void c; rest(); });
    if (reduceMotion.addEventListener) reduceMotion.addEventListener("change", () => {});
  }
  function hoverFrame() {
    hoverRaf = 0;
    const e = lastMove;
    if (!e || !S.board || S.moving || (drag && drag.pan)) return;
    const p = local(e);
    const onCard = e.target.closest && e.target.closest(".b-node");
    const n = onCard ? S.board.byId.get(onCard.dataset.id) : (S.level !== "read" ? nodeAt(p.x, p.y) : null);
    const chip = e.target.closest && e.target.closest(".b-elbl.noted");
    if (chip) { const id = chip.dataset.edge; if (!S.note || S.note.id !== id) { clearTimeout(S.noteTimer); S.noteTimer = setTimeout(() => openNote(id, true), 300); } return; }
    const id = n ? n.id : null;
    if (id !== S.hover) {
      S.hover = id;
      if (!S.selected && !S.focus) { S.lit = id; lightEdges(); }
      clearTimeout(S.noteTimer);
      if (S.note && !S.focus && S.note.id !== id) S.noteTimer = setTimeout(closeNote, 250);
      if (n && n.note && S.level === "read") S.noteTimer = setTimeout(() => openNote(n.id), 300);
    }
    if (S.level !== "read") showHover(n); else hideHover();
  }
  function followLink(a, e) {
    const newTab = e.metaKey;
    if (a.classList.contains("wl")) { post({ type: "openWiki", target: a.dataset.target, newTab, place: placeNow() }); return; }
    const href = a.getAttribute("href") || "";
    if (/^(https?|mailto|tel):/i.test(href)) { post({ type: "openExternal", url: href }); return; }
    if (/^[a-z][a-z0-9+.-]*:/i.test(href)) { post({ type: "openScheme", url: href }); return; }
    if (href.startsWith("#")) { const n = S.board.byId.get(decodeURIComponent(href.slice(1))); if (n) flyTo(nodeView(n, true)); return; }
    if (href) post({ type: "openLocal", href, newTab, place: placeNow() });
  }
  // A source like `server/a.py:118` opens in the editor at that line; with Option it is copied instead (BRD-6).
  function openRef(ref, copy) {
    const m = /^(.*?)(?::(\d+))?(?:-\d+)?$/.exec(String(ref || "").trim());
    const path = m ? m[1] : "", line = m && m[2] ? Number(m[2]) : null;
    if (copy || !path || /^[a-z][a-z0-9+.-]*:\/\//i.test(path) || path.includes("\u0000")) { post({ type: "copyText", text: ref }); toast(t("Copied a reference to {x}", { x: ref })); return; }
    post({ type: "openReference", path, line, docId: S.docId });
  }
  function toast(text) {
    R.toast.textContent = text;
    R.toast.hidden = false;
    clearTimeout(S.toastTimer);
    S.toastTimer = setTimeout(() => { R.toast.hidden = true; }, 1800);
  }

  // ---------- the rail and modes ----------
  function setRail(show, overlay) {
    S.rail = !!show;
    S.railOverlay = !!overlay;
    R.root.classList.toggle("rail-on", S.rail);
    R.root.classList.toggle("rail-overlay", S.rail && S.railOverlay);
    if (!S.board) return;
    const { s, tx, ty } = S.view;
    const cx = (S.W / 2 - tx) / s, cy = (S.H / 2 - ty) / s;
    measure();
    S.view.tx = S.W / 2 - cx * s;
    S.view.ty = S.H / 2 - cy * s;
    rest();
  }
  function setMode(m) {
    if (!S.board) return;
    S.mode = m;
    R.root.classList.toggle("list-mode", m === "list");
    R.list.hidden = m !== "list";
    R.canvas.hidden = m === "list";
    closeNote();
    if (m === "list") { buildList(); R.list.focus({ preventScroll: true }); }
    else { measure(); rest(); R.canvas.focus({ preventScroll: true }); }
    updatePanel();
    schedulePlace();
    scheduleView();
  }

  // ---------- List view (BRD-23): the board as a document in reading order ----------
  function buildList() {
    const b = S.board;
    if (S.listBuiltFor === b) { markList(); return; }
    S.listBuiltFor = b;
    const outs = new Map();
    for (const e of b.edges) if (!e.missing) { if (!outs.has(e.from)) outs.set(e.from, []); outs.get(e.from).push(e.to); }
    let noteNo = 0;
    let h = `<div class="b-lcol" dir="${S.dir}">`;
    if (b.eyebrow) h += `<div class="eyebrow">${esc(b.eyebrow)}</div>`;
    h += `<h1 class="title">${esc(b.title || S.name.replace(/\.canvas$/i, ""))}</h1>`;
    for (const id of b.order) {
      const n = b.byId.get(id);
      if (!n) continue;
      if (n.kind === "section") {
        const tag = n.depth > 0 ? "h3" : "h2";
        h += `${n.eyebrow ? `<div class="eyebrow grp">${esc(n.eyebrow)}</div>` : ""}<${tag} class="lsec" data-id="${esc(id)}">${esc(n.label || n.title || "")}</${tag}>`;
        continue;
      }
      const to = (outs.get(id) || []).map((k) => titleOf(b.byId.get(k))).filter(Boolean);
      const body = n.kind === "image" ? "" : n.body ? md(n.body) : n.file ? `<p class="b-path">${esc(n.file)}</p>` : n.url ? `<p class="b-path">${esc(n.url)}</p>` : "";
      if (n.note) noteNo++;
      const note = n.note ? `<div class="b-lnote" role="note"><div class="eyebrow"><sup>${num(noteNo)}</sup> ${esc(n.note.area || t("Note"))}</div>${n.note.title ? `<div class="nt">${esc(n.note.title)}</div>` : ""}${md(n.note.body || "")}${n.note.refs && n.note.refs.length ? `<div class="refs">${n.note.refs.map((r) => `<code data-ref="${esc(r)}">${esc(r)}</code>`).join("")}</div>` : ""}</div>` : "";
      h += `<div class="brow${n.placed ? "" : " unplaced"}" data-id="${esc(id)}">${pillOf(n)}<b class="bt">${esc(titleOf(n))}</b><div class="bb">${body}</div>${to.length ? `<div class="lto">${esc(t("Leads to {x}", { x: to.join(", ") }))}</div>` : ""}${note}${n.placed ? `<a class="b-onboard" href="#" data-id="${esc(id)}">${esc(t("Show on board"))}</a>` : ""}</div>`;
    }
    h += "</div>";
    R.list.innerHTML = h;
    R.list.querySelectorAll(".bb").forEach(expandBlocks);
    directionise(R.list);
    R.list.querySelectorAll("img").forEach(prepImg);
    if (S.wantImages) { S.wantImages = false; const x = X(); if (x.requestImages) x.requestImages(); }
    markList();
  }
  function markList() {
    R.list.querySelectorAll(".brow").forEach((r) => {
      const id = r.dataset.id;
      r.classList.toggle("chg", S.changed.has(id) && !S.rewritten);
      r.classList.toggle("hit", (S.find.open && S.find.hits.includes(id)) || (!!S.legend.word && S.legend.hits.includes(id)));
      r.classList.toggle("cur", (S.find.open && S.find.hits[S.find.cur] === id) || (!!S.legend.word && S.legend.hits[S.legend.cur] === id));
    });
  }
  function scrollListTo(id) {
    const row = R.list.querySelector(`.brow[data-id="${CSS.escape(id)}"], .lsec[data-id="${CSS.escape(id)}"]`);
    if (row) { row.scrollIntoView({ block: "center" }); row.classList.add("flash"); setTimeout(() => row.classList.remove("flash"), 900); }
    markList();
  }

  // ---------- place (BRD-15) ----------
  function placeNow() {
    if (!S.board) return null;
    const { s, tx, ty } = S.view;
    const c = centreNode();
    return { kind: "board", cx: (S.W / 2 - tx) / s, cy: (S.H / 2 - ty) / s, zoom: s, node: c ? c.id : null, mode: S.mode, selected: S.selected || null };
  }
  // What an agent can ask through Linen's MCP server: the box at the centre, the section and selection in view, the
  // zoom and level, the mode and how many changes are unread. Posted when a gesture rests, the selection changes or
  // marks are acknowledged, debounced, never mid-gesture.
  let viewTimer = 0;
  function scheduleView() {
    clearTimeout(viewTimer);
    viewTimer = setTimeout(() => {
      if (!S.active || !S.board) return;
      if (S.moving) { scheduleView(); return; }
      const c = S.mode === "canvas" ? centreNode() : null;
      post({ type: "view", docId: S.docId, node: c ? c.id : null, section: S.curSection || null, selected: S.selected || null, zoom: S.view.s, level: S.level,
        mode: S.mode, unread: S.rewritten ? S.board.nodes.filter((n) => n.kind !== "section").length : changeList().length });
    }, 300);
  }
  let placeTimer = 0;
  function schedulePlace() {
    clearTimeout(placeTimer);
    const doc = S.docId;
    placeTimer = setTimeout(() => { if (!S.active || S.docId !== doc) return; const p = placeNow(); if (p) post({ type: "place", place: p, docId: doc }); }, 500);
  }

  // ---------- problems and honest states (BRD-1) ----------
  function showFatal(b) {
    R.honest.hidden = false;
    R.root.classList.add("fatal");
    R.canvas.hidden = true;
    R.list.hidden = true;
    R.rail.hidden = true;
    const list = (b.fatal.problems || []).slice(0, 10);
    R.honest.innerHTML = `<div class="b-hcol"><div class="eyebrow">${esc(S.name)}</div><h1 class="b-htitle">${esc(t("Linen could not read this board"))}</h1>
      <ul class="b-probs">${list.map((p) => `<li><code>${esc(p.path || "")}${p.line ? ` · ${num(p.line)}` : ""}</code><span>${esc(p.message)}</span></li>`).join("")}</ul></div>`;
  }
  function hideFatal() { R.honest.hidden = true; R.root.classList.remove("fatal"); R.canvas.hidden = S.mode === "list"; R.rail.hidden = false; }
  function showBadLine(bad) {
    S.badVersion = bad;
    if (!bad) { R.line.hidden = true; renderProblems(); return; }
    const n = (bad.problems || []).length;
    R.line.hidden = false;
    R.line.querySelector("span").textContent = n === 1 ? t("This version has 1 problem · showing the last good board") : t("This version has {n} problems · showing the last good board", { n: num(n) });
    R.line.querySelector("button").textContent = t("Show");
    renderProblems();
  }

  // ---------- load and update ----------
  function parse(text, sidecar) {
    if (!window.LinenCanvas) throw new Error("board model missing");
    return window.LinenCanvas.parse(text, { sidecarText: sidecar == null ? null : sidecar });
  }
  function activate() {
    dom();
    if (S.active) return;
    S.active = true;
    html.classList.add("board-mode");
    R.root.hidden = false;
    // The app set the outline before the board arrived; the rail follows it.
    S.rail = html.classList.contains("outline-on");
    S.railOverlay = html.classList.contains("outline-overlay");
    R.root.classList.toggle("rail-on", S.rail);
    R.root.classList.toggle("rail-overlay", S.rail && S.railOverlay);
    readColors();
  }
  function deactivate() {
    if (!S.active) return;
    S.active = false;
    clearTimeout(placeTimer); clearTimeout(viewTimer); clearTimeout(seenTimer); clearTimeout(S.restTimer); clearTimeout(S.noteTimer);
    html.classList.remove("board-mode");
    unmountAll();
    for (const e of S.secs.values()) { e.label.remove(); if (e.title) e.title.remove(); }
    S.secs.clear();
    for (const o of S.edgesOn.values()) o.chip.remove();
    S.edgesOn.clear();
    closeNote();
    R.root.hidden = true;
    S.board = S.good = null;
    S.docId = null;
  }
  function resetForBoard(b) {
    unmountAll();
    for (const e of S.secs.values()) { e.label.remove(); if (e.title) e.title.remove(); }
    S.secs.clear();
    for (const o of S.edgesOn.values()) o.chip.remove();
    S.edgesOn.clear();
    geoms.clear();
    S.board = b;
    S.good = b;
    S.dir = b.dir || "ltr";
    S.roomAbove.clear();
    S.secCounts = null;
    S.listBuiltFor = null;
    S.out = new Map();
    for (const e of b.edges) if (!e.missing) { if (!S.out.has(e.from)) S.out.set(e.from, []); S.out.get(e.from).push(e.to); }
    S.missingEdges = b.edges.filter((e) => e.missing && e.missing !== "both");
    R.root.setAttribute("dir", S.dir);
    R.rail.setAttribute("dir", S.dir);
    R.btitle.hidden = !b.title;
    R.btitle.textContent = b.title || "";
    R.over.setAttribute("dir", S.dir);
    const hasWords = b.nodes.some((n) => n.word);
    R.legend.hidden = !hasWords;
    renderLegend();
    renderProblems();
    renderOutline();
    R.readlist.textContent = t("Read as list");
    R.canvas.querySelector(".b-readlist2").textContent = t("Read as list");
    R.filter.placeholder = t("Filter");
    R.findq.placeholder = t("Find on board");
    R.find.querySelector(".b-findd").textContent = t("Done");
    R.zpanel.querySelector(".b-fit").textContent = t("Fit");
    R.zpanel.querySelector(".b-zin").setAttribute("aria-label", t("Zoom in"));
    R.zpanel.querySelector(".b-zout").setAttribute("aria-label", t("Zoom out"));
  }
  async function load(msg) {
    activate();
    S.flight++; // a flight from the previous document ends here; it would land on this one's view
    const t0 = performance.now();
    Object.assign(S, { path: msg.path || "", name: msg.name || "", refPath: msg.refPath || msg.path || "", docId: msg.docId, version: msg.version || 0 });
    S.base = readBaseline(msg.baseline);
    S.previews = msg.previews && typeof msg.previews === "object" ? msg.previews : {};
    S.bgs = new Map();
    S.baseDate = msg.baselineDate || null;
    S.removed = [];
    S.removedMore = 0;
    S.seen = new Map();
    S.history = [];
    S.selected = S.focus = S.lit = S.hover = null;
    S.legend = { word: null, hits: [], cur: -1 };
    if (S.find.open) closeFind();
    S.mode = "canvas";
    S.badVersion = null;
    R.line.hidden = true;
    delete R.line.dataset.action;
    S.contentCache.clear();
    let b;
    try { b = parse(msg.text, msg.sidecar); } catch (err) { b = { fatal: { reason: "error", problems: [{ path: "$", message: String(err && err.message || err) }] }, problems: [] }; }
    if (b.fatal && b.fatal.reason !== "limits") {
      S.board = null;
      showFatal(b);
      post({ type: "firstPaint", version: S.version, paintMs: Math.round(performance.now() - t0) });
      post({ type: "rendered", title: S.name.replace(/\.canvas$/i, ""), blocks: 0, words: 0, docId: S.docId });
      return;
    }
    hideFatal();
    resetForBoard(b);
    computeChanges(null);
    measure();
    if (b.fatal) {
      // Past BRD-20's limits: shown as a list, with the reason (the canvas is not drawn).
      S.mode = "list";
      R.line.hidden = false;
      R.line.querySelector("span").textContent = t("Too large to draw here; showing it as a list");
      R.line.querySelector("button").hidden = false;
      R.line.querySelector("button").textContent = t("Draw it anyway");
      R.line.dataset.action = "large";
    } else R.line.querySelector("button").hidden = false;
    openingView(msg.place);
    S.openingUntouched = !msg.place;
    if (b.fatal) S.mode = "list"; // BRD-20: past the limits, a remembered Canvas place never draws the canvas
    S.level = levelOf(S.view.s);
    R.canvas.dataset.level = S.level;
    S.firstPaintPending = { t0, version: S.version };
    setMode(S.mode);
    if (S.mode === "canvas") {
      // First screen at once (BRD-24's first section is a few dozen cards), the rest by budget.
      R.under.style.setProperty("--px", `${(1 / S.view.s).toFixed(4)}px`);
      R.over.style.setProperty("--px", `${(1 / S.view.s).toFixed(4)}px`);
      frame();
      if (S.queue.length && S.queue.length <= 160) {
        const els = [];
        for (const n of S.queue.splice(0)) { const el = S.mounted.get(n.id); if (el) { fillCard(el, n); els.push(el); } else els.push(mountCard(n)); }
        markOverflow(els);
        drawShapes();
      }
      if (!S.queue.length) firstPaintDone();
    } else firstPaintDone();
    updateChip();
    post({ type: "rendered", title: b.title || S.name.replace(/\.canvas$/i, ""), blocks: b.nodes.length, words: 0, docId: S.docId });
    if (S.wantImages) { S.wantImages = false; const x = X(); if (x.requestImages) x.requestImages(); }
    S.reflowed = false;
    if (!b.fatal) reflowIfNeeded(msg.text, msg.sidecar == null ? null : msg.sidecar, S.docId);
  }
  async function reflowIfNeeded(text, sidecar, doc) {
    const b = S.board;
    if (!b || !b.hasLayout || !window.LinenLayout || typeof window.LinenLayout.run !== "function") return;
    const inLayout = (n) => { for (let p = n.parent ? b.byId.get(n.parent) : null; p; p = p.parent ? b.byId.get(p.parent) : null) if (p.layout) return true; return false; };
    const laid = b.nodes.filter((n) => n.placed && n.kind !== "section" && inLayout(n));
    if (!laid.length || laid.length > 300) return;
    const sizes = await measureCards(laid.map((n) => ({ node: n, width: n.w })), { words: b.words, dir: S.dir });
    if (!sizes.some((m, i) => m.h > laid[i].h + 1)) return;
    let res;
    try { res = await window.LinenLayout.run(text, { sidecarText: sidecar, cacheToken: "view" }); } catch (_) { return; }
    if (!res || !res.changed || S.docId !== doc || S.board !== b) return;
    const nb = parse(res.text, sidecar);
    if (nb.fatal) return;
    // Hashes ignore positions, so marks and the baseline are untouched; the file is not written (view only).
    const view = { ...S.view };
    resetForBoard(nb);
    computeChangesKeep(b);
    Object.assign(S.view, view);
    S.reflowPending = S.openingUntouched;
    S.reflowed = true;
    R.line.hidden = false;
    R.line.dataset.action = "";
    R.line.querySelector("span").textContent = t("Laid out again for this view · run linen layout to save it");
    R.line.querySelector("button").hidden = true;
    if (S.reflowPending) { S.reflowPending = false; openingView(null); } // the opening view, re-fitted to the new layout
    if (S.mode === "canvas") rest(); else buildList();
  }
  function computeChangesKeep(prev) { const keep = { changed: S.changed, edges: S.changedEdges, rewritten: S.rewritten }; S.changed = keep.changed; S.changedEdges = keep.edges; S.rewritten = keep.rewritten; void prev; }
  async function firstPaintDone() {
    const p = S.firstPaintPending;
    if (!p) return;
    S.firstPaintPending = null;
    try { if (document.fonts && document.fonts.ready) await document.fonts.ready; } catch (_) { /* fonts load in the background */ }
    await new Promise((r) => next(r));
    post({ type: "firstPaint", version: p.version, paintMs: Math.round(performance.now() - p.t0), kind: "board", mounted: S.mounted.size });
    S.lastFirstPaint = performance.now() - p.t0;
  }
  async function update(msg) {
    if (!S.active) return false; // only a load shows a board; a late update for one the tab has left is dropped
    if (msg.docId && S.docId && msg.docId !== S.docId) return false; // another document's update, delivered late
    if (S.active && S.good && typeof msg.version === "number" && msg.version <= S.version) return false; // older than what is drawn
    if (!S.active || !S.good) return load(msg);
    let b;
    try { b = parse(msg.text, msg.sidecar); } catch (err) { b = { fatal: { reason: "error", problems: [{ path: "$", message: String(err && err.message || err) }] }, problems: [] }; }
    S.version = msg.version || S.version;
    // A fatal reload keeps the last good board on screen (BRD-1, like LIVE-3).
    if (b.fatal) { showBadLine({ problems: b.fatal.problems || b.problems || [] }); return; }
    if (S.badVersion) showBadLine(null);
    // Hold the view (BRD-12): the node nearest the centre keeps its screen position when it survives.
    S.flight++;
    const prev = S.board;
    const c = centreNode();
    const { s, tx, ty } = S.view;
    // its centre keeps its place on screen, so a box that grows stays where the reader's eye is (BRD-12)
    const before = c ? { id: c.id, sx: (c.x + c.w / 2) * s + tx, sy: (c.y + c.h / 2) * s + ty } : null;
    resetForBoard(b);
    if (before) { const n = b.byId.get(before.id); if (n && n.placed) { S.view.tx = before.sx - (n.x + n.w / 2) * s; S.view.ty = before.sy - (n.y + n.h / 2) * s; } }
    computeChanges(prev);
    if (S.find.open && S.find.q) runFind(R.findq.value);
    if (S.legend.word) { const w = S.legend.word; S.legend.word = null; chooseWord(w); }
    if (S.mode === "list") buildList(); else rest();
    refreshMarks();
    updateChip();
    S.holdCheck = before ? { id: before.id, sx: before.sx, sy: before.sy } : null;
    post({ type: "rendered", title: b.title || S.name.replace(/\.canvas$/i, ""), blocks: b.nodes.length, words: 0, docId: S.docId });
  }

  // ---------- Copy Reference (BRD-26) and node links ----------
  function copyReference(msg) {
    const b = S.board;
    if (!b) return null;
    const id = S.selected || S.focus; // never a box the reader did not choose
    const n = id ? b.byId.get(id) : null;
    if (!n) return null;
    const ref = (msg && msg.refPath) || S.refPath || S.path;
    const lines = Array.isArray(n.line) ? n.line : null;
    const lineText = lines ? (lines[0] === lines[1] ? `line ${lines[0]}` : `lines ${lines[0]}-${lines[1]}`) : "";
    const out = [`${ref}#${n.id}${lineText ? ` (${lineText})` : ""}`];
    if (n.noteFrom === "sidecar") out.push(`note: ${ref}.notes.json[${JSON.stringify(n.id)}]`);
    const text = n.kind === "section" ? (n.label || n.title || "") : [n.title ? `# ${n.title}` : "", n.body || n.text || "", n.file || "", n.url || ""].filter(Boolean).join("\n");
    if (text) out.push("```", text.trim(), "```");
    toast(t("Copied a reference to {x}", { x: n.id }));
    return { text: out.join("\n") + "\n", id: n.id };
  }
  function goNode(id, sel) {
    const b = S.board;
    if (!b) return false;
    const n = b.byId.get(id);
    if (!n || !n.placed) { toast(t("That box is no longer on this board")); return false; }
    if (S.mode === "list" && !(S.board.fatal)) setMode("canvas"); // a link to a box shows the box (BRD-26)
    if (S.mode === "list") { scrollListTo(id); return true; }
    flyTo(n.kind === "section" ? fitView(n, 40, 1.25) : nodeView(n, true), { cut: true });
    if (sel !== false) { S.selected = id; S.focus = id; S.lit = id; refreshMarks(); lightEdges(); }
    return true;
  }
  function heading(text) {
    const b = S.board;
    if (!b) return false;
    const q = String(text || "").trim();
    if (b.byId.has(q)) return goNode(q, true);
    const fold = X().fold || ((x) => x.toLowerCase());
    const fq = fold(q);
    const n = b.nodes.find((x) => x.kind === "section" && fold(x.label || x.title || "") === fq) || b.nodes.find((x) => fold(titleOf(x)) === fq);
    if (n) return goNode(n.id, n.kind !== "section");
    toast(t("That box is no longer on this board"));
    return false;
  }

  // ---------- the display list for export (EXP-5): boxes, paths and text runs in board units ----------
  async function displayList(msg) {
    const b = S.board;
    if (!b) return null;
    const sec = msg && msg.section ? b.byId.get(msg.section) : null;
    const inScope = (n) => {
      if (!sec) return n.placed;
      if (!n.placed) return false;
      for (let p = n; p; p = p.parent ? b.byId.get(p.parent) : null) if (p.id === sec.id) return true;
      return false;
    };
    const box = sec ? { x: sec.x, y: sec.y - 60, w: sec.w, h: sec.h + 60 } : { x: b.bounds.x - 24, y: b.bounds.y - 80, w: b.bounds.w + 48, h: b.bounds.h + 104 };
    const items = [];
    const c = S.colors;
    const textRuns = (root, ox, oy) => {
      // Each line of each text node becomes a run, positioned from its line box (as X(b) reads notes).
      const out = [];
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
      const range = document.createRange();
      const rootRect = root.getBoundingClientRect();
      while (walker.nextNode()) {
        const tn = walker.currentNode;
        const s = tn.nodeValue;
        if (!s.trim()) continue;
        const el = tn.parentElement;
        if (el.closest("svg")) continue;
        const cs = getComputedStyle(el);
        if (cs.display === "none" || el.closest("[hidden]")) continue; // the stage itself is visibility: hidden
        const re = /\S+/g;
        let m, line = null;
        const flush = () => { if (line) out.push(line); line = null; };
        while ((m = re.exec(s))) {
          range.setStart(tn, m.index);
          range.setEnd(tn, m.index + m[0].length);
          const rects = range.getClientRects();
          if (!rects.length) continue;
          const r0 = rects[0];
          const top = r0.top - rootRect.top, left = r0.left - rootRect.left;
          if (line && Math.abs(line.top - top) < 2) {
            line.x0 = Math.min(line.x0, left); line.x1 = Math.max(line.x1, r0.right - rootRect.left);
            line.end = m.index + m[0].length;
          } else {
            flush();
            line = { node: tn, start: m.index, end: m.index + m[0].length, top, h: r0.height, x0: left, x1: r0.right - rootRect.left, cs };
          }
        }
        flush();
      }
      return out.map((l) => ({
        t: "text", text: l.node.nodeValue.slice(l.start, l.end), x: ox + l.x0, y: oy + l.top, w: l.x1 - l.x0, h: l.h,
        font: /Serif Display/.test(l.cs.fontFamily) ? "serif-display" : /Serif Text/.test(l.cs.fontFamily) ? "serif-text" : /Mono|monospace/.test(l.cs.fontFamily) ? "mono" : "sans",
        weight: Number(l.cs.fontWeight) || 400, size: parseFloat(l.cs.fontSize), color: l.cs.color,
        dir: (l.node.parentElement.closest("[dir]") || R.root).getAttribute("dir") || S.dir,
        upper: l.cs.textTransform === "uppercase", tracking: parseFloat(l.cs.letterSpacing) || 0,
      }));
    };
    // A scratch stage at scale 1 lays out each box at reading level.
    const stage = document.createElement("div");
    stage.className = "b-stage b-layer";
    stage.setAttribute("dir", S.dir);
    document.body.appendChild(stage);
    const saveLevel = S.level;
    S.level = "read";
    try {
      for (const n of b.nodes) {
        if (!inScope(n)) continue;
        if (n.kind === "section") {
          const wi = washIndex(n.color);
          items.push({ t: "rect", x: n.x, y: n.y, w: n.w, h: n.h, fill: wi >= 0 ? c.washes[wi] : c.sec, stroke: c.rule, lw: 1, r: 2, role: "section", id: n.id });
          const nested = n.depth > 0;
          if (n.label) items.push(nested
            ? { t: "text", text: n.label, x: n.x, y: n.y - 22, w: n.w, h: 18, font: "sans", weight: 500, size: 15, color: c.ink, dir: n.dir || S.dir, role: "section-name", id: n.id }
            : { t: "text", text: n.label, x: n.x, y: n.y - 36, w: n.w, h: 30, font: "serif-display", weight: 300, size: 24, color: c.ink, dir: n.dir || S.dir, role: "section-name", id: n.id });
          if (n.title) { const pad = nested ? 14 : 24; items.push({ t: "text", text: n.title, x: n.x + pad, y: n.y + pad, w: n.w - 2 * pad, h: 29, font: "serif-display", weight: 300, size: 24, color: c.ink, dir: n.dir || S.dir, role: "section-title", id: n.id }); }
          if (n.eyebrow) items.push({ t: "text", text: n.eyebrow, x: n.x, y: n.y - 56, w: n.w, h: 14, font: "sans", weight: 500, size: 11, color: c.ink2, dir: n.dir || S.dir, upper: true, tracking: 1.5 });
        }
      }
      for (const e of b.edges) {
        const a = b.byId.get(e.from), z = b.byId.get(e.to);
        if (!a || !z || !inScope(a) || !inScope(z)) continue;
        const g = geomCache(e);
        if (!g) continue;
        let d = g.d;
        if (e.toEnd !== "none") d += arrow(g.p2, g.end2.map((v) => -v), 1);
        if (e.fromEnd === "arrow") d += arrow(g.p1, g.end1.map((v) => -v), 1);
        items.push({ t: "path", d, stroke: e.kind === "fail" ? c.rust : e.kind === "main" ? c.ink : c.ink2, lw: e.kind === "main" ? 2.4 : 1.5, dash: e.kind === "code" ? [5, 4] : e.kind === "plan" ? [1.5, 3.5] : null, role: "edge", id: e.id });
        if (e.label) items.push({ t: "text", text: e.label, x: g.mid[0], y: g.mid[1] - 9, w: 0, h: 18, font: "sans", weight: 500, size: 12.5, color: c.ink2, dir: "ltr", anchor: "middle", chip: true, role: "edge-label", id: e.id });
      }
      let k = 0;
      // Build every box first, send its images through the gate (which consumes their stashed sources), wait for them
      // to load, then measure: an image's size moves the text under it (Codex verify2 #3, #4).
      const built = [];
      for (const n of b.nodes) {
        if (!inScope(n) || n.kind === "section") continue;
        const sh = shapeOf(n);
        const el = document.createElement("div");
        el.className = `b-node k-${n.kind} lv-read${sh ? ` s-${sh}` : ""}`;
        el.style.cssText = `left:0;top:0;width:${n.w}px;height:${n.h}px;position:relative`;
        el.setAttribute("dir", S.dir);
        el.innerHTML = readContent(n, S.board.words);
        expandBlocks(el);
        directionise(el);
        stage.appendChild(el);
        const imgs = [...el.querySelectorAll("img")].map((img) => {
          const src = img.dataset.file || (img.dataset.img && X().imgSource ? X().imgSource(img.dataset.img) : "") || img.getAttribute("src") || "";
          prepImg(img);
          return { img, src };
        });
        built.push({ n, el, imgs });
      }
      const all = built.flatMap((x) => x.imgs.map((i) => i.img));
      if (all.length) {
        const x = X(); if (x.requestImages) x.requestImages();
        S.wantImages = false;
        await Promise.race([
          Promise.all(all.map((img) => new Promise((r) => { if (img.complete && img.naturalWidth) r(); else { img.addEventListener("load", r, { once: true }); img.addEventListener("error", r, { once: true }); } }))),
          new Promise((r) => setTimeout(r, 3000)),
        ]);
      }
      for (const { n, el, imgs } of built) {
        const sh = shapeOf(n);
        const wi = washIndex(n.color);
        const fill = n.kind === "sticky" ? (wi >= 0 ? c.washes[wi] : c.washes[2]) : n.kind === "text" ? null : wi >= 0 ? c.washes[wi] : c.card;
        if (n.kind !== "text") items.push({ t: "rect", x: n.x, y: n.y, w: n.w, h: n.h, fill, stroke: n.kind === "sticky" ? null : c.rule, lw: 1, r: 2, role: "node", kind: n.kind, word: n.word || null, shape: sh, id: n.id, note: n.note ? ++k : null });
        for (const r of textRuns(el, n.x, n.y)) { r.id = n.id; items.push(r); }
        el.querySelectorAll(".st").forEach((p) => {
          const pr = p.getBoundingClientRect(), er = el.getBoundingClientRect();
          items.push({ t: "rect", x: n.x + pr.left - er.left, y: n.y + pr.top - er.top, w: pr.width, h: pr.height, fill: sh === "rust" ? c.rust : null, stroke: sh === "rust" ? c.rust : c.ink, lw: 1, dash: sh === "dashed" ? [3, 2] : sh === "dotted" ? [1, 2] : null, r: 2, role: "pill", shape: sh, id: n.id });
        });
        // each image at its own box, with its own source (the file for an image node, the Markdown source in a card)
        const er = el.getBoundingClientRect();
        for (const { img, src } of imgs) {
          const ir = img.getBoundingClientRect();
          items.push({ t: "image", x: n.x + ir.left - er.left, y: n.y + ir.top - er.top, w: ir.width, h: ir.height, src, id: n.id, loaded: !!img.naturalWidth });
        }
        el.remove();
      }
    } finally {
      S.level = saveLevel;
      stage.remove();
    }
    const notes = [];
    for (const n of b.nodes) if (inScope(n) && n.note) notes.push({ id: n.id, title: n.note.title || titleOf(n), area: n.note.area || "", body: n.note.body || "", refs: n.note.refs || [] });
    for (const e of b.edges) { // connectors' notes too, numbered after the boxes'
      if (!e.note) continue;
      const a = b.byId.get(e.from), z = b.byId.get(e.to);
      if (!a || !z || !inScope(a) || !inScope(z)) continue;
      const g = geomCache(e);
      const mid = g ? (g.at ? g.at(0.5) : g.mid) : null;
      notes.push({ id: e.id, edge: true, title: e.note.title || e.label || "", area: e.note.area || "", body: e.note.body || "", refs: e.note.refs || [], x: mid ? mid[0] : undefined, y: mid ? mid[1] : undefined });
      const lbl = items.find((it) => it.role === "edge-label" && it.id === e.id);
      if (lbl) lbl.note = notes.length;
    }
    return { size: { w: box.w, h: box.h }, origin: { x: box.x, y: box.y }, dir: S.dir, title: b.title || S.name.replace(/\.canvas$/i, ""), items, notes,
      sections: b.order.filter((id) => b.byId.get(id).kind === "section").map((id) => { const n = b.byId.get(id); return { id, name: n.label || n.title || "", x: n.x, y: n.y, w: n.w, h: n.h, depth: n.depth }; }) };
  }

  // ---------- measuring cards for `linen layout` (Lane E): the real card markup at a width, height to fit ----------
  let measureStage = null;
  function stage() {
    if (measureStage && measureStage.isConnected) return measureStage;
    measureStage = document.createElement("div");
    measureStage.className = "b-stage b-layer";
    document.body.appendChild(measureStage);
    return measureStage;
  }
  // Stateless: the card is built from the node and the words given, exactly as drawn, never from the loaded board.
  // Faces load on first use, so a page that has drawn nothing yet would measure in fallback faces: load them first.
  let facesLoaded = null;
  function loadFaces() {
    if (!facesLoaded) facesLoaded = Promise.all(["400 15px \"Linen Sans\"", "500 15px \"Linen Sans\"", "600 15px \"Linen Sans\"", "300 19px \"Linen Serif Display\"",
      "400 15px \"Linen Serif Text\"", "500 15px \"Linen Serif Text\""].map((f) => (document.fonts ? document.fonts.load(f, "Aa ب").catch(() => null) : null))).then(() => document.fonts && document.fonts.ready);
    return facesLoaded;
  }
  async function measureCards(list, opts) {
    try { await loadFaces(); } catch (_) { /* measured with what loaded */ }
    const words = (opts && Array.isArray(opts.words) && opts.words.length ? opts.words : null) || (window.LinenCanvas ? window.LinenCanvas.DEFAULT_WORDS : []);
    const st = stage();
    const els = (list || []).map(({ node, width }) => {
      const n = node || {};
      const el = document.createElement("div");
      const w = findWord(n, words);
      el.className = `b-node k-${n.kind || "card"} lv-read${w ? ` s-${w.shape}` : ""}${n.note ? " noted" : ""}`;
      el.style.cssText = `position:absolute;left:0;top:0;width:${Math.max(1, width)}px;height:auto`;
      el.setAttribute("dir", n.dir || (opts && opts.dir) || "ltr");
      el.innerHTML = readContent(Object.assign({ w: width, h: n.h || 100 }, n, { w: width }), words);
      expandBlocks(el);
      directionise(el);
      st.appendChild(el);
      return el;
    });
    const out = els.map((el) => ({ w: el.offsetWidth, h: Math.ceil(Math.max(el.scrollHeight, el.offsetHeight)) }));
    els.forEach((el) => el.remove());
    return out;
  }
  async function measureCard(node, width, opts) { return (await measureCards([{ node, width }], opts))[0]; }

  // ---------- frame budget runs (spike B(a) on the Mac, with real cards) ----------
  async function bench(opts) {
    const o = opts || {};
    const frames = o.frames || 180;
    const raf = () => new Promise((r) => requestAnimationFrame(r));
    const out = { w: S.W, h: S.H, dpr: devicePixelRatio, n: S.board.nodes.length, e: S.board.edges.length, runs: [] };
    S.exp = o.exp || {};
    async function run(name, step) {
      for (let i = 0; i < 6; i++) await raf(); // the setup's own DOM changes paint before the gesture starts
      const d = [];
      S.moving = true;
      if (S.view.s >= MAP && S.mounted.size) R.over.classList.add("moving");
      if (S.exp.underComposite) R.under.classList.add("moving");
      R.secl.style.display = S.exp.noSecs ? "none" : "";
      R.secl.classList.toggle("nolabels", !!S.exp.noLabels);
      R.secl.classList.toggle("nowash", !!S.exp.noWash);
      let prev = performance.now();
      let js = 0;
      for (let i = 0; i < frames; i++) {
        step(i);
        const j0 = performance.now();
        frame();
        js += performance.now() - j0;
        await raf();
        const now = performance.now();
        d.push(now - prev);
        prev = now;
      }
      R.under.classList.remove("moving");
      rest();
      const s0 = performance.now();
      let settle = 0;
      do { await raf(); settle++; } while (S.pumping && settle < 900);
      out.runs.push({ name, frames: d, settleMs: performance.now() - s0, mounted: S.mounted.size, level: S.level, jsMs: js / frames, dom: document.getElementsByTagName("*").length, over: R.over.childElementCount, under: R.secl.childElementCount });
    }
    const sec = firstSection();
    const read = sec ? sectionView(sec) : fitView(boardBox(), 32);
    Object.assign(S.view, read); rest(); for (let i = 0; i < 40 && S.pumping; i++) await raf();
    await run("pan at reading zoom", () => { S.view.tx -= 8; S.view.ty -= 2; });
    Object.assign(S.view, fitBoard(32)); rest(); for (let i = 0; i < 60 && S.pumping; i++) await raf();
    const cx = S.W / 2, cy = S.H / 2;
    const fitS = S.view.s;
    await run("zoom fit to 150%", () => { if (S.view.s < 1.5) zoomAt(Math.min(1.02, 1.5 / S.view.s), cx, cy); });
    await run("zoom back out", () => { if (S.view.s > fitS) zoomAt(Math.max(1 / 1.02, fitS / S.view.s), cx, cy); });
    Object.assign(S.view, fitBoard(32)); rest(); for (let i = 0; i < 60 && S.pumping; i++) await raf();
    await run("pan at overview", () => { S.view.tx -= 3; });
    Object.assign(S.view, read); rest(); for (let i = 0; i < 60 && S.pumping; i++) await raf();
    await run("pinch at reading zoom", (i) => zoomAt(i < 90 ? 1.004 : 1 / 1.004, cx, cy));
    return out;
  }

  // Structural checks (PRD-2 section 13): at rest, no text drawn under 9 px on screen; every node in view at the read
  // level has its text in the DOM; no connector label chip drawn under 9 px.
  function structural() {
    const res = { level: S.level, s: S.view.s, mounted: S.mounted.size, small: [], missingText: [], cards: 0 };
    const vis = (r) => r.right > 0 && r.left < innerWidth && r.bottom > 0 && r.top < innerHeight && r.width > 0 && r.height > 0;
    const walker = document.createTreeWalker(R.canvas, NodeFilter.SHOW_TEXT);
    const range = document.createRange();
    while (walker.nextNode()) {
      const tn = walker.currentNode;
      if (!tn.nodeValue.trim()) continue;
      const el = tn.parentElement;
      if (el.closest("[hidden], .b-zpanel, .b-chip, .b-toast, .b-hlabel, .b-notecard, .b-line")) continue;
      range.selectNodeContents(tn);
      const r = range.getBoundingClientRect();
      if (!vis(r)) continue;
      const fs = parseFloat(getComputedStyle(el).fontSize) * S.view.s;
      const inWorld = el.closest(".b-layer");
      const screen = inWorld ? fs : parseFloat(getComputedStyle(el).fontSize);
      if (screen < 8.95 && res.small.length < 20) res.small.push(`${tn.nodeValue.trim().slice(0, 30)} @ ${screen.toFixed(1)}px`);
    }
    res.hiddenChips = [];
    for (const [id, o] of S.edgesOn) {
      const r = o.chip.getBoundingClientRect();
      if (!vis(r)) continue;
      const hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
      if (hit && !o.chip.contains(hit) && hit.closest(".b-node")) res.hiddenChips.push(id);
    }
    // A visible label chip never sits over a card's box (it is hidden instead, and shown while its box is lit).
    res.chipsOverCards = [];
    const cards = [...S.mounted.values()].map((el) => el.getBoundingClientRect());
    for (const [id, o] of S.edgesOn) {
      if (getComputedStyle(o.chip).display === "none") continue;
      const r = o.chip.getBoundingClientRect();
      if (!vis(r)) continue;
      if (cards.some((c) => r.left < c.right - 1 && r.right > c.left + 1 && r.top < c.bottom - 1 && r.bottom > c.top + 1)) res.chipsOverCards.push(id);
    }
    // (1) Section names, where shown, at 15 px or more on screen (BRD-8).
    res.smallNames = [];
    for (const [id, e] of S.secs) {
      const b = e.label.querySelector("b");
      if (!b || e.label.closest("[hidden]")) continue;
      const px = parseFloat(getComputedStyle(b).fontSize) * S.view.s;
      if (px < 14.9) res.smallNames.push(`${id}@${px.toFixed(1)}`);
    }
    res.namesShown = [...S.secs.values()].filter((e) => e.label.querySelector("b")).length;
    // (2) A text node at the map level shows its words at 9 px or more, or nothing; never a blank box.
    res.blankText = [];
    for (const [id, el] of S.mounted) {
      if (!el.classList.contains("k-text") || el.dataset.lv !== "map") continue;
      const cs = getComputedStyle(el);
      const boxed = cs.backgroundColor !== "rgba(0, 0, 0, 0)" || parseFloat(cs.borderTopWidth) > 0;
      const t0 = el.textContent.trim();
      const px = t0 ? parseFloat(getComputedStyle(el.firstElementChild).fontSize) * S.view.s : 0;
      if (boxed || (t0 && px < 8.95)) res.blankText.push(id);
    }
    // Section names sit above the connector layer on a ground band.
    const lz = Number(getComputedStyle(R.under).zIndex) || 0, cz = Number(getComputedStyle(R.shapes).zIndex) || 0;
    res.labelsUnderConnectors = lz > cz ? 0 : S.secs.size;
    res.labelsWithoutBand = 0;
    for (const e of S.secs.values()) { const b = e.label.querySelector("b"); if (b && getComputedStyle(b).backgroundColor === "rgba(0, 0, 0, 0)") res.labelsWithoutBand++; }
    if (S.level === "read") {
      const r = viewRect(0);
      for (const id of S.board.grid.query(r.x, r.y, r.w, r.h)) {
        const n = S.board.byId.get(id);
        if (!n || n.kind === "section" || n.kind === "image") continue;
        res.cards++;
        const el = S.mounted.get(id);
        const want = titleOf(n).slice(0, 12);
        if (!el || (want && !el.textContent.includes(want))) res.missingText.push(id);
      }
    }
    return res;
  }

  // ---------- the bridge ----------
  function handles(msg) {
    if (!msg) return false;
    if (msg.type === "load" || msg.type === "update") {
      if (msg.kind === "board") return true;
      if (S.active) deactivate();
      return false;
    }
    if (msg.type === "command" && msg.name === "measureNodes") return true; // works with no board loaded
    return S.active && (msg.type === "command" || msg.type === "quiet" || msg.type === "focus");
  }
  async function receive(msg) {
    switch (msg.type) {
      case "load": await load(msg); return true;
      case "update": await update(msg); return true;
      case "quiet": return true;
      case "focus": scheduleSeen(); return true;
      case "command": return command(msg);
      default: return false;
    }
  }
  function command(msg) {
    if (msg.name === "measureNodes") {
      const b = window.LinenCanvas.parse(String(msg.text || ""), { sidecarText: msg.sidecar == null ? null : msg.sidecar });
      const nodes = b.nodes.filter((n) => n.kind !== "section" && n.placed);
      return measureCards(nodes.map((n) => ({ node: n, width: n.w })), { words: b.words }).then((out) => out.map((m, i) => `${nodes[i].id}:${m.h}`));
    }
    if (!S.board && msg.name !== "place") return false;
    switch (msg.name) {
      case "find": openFind(false); return true;
      case "findSelection": openFind(true); return true;
      case "findNext": return stepFind(1);
      case "findPrevious": return stepFind(-1);
      case "outline": setRail(!!msg.show, !!msg.overlay); return true;
      case "nextChange": return goChange(1);
      case "previousChange": return goChange(-1);
      case "copyReference": return copyReference(msg);
      case "place": return placeNow();
      case "restorePlace": S.flight++; if (msg.place && msg.place.kind === "board") { openingView(msg.place); setMode(S.mode); } return true;
      case "zoomIn": zoomBy(1.25); return true;
      case "zoomOut": zoomBy(0.8); return true;
      case "fit": fit(); return true;
      case "zoom100": zoom100(); return true;
      case "back": return back();
      case "toggleList":
        if (S.mode === "list" && S.board.fatal && !msg.allowLarge) return false; // past BRD-20's limits: Canvas only when asked for explicitly
        setMode(S.mode === "list" ? "canvas" : "list"); return true;
      case "legend": chooseWord(msg.word || null); return true;
      case "goNode": return goNode(String(msg.id || ""), msg.select !== false);
      case "heading": return heading(msg.text);
      case "displayList": return displayList(msg);
      case "bench": return bench(msg);
      case "structural": return structural();
      case "fitClear": {
        // After Fit, the board's box on screen is clear of the zoom panel, the change chip and a floating rail.
        Object.assign(S.view, fitBoard(32)); rest();
        const { s, tx, ty } = S.view, bb = boardBox(), cr = R.canvas.getBoundingClientRect();
        const box = { left: cr.left + bb.x * s + tx, top: cr.top + bb.y * s + ty, right: cr.left + (bb.x + bb.w) * s + tx, bottom: cr.top + (bb.y + bb.h) * s + ty };
        const hits = [];
        for (const [name, el] of [["zoom panel", R.zpanel], ["change chip", R.chip], ["rail", S.railOverlay ? R.rail : null]]) {
          if (!el || el.hidden || el.offsetParent === null) continue;
          const r = el.getBoundingClientRect();
          if (r.left < box.right && r.right > box.left && r.top < box.bottom && r.bottom > box.top) hits.push(name);
        }
        return { s, hits: s <= MIN_S + 1e-9 ? [] : hits, atFloor: s <= MIN_S + 1e-9 };
      }

      case "openNote": openNote(String(msg.id || ""), !!msg.edge); return !!S.note;
      case "findText": openFind(false); R.findq.value = String(msg.q || ""); runFind(R.findq.value); return S.find.hits.length;
      case "displayListSummary": return displayList(msg).then((d) => d && { items: d.items.length, texts: d.items.filter((i) => i.t === "text").length, sample: d.items.filter((i) => i.t === "text").slice(0, 6), notes: d.notes.length, size: d.size });
      case "view": return { ...S.view, level: S.level, mounted: S.mounted.size, mode: S.mode, W: S.W, H: S.H, changed: changeList().length, rewritten: S.rewritten, queue: S.queue.length };
      case "setView": S.flight++; Object.assign(S.view, { s: msg.s, tx: msg.tx, ty: msg.ty }); rest(); return true;
      case "zoomTo": { const s = clamp(Number(msg.s), MIN_S, MAX_S); const v = S.view; v.tx = S.W / 2 - (S.W / 2 - v.tx) * s / v.s; v.ty = S.H / 2 - (S.H / 2 - v.ty) * s / v.s; v.s = s; rest(); return true; }
      case "properties": return false;
      case "prepareForPrint": return { title: S.board.title || S.name, headings: [] };
      case "selectionText": return String(getSelection() || "");
      default: return false;
    }
  }
  function settings(s) {
    if (!S.active) return;
    if (s.theme) {
      readColors();
      S.contentCache.clear();
      if (S.board) { rest(); for (const [id, el] of S.mounted) { const n = S.board.byId.get(id); if (n) fillCard(el, n); } }
    }
    if (s.lang && S.board) { renderLegend(); renderOutline(); updateChip(); updatePanel(); }
  }

  window.LinenBoard = {
    get active() { return S.active; },
    handles, receive, settings, measureCards, measureCard,
    _state: S,
    _test: { phoneList },
  };
})();
