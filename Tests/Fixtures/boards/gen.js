// Writes Linen's board fixtures (PRD-2 section 13, "Board fixtures") in Obsidian 1.13.7's file style: tab indents,
// an object whose values are all plain on one line, nested objects expanded (its serializer, ported below).
// Everything here is synthetic. Run: node Tests/Fixtures/boards/gen.js [--big-only]
"use strict";
const fs = require("fs");
const path = require("path");

const dir = __dirname;
const bigOnly = process.argv.includes("--big-only");

// ---------- Obsidian's serializer ($d / Zd in app.js 1.13.7) ----------
const plain = (v) => v === null || typeof v !== "object";
function lines(e, t) {
  if (e === undefined) return ["null"];
  if (plain(e) || !e) return [JSON.stringify(e)];
  if (Array.isArray(e)) {
    if (e.every(plain)) return [JSON.stringify(e)];
    const out = ["["];
    e.forEach((item, r) => {
      const h = lines(item, t);
      h.forEach((l, a) => out.push(t + l + (a === h.length - 1 && r !== e.length - 1 ? "," : "")));
    });
    out.push("]");
    return out;
  }
  let flat = true;
  for (const k in e) if (Object.prototype.hasOwnProperty.call(e, k) && !plain(e[k])) { flat = false; break; }
  if (flat) return [JSON.stringify(e)];
  const keys = Object.keys(e).filter((k) => e[k] !== undefined);
  const out = ["{"];
  keys.forEach((k, r) => {
    const h = lines(e[k], t);
    h[0] = JSON.stringify(k) + ":" + h[0];
    h.forEach((l, a) => out.push(t + l + (a === h.length - 1 && r !== keys.length - 1 ? "," : "")));
  });
  out.push("}");
  return out;
}
const obsidian = (obj) => lines(obj, "\t").join("\n");
// Writes only when the content changed, through a temporary file and a rename, so a reader never sees half a file.
const write = (name, text) => {
  const file = path.join(dir, name);
  try { if (fs.readFileSync(file, "utf8") === text) return; } catch (_) {}
  fs.writeFileSync(file + ".tmp", text);
  fs.renameSync(file + ".tmp", file);
};
const writeBoard = (name, obj) => write(name, obsidian(obj));

// ---------- small builders ----------
const card = (id, x, y, text, extra) => Object.assign({ id, type: "text", text, x, y, width: 280, height: 140 }, extra || {});
const group = (id, x, y, w, h, label, extra) => Object.assign({ id, type: "group", x, y, width: w, height: h }, label == null ? {} : { label }, extra || {});
const fileNode = (id, x, y, file, extra) => Object.assign({ id, type: "file", file, x, y, width: 280, height: 160 }, extra || {});
const edge = (id, from, to, extra) => Object.assign({ id, fromNode: from, toNode: to }, extra || {});

