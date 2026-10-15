// Codex M7 review findings, one check each (board-host m7). Runs inside the renderer page; each check builds its own
// board, drives window.linen.receive as the app does, and reads the page's state and the messages it posts.
(async () => {
  const B = window.LinenBoard, S = B._state, X = window.linenInternals;
  const sent = [];
  const realPost = X.post;
  X.post = (m) => { sent.push(m); try { realPost(m); } catch (_) { /* host */ } };
  const recv = (m) => window.linen.receive(m);
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const cmd = (name, extra) => recv(Object.assign({ type: "command", name }, extra || {}));
  const node = (id, x, y, text, extra) => Object.assign({ id, type: "text", text: text || `## ${id}\n\nBody of ${id}.`, x, y, width: 260, height: 120 }, extra || {});
  const grid = (n, prefix) => Array.from({ length: n }, (_, i) => node(`${prefix || "n"}${i}`, (i % 20) * 300, Math.floor(i / 20) * 160));
  const board = (nodes, edges, linen) => JSON.stringify(Object.assign({ nodes, edges: edges || [] }, linen ? { linen } : {}));
  let seq = 0;
  const load = async (text, extra) => { const docId = `d${++seq}`; await recv(Object.assign({ type: "load", kind: "board", docId, name: "t.canvas", path: "/x/t.canvas", refPath: "boards/system/t.canvas", text, sidecar: null, version: 1 }, extra || {})); await sleep(150); return docId; };
  const out = [];
  const check = async (id, name, fn) => {
    try { const r = await fn(); out.push({ id, name, pass: !!(r && r.pass), detail: r && r.detail }); }
    catch (e) { out.push({ id, name, pass: false, detail: `threw ${e && e.message}` }); }
  };

  await check(1, "a board past the limits stays a list even with a remembered Canvas place", async () => {
    await load(board(grid(2001)), { place: { kind: "board", cx: 100, cy: 100, zoom: 1, node: null, mode: "canvas" } });
    const a = S.mode;
    await cmd("toggleList");
    return { pass: a === "list" && S.mode === "list", detail: `after load ${a}, after toggle ${S.mode}` };
  });
  await check(2, "an update for another document or an older version is ignored; messages carry docId", async () => {
    const d = await load(board([node("a", 0, 0)]));
    sent.length = 0;
    await recv({ type: "update", kind: "board", docId: "other", text: board([node("zzz", 0, 0)]), sidecar: null, version: 9 });
    const kept1 = S.board.byId.has("a");
    await recv({ type: "update", kind: "board", docId: d, text: board([node("old", 0, 0)]), sidecar: null, version: 0 });
    const kept2 = S.board.byId.has("a");
    await cmd("setView", { s: 1, tx: 10, ty: 10 });
    await sleep(900);
    const msgs = sent.filter((m) => ["place", "view", "rendered", "baseline"].includes(m.type));
    const withId = msgs.every((m) => m.docId === d);
    return { pass: kept1 && kept2 && msgs.length > 0 && withId, detail: `kept ${kept1}/${kept2}, ${msgs.length} messages, all with docId ${withId}` };
  });
  await check(5, "a pending place or view from a board is not posted after the tab leaves it", async () => {
    await load(board([node("a", 0, 0)]));
    await cmd("setView", { s: 0.9, tx: 40, ty: 40 });
    sent.length = 0;
    await recv({ type: "load", docId: "note1", name: "n.md", path: "/x/n.md", text: "# Note\n\nText.", plain: false, version: 1, meta: {} });
    await sleep(900);
    const stale = sent.filter((m) => (m.type === "place" && m.place && m.place.kind === "board") || m.type === "view");
    return { pass: stale.length === 0, detail: `${stale.length} stale board messages` };
  });
  await check(6, "a board load cancels a note still rendering", async () => {
    const big = Array.from({ length: 400 }, (_, i) => `Paragraph ${i} with some words to lex.\n`).join("\n");
    sent.length = 0;
    recv({ type: "load", docId: "bignote", name: "big.md", path: "/x/big.md", text: big, plain: false, version: 1, meta: {} });
    await sleep(30);
    const d = await load(board([node("a", 0, 0)], [], { title: "The board" }));
    await sleep(3000);
    // the note's continuation would fill the hidden note page and post its own title
    const leaked = document.getElementById("doc").textContent.includes("Paragraph 399");
    return { pass: !leaked && document.documentElement.classList.contains("board-mode"), detail: `note kept rendering after the board loaded: ${leaked}, doc ${d}` };
  });
  await check(8, "an edge-only change is marked", async () => {
    const v1 = board([node("a", 0, 0), node("b", 400, 0)], [{ id: "e", fromNode: "a", toNode: "b" }]);
    await load(v1);
    const base = sent.filter((m) => m.type === "baseline").pop();
    const v2 = board([node("a", 0, 0), node("b", 400, 0)], [{ id: "e", fromNode: "a", toNode: "b", toEnd: "none" }]);
    await load(v2, { baseline: base ? base.hashes : [] });
    const n = (await cmd("view")).changed;
    return { pass: n >= 1, detail: `changed ${n}` };
  });
  await check(9, "acknowledgement needs 3 s on screen at reading zoom (rewritten line, sections)", async () => {
    const v1 = board(grid(12));
    await load(v1);
    const base = sent.filter((m) => m.type === "baseline").pop().hashes;
    const v2 = board(grid(12).map((n) => Object.assign(n, { text: n.text + " changed" })));
    await load(v2, { baseline: base });
    await cmd("zoomTo", { s: 0.1 });
    await recv({ type: "focus", key: true });
    await sleep(3800);
    const stillRewritten = (await cmd("view")).rewritten;
    const g1 = board([{ id: "g", type: "group", label: "Old name", x: -40, y: -40, width: 400, height: 260 }, node("a", 0, 0)]);
    await load(g1);
    const gb = sent.filter((m) => m.type === "baseline").pop().hashes;
    await load(board([{ id: "g", type: "group", label: "New name", x: -40, y: -40, width: 400, height: 260 }, node("a", 0, 0)]), { baseline: gb });
    await cmd("zoomTo", { s: 0.1 });
    await sleep(1200);
    const secStill = S.changed.has("g");
    return { pass: stillRewritten && secStill, detail: `rewritten kept at areas ${stillRewritten}, section mark kept ${secStill}` };
  });
  await check(10, "section names keep 15 px or give way; none scale down mid-gesture", async () => {
    await load(board([{ id: "g", type: "group", label: "A long section name that will not fit", x: 0, y: 0, width: 300, height: 200 }, node("a", 20, 20), { id: "h", type: "group", label: "Next", x: 0, y: 320, width: 300, height: 200 }]));
    await cmd("zoomTo", { s: 0.3 });
    await sleep(100);
    const sizes = [...document.querySelectorAll(".b-slbl b")].map((b) => parseFloat(getComputedStyle(b).fontSize) * S.view.s);
    const small = sizes.filter((x) => x < 14.9);
    document.querySelector(".b-canvas").dispatchEvent(new WheelEvent("wheel", { deltaY: -40, ctrlKey: true, bubbles: true, cancelable: true }));
    const hiddenMid = getComputedStyle(document.querySelector(".b-under")).visibility === "hidden";
    await sleep(300);
    return { pass: small.length === 0 && hiddenMid, detail: `names under 15 px: ${small.map((x) => x.toFixed(1)).join(",")}; DOM names hidden mid-gesture ${hiddenMid}` };
  });
  await check(11, "a manual pan can be undone with Back", async () => {
    await load(board(grid(40)));
    await sleep(200);
    const v0 = JSON.stringify(S.view);
    const c = document.querySelector(".b-canvas");
    c.dispatchEvent(new WheelEvent("wheel", { deltaX: 120, deltaY: 60, bubbles: true, cancelable: true }));
    await sleep(300);
    const moved = JSON.stringify(S.view) !== v0;
    const r = await cmd("back");
    await sleep(600);
    const back = ["s", "tx", "ty"].every((k) => Math.abs(S.view[k] - JSON.parse(v0)[k]) < 0.5);
    return { pass: r === true && moved && back, detail: `back ${r}, pan moved ${moved}, returned to the view before the pan ${back}` };
  });
  await check(12, "a reload holds the nearest box's centre even when the view is in a gap", async () => {
    await load(board([node("a", 0, 0), node("b", 3000, 0)]));
    await cmd("setView", { s: 1, tx: -1100, ty: 200 }); // centre in the gap, no box in view
    const { s: s0, tx, ty } = S.view, cx0 = (S.W / 2 - tx) / s0, cy0 = (S.H / 2 - ty) / s0;
    const near = ["a", "b"].map((id) => S.board.byId.get(id)).sort((p, q) => Math.hypot(p.x + p.w / 2 - cx0, p.y + p.h / 2 - cy0) - Math.hypot(q.x + q.w / 2 - cx0, q.y + q.h / 2 - cy0))[0];
    const before = [(near.x + near.w / 2) * s0 + tx, (near.y + near.h / 2) * s0 + ty];
    // both boxes grow, so the hold must follow the centre, not the corner
    const nb = board([node("a", 0, 0, null, { width: 400, height: 300 }), node("b", 3000, 0, null, { width: 420, height: 320 })]);
    await recv({ type: "update", kind: "board", docId: S.docId, text: nb, sidecar: null, version: 5 });
    await sleep(100);
    const n = S.board.byId.get(near.id);
    const after = [(n.x + n.w / 2) * S.view.s + S.view.tx, (n.y + n.h / 2) * S.view.s + S.view.ty];
    const d = Math.hypot(after[0] - before[0], after[1] - before[1]);
    return { pass: d < 2, detail: `nearest ${near.id}, its centre moved ${d.toFixed(1)} px; view ${s0},${tx},${ty} -> ${JSON.stringify(S.view)} W ${S.W} ver ${S.version}` };
  });
  await check(13, "focus opens a note; a source opens the editor through openReference", async () => {
    await load(board([node("a", 0, 0, null, { linen: { note: { title: "N", body: "B", refs: ["server/a.py:18"] } } }), node("b", 400, 0)]));
    await cmd("goNode", { id: "a", select: true });
    await sleep(50);
    document.querySelector(".b-canvas").dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "Tab", bubbles: true }));
    await sleep(500);
    const opened = !!S.note;
    sent.length = 0;
    const ref = document.querySelector(".b-notecard [data-ref]");
    if (ref) ref.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    const o = sent.find((m) => m.type === "openReference");
    return { pass: opened && !!o && o.path === "server/a.py" && o.line === 18, detail: `note on focus ${opened}, openReference ${JSON.stringify(o)}` };
  });
  await check(14, "a section's background image is requested and drawn", async () => {
    sent.length = 0;
    await load(board([{ id: "g", type: "group", label: "G", x: 0, y: 0, width: 400, height: 300, background: "assets/ground.png", backgroundStyle: "cover" }]));
    await sleep(100);
    const img = S.bgs && S.bgs.get("g");
    const asked = !!(img && /assets\/ground\.png/.test(img.dataset.req || ""));
    return { pass: asked, detail: `asked through the image gate: ${img ? img.dataset.req : "no image"}` };
  });
  await check(15, "a note file node shows its first screen when the app sends it", async () => {
    await load(board([{ id: "f", type: "file", file: "plan.md", x: 0, y: 0, width: 300, height: 200 }]), { previews: { f: "# Plan\n\nThree goals for the quarter." } });
    await cmd("zoomTo", { s: 1 });
    await sleep(200);
    const el = document.querySelector('.b-node[data-id="f"]');
    return { pass: !!el && /Three goals/.test(el.textContent), detail: el ? el.textContent.slice(0, 60) : "not mounted" };
  });
  await check(16, "the outline lists titled nodes and tours", async () => {
    await load(board([{ id: "g", type: "group", label: "G", x: -20, y: -20, width: 700, height: 200 }, node("a", 0, 0, "## Gateway box\n\nBody."), node("b", 300, 0, "## Queue box\n\nBody.")], [], { tours: [{ title: "Walk", steps: [{ nodes: ["a"], text: "Start" }] }] }));
    const txt = document.querySelector(".b-secs").textContent;
    return { pass: txt.includes("Gateway box") && txt.includes("Queue box") && /Walk/.test(txt) && /Start/.test(txt), detail: txt.slice(0, 80) };
  });
  await check(17, "the compact legend is the same control: counts, no flight on choosing, hidden with an overlay rail", async () => {
    await load(board(grid(30).map((n, i) => Object.assign(n, { linen: { word: i % 2 ? "Broken" : "Works" } }))));
    await cmd("outline", { show: false });
    await cmd("zoomTo", { s: 0.2 });
    const z = document.querySelector(".b-zlegend");
    const hasCounts = /\d/.test(z.textContent);
    const v0 = JSON.stringify(S.view);
    const row = z.querySelector('[data-word="Broken"]');
    if (row) row.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    await sleep(500);
    const moved = JSON.stringify(S.view) !== v0;
    await cmd("outline", { show: true, overlay: true });
    const hiddenWithOverlay = z.hidden;
    return { pass: hasCounts && !moved && hiddenWithOverlay, detail: `counts ${hasCounts}, flew ${moved}, hidden with overlay ${hiddenWithOverlay}` };
  });
  await check(18, "an RTL board puts names and threads on the right even for a Latin section name", async () => {
    await load(board([{ id: "g", type: "group", label: "API", x: 0, y: 0, width: 600, height: 300 }, node("a", 20, 40, "نص عربي")], [], { dir: "rtl" }));
    await cmd("zoomTo", { s: 1 });
    const lbl = document.querySelector('.b-slbl[data-id="g"]');
    const card = document.querySelector('.b-node[data-id="a"]');
    return { pass: lbl && lbl.getAttribute("dir") === "rtl" && card && card.getAttribute("dir") === "rtl", detail: `label ${lbl && lbl.getAttribute("dir")}, card ${card && card.getAttribute("dir")}` };
  });
  await check(19, "List view: notes as numbered cards; a node link switches to Canvas", async () => {
    await load(board([node("a", 0, 0, null, { linen: { note: { title: "Why", body: "Because." } } })]));
    await cmd("toggleList");
    const card = document.querySelector(".b-list .b-lnote");
    const isCard = !!card && card.tagName !== "DETAILS" && /1/.test(card.textContent);
    await cmd("goNode", { id: "a", select: true });
    return { pass: isCard && S.mode === "canvas" && S.selected === "a", detail: `note card ${card && card.tagName}, mode ${S.mode}` };
  });
  await check(20, "a malformed image path does not stop the cards mounting", async () => {
    sent.length = 0;
    await load(board(grid(40).map((n) => Object.assign(n, { text: "![x](bad%zz.png)\n\nBody" }))));
    await cmd("zoomTo", { s: 1 });
    await sleep(400);
    const v = await cmd("view");
    // the same path in a note: the note still renders
    await recv({ type: "load", docId: "badnote", name: "bad.md", path: "/x/bad.md", text: "# Bad\n\n![x](bad%zz.png)\n\nAfter the image.", plain: false, version: 1, meta: {} });
    await sleep(400);
    const noteDone = document.getElementById("doc").textContent.includes("After the image.");
    return { pass: v.queue === 0 && !S.pumping && v.mounted > 0 && noteDone, detail: `queue ${v.queue}, pumping ${S.pumping}, mounted ${v.mounted}, note rendered ${noteDone}` };
  });
  await check(21, "removed outlines and seen state stay bounded", async () => {
    await load(board(grid(300, "r0-")));
    for (let k = 1; k <= 5; k++) await recv({ type: "update", kind: "board", docId: S.docId, text: board(grid(300, `r${k}-`)), sidecar: null, version: 10 + k });
    return { pass: S.removed.length <= 500, detail: `removed ${S.removed.length}` };
  });
  await check(22, "the Mermaid budget is per document", async () => {
    if (!X.spendMermaid) return { pass: false, detail: "no budget hooks" };
    X.spendMermaid(50); // a document that used its whole budget
    const q = X.mermaidBudget();
    await load(board([node("a", 0, 0)]));
    const q2 = X.mermaidBudget();
    return { pass: q === 0 && q2 === 50, detail: `budget ${q} after 50 diagrams, ${q2} on the next document` };
  });
  await check(23, "a connector's colour is drawn as a wash under its line", async () => {
    await load(board([node("a", 0, 0), node("b", 400, 0)], [{ id: "e", fromNode: "a", toNode: "b", color: "4" }]));
    return { pass: !!(S.lastEdgeWashes && S.lastEdgeWashes > 0), detail: `washed edges ${S.lastEdgeWashes}` };
  });
  await check(24, "Copy Reference names the sidecar by its full path and needs a selection", async () => {
    await load(board([node("a", 0, 0)]), { sidecar: JSON.stringify({ a: { title: "N" } }) });
    const none = await cmd("copyReference", { refPath: "boards/system/t.canvas" });
    await cmd("goNode", { id: "a", select: true });
    const r = await cmd("copyReference", { refPath: "boards/system/t.canvas" });
    const ok = r && r.text.includes('boards/system/t.canvas.notes.json["a"]');
    return { pass: !none && ok, detail: `no selection -> ${JSON.stringify(none)}; ${r && r.text.split("\n")[1]}` };
  });
  await check(25, "VoiceOver reads mounted boxes in reading order; Read as list is on the canvas", async () => {
    await load(board(grid(30)));
    await cmd("zoomTo", { s: 1 });
    await sleep(300);
    const owns = (document.querySelector(".b-canvas").getAttribute("aria-owns") || "").split(/\s+/).filter(Boolean);
    const ids = owns.map((x) => { const el = document.getElementById(x); return el ? el.dataset.id : null; }).filter(Boolean);
    const order = S.board.order.filter((id) => ids.includes(id));
    const inOrder = ids.length > 1 && ids.join() === order.join();
    const btn = document.querySelector(".b-canvas .b-readlist2");
    return { pass: inOrder && !!btn, detail: `aria-owns ${ids.length} in order ${inOrder}, button ${!!btn}` };
  });
  await check(26, "on a phone a first section too wide for reading zoom opens as a list", async () => {
    const W = S.W;
    S.W = 390;
    const sec = { id: "g", kind: "section", x: 0, y: 0, w: 500, h: 300, placed: true, dir: "ltr" };
    const r = B._test ? B._test.phoneList(sec) : null;
    S.W = W;
    return { pass: r === true, detail: `opens as list ${r}` };
  });

  // ----- second verification (docs/reviews/m7-board-verify2-codex.md) -----
  const IMG = "/Users/hatim/Developer/Satr/Tests/Fixtures/satr-test-image.png"; // 240 x 240
  await check("n3", "an exported Markdown image is measured at its own size, after it loads", async () => {
    await load(board([node("a", 0, 0, `## Pic\n\n![square](${IMG})`, { width: 300, height: 400 })]));
    const d = await cmd("displayList");
    const im = d && d.items.find((i) => i.t === "image");
    return { pass: !!im && im.w > 150 && Math.abs(im.w - im.h) < 2 && im.src === IMG, detail: im ? `${im.w.toFixed(0)} x ${im.h.toFixed(0)}, src ${im.src}` : "no image item" };
  });
  await check("n4", "exporting does not leave image sources behind", async () => {
    const before = X.imgSourceCount ? X.imgSourceCount() : -1;
    for (let k = 0; k < 3; k++) await cmd("displayList");
    const after = X.imgSourceCount ? X.imgSourceCount() : -2;
    return { pass: before >= 0 && after === before, detail: `${before} sources before, ${after} after three exports` };
  });
  await check("n5", "an edge note in the display list carries the connector's midpoint", async () => {
    await load(board([node("a", 0, 0), node("b", 600, 0)], [{ id: "e", fromNode: "a", toNode: "b", label: "calls", linen: { note: { title: "Why", body: "Because." } } }]));
    const d = await cmd("displayList");
    const n = d && d.notes.find((x) => x.id === "e");
    return { pass: !!n && typeof n.x === "number" && typeof n.y === "number" && n.x > 260 && n.x < 600, detail: n ? `x ${n.x}, y ${n.y}` : "no note" };
  });
  await check("9b", "a section whose name gave way is not acknowledged; its List row is", async () => {
    const mk = (label) => board([{ id: "g", type: "group", label, x: 0, y: 0, width: 120, height: 200 }, node("a", 10, 30, null, { width: 100 }), { id: "k", type: "group", label: "K", x: 130, y: 0, width: 120, height: 200 }, { id: "h", type: "group", label: "Above", x: 0, y: -230, width: 120, height: 200 }]);
    await load(mk("A section name far too long for its narrow frame"));
    const base = sent.filter((m) => m.type === "baseline").pop().hashes;
    await load(mk("A different section name far too long for its frame"), { baseline: base });
    await cmd("zoomTo", { s: 1 });
    await recv({ type: "focus", key: true });
    const named = !!document.querySelector('.b-slbl[data-id="g"] b');
    await sleep(3800);
    const keptOnCanvas = S.changed.has("g");
    await cmd("toggleList");
    await sleep(3800);
    const ackedInList = !S.changed.has("g");
    await cmd("toggleList");
    return { pass: !named && keptOnCanvas && ackedInList, detail: `name shown ${named}, mark kept on canvas ${keptOnCanvas}, acknowledged in List ${ackedInList}` };
  });
  await check("22b", "a Mermaid render that finishes after the document changed is dropped; the cache is LRU", async () => {
    if (!X.fill || !X.lruTest) return { pass: false, detail: "hooks missing" };
    const el = document.createElement("div");
    el.className = "mermaid-src"; el.dataset.src = "graph TD; A-->B"; document.body.appendChild(el);
    await X.fill(el); // loads Mermaid for real once
    const real = window.mermaid.render;
    window.mermaid.render = () => new Promise((r) => setTimeout(() => r({ svg: '<svg id="late-one"></svg>' }), 400));
    const el2 = document.createElement("div");
    el2.className = "mermaid-src"; el2.dataset.src = "graph TD; C-->D"; document.body.appendChild(el2);
    const p = X.fill(el2);
    await sleep(60);
    await load(board([node("z", 0, 0)])); // the document changes while it renders
    await p; await sleep(100);
    window.mermaid.render = real;
    const leaked = !!el2.querySelector("#late-one");
    el.remove(); el2.remove();
    const lru = X.lruTest();
    return { pass: !leaked && lru, detail: `late render inserted ${leaked}, LRU keeps a recently used entry ${lru}` };
  });
  await check("2b", "a late update for a board the tab has left does not bring it back", async () => {
    const d = await load(board([node("a", 0, 0)]));
    await recv({ type: "load", docId: "note-after", name: "n.md", path: "/x/n.md", text: "# After\n\nThe note.", plain: false, version: 1, meta: {} });
    await sleep(200);
    await recv({ type: "update", kind: "board", docId: d, text: board([node("a", 0, 0), node("b", 300, 0)]), sidecar: null, version: 9 });
    await sleep(200);
    const back = document.documentElement.classList.contains("board-mode");
    return { pass: !back, detail: `board came back over the note ${back}` };
  });
  await check("13b", "openReference carries the board's docId", async () => {
    await load(board([node("a", 0, 0, null, { linen: { note: { title: "N", body: "B", refs: ["server/a.py:18"] } } })]));
    await cmd("openNote", { id: "a" });
    sent.length = 0;
    const ref = document.querySelector(".b-notecard [data-ref]");
    if (ref) ref.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    const o = sent.find((m) => m.type === "openReference");
    return { pass: !!o && o.docId === S.docId && o.line === 18, detail: JSON.stringify(o) };
  });

  X.post = realPost;
  return out;
})();
