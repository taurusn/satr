// Linen's page (PRD 6.2 to 6.4, 6.11, 6.12). Built once per tab; documents arrive through window.linen.receive.
// It renders blocks in time slices, sanitised, keeps the reader's place across reloads, marks what changed since
// the reader last looked, finds text, and drives the outline and footer. Everything it asks of the app goes
// through post(); nothing here touches the network or a file.
(() => {
  "use strict";

  const D = window.LinenDialect;
  const marked = D.configure(new window.marked.Marked());
  const $ = (id) => document.getElementById(id);
  const docEl = $("doc");
  const html = document.documentElement;
  const post = (msg) => { try { window.webkit.messageHandlers.linen.postMessage(msg); } catch (_) { /* opened outside the app */ } };
  // Yields between render slices. A message channel is not throttled in hidden windows and background tabs,
  // where animation frames nearly stop.
  const yieldChannel = new MessageChannel();
  const yieldQueue = [];
  yieldChannel.port1.onmessage = () => { const r = yieldQueue.shift(); if (r) r(); };
  const nextFrame = () => new Promise((r) => { yieldQueue.push(r); yieldChannel.port2.postMessage(0); });
  const READ_LINE = 64; // px below the top of the window: the line being read
  // Bounded work (SAFE-5): a bigger document opens as plain text; past these the page stops adding blocks.
  const MAX_BYTES = 20 * 1024 * 1024, MAX_BLOCKS = 10000, MAX_NODES = 200000;
  const { diff, pairEdited } = window.LinenDiff;

  // The page's own words, in English and Arabic (ARB-4). Templates take {name} slots.
  const AR = {
    "Copy": "نسخ", "Copied": "نُسخ", "Done": "تم", "Not done": "لم يتم", "Filter": "تصفية", "Not found": "لا توجد نتائج",
    "{a} of {b}": "{a} من {b}", "{n} words": "{n} كلمة", "{n} word": "{n} كلمة", "{n} min": "{n} د", "modified {d}": "عُدّل {d}",
    "Properties": "الخصائص", "This note has no properties.": "لا خصائص لهذه الملاحظة.", "Back to text": "العودة إلى النص",
    "Image from {h}": "صورة من {h}", "Load images for this file": "حمّل صور هذا الملف", "{f} is outside this vault": "{f} خارج هذا المخزن",
    "Allow this file": "اسمح بهذا الملف", "Image: {f}": "صورة: {f}", "Missing image": "صورة مفقودة",
    "Rewritten since you read it on {d}.": "أعيدت كتابتها منذ قرأتها في {d}.", "Rewritten since you last read it.": "أعيدت كتابتها منذ آخر قراءة.",
    "This document is too long to show whole; Linen shows its first {n} blocks.": "المستند أطول من أن يُعرض كاملًا؛ يعرض سطر أول {n} جزء منه.",
    "This document is too large to typeset, so it is shown as plain text.": "هذا المستند أكبر من أن يُنضَّد، فيُعرض نصًا عاديًا.",
    "This block is too large to typeset, so it is shown as plain text.": "هذا الجزء أكبر من أن يُنضَّد، فيُعرض نصًا عاديًا.",
    "This math could not render: {e}": "تعذّر عرض هذه المعادلة: {e}", "This diagram could not render: {e}": "تعذّر رسم هذا المخطط: {e}",
    "Too large to draw here.": "أكبر من أن يُرسم هنا.", "{n} removed": "حُذف {n}", "the web": "الويب",
    "Ignore Arabic diacritics and letter forms": "تجاهل التشكيل وصور الحروف",
    "Updated, 1 change": "حُدّث المستند، تغيير واحد", "Updated, {n} changes": "حُدّث المستند، التغييرات: {n}",
  };
  let lang = "en";
  const t = (key, vars) => {
    let out = (lang === "ar" && AR[key]) || key;
    for (const [k, v] of Object.entries(vars || {})) out = out.replaceAll(`{${k}}`, v);
    return out;
  };
  // "ar" alone gives Western digits in this WebKit; the numbering system has to be asked for (ARB-4).
  const num = (n) => Number(n).toLocaleString(lang === "ar" ? "ar-u-nu-arab" : "en");

  const state = {
    docId: null, name: "", path: "", plain: false, version: 0,
    blocks: [], ctx: { links: {}, footnotes: {}, footnoteDefs: [] }, yaml: null, meta: {},
    baseline: null, baselineDate: null, keyWindow: true, renderToken: 0, docDir: "ltr",
    allowRemote: false, held: null, anchorEl: null, outline: [], settings: {},
    rendered: 0, nodes: 0, capped: false, rewritten: false, loading: null, hasArabic: false,
  };

  // ---------- worker (PERF-2), with an in-page fallback where workers cannot start ----------
  // A new document or reload while a parse runs ends that parse (SAFE-5): the worker is stopped and started again,
  // its callers get null, and replies from the old one are never read.
  let worker = null;
  const pending = new Map();
  let reqId = 0;
  function startWorker() {
    let w;
    try { w = new Worker("worker.js"); } catch (_) { worker = null; return; }
    w.onmessage = (e) => {
      const p = pending.get(e.data.id);
      if (!p || w !== worker) return;
      if (!e.data.ok) { pending.delete(e.data.id); p.reject(new Error(e.data.error)); return; }
      if (e.data.part === 0) p.result = e.data.result; else for (const b of e.data.result.blocks) p.result.blocks.push(b);
      if (e.data.done) { pending.delete(e.data.id); p.resolve(p.result); }
    };
    w.onerror = () => { if (w !== worker) return; worker = null; for (const p of pending.values()) p.reject(new Error("worker")); pending.clear(); };
    worker = w;
  }
  startWorker();
  function lexInPage(source, plain) { return window.LinenLex.lex(source, plain); }
  function lex(source, plain) {
    if (worker && pending.size) {
      worker.terminate();
      for (const p of pending.values()) p.resolve(null);
      pending.clear();
      startWorker();
    }
    if (!worker) return Promise.resolve(lexInPage(source, plain));
    return new Promise((resolve, reject) => {
      const id = ++reqId;
      pending.set(id, { resolve, reject });
      worker.postMessage({ id, source, plain });
    }).catch(() => lexInPage(source, plain));
  }
  // Whether text takes more than limit bytes as UTF-8, counted without encoding it.
  function overBytes(s, limit) {
    if (s.length > limit) return true;
    if (s.length * 3 <= limit) return false;
    let n = 0;
    for (let i = 0; i < s.length; i++) {
      const c = s.charCodeAt(i);
      if (c < 0x80) n++;
      else if (c < 0x800) n += 2;
      else if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) { n += 4; i++; }
      else n += 3;
      if (n > limit) return true;
    }
    return false;
  }

  // ---------- sanitising (SAFE-3, REN-9) ----------
  const PURIFY = {
    USE_PROFILES: { html: true, svg: true, svgFilters: true },
    FORBID_TAGS: ["style", "form", "textarea", "select", "button", "iframe", "object", "embed", "link", "meta", "base", "frame", "frameset", "noscript", "template", "video", "audio", "source", "track"],
    FORBID_ATTR: ["style", "srcset", "formaction", "action", "ping", "background", "poster"],
    ADD_ATTR: ["open", "checked", "disabled", "align"],
    ALLOWED_URI_REGEXP: /^(?:(?:https?|mailto|tel|obsidian|vscode|zed|bbedit|x-devonthink-item):|[^a-z]|[a-z+.-]+(?:[^a-z+.\-:]|$))/i,
  };
  DOMPurify.addHook("uponSanitizeElement", (node, data) => {
    if (data.tagName === "input" && node.getAttribute && node.getAttribute("type") !== "checkbox") node.remove();
  });
  // Image sources leave the markup while it is still inert (DOMPurify's own document), so no <img> in the page
  // fetches anything before prepareImage decides how it loads (SAFE-1, SAFE-2). Kept by number, since DOMPurify
  // drops attribute values holding "-->".
  const imgSources = new Map();
  let imgSourceSeq = 0;
  DOMPurify.addHook("afterSanitizeAttributes", (node) => {
    if (node.removeAttribute) node.removeAttribute("data-img"); // only this hook names stashed sources
    if (node.hasAttribute && node.hasAttribute("src")) {
      const v = node.getAttribute("src") || "";
      if (/^data:/i.test(v) && v.length > 2e6) node.removeAttribute("src");
      if (/^(?:linen-|file:)/i.test(v)) node.removeAttribute("src"); // only the page itself may point at the app's schemes
      if (node.nodeName === "IMG" && node.hasAttribute("src") && !/^data:/i.test(v)) {
        const k = String(++imgSourceSeq);
        imgSources.set(k, v);
        node.setAttribute("data-img", k);
        node.removeAttribute("src");
      }
    }
    if (node.hasAttribute && node.hasAttribute("href") && /^(?:file|data|javascript|vbscript|linen-)/i.test(node.getAttribute("href") || "")) node.removeAttribute("href");
  });

  // ---------- small helpers ----------
  const slugify = (text) => (text || "").normalize("NFKC").toLowerCase().trim()
    .replace(/[^\p{L}\p{N}\s-]/gu, "").replace(/\s+/g, "-").replace(/-+/g, "-") || "section";
  const RTL_RE = /[֐-ࣿיִ-﷿ﹰ-﻿]/g;
  const LTR_RE = /[A-Za-zÀ-ɏͰ-ϿЀ-ӿ]/g;
  const count = (s, re) => (s.match(re) || []).length;
  function textWithout(el, skip) {
    let out = "";
    const w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT, {
      acceptNode(n) { for (let p = n.parentElement; p && p !== el; p = p.parentElement) if (skip.has(p.tagName)) return NodeFilter.FILTER_REJECT; return NodeFilter.FILTER_ACCEPT; },
    });
    while (w.nextNode()) out += w.currentNode.nodeValue;
    return out;
  }
  const SKIP_DIR = new Set(["CODE", "PRE", "A", "KBD", "SUP"]);
  const SKIP_ITEM = new Set([...SKIP_DIR, "UL", "OL"]); // a list item's own text, without the lists inside it
  function directionOf(el, fallback) {
    const t = textWithout(el, SKIP_DIR);
    const r = count(t, RTL_RE), l = count(t, LTR_RE);
    if (r + l === 0) return null;
    const ratio = r / (r + l);
    return ratio > 0.6 ? "rtl" : ratio < 0.4 ? "ltr" : fallback;
  }
  function fold(s) {
    // Find folds case, tashkeel, tatweel, hamza forms, alef maqsura and taa marbuta (READ-3).
    return s.toLowerCase()
      .replace(/[ً-ٰٟۖ-ۭـ]/g, "")
      .replace(/[أإآٱ]/g, "ا").replace(/ى/g, "ي").replace(/ة/g, "ه").replace(/ؤ/g, "و").replace(/ئ/g, "ي");
  }
  const FOLD_DROPS = /[ً-ٰٟۖ-ۭـ]/;

  // ---------- frontmatter (REN-6) ----------
  function parseYAML(text) {
    const out = [];
    if (!text) return out;
    const lines = text.split(/\r?\n/);
    for (let i = 0; i < lines.length; i++) {
      const m = /^([A-Za-z0-9_\-؀-ۿ ]+):\s*(.*)$/.exec(lines[i]);
      if (!m) continue;
      let value = m[2].trim();
      if (value === "" || value === "|" || value === ">") {
        const items = [];
        while (i + 1 < lines.length && /^\s+(-\s+)?\S/.test(lines[i + 1])) { items.push(lines[++i].trim().replace(/^-\s+/, "")); }
        value = items;
      } else if (/^\[.*\]$/.test(value)) {
        value = value.slice(1, -1).split(",").map((v) => v.trim()).filter(Boolean);
      }
      const clean = (v) => String(v).replace(/^["']|["']$/g, "").replace(/^\[\[(.*)\]\]$/, "$1");
      out.push([m[1].trim(), Array.isArray(value) ? value.map(clean) : clean(value)]);
    }
    return out;
  }
  const yamlGet = (key) => { const e = (state.yaml || []).find(([k]) => k === key); return e ? e[1] : null; };

  // ---------- rendering blocks ----------
  const WIDE_TYPES = new Set(["code", "table"]);
  let mermaidCount = 0, mermaidSeq = 0, mermaidGen = 0;
  // A Map used as an LRU: a hit moves the key to the end, inserts evict from the front.
  const lruGet = (m, k) => { if (!m.has(k)) return undefined; const v = m.get(k); m.delete(k); m.set(k, v); return v; };
  const lruSet = (m, k, v, cap) => { m.delete(k); m.set(k, v); while (m.size > cap) m.delete(m.keys().next().value); }; // the budget (50 per document) and a never-reused id counter
  const lazy = new IntersectionObserver((entries) => {
    for (const e of entries) if (e.isIntersecting) { lazy.unobserve(e.target); fill(e.target); }
  }, { rootMargin: "1400px 0px" });

  function renderBlock(b) {
    const el = document.createElement("div");
    el.className = "blk";
    el.dataset.h = b.hash;
    el.dataset.l = b.lines.join("-");
    if (b.kind === "plain") {
      const note = b.big ? `<p class="big-note">${D.escapeHTML(t("This block is too large to typeset, so it is shown as plain text."))}</p>` : "";
      el.innerHTML = `${note}<pre class="plain">${D.escapeHTML(b.text)}</pre>`;
      b.nodes = b.big ? 3 : 2;
      const d = b.text.length <= 20000 ? directionOf(el.lastElementChild, null) : null;
      if (d) el.setAttribute("dir", d); // marks sit on the block's leading side (LIVE-5)
      return el;
    }
    const list = [b.token];
    list.links = state.ctx.links || {};
    let out;
    // The lifted footnotes are a block of their own (lexer.js; Lane F, BLK-1).
    if (b.token.type === "footnoteList") el.classList.add("footnotes-blk");
    try { out = b.token.type === "footnoteList" ? footnotesHTML() : marked.parser(list); } catch (_) { out = `<p>${D.escapeHTML(b.token.raw || "")}</p>`; }
    el.innerHTML = DOMPurify.sanitize(out, PURIFY);
    if (WIDE_TYPES.has(b.token.type) || el.querySelector(":scope > .mermaid-src, :scope > .math.display")) el.classList.add("wide");
    if (window.LinenBlocks) window.LinenBlocks.expand(el, b); // Linen 2 blocks, words, note terms (Lane F)
    decorate(el, b);
    // The block takes its leading element's direction, so its change mark sits on that side (LIVE-5): code, math
    // and diagrams read left to right; a table by its own direction; a Loom block by its text (Lane F).
    const ltrTypes = (b.token.type === "code" && !el.dataset.lblk) || el.querySelector(":scope > .math.display, :scope > .mermaid-src");
    const first = el.firstElementChild, table = first && first.querySelector("table[dir]");
    const lead = ltrTypes ? "ltr" : el.dataset.lblk ? directionOf(el, state.docDir) || state.docDir : (first && first.getAttribute("dir")) || (table && table.getAttribute("dir"));
    if (lead) el.setAttribute("dir", lead);
    b.nodes = el.getElementsByTagName("*").length + 1; // elements, for the DOM budget (SAFE-5)
    return el;
  }

  function decorate(el, b) {
    let hi = 0;
    el.querySelectorAll("h1, h2, h3, h4, h5, h6").forEach((h) => { h.id = (b.ids && b.ids[hi++]) || slugify(h.textContent); });
    // Direction (ARB-1): lists take one direction; then each block element.
    el.querySelectorAll("ul, ol").forEach((list) => {
      const d = directionOf(list, state.docDir);
      if (d) list.setAttribute("dir", d);
      // An item in the other script takes its own direction, so its punctuation lands at its own end (Lane F).
      const ld = d || state.docDir;
      for (const li of list.children) {
        if (li.tagName !== "LI") continue;
        const own = textWithout(li, SKIP_ITEM), r = count(own, RTL_RE), l = count(own, LTR_RE);
        const id = r + l === 0 ? null : r / (r + l) > 0.6 ? "rtl" : r / (r + l) < 0.4 ? "ltr" : null;
        if (id && id !== ld) li.setAttribute("dir", id);
      }
    });
    el.querySelectorAll("p, h1, h2, h3, h4, h5, h6, blockquote, .callout, td, th, dt, dd, figcaption, summary").forEach((n) => {
      if (n.closest("li") && n.tagName === "P") return;
      const d = directionOf(n, state.docDir);
      if (d) n.setAttribute("dir", d);
    });
    el.querySelectorAll("table").forEach((t) => {
      const d = directionOf(t, state.docDir);
      if (d) t.setAttribute("dir", d);
      const wrap = document.createElement("div");
      wrap.className = "table-wrap";
      t.replaceWith(wrap);
      wrap.appendChild(t);
      requestAnimationFrame(() => { if (wrap.scrollWidth > wrap.clientWidth + 2) wrap.classList.add("scrollx"); });
      wrap.addEventListener("scroll", () => wrap.classList.toggle("at-end", wrap.scrollLeft + wrap.clientWidth >= wrap.scrollWidth - 2), { passive: true });
    });
    el.querySelectorAll('input[type="checkbox"]').forEach((c) => { c.disabled = true; c.setAttribute("aria-label", c.checked ? t("Done") : t("Not done")); });
    el.querySelectorAll("pre.code").forEach((pre) => {
      const copy = document.createElement("button");
      copy.className = "copy";
      copy.textContent = t("Copy");
      copy.addEventListener("click", (ev) => { ev.preventDefault(); post({ type: "copyText", text: pre.querySelector("code").textContent }); copy.textContent = t("Copied"); setTimeout(() => (copy.textContent = t("Copy")), 1200); });
      pre.appendChild(copy);
    });
    el.querySelectorAll(".math, .mermaid-src").forEach((n) => {
      n.dataset.src = D.sources.get(n.dataset.k) || "";
      D.sources.delete(n.dataset.k);
      if (n.classList.contains("mermaid-src")) {
        const cached = mermaidHeights.get(n.dataset.src);
        n.style.setProperty("--h", `${cached || Math.min(900, 60 + 26 * n.dataset.src.split("\n").length)}px`);
      }
    });
    el.querySelectorAll("a.wl").forEach((a) => wikiTargets.add(a.dataset.target));
    if (!b.deferMedia) activateMedia(el);
  }
  // Image requests and lazy fills, for a block that is on the page (a reload typesets ahead, and may drop the work).
  function activateMedia(el) {
    el.querySelectorAll("img").forEach(prepareImage);
    el.querySelectorAll("pre.code, .math, .mermaid-src").forEach((n) => lazy.observe(n));
  }

  // ---------- lazy fills: code, math, diagrams (PERF-3) ----------
  const mermaidSVG = new Map();
  const mermaidHeights = new Map();
  let mermaidLoad = null;
  function loadMermaid() {
    if (!mermaidLoad) {
      mermaidLoad = new Promise((resolve, reject) => {
        const s = document.createElement("script");
        s.src = "vendor/mermaid.min.js";
        s.onload = () => resolve();
        s.onerror = reject;
        document.head.appendChild(s);
      });
    }
    return mermaidLoad.then(() => {
      const night = html.dataset.theme === "night";
      const css = getComputedStyle(html);
      window.mermaid.initialize({
        startOnLoad: false, securityLevel: "strict", theme: "base", fontFamily: "Linen Sans, -apple-system, sans-serif",
        themeVariables: {
          background: css.getPropertyValue("--ground").trim(), primaryColor: night ? "#284734" : "#E3E7DF",
          primaryTextColor: night ? "#F6F3EB" : "#1F3328", primaryBorderColor: night ? "#8FA394" : "#284734",
          lineColor: night ? "#8FA394" : "#284734", secondaryColor: night ? "#1F3328" : "#FBF9F4", tertiaryColor: night ? "#1F3328" : "#F6F3EB",
          fontSize: "14px",
        },
      });
    });
  }
  async function fill(n) {
    if (n.matches("pre.code")) {
      const code = n.querySelector("code");
      const lang = n.dataset.lang;
      if (lang && window.hljs && window.hljs.getLanguage(lang) && code.textContent.split("\n").length <= 2000) {
        code.className = `language-${lang}`;
        try { window.hljs.highlightElement(code); } catch (_) { /* stays plain */ }
      }
    } else if (n.classList.contains("math")) {
      const display = n.classList.contains("display");
      try {
        window.katex.render(n.dataset.src, n, { displayMode: display, throwOnError: true, trust: false, maxExpand: 1000, maxSize: 10, strict: "ignore" });
      } catch (err) {
        n.className = display ? "render-failed" : "render-failed inline";
        n.innerHTML = `<b>${D.escapeHTML(t("This math could not render: {e}", { e: String(err.message || err) }))}</b>${D.escapeHTML(n.dataset.src)}`;
      }
    } else if (n.classList.contains("mermaid-src")) {
      if (mermaidCount >= 50 || n.dataset.src.length > 20000) { failDiagram(n, t("Too large to draw here.")); return; }
      const key = `${html.dataset.theme}\u0000${n.dataset.src}`;
      const gen = mermaidGen;
      try {
        let svg = lruGet(mermaidSVG, key);
        if (!svg) {
          await loadMermaid();
          if (gen !== mermaidGen || !n.isConnected) return; // the document changed while Mermaid loaded
          mermaidCount++;
          ({ svg } = await window.mermaid.render(`linen-mermaid-${++mermaidSeq}`, n.dataset.src));
          if (gen !== mermaidGen || !n.isConnected) return; // finished after the document changed: dropped
          lruSet(mermaidSVG, key, svg, 200); // bounded, least recently used first
          if (mermaidHeights.size > 400) mermaidHeights.delete(mermaidHeights.keys().next().value);
        }
        n.innerHTML = svg;
        requestAnimationFrame(() => { mermaidHeights.set(n.dataset.src, n.offsetHeight); n.style.removeProperty("--h"); });
      } catch (err) {
        failDiagram(n, err && err.message ? err.message : String(err));
      }
    }
  }
  function failDiagram(n, why) {
    n.className = "render-failed";
    n.innerHTML = `<b>${D.escapeHTML(t("This diagram could not render: {e}", { e: why.split("\n")[0] }))}</b>${D.escapeHTML(n.dataset.src)}`;
  }

  // ---------- images (REN-7, SAFE-1, SAFE-2) ----------
  const imageWaits = [];
  function prepareImage(img) {
    const wiki = img.dataset.wikiSrc;
    const stashed = img.dataset.img;
    const src = stashed !== undefined ? imgSources.get(stashed) || "" : img.getAttribute("src") || "";
    if (stashed !== undefined) { imgSources.delete(stashed); img.removeAttribute("data-img"); }
    if (wiki) { img.dataset.req = `wiki:${wiki}`; img.removeAttribute("src"); imageWaits.push(img); return; }
    if (/^https?:/i.test(src)) {
      if (state.allowRemote) img.setAttribute("src", `linen-remote://fetch?u=${encodeURIComponent(src)}&d=${state.docId}`);
      else blockImage(img, t("Image from {h}", { h: hostOf(src) }), t("Load images for this file"), { type: "allowRemote" });
      return;
    }
    if (/^data:/i.test(src) || !src) return;
    img.dataset.req = `path:${safeDecode(src)}`;
    img.removeAttribute("src");
    imageWaits.push(img);
  }
  const hostOf = (u) => { try { return new URL(u).host; } catch (_) { return t("the web"); } };
  const safeDecode = (u) => { try { return decodeURI(u); } catch (_) { return u; } }; // `bad%zz.png` stays as written
  function blockImage(img, text, action, msg) {
    const box = document.createElement("div");
    box.className = "blocked";
    box.innerHTML = `<span></span><button></button>`;
    box.firstChild.textContent = text;
    box.lastChild.textContent = action;
    box.lastChild.addEventListener("click", () => post(msg));
    (img.closest("p") && img.closest("p").childNodes.length === 1 ? img.closest("p") : img).replaceWith(box);
  }
  function requestImages() {
    if (!imageWaits.length) return;
    const reqs = [...new Set(imageWaits.map((i) => i.dataset.req))];
    post({ type: "imageInfo", requests: reqs });
  }
  function applyImageInfo(map) {
    const unanswered = [];
    for (const img of imageWaits.splice(0)) {
      const info = map[img.dataset.req];
      if (!info) { if (img.isConnected) unanswered.push(img); continue; } // asked later; its answer is still coming
      if (info.status === "missing") { img.alt = img.alt || t("Missing image"); img.classList.add("missing"); continue; }
      // SAFE-2: the grant is for exactly this file, named by its request; the app reloads with it allowed.
      if (info.status === "outside") { blockImage(img, t("{f} is outside this vault", { f: info.label }), t("Allow this file"), { type: "allowOutside", request: img.dataset.req }); continue; }
      if (info.status === "unavailable") {
        const box = document.createElement("div");
        box.className = "blocked";
        box.textContent = t("Image: {f}", { f: info.label });
        (img.closest("p") && img.closest("p").childNodes.length === 1 ? img.closest("p") : img).replaceWith(box);
        continue;
      }
      if (info.width && info.height) { img.width = info.width; img.height = info.height; }
      img.src = info.url;
    }
    imageWaits.push(...unanswered);
  }

  // ---------- wiki link states (VAULT-2) ----------
  const wikiTargets = new Set();
  function requestLinkStatus() {
    if (!wikiTargets.size) return;
    post({ type: "resolveLinks", targets: [...wikiTargets] });
  }
  function applyLinkStatus(map) {
    docEl.querySelectorAll("a.wl").forEach((a) => {
      const st = map[a.dataset.target];
      if (!st) return;
      a.classList.toggle("missing", st.state === "missing");
      a.classList.toggle("ambiguous", st.state === "ambiguous");
      a.title = st.hint || a.dataset.target;
    });
  }

  // ---------- note header and preamble (REN-6) ----------
  function headerFor(blocks) {
    const eyebrow = [yamlGet("type"), yamlGet("status"), yamlGet("updated") || yamlGet("date")].filter((v) => v && typeof v === "string");
    $("eyebrow").innerHTML = eyebrow.map((v) => `<span>${D.escapeHTML(v)}</span>`).join("");
    const titleIndex = blocks.findIndex((b) => b.kind === "md" && b.token.type === "heading" && b.token.depth === 1);
    const title = titleIndex >= 0 ? blocks[titleIndex].token.text : state.name.replace(/\.(md|markdown|mdown|mkd|txt)$/i, "");
    $("note-title").innerHTML = DOMPurify.sanitize(titleIndex >= 0 ? marked.parseInline(title) : D.escapeHTML(title), PURIFY);
    $("note-title").querySelectorAll("img").forEach(prepareImage);
    const d = directionOf($("note-title"), state.docDir) || state.docDir;
    $("note-title").setAttribute("dir", d);
    $("note-header").setAttribute("dir", d); // the eyebrow lines up with its title
    $("note-header").hidden = state.plain;
    if (window.LinenBlocks) window.LinenBlocks.header($("eyebrow"), $("note-title"), $("note-header")); // linen: eyebrow, lead (Lane F)
    let preamble = [];
    if (titleIndex > 0 && blocks[0].kind === "md" && blocks[0].token.type === "heading") preamble = blocks.slice(0, titleIndex).map((b) => b.hash);
    else if (titleIndex < 0 && blocks[0] && blocks[0].kind === "md" && blocks[0].token.type === "heading" && /^for future claude/i.test(blocks[0].token.text)) {
      const depth = blocks[0].token.depth;
      let end = 1;
      while (end < blocks.length && !(blocks[end].kind === "md" && blocks[end].token.type === "heading" && blocks[end].token.depth <= depth)) end++;
      preamble = blocks.slice(0, end).map((b) => b.hash);
    }
    return { titleHash: titleIndex >= 0 ? blocks[titleIndex].hash : null, preamble: new Set(preamble) };
  }
  function applyHeaderToBlocks(info) {
    docEl.querySelectorAll(".preamble-toggle").forEach((n) => n.remove());
    let first = null;
    for (const b of state.blocks) {
      if (!b.el) continue;
      b.el.hidden = b.hash === info.titleHash;
      const inPre = info.preamble.has(b.hash);
      b.el.classList.toggle("pre", inPre);
      if (inPre && !first) first = b;
    }
    if (first) {
      const firstLine = (first.el.textContent || "").trim().split("\n")[0];
      const rest = state.blocks.filter((b) => b.el && info.preamble.has(b.hash) && b !== first).map((b) => b.el.textContent.trim()).join(" ");
      const t = document.createElement("details");
      t.className = "preamble preamble-toggle";
      t.open = docEl.classList.contains("pre-open");
      t.innerHTML = `<summary></summary>`;
      t.firstChild.textContent = `${firstLine}: ${rest}`.slice(0, 220);
      t.setAttribute("dir", directionOf(t.firstChild, state.docDir) || state.docDir);
      t.addEventListener("toggle", () => { docEl.classList.toggle("pre-open", t.open); keepPlace(() => {}); });
      docEl.insertBefore(t, first.el);
    }
  }
  const preStyle = document.createElement("style");
  preStyle.textContent = "#doc:not(.pre-open) > .blk.pre { display: none; }";
  document.head.appendChild(preStyle);

  // ---------- outline (READ-4) ----------
  function buildOutline() {
    const list = $("outline-list");
    list.replaceChildren();
    $("outline-title").textContent = $("note-title").textContent;
    state.outline = [...docEl.querySelectorAll(":scope > .blk:not([hidden]) h1, :scope > .blk:not([hidden]) h2, :scope > .blk:not([hidden]) h3")]
      .filter((h) => !h.closest(".blk.pre") || docEl.classList.contains("pre-open"));
    for (const h of state.outline) {
      const li = document.createElement("li");
      li.className = h.tagName.toLowerCase();
      const a = document.createElement("a");
      a.textContent = h.textContent;
      const d = directionOf(h, state.docDir);
      if (d) a.dir = d;
      a.addEventListener("click", (e) => { e.preventDefault(); jumpTo(h); });
      li.appendChild(a);
      list.appendChild(li);
    }
    markOutlineChanges();
    updateOutline();
    filterOutline();
  }
  function updateOutline() {
    const items = $("outline-list").children;
    let cur = -1;
    for (let i = 0; i < state.outline.length; i++) if (state.outline[i].getBoundingClientRect().top <= READ_LINE + 60) cur = i;
    for (let i = 0; i < items.length; i++) items[i].classList.toggle("cur", i === cur);
    if (cur >= 0 && !$("outline").hidden) {
      const li = items[cur], box = $("outline");
      if (li.offsetTop < box.scrollTop + 60 || li.offsetTop > box.scrollTop + box.clientHeight - 60) box.scrollTop = li.offsetTop - box.clientHeight / 3;
    }
    const max = Math.max(1, document.documentElement.scrollHeight - innerHeight);
    $("progress").firstChild.style.height = `${Math.min(100, (scrollY / max) * 100)}%`;
  }
  function filterOutline() {
    const q = fold($("outline-filter").value.trim());
    [...$("outline-list").children].forEach((li) => { li.hidden = q && !fold(li.textContent).includes(q); });
  }
  $("outline-filter").addEventListener("input", filterOutline);
  function markOutlineChanges() {
    const items = $("outline-list").children;
    for (let i = 0; i < state.outline.length; i++) {
      const start = state.outline[i].closest(".blk");
      const end = state.outline[i + 1] ? state.outline[i + 1].closest(".blk") : null;
      let changed = false;
      for (let n = start; n && n !== end; n = n.nextElementSibling) if (n.classList.contains("chg") || n.classList.contains("gap")) { changed = true; break; }
      if (items[i]) items[i].classList.toggle("chg", changed);
    }
  }
  function setOutline(show, overlay) {
    $("outline").hidden = !show;
    $("progress").hidden = !show;
    keepPlace(() => {
      html.classList.toggle("outline-on", show);
      html.classList.toggle("outline-overlay", !!overlay);
    });
  }
  function jumpTo(el) {
    post({ type: "pushStep", place: capturePlace() });
    el.scrollIntoView({ block: "start" });
    scrollBy(0, -READ_LINE + 24);
    updateOutline();
  }

  // ---------- place keeping (OPEN-3, LIVE-4, READ-4) ----------
  function blockAt(y) {
    const bs = state.blocks.filter((b) => b.el && b.el.isConnected && b.el.offsetParent !== null);
    let lo = 0, hi = bs.length - 1, found = bs[0] || null;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      const r = bs[mid].el.getBoundingClientRect();
      if (r.bottom <= y) lo = mid + 1;
      else { found = bs[mid]; if (r.top <= y) break; hi = mid - 1; }
    }
    return found;
  }
  function quoteAt(block, y) {
    const r = block.el.getBoundingClientRect();
    const range = document.caretRangeFromPoint ? document.caretRangeFromPoint(Math.max(r.left + 4, Math.min(innerWidth / 2, r.right - 4)), Math.max(y, r.top + 2)) : null;
    if (!range || !block.el.contains(range.startContainer)) return { quote: (block.el.textContent || "").slice(0, 40), qoff: 0, qdy: 0 };
    const pre = document.createRange();
    pre.setStart(block.el, 0);
    pre.setEnd(range.startContainer, range.startOffset);
    const off = pre.toString().length;
    const text = block.el.textContent || "";
    // qdy: how far the reading line sits below the top of the quote's first character.
    const at = rangeAtTextOffset(block.el, off);
    const rect = at ? at.getBoundingClientRect() : null;
    return { quote: text.slice(off, off + 40), qoff: off, qdy: rect && rect.height ? Math.max(0, y - rect.top) : 0 };
  }
  function capturePlace() {
    const b = blockAt(READ_LINE);
    if (!b) return null;
    const r = b.el.getBoundingClientRect();
    const q = quoteAt(b, READ_LINE);
    const max = document.documentElement.scrollHeight - innerHeight;
    return { hash: b.hash, index: state.blocks.indexOf(b), offset: READ_LINE - r.top, bh: r.height, top: r.top, quote: q.quote, qoff: q.qoff, qdy: q.qdy, atEnd: scrollY >= max - 4 };
  }
  // Runs a change to the page and puts the line being read back where it was.
  function keepPlace(change) {
    const anchor = blockAt(READ_LINE);
    const before = anchor ? anchor.el.getBoundingClientRect().top : 0;
    change();
    if (anchor && anchor.el.isConnected) scrollBy(0, anchor.el.getBoundingClientRect().top - before);
  }
  // A one-character range at a text offset in el (a boundary belongs to the next text node), or the last character.
  function rangeAtTextOffset(el, off) {
    const w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    let seen = 0, last = null;
    while (w.nextNode()) {
      const n = w.currentNode, len = n.nodeValue.length;
      if (seen + len > off) { const r = document.createRange(); r.setStart(n, off - seen); r.setEnd(n, off - seen + 1); return r; }
      seen += len;
      if (len) last = n;
    }
    if (!last) return null;
    const r = document.createRange();
    r.setStart(last, last.nodeValue.length - 1);
    r.setEnd(last, last.nodeValue.length);
    return r;
  }
  // The block a place returns to (OPEN-3, LIVE-4): the occurrence of its hash nearest the stored index, else the
  // block now at that index.
  function placeIndexOf(place) {
    if (!place || !state.blocks.length) return -1;
    const want = Math.max(0, Number(place.index) || 0);
    let best = -1;
    for (let i = 0; i < state.blocks.length; i++) {
      if (state.blocks[i].hash !== place.hash) continue;
      if (best < 0 || Math.abs(i - want) < Math.abs(best - want)) best = i; else break;
    }
    return best >= 0 ? best : Math.min(want, state.blocks.length - 1);
  }
  const share = (place, h) => Math.min(1, Math.max(0, (place.offset || 0) / (place.bh || h || 1)));
  function nearestIndex(text, q, want) {
    let best = -1;
    for (let at = text.indexOf(q); at >= 0; at = text.indexOf(q, at + 1)) {
      if (best < 0 || Math.abs(at - want) < Math.abs(best - want)) best = at; else break;
    }
    return best;
  }
  // Puts the reading line back on the place's quote inside el; false when the quote is gone. A repeated quote is
  // told apart by the saved character offset (a place stored without one estimates it from its share of the block).
  function scrollToQuote(el, place) {
    if (!place.quote) return false;
    const text = el.textContent || "";
    const want = place.qoff != null ? place.qoff : Math.round(text.length * share(place, el.getBoundingClientRect().height));
    for (const q of [place.quote, place.quote.slice(0, 16)]) {
      const at = nearestIndex(text, q, want);
      const range = at >= 0 ? rangeAtTextOffset(el, at) : null;
      const rect = range ? range.getBoundingClientRect() : null;
      if (rect && rect.height) { scrollBy(0, rect.top - (READ_LINE - (place.qdy || 0))); return true; }
    }
    return false;
  }
  // Keeps the reading line at the same share of the block's height, for a block whose quote is gone.
  function scrollToShare(el, place) {
    const r = el.getBoundingClientRect();
    scrollBy(0, r.top + share(place, r.height) * r.height - READ_LINE);
  }
  function restorePlace(place) {
    if (!place) { scrollTo(0, 0); return; }
    const k = placeIndexOf(place);
    if (k < 0) return;
    ensureRendered(k);
    const b = state.blocks[Math.min(k, state.rendered - 1)];
    if (!b || !b.el) return;
    scrollTo(0, 0);
    if (b.hash === place.hash) {
      scrollBy(0, b.el.getBoundingClientRect().top - (READ_LINE - (place.offset || 0)));
      scrollToQuote(b.el, place);
    } else if (!scrollToQuote(b.el, place)) scrollToShare(b.el, place);
  }
  // Late heights above the reader (images, diagrams, fonts) are compensated in the same frame.
  const heights = new WeakMap();
  const resize = new ResizeObserver((entries) => {
    const anchor = state.anchorEl;
    let delta = 0;
    for (const e of entries) {
      const el = e.target;
      const h = e.borderBoxSize && e.borderBoxSize[0] ? e.borderBoxSize[0].blockSize : el.offsetHeight;
      // A removed element reports zero, and its order against the page is arbitrary: never count it.
      if (!el.isConnected) { heights.delete(el); resize.unobserve(el); continue; }
      const old = heights.get(el);
      heights.set(el, h);
      if (old === undefined || !anchor || el === anchor || !anchor.isConnected) continue;
      if (el.compareDocumentPosition(anchor) & Node.DOCUMENT_POSITION_FOLLOWING) delta += h - old;
    }
    if (delta) scrollBy(0, delta);
  });
  let scrollTick = 0, placeTimer = 0;
  addEventListener("scroll", () => {
    if (scrollTick) return;
    scrollTick = requestAnimationFrame(() => {
      scrollTick = 0;
      const b = blockAt(READ_LINE);
      state.anchorEl = b ? b.el : null;
      updateOutline();
      if (marksLeft()) tickSeen();
      clearTimeout(placeTimer);
      placeTimer = setTimeout(() => { const p = capturePlace(); if (p) post({ type: "place", place: p }); }, 500);
    });
  }, { passive: true });

  // ---------- trackpad swipe (READ-5) ----------
  // A two-finger sideways swipe goes back (fingers moving right) or forward, once per gesture; never when it starts
  // over something that scrolls sideways (code, wide tables, math, diagrams), at its edge or not.
  let swipe = null;
  function scrollsSideways(n) {
    for (; n && n.nodeType === 1 && n !== document.body; n = n.parentElement) {
      if (n.scrollWidth > n.clientWidth + 1 && /auto|scroll/.test(getComputedStyle(n).overflowX)) return true;
    }
    return false;
  }
  addEventListener("wheel", (e) => {
    if (e.ctrlKey) return; // a pinch
    if (html.classList.contains("board-mode")) return; // a board pans with two fingers (Lane B)
    const now = performance.now();
    if (!swipe || now - swipe.last > 200) swipe = { dx: 0, dy: 0, done: false, blocked: scrollsSideways(e.target) };
    swipe.last = now;
    if (swipe.done || swipe.blocked) return;
    swipe.dx += e.deltaX;
    swipe.dy += e.deltaY;
    if (Math.abs(swipe.dx) > 120 && Math.abs(swipe.dx) > 2.5 * Math.abs(swipe.dy)) {
      swipe.done = true;
      post({ type: "swipe", direction: swipe.dx < 0 ? "back" : "forward" });
    }
  }, { passive: true });

  // ---------- change marks (LIVE-5) ----------
  // state.baseline is the ordered sequence of acknowledged hashes, repeats and removed blocks included. It is
  // matched against the page with the reload diff, so duplicates stay apart and a removed block's gap keeps its
  // place. A mark is acknowledged after 3 s meaningfully on screen in the key window (half of it showing, or half
  // the window for a block taller than that), counted across looks; the "rewritten" line follows the same rule.
  const ACK_MS = 3000;
  const chgLive = docEl.getElementsByClassName("chg"), gapLive = docEl.getElementsByClassName("gap");
  const seenMs = new WeakMap();
  let seenEls = [], seenAt = 0, seenTimer = 0;
  const marksLeft = () => chgLive.length + gapLive.length + (state.rewritten ? 1 : 0);
  function meaningful(el) {
    if (el.offsetParent === null) return false;
    const r = el.getBoundingClientRect();
    if (!r.height) return r.top >= 0 && r.top <= innerHeight;
    return Math.min(r.bottom, innerHeight) - Math.max(r.top, 0) >= Math.min(r.height, innerHeight) / 2;
  }
  function marksOnScreen() {
    const out = [];
    const line = state.rewritten ? $("banner").querySelector('[data-k="rewritten"]') : null;
    if (line && meaningful(line)) out.push(line);
    const first = chgLive.length || gapLive.length ? blockAt(0) : null;
    if (!first) return out;
    let n = first.el;
    while (n.previousElementSibling && n.previousElementSibling.classList.contains("gap")) n = n.previousElementSibling;
    for (; n; n = n.nextElementSibling) {
      if (n.offsetParent === null) continue;
      if ((n.classList.contains("chg") || n.classList.contains("gap")) && meaningful(n)) out.push(n);
      else if (n.getBoundingClientRect().top > innerHeight) break;
    }
    return out;
  }
  // Credits the time since the last tick to the marks that were showing, acknowledges those past 3 s, and wakes
  // again when the next one will be.
  function tickSeen() {
    const now = performance.now();
    if (state.loading) { clearTimeout(seenTimer); seenEls = []; seenAt = now; return; } // a new document is parsing
    for (const el of seenEls) seenMs.set(el, (seenMs.get(el) || 0) + now - seenAt);
    clearTimeout(seenTimer);
    seenAt = now;
    seenEls = state.keyWindow && marksLeft() ? marksOnScreen() : [];
    const due = seenEls.filter((el) => (seenMs.get(el) || 0) >= ACK_MS);
    if (due.length) { acknowledge(due); seenEls = seenEls.filter((el) => !due.includes(el)); }
    let next = Infinity;
    for (const el of seenEls) next = Math.min(next, ACK_MS - (seenMs.get(el) || 0));
    if (next < Infinity) seenTimer = setTimeout(tickSeen, next + 20);
  }
  function acknowledge(els) {
    if (els.some((el) => el.dataset.k === "rewritten")) {
      // The rewritten line stands for the whole page.
      state.rewritten = false;
      state.baseline = state.blocks.map((b) => b.hash);
    } else {
      for (const el of els) { if (el.classList.contains("gap")) el.remove(); else el.classList.remove("chg"); }
      state.baseline = ackedSequence();
      markOutlineChanges();
    }
    saveBaseline();
  }
  // The baseline as the page now shows it: unmarked blocks and each gap's removed hashes, in page order.
  function ackedSequence() {
    const out = [];
    for (let n = docEl.firstElementChild; n; n = n.nextElementSibling) {
      if (n.classList.contains("gap")) { for (const h of n.dataset.removed.split(",")) if (h) out.push(h); }
      else if (n.dataset.h && !n.classList.contains("chg")) out.push(n.dataset.h);
    }
    return out;
  }
  // state.baseline already holds what is sent, so a reload before the app stores it cannot bring marks back.
  function saveBaseline() { post({ type: "baseline", hashes: state.baseline, docId: state.docId }); }
  function applyMarks(fresh) {
    docEl.querySelectorAll(":scope > .gap").forEach((g) => g.remove());
    const hashes = state.blocks.map((b) => b.hash);
    const unmark = () => state.blocks.forEach((b) => b.el && b.el.classList.remove("chg"));
    if (state.baseline === null) {
      // First sight, or Quick Look, which sends no baseline: everything counts as read; no marks, no notice.
      unmark();
      banner("rewritten", null);
      state.rewritten = false;
      state.baseline = hashes;
      saveBaseline();
      return;
    }
    const pairs = diff(state.baseline, hashes);
    const kept = new Uint8Array(hashes.length);
    for (const [, j] of pairs) kept[j] = 1;
    // Over half changed (new and removed blocks against everything either side holds): one line replaces the marks,
    // on opening and on live reloads alike, until that line is read.
    const changed = hashes.length - pairs.length + (state.baseline.length - pairs.length);
    const union = hashes.length + state.baseline.length - pairs.length;
    if (changed > union / 2 && union > 4) {
      unmark();
      state.rewritten = true;
      banner("rewritten", state.baselineDate ? t("Rewritten since you read it on {d}.", { d: state.baselineDate }) : t("Rewritten since you last read it."));
      tickSeen();
      return;
    }
    state.rewritten = false;
    banner("rewritten", null);
    // The title block is hidden behind the note header, so it is never marked.
    state.blocks.forEach((b, j) => b.el && b.el.classList.toggle("chg", !kept[j] && !b.el.hidden));
    // Gaps: each run of acknowledged hashes with no match, right after the block matched before it.
    const gap = (i0, i1, j) => {
      if (i1 <= i0) return;
      const g = document.createElement("div");
      g.className = "gap";
      g.dataset.removed = state.baseline.slice(i0, i1).join(",");
      g.title = t("{n} removed", { n: num(i1 - i0) });
      const after = j >= 0 ? state.blocks[j].el : null;
      if (after) after.after(g); else docEl.prepend(g);
      const near = g.nextElementSibling && g.nextElementSibling.dataset.h ? g.nextElementSibling : g.previousElementSibling;
      const lead = near && near.getAttribute("dir");
      if (lead) g.setAttribute("dir", lead); // on the leading side of the text it sits in
    };
    let pi = -1, pj = -1;
    for (const [i, j] of pairs) { gap(pi + 1, i, pj); pi = i; pj = j; }
    gap(pi + 1, state.baseline.length, pj);
    tickSeen();
  }
  function goChange(dir) {
    const marks = [...docEl.querySelectorAll(":scope > .blk.chg, :scope > .gap")].filter((n) => n.offsetParent !== null || n.classList.contains("gap"));
    if (!marks.length) return false;
    const y = READ_LINE + 4;
    const target = dir > 0 ? marks.find((n) => n.getBoundingClientRect().top > y + 8) : [...marks].reverse().find((n) => n.getBoundingClientRect().top < y - 8);
    if (!target) return false;
    jumpTo(target);
    return true;
  }

  // ---------- loading and reloading ----------
  function assignIds(blocks) {
    const used = new Map();
    for (const b of blocks) {
      if (b.kind !== "md") continue;
      const ids = [];
      const visit = (t) => {
        if (t.type === "heading") {
          const base = slugify(t.text.replace(/\[\[([^\]|]+)(?:\|([^\]]+))?\]\]/g, (_, a, l) => l || a));
          const n = used.get(base) || 0;
          used.set(base, n + 1);
          ids.push(n ? `${base}-${n + 1}` : base);
        }
        for (const c of t.tokens || []) if (c.type !== "text") visit(c);
      };
      visit(b.token);
      b.ids = ids;
    }
  }
  function documentDirection(source) {
    const r = count(source, RTL_RE), l = count(source, LTR_RE);
    return r > l ? "rtl" : "ltr";
  }

  // Renders the next blocks in order while more() holds, up to 10,000 blocks and 200,000 elements (SAFE-5).
  function renderMore(more) {
    const frag = document.createDocumentFragment();
    while (state.rendered < state.blocks.length && more()) {
      if (state.rendered >= MAX_BLOCKS) { state.capped = true; break; }
      const b = state.blocks[state.rendered];
      const el = renderBlock(b);
      if (state.nodes + b.nodes > MAX_NODES) { state.capped = true; break; }
      b.el = el;
      state.nodes += b.nodes;
      resize.observe(el);
      frag.appendChild(el);
      state.rendered++;
    }
    docEl.appendChild(frag);
  }
  function ensureRendered(k) { if (k >= state.rendered && !state.capped) renderMore(() => state.rendered <= k); }
  const tooLong = (n) => t("This document is too long to show whole; Linen shows its first {n} blocks.", { n: num(n) });
  const ARABIC = /[؀-ۿݐ-ݿࢠ-ࣿﭐ-﷿ﹰ-﻿]/;
  function setArabic(text) { state.hasArabic = ARABIC.test(text); $("find-fold").hidden = !state.hasArabic; }

  async function load(msg) {
    const token = ++state.renderToken;
    mermaidCount = 0;
    mermaidGen++;
    // The old page's timers stop before anything names the new document (acknowledgements, announcements).
    clearTimeout(seenTimer);
    seenEls = [];
    clearTimeout(settleTimer);
    $("status").textContent = "";
    Object.assign(state, {
      docId: msg.docId, name: msg.name || "", path: msg.path || "", plain: !!msg.plain, meta: msg.meta || {},
      baseline: Array.isArray(msg.baseline) ? msg.baseline.slice() : null, baselineDate: msg.baselineDate || null,
      allowRemote: !!msg.allowRemote, held: null, rewritten: false, loading: msg,
    });
    heard = null;
    unannounced = false;
    html.classList.toggle("log", false);
    state.docDir = documentDirection(msg.text.slice(0, 200000));
    // Over 20 MB never reaches the Markdown lexer (SAFE-5); the byte count is taken before anything is posted.
    const big = overBytes(msg.text, MAX_BYTES);
    const tLex = performance.now();
    const result = await lex(msg.text, state.plain || big);
    const lexMs = performance.now() - tLex;
    if (!result || token !== state.renderToken) return;
    state.loading = null;
    state.ctx = { links: result.links, footnotes: result.footnotes, footnoteDefs: result.footnoteDefs };
    D.context = state.ctx;
    state.yaml = parseYAML(result.yaml);
    if (window.LinenBlocks) window.LinenBlocks.configure(result.yaml, msg.sidecar); // linen: settings, sidecar notes (Lane F)
    html.classList.toggle("log", !!result.logLike);
    assignIds(result.blocks);
    for (const b of state.blocks) if (b.el) resize.unobserve(b.el);
    docEl.replaceChildren();
    docEl.classList.remove("pre-open");
    wikiTargets.clear();
    $("notice").hidden = true;
    banner("rewritten", null);
    banner("size", big || result.tooBig ? t("This document is too large to typeset, so it is shown as plain text.") : null);
    setArabic(msg.text);
    state.blocks = result.blocks;
    Object.assign(state, { rendered: 0, nodes: 0, capped: false });
    const header = headerFor(state.blocks);
    const placeIndex = msg.place ? placeIndexOf(msg.place) : 0;
    // First screen first: render through the block being returned to, then the rest in 12 ms slices.
    let first = true;
    // A place the first screen could not reach (the page ended below it) is restored again as blocks arrive,
    // until it is reached or the reader scrolls.
    let clampedAt = -1;
    const atBottom = () => scrollY >= document.documentElement.scrollHeight - innerHeight - 1;
    while (state.rendered < state.blocks.length && !state.capped) {
      const t0 = performance.now();
      renderMore(() => performance.now() - t0 < 12 || (first && state.rendered <= placeIndex + 20));
      if (first) {
        first = false;
        applyHeaderToBlocks(header);
        restorePlace(msg.place);
        if (msg.place && atBottom()) clampedAt = scrollY;
        state.anchorEl = (blockAt(READ_LINE) || {}).el || null;
        post({ type: "firstPaint", version: msg.version || 0, lexMs: Math.round(lexMs), paintMs: Math.round(performance.now() - tLex - lexMs) });
      } else if (clampedAt >= 0 && scrollY === clampedAt) {
        restorePlace(msg.place);
        clampedAt = atBottom() ? scrollY : -1;
        state.anchorEl = (blockAt(READ_LINE) || {}).el || null;
      }
      if (state.rendered < state.blocks.length && !state.capped) await nextFrame();
      if (token !== state.renderToken) return;
    }
    if (state.capped) { state.blocks.length = state.rendered; showNotice(tooLong(state.rendered)); }
    if (first) {
      // An empty document: nothing went through the loop.
      applyHeaderToBlocks(header);
      post({ type: "firstPaint", version: msg.version || 0 });
    }
    // The footnotes are a block of their own now (lexer.js, Lane F).
    if (window.LinenBlocks) keepPlace(() => window.LinenBlocks.finish(docEl)); // noted items, sources for print (Lane F)
    applyHeaderToBlocks(header);
    keepPlace(() => applyMarks(true));
    buildOutline();
    footer();
    requestLinkStatus();
    requestImages();
    if (msg.place && msg.place.atEnd && msg.grown) {
      const firstNew = docEl.querySelector(":scope > .blk.chg");
      if (firstNew) jumpTo(firstNew);
    }
    heard = state.blocks.slice();
    post({ type: "rendered", title: $("note-title").textContent, blocks: state.blocks.length, words: wordCount(), docId: state.docId });
  }

  // A reload (LIVE-2 to LIVE-4): diff, patch only what changed, keep the place. A load still parsing starts over
  // with the newer text, so it keeps its place.
  let updateSeq = 0, quietSeq = 0;
  async function update(msg) {
    if (state.loading) return load({ ...state.loading, text: msg.text, version: msg.version, ...("sidecar" in msg ? { sidecar: msg.sidecar } : {}) });
    const seq = ++updateSeq;
    const token = ++state.renderToken;
    state.held = null;
    if (msg.meta) state.meta = msg.meta; // the footer's modified time follows the file
    const big = overBytes(msg.text, MAX_BYTES);
    const result = await lex(msg.text, state.plain || big);
    if (!result || token !== state.renderToken) return;
    // Keep the last good page (LIVE-3): a read that is empty or loses over half the blocks waits for the quiet that
    // follows it (unless that quiet came while it was parsing); a later good read replaces it sooner.
    const degraded = result.blocks.length === 0 || result.blocks.length < state.blocks.length / 2;
    if (degraded && quietSeq < seq) { state.held = { msg, result, big, seq }; return; }
    await (applying = applyUpdate(msg, result, big, !msg.inBurst));
  }
  // A quiet that arrives while a reload is still typesetting waits for it, so the settled reload is announced.
  let applying = null;
  async function quiet() {
    quietSeq = updateSeq;
    if (applying) await applying;
    const h = state.held;
    if (h && h.seq === updateSeq) { state.held = null; await (applying = applyUpdate(h.msg, h.result, h.big, true)); }
    else if (unannounced) settle();
  }

  async function applyUpdate(msg, result, big, settles) {
    const token = ++state.renderToken; // stops slices still running from a load or an older reload
    const oldBlocks = state.blocks;
    state.ctx = { links: result.links, footnotes: result.footnotes, footnoteDefs: result.footnoteDefs };
    D.context = state.ctx;
    state.yaml = parseYAML(result.yaml);
    if (window.LinenBlocks) window.LinenBlocks.configure(result.yaml, msg.sidecar); // Lane F
    assignIds(result.blocks);
    const blocks = result.blocks.length > MAX_BLOCKS ? result.blocks.slice(0, MAX_BLOCKS) : result.blocks;
    let capped = blocks.length < result.blocks.length;
    const pairs = diff(oldBlocks.map((b) => b.hash), blocks.map((b) => b.hash));
    const edited = pairEdited(oldBlocks, blocks, pairs);
    const newToOld = new Map(pairs.map(([o, n]) => [n, o]));
    // New blocks are typeset in slices of 12 ms between frames, stopping if a newer load or reload starts (SAFE-5);
    // the page keeps showing the old version until the patch below.
    let t0 = performance.now(), budget = 0;
    for (let j = 0; j < blocks.length && budget <= MAX_NODES; j++) {
      const o = newToOld.get(j);
      if (o !== undefined && oldBlocks[o].el) { budget += oldBlocks[o].nodes || 1; continue; }
      blocks[j].deferMedia = true;
      blocks[j].el = renderBlock(blocks[j]);
      budget += blocks[j].nodes;
      if (performance.now() - t0 > 12) {
        await nextFrame();
        if (token !== state.renderToken) return;
        t0 = performance.now();
      }
    }
    const place = capturePlace();
    const anchorTop = place ? READ_LINE - place.offset : 0;
    const selection = captureSelection();
    const keptOld = new Set();
    const anchorOldIndex = place ? place.index : -1;
    let anchorNew = null, replacement = null, nodes = 0;
    const next = [];
    for (let j = 0; j < blocks.length; j++) {
      const b = blocks[j], o = newToOld.get(j);
      const reuse = o !== undefined && oldBlocks[o].el ? oldBlocks[o] : null;
      if (reuse) { b.el = reuse.el; b.nodes = reuse.nodes || 1; } else if (!b.el) { b.deferMedia = true; b.el = renderBlock(b); }
      if (nodes + b.nodes > MAX_NODES) { capped = true; break; }
      nodes += b.nodes;
      if (reuse) {
        keptOld.add(o);
        b.el.dataset.l = b.lines.join("-");
        if (o === anchorOldIndex) anchorNew = b;
      } else resize.observe(b.el);
      next.push(b);
    }
    if (!anchorNew && anchorOldIndex >= 0) {
      // The block being read was edited (its pair carries the place) or removed (the next surviving block takes
      // it, placed where the removed one began).
      const ed = edited.get(anchorOldIndex);
      if (ed !== undefined && ed < next.length) replacement = next[ed];
      else anchorNew = next.find((b, j) => newToOld.has(j) && newToOld.get(j) > anchorOldIndex) || null;
    }
    // Patch the DOM in order, reusing kept elements.
    docEl.querySelectorAll(":scope > .gap, :scope > .preamble-toggle, :scope > .lnotes-blk").forEach((g) => g.remove());
    oldBlocks.forEach((b, o) => { if (!keptOld.has(o) && b.el && b.el.isConnected) { resize.unobserve(b.el); b.el.remove(); } });
    let cursor = docEl.firstChild;
    for (const b of next) {
      if (b.el === cursor) { cursor = cursor.nextSibling; continue; }
      docEl.insertBefore(b.el, cursor);
    }
    state.blocks = next;
    Object.assign(state, { rendered: next.length, nodes, capped });
    for (const b of next) if (b.deferMedia) { b.deferMedia = false; activateMedia(b.el); }
    if (capped) showNotice(tooLong(next.length)); else $("notice").hidden = true;
    banner("size", big || result.tooBig ? t("This document is too large to typeset, so it is shown as plain text.") : null);
    setArabic(msg.text);
    // The footnotes are a block of their own now (lexer.js, Lane F).
    if (window.LinenBlocks) window.LinenBlocks.finish(docEl); // Lane F
    const header = headerFor(state.blocks);
    applyHeaderToBlocks(header);
    applyMarks(false);
    // Put the reading line back (LIVE-4), after everything that changes layout.
    if (place) {
      if (anchorNew && anchorNew.el.isConnected) {
        scrollBy(0, anchorNew.el.getBoundingClientRect().top - anchorTop);
      } else if (replacement) {
        scrollBy(0, replacement.el.getBoundingClientRect().top - anchorTop);
        if (!scrollToQuote(replacement.el, place)) scrollToShare(replacement.el, place);
      }
    }
    restoreSelection(selection, edited, next);
    state.anchorEl = (blockAt(READ_LINE) || {}).el || null;
    buildOutline();
    footer();
    requestLinkStatus();
    requestImages();
    if (findState.query) runFind(findState.query, true);
    unannounced = true;
    if (settles) settle();
    post({ type: "reloaded", version: msg.version || 0, changed: blocks.length - pairs.length });
  }

  // LOOK-4: no live region over the page; a settled reload is announced once in a hidden status line, counting
  // what changed since the last announcement (new and edited blocks, and removed ones that were not edited).
  let heard = null, unannounced = false, settleTimer = 0;
  function settle() {
    clearTimeout(settleTimer);
    unannounced = false;
    const prev = heard || [];
    heard = state.blocks.slice();
    const pairs = diff(prev.map((b) => b.hash), heard.map((b) => b.hash));
    const n = heard.length - pairs.length + prev.length - pairs.length - pairEdited(prev, heard, pairs).size;
    if (n <= 0) return;
    const status = $("status");
    status.textContent = "";
    settleTimer = setTimeout(() => { status.textContent = n === 1 ? t("Updated, 1 change") : t("Updated, {n} changes", { n: num(n) }); }, 100);
  }

  function captureSelection() {
    const sel = getSelection();
    if (!sel || sel.isCollapsed || !sel.rangeCount) return null;
    const r = sel.getRangeAt(0);
    const blk = (r.startContainer.nodeType === 1 ? r.startContainer : r.startContainer.parentElement).closest(".blk");
    const index = state.blocks.findIndex((b) => b.el === blk);
    if (index < 0) return null;
    return { index, text: sel.toString() };
  }
  function restoreSelection(saved, edited, next) {
    if (!saved) return;
    const j = edited.get(saved.index);
    if (j === undefined || !next[j]) return; // kept blocks keep their selection; removed ones lose it
    const el = next[j].el, text = el.textContent || "", at = text.indexOf(saved.text);
    if (at < 0 || !saved.text) return;
    const s = rangeAtTextOffset(el, at), e = rangeAtTextOffset(el, at + saved.text.length - 1);
    if (!s || !e) return;
    const r = document.createRange();
    r.setStart(s.startContainer, s.startOffset);
    r.setEnd(e.endContainer, e.endOffset);
    getSelection().removeAllRanges();
    getSelection().addRange(r);
  }

  // The footnotes list, rendered as the source-backed block lexer.js lifts to the end (Lane F, BLK-1). Each item carries
  // its own number, the one its references show.
  function footnotesHTML() {
    const defs = state.ctx.footnoteDefs.slice().sort((a, b) => (state.ctx.footnotes[a.id] || 0) - (state.ctx.footnotes[b.id] || 0));
    const items = defs.map((d) => {
      let inner;
      try { inner = marked.parser([{ type: "paragraph", raw: "", text: "", tokens: d.tokens }]); } catch (_) { inner = ""; }
      const id = D.escapeHTML(d.id);
      return `<li id="fn-${id}" value="${Number(state.ctx.footnotes[d.id]) || 0}">${inner.replace(/<\/p>\s*$/, ` <a class="back" href="#fnref-${id}" aria-label="${D.escapeHTML(t("Back to text"))}">↩</a></p>`)}</li>`;
    }).join("");
    return `<section class="footnotes"><ol>${items}</ol></section>`;
  }
  function showNotice(text) { const n = $("notice"); n.textContent = text; n.hidden = false; }
  // The banner over the page holds one line per key ("size": shown as plain text; "rewritten": LIVE-5). It sits
  // above the reader, so callers keep the place.
  function banner(key, text) {
    const box = $("banner");
    let line = box.querySelector(`[data-k="${key}"]`);
    if (text) {
      if (!line) { line = document.createElement("p"); line.dataset.k = key; box.appendChild(line); }
      line.textContent = text;
    } else if (line) line.remove();
    box.hidden = !box.firstChild;
  }

  // ---------- footer (READ-7) ----------
  function wordCount() {
    const text = docEl.innerText || "";
    return (text.match(/[\p{L}\p{N}]+(?:['’][\p{L}]+)*/gu) || []).length;
  }
  function footer() {
    const words = wordCount();
    const parts = [t(words === 1 ? "{n} word" : "{n} words", { n: num(words) }), t("{n} min", { n: num(Math.max(1, Math.round(words / 230))) })];
    if (state.meta.modified) parts.push(t("modified {d}", { d: state.meta.modified }));
    if (state.meta.encoding) parts.push(state.meta.encoding);
    $("footer").innerHTML = parts.map((p) => `<span>${D.escapeHTML(p)}</span>`).join("");
  }

  // ---------- find (READ-3) ----------
  const findState = { query: "", marks: [], cur: -1, foldArabic: true };
  function clearFind() {
    for (const m of findState.marks) {
      const p = m.parentNode;
      if (!p) continue;
      p.replaceChild(document.createTextNode(m.textContent), m);
      p.normalize();
    }
    findState.marks = [];
    findState.cur = -1;
    $("match-rail").replaceChildren();
  }
  function runFind(query, keep) {
    const prevCur = findState.cur;
    clearFind();
    findState.query = query;
    if (!query) { updateFindCount(); return; }
    const norm = findState.foldArabic ? fold : (s) => s.toLowerCase();
    const q = norm(query);
    if (!q) { updateFindCount(); return; }
    // A flat folded copy of the page text, with a map from each folded character back to its node and offset.
    const nodes = [];
    const w = document.createTreeWalker(docEl, NodeFilter.SHOW_TEXT, {
      acceptNode(n) {
        const p = n.parentElement;
        if (!p || p.closest(".copy, .lang, [hidden], .blk.pre:not(.pre-open .blk.pre), .katex-mathml")) return NodeFilter.FILTER_REJECT;
        return n.nodeValue.trim() || n.nodeValue.length ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
      },
    });
    let flat = "";
    const map = [];
    while (w.nextNode()) {
      const n = w.currentNode, v = n.nodeValue;
      for (let i = 0; i < v.length; i++) {
        const ch = v[i];
        if (findState.foldArabic && FOLD_DROPS.test(ch)) continue;
        const f = norm(ch);
        for (let k = 0; k < f.length; k++) { flat += f[k]; map.push([n, i]); }
      }
      nodes.push(n);
    }
    const hits = [];
    let from = 0;
    while (hits.length < 2000) {
      const at = flat.indexOf(q, from);
      if (at < 0) break;
      hits.push([at, at + q.length - 1]);
      from = at + q.length;
    }
    // Wrap from the end so earlier offsets stay valid.
    for (let h = hits.length - 1; h >= 0; h--) {
      const [s, e] = hits[h];
      const [sn, so] = map[s];
      const [en, eo] = map[e];
      const marks = wrapRange(sn, so, en, eo + 1);
      findState.marks.unshift(...marks.map((m) => { m.dataset.hit = h; return m; }));
    }
    findState.count = hits.length;
    if (hits.length) {
      findState.cur = keep && prevCur >= 0 ? Math.min(prevCur, hits.length - 1) : firstHitBelow();
      showHit(!keep);
    }
    drawRail();
    updateFindCount();
  }
  function wrapRange(sn, so, en, eo) {
    const out = [];
    const w = document.createTreeWalker(docEl, NodeFilter.SHOW_TEXT);
    w.currentNode = sn;
    let node = sn;
    const segments = [];
    while (node) {
      const start = node === sn ? so : 0;
      const end = node === en ? eo : node.nodeValue.length;
      if (end > start) segments.push([node, start, end]);
      if (node === en) break;
      node = w.nextNode();
    }
    for (const [n, s, e] of segments) {
      const range = document.createRange();
      range.setStart(n, s);
      range.setEnd(n, e);
      const m = document.createElement("mark");
      m.className = "find";
      try { range.surroundContents(m); out.push(m); } catch (_) { /* crosses an element boundary */ }
    }
    return out;
  }
  function hitMarks(i) { return findState.marks.filter((m) => Number(m.dataset.hit) === i); }
  function firstHitBelow() {
    for (let i = 0; i < findState.count; i++) { const m = hitMarks(i)[0]; if (m && m.getBoundingClientRect().top >= READ_LINE - 10) return i; }
    return 0;
  }
  function showHit(scroll) {
    findState.marks.forEach((m) => m.classList.toggle("cur", Number(m.dataset.hit) === findState.cur));
    const m = hitMarks(findState.cur)[0];
    if (m && scroll) {
      const r = m.getBoundingClientRect();
      if (r.top < READ_LINE || r.bottom > innerHeight - 60) scrollBy(0, r.top - innerHeight / 3);
    }
    $("match-rail").querySelectorAll("i").forEach((i) => i.classList.toggle("cur", Number(i.dataset.hit) === findState.cur));
    updateFindCount();
  }
  function stepFind(dir) {
    if (!findState.count) return;
    findState.cur = (findState.cur + dir + findState.count) % findState.count;
    showHit(true);
  }
  function drawRail() {
    const rail = $("match-rail");
    rail.replaceChildren();
    const total = document.documentElement.scrollHeight;
    const h = rail.clientHeight || innerHeight;
    for (let i = 0; i < findState.count; i++) {
      const m = hitMarks(i)[0];
      if (!m) continue;
      const y = (m.getBoundingClientRect().top + scrollY) / total;
      const dot = document.createElement("i");
      dot.style.top = `${Math.round(y * h)}px`;
      dot.dataset.hit = i;
      rail.appendChild(dot);
    }
  }
  function updateFindCount() {
    const c = findState.count || 0;
    $("find-count").textContent = findState.query ? (c ? t("{a} of {b}", { a: num(findState.cur + 1), b: num(c) }) : t("Not found")) : "";
    post({ type: "findState", count: c, current: findState.cur + 1 });
  }
  function openFind(useSelection) {
    const bar = $("findbar");
    bar.hidden = false;
    const input = $("find-input");
    if (useSelection) { const sel = String(getSelection() || "").trim(); if (sel) input.value = sel; }
    input.focus();
    input.select();
    if (input.value) runFind(input.value, false);
  }
  function closeFind() {
    $("findbar").hidden = true;
    const cur = hitMarks(findState.cur)[0];
    const keepTop = cur ? cur.getBoundingClientRect().top : null;
    const anchor = cur ? cur.closest(".blk") : null;
    clearFind();
    findState.query = "";
    if (anchor && keepTop !== null) { /* the page stays where the current match was */ }
    post({ type: "findClosed" });
  }
  let findTimer = 0;
  $("find-input").addEventListener("input", (e) => { clearTimeout(findTimer); const v = e.target.value; findTimer = setTimeout(() => runFind(v, false), 60); });
  $("find-input").addEventListener("keydown", (e) => {
    if (e.key === "Enter") { e.preventDefault(); stepFind(e.shiftKey ? -1 : 1); }
    if (e.key === "Escape") { e.preventDefault(); closeFind(); }
  });
  $("find-next").addEventListener("click", () => stepFind(1));
  $("find-prev").addEventListener("click", () => stepFind(-1));
  $("find-done").addEventListener("click", closeFind);
  // Arabic folding (READ-3): on unless the reader turns it off here; the choice is the app's setting foldArabic.
  // The option shows only for documents with Arabic in them.
  function setFold(on, byReader) {
    findState.foldArabic = on;
    const b = $("find-fold");
    b.setAttribute("aria-pressed", String(on));
    b.textContent = on ? "أ = ا" : "أ ≠ ا";
    if (byReader) post({ type: "setting", key: "foldArabic", value: on });
    if (findState.query) runFind(findState.query, true);
  }
  $("find-fold").addEventListener("click", (e) => { setFold(!findState.foldArabic, true); if (e.detail) $("find-input").focus(); });
  setFold(true, false);

  // ---------- properties (REN-6) ----------
  function toggleProperties() {
    const p = $("props");
    if (!p.hidden) { p.hidden = true; return; }
    const rows = (state.yaml || []).map(([k, v]) => `<tr><th>${D.escapeHTML(k)}</th><td dir="auto">${D.escapeHTML(Array.isArray(v) ? v.join(", ") : v)}</td></tr>`).join("");
    p.innerHTML = `<div class="eyebrow">${D.escapeHTML(t("Properties"))}</div>${rows ? `<table>${rows}</table>` : `<p>${D.escapeHTML(t("This note has no properties."))}</p>`}`;
    p.hidden = false;
  }
  addEventListener("keydown", (e) => { if (e.key === "Escape" && !$("props").hidden) $("props").hidden = true; });
  addEventListener("mousedown", (e) => { if (!$("props").hidden && !$("props").contains(e.target)) $("props").hidden = true; });

  // ---------- Copy Reference (READ-6) ----------
  function copyReference() {
    const sel = getSelection();
    const blocks = [];
    let lines = null;
    const linesOf = (el) => (el.dataset.l || "").split("-").map(Number);
    if (sel && !sel.isCollapsed && sel.rangeCount) {
      const r = sel.getRangeAt(0);
      const startBlk = (r.startContainer.nodeType === 1 ? r.startContainer : r.startContainer.parentElement).closest(".blk");
      const endBlk = (r.endContainer.nodeType === 1 ? r.endContainer : r.endContainer.parentElement).closest(".blk");
      if (startBlk && endBlk) {
        const s = state.blocks.find((b) => b.el === startBlk), e = state.blocks.find((b) => b.el === endBlk);
        if (s && e) {
          lines = [linesOf(startBlk)[0], linesOf(endBlk)[1]];
          // Narrow to list items and table rows when the selection stays inside one block.
          if (s === e && s.parts && s.parts.length) {
            const partEls = startBlk.querySelectorAll(s.token.type === "list" ? ":scope > ul > li, :scope > ol > li" : "tr");
            const idx = [...partEls].map((p, i) => (r.intersectsNode(p) ? i : -1)).filter((i) => i >= 0);
            if (idx.length && s.parts[idx[0]] && s.parts[idx[idx.length - 1]]) lines = [s.parts[idx[0]][0], s.parts[idx[idx.length - 1]][1]];
          }
          blocks.push(s, e);
        }
      }
    }
    if (!lines) { const b = blockAt(READ_LINE); if (b) lines = linesOf(b.el); }
    return lines ? { start: lines[0], end: lines[1] } : null;
  }

  // ---------- links (SAFE-4, READ-5, REN-12) ----------
  docEl.addEventListener("click", (e) => {
    const a = e.target.closest("a");
    if (!a) {
      const img = e.target.closest("img");
      if (img && img.src) post({ type: "showImage", src: img.dataset.req || img.src });
      return;
    }
    e.preventDefault();
    const newTab = e.metaKey || e.button === 1;
    if (a.classList.contains("wl")) { post({ type: "openWiki", target: a.dataset.target, newTab, place: capturePlace() }); return; }
    const href = a.getAttribute("href") || "";
    if (href.startsWith("#")) {
      const target = document.getElementById(decodeURIComponent(href.slice(1)));
      if (target) jumpTo(target);
      return;
    }
    if (/^(https?|mailto|tel):/i.test(href)) { post({ type: "openExternal", url: href }); return; }
    if (/^[a-z][a-z0-9+.-]*:/i.test(href)) { post({ type: "openScheme", url: href }); return; }
    if (href) post({ type: "openLocal", href, newTab, place: capturePlace() });
  });
  docEl.addEventListener("auxclick", (e) => { if (e.button === 1) docEl.dispatchEvent(new MouseEvent("click", e)); });

  // ---------- the bridge ----------
  async function receive(msg) {
    try { return await route(msg); } catch (err) {
      console.error(`linen ${msg.type}: ${err && err.message} ${err && err.stack ? err.stack.split("\n").slice(0, 3).join(" | ") : ""}`);
      post({ type: "error", message: String(err && err.message || err), during: msg.type });
      return false;
    }
  }
  async function route(msg) {
    // Linen 2 boards (Lane B): a board's load, update and commands go to board.js; settings and focus reach both.
    const board = window.LinenBoard;
    if (msg.type === "focus") state.keyWindow = !!msg.key;
    if (board && msg.type === "settings") { applySettings(msg); board.settings(msg); return true; }
    if (board && board.handles(msg)) {
      if (msg.type === "load") { // Lane B: the board takes the tab; a note still rendering stops here
        ++state.renderToken;
        state.loading = null;
        if (worker && pending.size) { worker.terminate(); for (const p of pending.values()) p.resolve(null); pending.clear(); startWorker(); }
        mermaidCount = 0;
        mermaidGen++;
      }
      return board.receive(msg);
    }
    switch (msg.type) {
      case "load": await load(msg); return true;
      case "update": await update(msg); return true;
      case "quiet": await quiet(); return true;
      case "settings": applySettings(msg); return true;
      case "linkStatus": applyLinkStatus(msg.map || {}); return true;
      case "imageInfo": applyImageInfo(msg.map || {}); return true;
      case "allowRemote": state.allowRemote = true; return true;
      case "focus": state.keyWindow = !!msg.key; tickSeen(); return true;
      case "command": return command(msg);
      default: return false;
    }
  }
  function command(msg) {
    switch (msg.name) {
      case "find": openFind(false); return true;
      case "findSelection": openFind(true); return true;
      case "findNext": stepFind(1); return true;
      case "findPrevious": stepFind(-1); return true;
      case "outline": setOutline(!!msg.show, !!msg.overlay); return true;
      case "nextChange": return goChange(1);
      case "previousChange": return goChange(-1);
      case "properties": toggleProperties(); return true;
      case "copyReference": return copyReference();
      case "place": return capturePlace();
      case "restorePlace": restorePlace(msg.place); return true;
      case "prepareForPrint": return prepareForPrint();
      case "selectionText": return String(getSelection() || "");
      case "heading": {
        const want = String(msg.text || "").trim().toLowerCase();
        const h = [...docEl.querySelectorAll("h1, h2, h3, h4, h5, h6")].find((n) => n.textContent.trim().toLowerCase() === want || n.id === slugify(msg.text || ""));
        if (h) { h.scrollIntoView({ block: "start" }); scrollBy(0, -READ_LINE + 24); updateOutline(); }
        return !!h;
      }
      // `linen open --line n` (CLI-6, Lane F): the block holding source line n goes to the reading line; nothing selected.
      case "line": {
        const n = Math.max(1, Math.round(Number(msg.line)) || 1);
        // The block whose lines hold n (the lifted footnotes sit last but name their own lines), else the next one.
        let k = state.blocks.findIndex((b) => b.lines && b.lines[0] <= n && n <= b.lines[1]);
        if (k < 0) k = state.blocks.findIndex((b) => b.lines && n <= b.lines[1]);
        if (k < 0) k = state.blocks.length - 1;
        if (k < 0) return false;
        ensureRendered(k);
        const b = state.blocks[Math.min(k, state.rendered - 1)];
        if (!b || !b.el) return false;
        if (b.el.classList.contains("pre")) { docEl.classList.add("pre-open"); const pt = docEl.querySelector(":scope > .preamble-toggle"); if (pt) pt.open = true; }
        if (b.el.hidden || b.el.offsetParent === null) scrollTo(0, 0);
        else scrollTo(0, scrollY + b.el.getBoundingClientRect().top - READ_LINE);
        updateOutline();
        return true;
      }
      default: return false;
    }
  }
  function applySettings(s) {
    state.settings = { ...state.settings, ...s };
    keepPlace(() => {
      if (s.theme) html.dataset.theme = s.theme;
      if (s.face) html.dataset.face = s.face;
      if ("contrast" in s) html.classList.toggle("contrast", !!s.contrast);
      if (s.uiDir) $("shell").setAttribute("dir", s.uiDir), html.setAttribute("dir", s.uiDir);
      if ("quickLook" in s) html.classList.toggle("ql", !!s.quickLook);
      if (s.lang) { html.lang = s.lang; lang = s.lang === "ar" ? "ar" : "en"; localizeChrome(); }
      if ("printPaper" in s) html.classList.toggle("print-paper", !!s.printPaper);
    });
    if ("foldArabic" in s && (s.foldArabic !== false) !== findState.foldArabic) setFold(s.foldArabic !== false, false);
    if (s.theme && mermaidSVG.size) {
      docEl.querySelectorAll(".mermaid-src").forEach((n) => { if (n.querySelector("svg")) fill(n); });
    }
  }
  function localizeChrome() {
    $("outline-filter").placeholder = t("Filter");
    $("find-done").textContent = t("Done");
    $("find-fold").title = t("Ignore Arabic diacritics and letter forms");
    $("find-fold").setAttribute("aria-label", t("Ignore Arabic diacritics and letter forms"));
  }
  async function prepareForPrint() {
    docEl.classList.add("pre-open");
    const pendingFills = [...docEl.querySelectorAll("pre.code, .math:empty, .mermaid-src")].filter((n) => !n.querySelector(".hljs, svg, .katex"));
    for (const n of pendingFills) { lazy.unobserve(n); await fill(n); }
    await (document.fonts ? document.fonts.ready : Promise.resolve());
    const heads = [...docEl.querySelectorAll(":scope > .blk:not([hidden]) h1, :scope > .blk:not([hidden]) h2, :scope > .blk:not([hidden]) h3")].map((h) => ({ level: Number(h.tagName[1]), text: h.textContent.trim() }));
    return { title: $("note-title").textContent, headings: heads };
  }

  localizeChrome();
  // Linen 2 boards (Lane B): board.js draws card text with the note pipeline, through these.
  window.linenInternals = Object.assign(window.linenInternals || {}, {
    marked, PURIFY, post, t, fold, directionOf, prepareImage, requestImages, nextFrame, fill, slugify,
    lang: () => lang, keyWindow: () => state.keyWindow, mermaidBudget: () => 50 - mermaidCount, spendMermaid: (k) => { mermaidCount += k; }, mermaidGen: () => mermaidGen,
    imgSourceCount: () => imgSources.size,
    lruTest: () => { const m = new Map(); lruSet(m, "a", 1, 2); lruSet(m, "b", 2, 2); lruGet(m, "a"); lruSet(m, "c", 3, 2); return m.has("a") && !m.has("b") && m.has("c"); }, imgSource: (k) => imgSources.get(k),
    decorate, activateMedia, // blocks.js renders a kept block again with the page's own decoration (Lane F)
  });
  window.linen = { receive, version: 1 };
  if (window.matchMedia) {
    const mq = window.matchMedia("(prefers-contrast: more)");
    html.classList.toggle("contrast", mq.matches);
  }
  post({ type: "ready", version: 1 });
})();