// ---------- fixtures ----------
function fixtures() {
  writeBoard("kinds.canvas", {
    nodes: [
      card("card-titled", 0, 0, "## Gateway\n\nRoutes requests to the **core** service.\n\n- retries twice\n- logs every call"),
      card("card-plain", 320, 0, "A card without a heading line."),
      card("card-linen-title", 640, 0, "Body under an explicit title.", { linen: { title: "Explicit title", eyebrow: "Edge" } }),
      card("sticky", 960, 0, "Ask about the retry budget", { linen: { kind: "sticky" } }),
      card("shape-rect", 0, 200, "Rect", { linen: { kind: "shape", shape: "rect" } }),
      card("shape-rounded", 320, 200, "Rounded", { linen: { kind: "shape", shape: "rounded" } }),
      card("shape-ellipse", 640, 200, "Ellipse", { linen: { kind: "shape", shape: "ellipse" } }),
      card("shape-diamond", 960, 200, "Decide?", { linen: { kind: "shape", shape: "diamond" } }),
      card("shape-pill", 0, 400, "Pill", { linen: { kind: "shape", shape: "pill" } }),
      card("shape-cylinder", 320, 400, "Store", { linen: { kind: "shape", shape: "cylinder" } }),
      card("shape-hexagon", 640, 400, "Hex", { linen: { kind: "shape", shape: "hexagon" } }),
      card("shape-bad", 960, 400, "Star", { linen: { kind: "shape", shape: "star" } }),
      card("text-title", 0, 600, "Release map", { linen: { kind: "text" }, width: 600, height: 80 }),
      fileNode("image", 0, 720, "assets/diagram.png"),
      fileNode("note", 320, 720, "notes/Plan.md", { subpath: "#Scope" }),
      fileNode("board", 640, 720, "maps/system.canvas"),
      fileNode("page", 960, 720, "pages/report.html"),
      fileNode("other-file", 0, 920, "docs/spec.pdf"),
      { id: "link", type: "link", url: "https://example.com/docs", x: 320, y: 920, width: 280, height: 100, linen: { title: "Docs" } },
      card("kind-bad", 640, 920, "Bubble", { linen: { kind: "bubble" } }),
    ],
    edges: [],
  });

  writeBoard("sections-nested.canvas", {
    nodes: [
      group("outer", 0, 0, 1200, 800, "Platform", { background: "assets/ground.png", backgroundStyle: "ratio", linen: { title: "Platform services" } }),
      group("inner", 40, 80, 520, 680, "Edge"),
      group("inner2", 620, 80, 540, 600, "Core"),
      group("deeper", 60, 300, 480, 400, "Workers"),
      card("c1", 60, 120, "## Gateway\n\nFront door."),
      card("c2", 80, 340, "## Queue worker\n\nDrains jobs."),
      card("c3", 640, 120, "## Ledger\n\nKeeps events."),
      card("loose", 1300, 0, "A card outside every section."),
    ],
    edges: [edge("e1", "c1", "c2"), edge("e2", "c1", "c3", { label: "writes" })],
  });

  const box = (id, x, y) => card(id, x, y, id.toUpperCase(), { width: 200, height: 100 });
  writeBoard("connectors.canvas", {
    nodes: [box("a", 0, 0), box("b", 500, 0), box("c", 0, 400), box("d", 500, 400), box("e", 250, 800)],
    edges: [
      edge("e-works", "a", "b"),
      edge("e-main", "a", "c", { fromSide: "bottom", toSide: "top", linen: { kind: "main" } }),
      edge("e-code", "b", "d", { label: "async", linen: { kind: "code" } }),
      edge("e-plan", "c", "d", { fromEnd: "arrow", toEnd: "arrow", linen: { kind: "plan", route: "elbow" } }),
      edge("e-fail", "d", "e", { toEnd: "none", linen: { kind: "fail", route: "straight" } }),
      edge("e-left", "b", "a", { fromSide: "left", toSide: "right", label: "reply" }),
      edge("e-badside", "a", "d", { fromSide: "middle" }),
      edge("e-badkind", "c", "e", { fromEnd: "dot", linen: { kind: "maybe", route: "zigzag" } }),
    ],
  });

  writeBoard("colours.canvas", {
    nodes: [
      ...["1", "2", "3", "4", "5", "6"].map((c, i) => card("preset-" + c, i * 320, 0, "Preset " + c, { color: c })),
      card("hex", 0, 200, "Hex colour", { color: "#4A6B57" }),
      card("bad-seven", 320, 200, "Not a preset", { color: "7" }),
      card("bad-number", 640, 200, "A number", { color: 12 }),
    ],
    edges: [edge("col-edge", "preset-1", "preset-2", { color: "3" }), edge("hex-edge", "preset-2", "preset-3", { color: "#123456" })],
  });

  const worded = (id, x, y, word) => card(id, x, y, "## " + id + "\n\nState " + word, { linen: { word } });
  writeBoard("words-default.canvas", {
    nodes: [
      worded("w1", 0, 0, "Works"), worded("w2", 320, 0, "Works"), worded("w3", 640, 0, "Works"),
      worded("p1", 0, 200, "Partial"), worded("p2", 320, 200, "Partial"),
      worded("b1", 640, 200, "Broken"), worded("b2", 960, 200, "broken"),
      worded("m1", 0, 400, "Missing"), worded("pl1", 320, 400, "Planned"),
      worded("u1", 640, 400, "Unknown"),
    ],
    edges: [],
  });

  writeBoard("words-custom.canvas", {
    nodes: [
      worded("live1", 0, 0, "Live"), worded("live2", 320, 0, "Live"),
      worded("shaky", 640, 0, "Shaky"), worded("down", 960, 0, "Down"),
      worded("idea", 0, 200, "Idea"), worded("stop", 320, 200, "متوقف"), worded("hot", 640, 200, "Hot"),
    ],
    edges: [],
    linen: {
      words: [
        { word: "Live", shape: "outline", quiet: true, meaning: "Running in production" },
        { word: "Shaky", shape: "threads", meaning: "Works with known gaps" },
        { word: "Down", shape: "rust", meaning: "Failed in the last run" },
        { word: "Idea", shape: "dotted", quiet: true },
        { word: "متوقف", shape: "solid", meaning: "أوقف عمدا" },
        { word: "Hot", shape: "rust", meaning: "Many requests" },
      ],
    },
  });

  writeBoard("words-seven.canvas", {
    nodes: [worded("x1", 0, 0, "One"), worded("x7", 320, 0, "Seven")],
    edges: [],
    linen: {
      words: ["One", "Two", "Three", "Four", "Five", "Six", "Seven"].map((w, i) => ({ word: w, shape: ["outline", "threads", "solid", "dashed", "dotted", "outline"][i % 6] })),
    },
  });

  writeBoard("arabic-mixed.canvas", {
    nodes: [
      card("en1", 0, 0, "## Gateway\n\nRoutes requests."),
      card("en2", 320, 0, "## Ledger\n\nKeeps events."),
      card("ar1", 640, 0, "## البوابة\n\nتوجه الطلبات إلى الخدمة."),
      card("mixed-ltr", 0, 200, "Linen سطر reader"),
      card("mixed-rtl", 320, 200, "سطر Linen قارئ"),
    ],
    edges: [edge("m1", "en1", "ar1")],
  });

  const arCard = (id, x, y, text) => card(id, x, y, text, { width: 280, height: 120 });
  writeBoard("arabic-rtl.canvas", {
    nodes: [
      group("s1", 0, 0, 1000, 400, "الواجهة"),
      arCard("a1", 40, 60, "## البوابة\n\nتوجه الطلبات."),
      arCard("a2", 360, 60, "## الطابور\n\nيرتب المهام."),
      arCard("a3", 680, 60, "## السجل\n\nيحفظ الأحداث."),
      arCard("a4", 680, 220, "## التقارير\n\nتلخص الأسبوع."),
      group("s2", 0, 600, 1000, 300, "النواة"),
      arCard("a5", 360, 660, "## المخزن\n\nيحفظ الملفات."),
    ],
    edges: [edge("r1", "a3", "a2"), edge("r2", "a2", "a1")],
    linen: { dir: "rtl", title: "خريطة النظام" },
  });

  writeBoard("arabic-inferred.canvas", {
    nodes: [card("i1", 0, 0, "## البوابة\n\nتوجه الطلبات."), card("i2", 320, 0, "## السجل\n\nيحفظ الأحداث."), card("i3", 640, 0, "Gateway")],
    edges: [],
  });

  writeBoard("notes-inline.canvas", {
    nodes: [
      card("n1", 0, 0, "## Gateway\n\nFront door.", {
        linen: { word: "Partial", note: { area: "Edge", title: "Why partial", body: "Retries work; **timeouts** do not.", state: "Partial", refs: ["src/gateway.ts:40-52"], fields: { Owner: "Platform", Seen: "2026-10-01" } } },
      }),
      card("n2", 320, 0, "## Ledger", { linen: { note: "just a string" } }),
      card("n3", 640, 0, "## Queue", { linen: { note: { title: "Refs", refs: ["a.md", 7] } } }),
    ],
    edges: [edge("e1", "n1", "n2", { label: "writes", linen: { note: { title: "Edge note", body: "Writes every event." } } })],
  });

  writeBoard("notes-sidecar.canvas", {
    nodes: [card("n1", 0, 0, "## Gateway"), card("n2", 320, 0, "## Ledger")],
    edges: [edge("e1", "n1", "n2")],
  });
  write("notes-sidecar.canvas.notes.json", JSON.stringify({
    n1: { area: "Edge", title: "From the sidecar", body: "Kept beside the board." },
    e1: { title: "Edge from the sidecar" },
    ghost: { title: "No node has this id" },
  }, null, "\t"));

  writeBoard("notes-both.canvas", {
    nodes: [card("n1", 0, 0, "## Gateway", { linen: { note: { title: "In the board" } } }), card("n2", 320, 0, "## Ledger")],
    edges: [],
  });
  write("notes-both.canvas.notes.json", JSON.stringify({ n1: { title: "In the sidecar" }, n2: { title: "Only in the sidecar" } }, null, "\t"));

  writeBoard("tours.canvas", {
    nodes: [card("t1", 0, 0, "## Start"), card("t2", 320, 0, "## Middle"), card("t3", 640, 0, "## End")],
    edges: [edge("te1", "t1", "t2"), edge("te2", "t2", "t3")],
    linen: {
      tours: [
        { title: "The happy path", lead: "From start to end.", steps: [{ nodes: ["t1"], text: "Begin here." }, { nodes: ["t2", "t3"], edges: ["te2"], text: "Then on." }] },
        "not a tour",
      ],
    },
  });

  writeBoard("layouts.canvas", {
    nodes: [
      group("lanes", 0, 0, 1000, 600, "Lanes", { linen: { layout: "lanes" } }),
      card("l1", 40, 60, "Lane card"),
      group("grid", 1100, 0, 1000, 600, "Grid", { linen: { layout: "grid", cols: 3, gap: 24 } }),
      card("g1", 1140, 60, "Grid card"),
      group("stack", 0, 800, 1000, 600, "Stack", { linen: { layout: "stack", gap: 16 } }),
      card("s1", 40, 860, "Stack card"),
      group("layered", 1100, 800, 1000, 600, "Layered", { linen: { layout: "layered" } }),
      card("y1", 1140, 860, "Layered card"),
      group("spiral", 0, 1600, 600, 400, "Spiral", { linen: { layout: "spiral", cols: "three" } }),
      card("bad-layout", 700, 1600, "A card cannot lay out", { linen: { layout: "grid" } }),
    ],
    edges: [],
  });

  writeBoard("node-links.canvas", {
    nodes: [
      card("source", 0, 0, "See [[node-links.canvas#target]] and [[other.canvas#n9]] and [the target](#target)."),
      card("target", 320, 0, "## Target\n\nLinks land here."),
      fileNode("note-sub", 640, 0, "notes/Plan.md", { subpath: "#Scope" }),
      fileNode("board-sub", 960, 0, "maps/system.canvas", { subpath: "#gateway" }),
    ],
    edges: [edge("ln1", "source", "target")],
  });

  // ---------- invalid files ----------
  write("invalid-not-json.canvas", [
    "{",
    '\t"nodes":[',
    '\t\t{"id":"a","type":"text","text":"A","x":0,"y":0,"width":200,"height":100}',
    '\t\t{"id":"b","type":"text","text":"B","x":300,"y":0,"width":200,"height":100}',
    "\t],",
    '\t"edges":[]',
    "}",
  ].join("\n"));
  write("invalid-root.canvas", '[{"id":"a","type":"text","text":"A","x":0,"y":0,"width":200,"height":100}]');
  write("invalid-nodes-object.canvas", '{\n\t"nodes":{"a":1},\n\t"edges":[]\n}');
  write("empty.canvas", "");
  write("empty-object.canvas", "{}");

  writeBoard("invalid-no-position.canvas", {
    nodes: [
      card("ok1", 0, 0, "Placed"),
      { id: "nopos", type: "text", text: "No x", y: 0, width: 200, height: 100 },
      { id: "nosize", type: "text", text: "No width", x: 0, y: 200, height: 100 },
      card("zero", 320, 200, "Zero width", { width: 0 }),
      { id: "strpos", type: "text", text: "x as text", x: "10", y: 400, width: 200, height: 100 },
      card("frac", 640, 0.5, "Half a pixel"),
    ],
    edges: [edge("to-unplaced", "ok1", "nopos")],
  });

  writeBoard("invalid-ids.canvas", {
    nodes: [
      { type: "text", text: "No id", x: 0, y: 0, width: 200, height: 100 },
      card("", 320, 0, "Empty id"),
      card("a", 0, 200, "First a"),
      card("a", 320, 200, "Second a"),
      card("b", 640, 200, "B"),
    ],
    edges: [edge("dup", "a", "b"), edge("dup", "b", "a")],
  });

  writeBoard("invalid-unknown-type.canvas", {
    nodes: [
      { id: "sticker", type: "sticker", x: 0, y: 0, width: 200, height: 100 },
      { id: "typeless", text: "No type", x: 320, y: 0, width: 200, height: 100 },
      card("fine", 0, 200, "Fine"),
    ],
    edges: [edge("to-sticker", "fine", "sticker")],
  });

  writeBoard("invalid-dangling.canvas", {
    nodes: [card("a", 0, 0, "A"), card("b", 320, 0, "B")],
    edges: [edge("to-ghost", "a", "ghost"), edge("from-ghost", "ghost", "b"), edge("ghosts", "ghost1", "ghost2"), edge("fine", "a", "b")],
  });

  write("invalid-shapes.canvas", obsidian({
    nodes: [
      null,
      42,
      "card",
      card("valid", 0, 0, "Valid"),
      { id: "numtext", type: "text", text: 12, x: 320, y: 0, width: 200, height: 100 },
      card("badlinen", 640, 0, "Linen as text", { linen: "card" }),
      card("valid2", 960, 0, "Valid too"),
    ],
    edges: [
      { fromNode: "valid", toNode: "valid2" },
      { id: "e-bad-from", fromNode: 5, toNode: "valid" },
      edge("e-ok", "valid", "valid2"),
    ],
  }));

  // A 70 KB node (BRD-20 caps a node at 64 KB).
  const para = "This sentence repeats to make one very large card for the size limit test. ";
  let big = "## Huge card\n\n";
  while (big.length < 70 * 1024) big += para;
  writeBoard("invalid-big-node.canvas", { nodes: [card("huge", 0, 0, big), card("small", 320, 0, "Small")], edges: [] });

  // 2,001 nodes (BRD-20 draws up to 2,000).
  const many = [];
  for (let i = 0; i < 2001; i++) many.push(card("n" + i, (i % 50) * 220, Math.floor(i / 50) * 120, "Card " + i, { width: 200, height: 100 }));
  writeBoard("invalid-2001-nodes.canvas", { nodes: many, edges: [] });
}

// ---------- big boards shaped like an agent's readiness map ----------
function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const TITLES = ["Gateway", "Ledger", "Queue worker", "Search index", "Auth service", "Billing", "Notifier", "Scheduler", "Exporter", "Importer",
  "Audit log", "Rate limiter", "Cache", "Config store", "Feature flags", "Reports", "Mailer", "Uploader", "Thumbnailer", "Webhooks",
  "Admin panel", "Sync engine", "Backup job", "Metrics", "Tracing", "Alerting", "Sessions", "Profiles", "Payments", "Inventory"];
const PHRASES = ["Routes requests to the core service.", "Retries twice, then gives up and logs the failure.", "Writes every event to the ledger.",
  "Reads its settings from the config store at start.", "Has **no tests** for the timeout path.", "Runs nightly at `02:00`.",
  "Owned by the platform team.", "Seen working in the last demo.", "Exists in code; not seen running.", "Planned for the next release.",
  "Depends on the cache being warm.", "Drops messages over 1 MB.", "Logs are kept for 30 days.", "- reads from the queue\n- writes to the index",
  "Uses the shared database pool.", "Fails when the upstream is slow."];
const AR_TITLES = ["البوابة", "السجل", "الطابور", "الفهرس", "المصادقة", "الفوترة", "التنبيهات", "المجدول", "التصدير", "الاستيراد"];
const AR_PHRASES = ["توجه الطلبات إلى الخدمة الأساسية.", "تعيد المحاولة مرتين ثم تسجل الخطأ.", "تكتب كل حدث في السجل.", "تعمل كل ليلة.",
  "لا توجد اختبارات لهذا المسار.", "مخطط لها في الإصدار القادم."];
const WORD_POOL = [["Works", 50], ["Partial", 20], ["Broken", 8], ["Missing", 10], ["Planned", 12]];

function bigBoard(name, sectionCount, perRow, cardsPerSection, edgeTarget, seed) {
  const r = rng(seed);
  const pick = (arr) => arr[Math.floor(r() * arr.length)];
  const pickWord = () => {
    let x = r() * 100;
    for (const [w, p] of WORD_POOL) { if ((x -= p) < 0) return w; }
    return "Works";
  };
  const nodes = [], cards = [], notes = {};
  const CW = 300, GAP = 24, PAD = 40, TOP = 60, ROWGAP = 180;
  let y = 0, n = 0;
  const sections = [];
  for (let s = 0; s < sectionCount; s += perRow) {
    let rowHeight = 0;
    const rowSections = [];
    for (let c = 0; c < perRow && s + c < sectionCount; c++) {
      const si = s + c;
      const x = c * (3 * CW + 2 * GAP + 2 * PAD + 120);
      const sec = { id: "sec-" + si, list: [] };
      let cy = y + TOP;
      for (let row = 0; row * 3 < cardsPerSection; row++) {
        let rowH = 0;
        for (let col = 0; col < 3 && row * 3 + col < cardsPerSection; col++) {
          const arabic = n % 5 === 4;
          const title = arabic ? pick(AR_TITLES) : pick(TITLES) + " " + (n + 1);
          const count = 1 + Math.floor(r() * 4);
          const body = Array.from({ length: count }, () => (arabic ? pick(AR_PHRASES) : pick(PHRASES))).join(arabic ? " " : "\n\n");
          const h = Math.min(320, 84 + Math.ceil(body.length / 34) * 22);
          const id = "card-" + n;
          const node = { id, type: "text", text: "## " + title + "\n\n" + body, x: x + PAD + col * (CW + GAP), y: cy, width: CW, height: h, linen: { word: pickWord() } };
          if (n % 11 === 3) node.linen.note = { area: "Section " + (si + 1), title: "Evidence for " + title, body: "Checked in the last run. " + pick(PHRASES), refs: ["src/service-" + (n % 17) + ".ts:" + (10 + (n % 90))] };
          else if (n % 7 === 0) notes[id] = { area: "Section " + (si + 1), title: "Why " + node.linen.word, body: pick(PHRASES), refs: ["docs/notes-" + (n % 13) + ".md"] };
          cards.push(node);
          sec.list.push(node);
          rowH = Math.max(rowH, h);
          n++;
        }
        cy += rowH + GAP;
      }
      const secH = cy - y + PAD - GAP;
      sec.node = { id: sec.id, type: "group", label: "Area " + (si + 1), x, y, width: 3 * CW + 2 * GAP + 2 * PAD, height: secH, linen: { title: "Area " + (si + 1) + " services" } };
      rowHeight = Math.max(rowHeight, secH);
      rowSections.push(sec);
    }
    for (const sec of rowSections) sections.push(sec);
    y += rowHeight + ROWGAP;
  }
  for (const sec of sections) nodes.push(sec.node);
  for (const c of cards) nodes.push(c);

  // Edge pool: down a column and across a row inside each section, plus a few between neighbouring sections.
  const pool = [];
  sections.forEach((sec, si) => {
    const L = sec.list;
    for (let k = 0; k + 3 < L.length; k++) pool.push([L[k], L[k + 3]]);
    for (let k = 0; k + 1 < L.length; k++) if (k % 3 !== 2) pool.push([L[k], L[k + 1]]);
    const next = sections[(si + 1) % sections.length].list;
    for (let k = 0; k < 5; k++) pool.push([pick(L), pick(next)]);
  });
  for (let i = pool.length - 1; i > 0; i--) { const j = Math.floor(r() * (i + 1)); [pool[i], pool[j]] = [pool[j], pool[i]]; }
  const side = (a, b) => {
    const ax = a.x + a.width / 2, ay = a.y + a.height / 2, bx = b.x + b.width / 2, by = b.y + b.height / 2;
    const ang = Math.atan2(by - ay, bx - ax), o = Math.atan2(a.height, a.width);
    return ang > -o && ang <= o ? "right" : ang > o && ang <= Math.PI - o ? "bottom" : ang > Math.PI - o || ang <= -(Math.PI - o) ? "left" : "top";
  };
  const kinds = ["works", "works", "works", "main", "code", "plan", "fail"];
  const edges = pool.slice(0, edgeTarget).map(([a, b], i) => {
    const e = { id: "edge-" + i, fromNode: a.id, toNode: b.id };
    if (i % 2 === 0) { e.fromSide = side(a, b); e.toSide = side(b, a); }
    if (i % 9 === 0) e.label = pick(["reads", "writes", "calls", "feeds"]);
    const k = kinds[i % kinds.length];
    if (k !== "works") e.linen = { kind: k };
    return e;
  });
  writeBoard(name + ".canvas", { nodes, edges });
  write(name + ".canvas.notes.json", JSON.stringify(notes, null, "\t"));
  return { nodes: nodes.length, edges: edges.length };
}

// 2,000 concentric sections with 700-character labels and 3,000 edges between them: the deepest nesting BRD-20
// allows, for the parent search and depth (Codex review of the model, finding 13).
function nestedBoard() {
  const label = (i) => ("Section " + i + " ").padEnd(700, "nested section label ");
  const nodes = [];
  for (let i = 0; i < 2000; i++) nodes.push({ id: "g" + i, type: "group", label: label(i), x: -i * 25, y: -i * 25, width: 100 + i * 50, height: 100 + i * 50 });
  const edges = [];
  for (let i = 0; i + 1 < 2000; i++) edges.push({ id: "c" + i, fromNode: "g" + i, toNode: "g" + (i + 1) });
  for (let i = 0; edges.length < 3000; i++) edges.push({ id: "s" + i, fromNode: "g" + i, toNode: "g" + (i + 2) });
  writeBoard("nested-2000.canvas", { nodes, edges });
}

if (!bigOnly) fixtures();
nestedBoard();
const s500 = bigBoard("big-500", 10, 5, 49, 700, 500);
const s2000 = bigBoard("big-2000", 40, 8, 49, 3000, 2000);
if (require.main === module) console.log("fixtures written; big-500:", s500, "big-2000:", s2000);
module.exports = { obsidian, rng };
