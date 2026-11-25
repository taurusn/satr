// Boards in notes (BRD-19, BLK-8) in the page, as the app sends them: `board` is a board file's text. The body of an
// async function; returns [{name, pass, detail}]. Leaves the last note loaded for the host's PDF check.
const out = [];
const check = (name, pass, detail) => out.push({ name, pass: !!pass, detail: String(detail) });
const raf = () => new Promise((r) => { let done = false; const go = () => { if (!done) { done = true; r(); } }; requestAnimationFrame(go); setTimeout(go, 60); });
let seq = 0;
async function note(text, boards) {
  seq += 1;
  await window.linen.receive({ type: "load", docId: "n" + seq, name: "note.md", path: "/tmp/note.md", text, plain: false, version: seq, meta: {}, boards });
}
const ok = (text) => ({ status: "ok", text, name: "map.canvas", path: "/tmp/map.canvas" });
const doc = () => document.getElementById("doc");

// 1. The frame's height is known when the note is drawn: the same before and after the next frames
await note("# A note\n\nBefore.\n\n![[map.canvas]]\n\nAfter.\n", { "wiki:map.canvas": ok(board) });
const fig = doc().querySelector("figure.board-embed");
const frame = fig && fig.querySelector(".be-frame");
const h0 = frame ? frame.getBoundingClientRect().height : -1, after0 = doc().textContent.indexOf("After.");
await raf(); await raf();
const h1 = frame ? frame.getBoundingClientRect().height : -1;
const svg = fig && fig.querySelector("svg.bsvg");
check("an embedded board draws in the column at a height known before the first frame (no jump)", fig && svg && h0 > 100 && Math.abs(h0 - h1) < 0.5 && after0 > 0, `height ${h0} then ${h1}`);
check("the frame is the column's width, its height the board's shape (at most 600 px)", frame && Math.abs(frame.getBoundingClientRect().width / h1 - Number(fig.dataset.view.split(" ")[2]) / Number(fig.dataset.view.split(" ")[3])) < 0.05 || h1 >= 599, `${frame && frame.getBoundingClientRect().width} x ${h1}`);

// 2. Static until clicked, then pan and zoom; Esc puts it back
const vb0 = svg.getAttribute("viewBox");
frame.dispatchEvent(new MouseEvent("click", { bubbles: true, clientX: 20, clientY: 20 }));
const live = fig.classList.contains("live");
const r = frame.getBoundingClientRect();
frame.dispatchEvent(new WheelEvent("wheel", { bubbles: true, cancelable: true, ctrlKey: true, deltaY: -40, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2 }));
const vbZoom = svg.getAttribute("viewBox");
frame.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, button: 0, pointerId: 3, clientX: r.left + 50, clientY: r.top + 50 }));
frame.dispatchEvent(new PointerEvent("pointermove", { bubbles: true, pointerId: 3, clientX: r.left + 90, clientY: r.top + 70 }));
frame.dispatchEvent(new PointerEvent("pointerup", { bubbles: true, pointerId: 3 }));
const vbPan = svg.getAttribute("viewBox");
document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
check("a click makes it live: ⌘-scroll zooms, a drag pans, Esc puts it back", live && vbZoom !== vb0 && vbPan !== vbZoom && svg.getAttribute("viewBox") === vb0 && !fig.classList.contains("live"), `${vb0} -> ${vbZoom} -> ${vbPan}`);
const open = fig.querySelector(".be-open");
if (open) open.click();

// 3. One section; a missing board, a missing section and a bad inline board show the link card with the reason
await note("![[map.canvas#Nightly|Just the night run]]\n\n![[map.canvas#Nowhere]]\n\n![[ghost.canvas]]\n\n```board\n{nope\n```\n\n```board\n" + board + "\n```\n", { "wiki:map.canvas": ok(board), "wiki:ghost.canvas": { status: "missing" } });
const figs = [...doc().querySelectorAll("figure.board-embed")], cards = [...doc().querySelectorAll(".board-card")];
check("one section draws alone, with its caption", figs[0] && figs[0].querySelector("figcaption").textContent === "Just the night run" && figs[0].querySelector('g.bc[data-id="import"]') && !figs[0].querySelector('g.bc[data-id="form"]'), figs.length);
check("missing board, missing section and a bad inline board each show the link card and why", cards.length === 3 && /No section called/.test(cards[0].textContent) && /Missing/.test(cards[1].textContent) && cards[1].classList.contains("wl") && /JSON/.test(cards[2].textContent), cards.map((c) => c.textContent).join(" | "));
check("a board fence draws inline", figs.length === 2 && !figs[1].querySelector(".be-open"), figs.length);

// 4. touches: hovering a row lights those boxes in the board above; the cell reads as their names
await note("![[map.canvas]]\n\n| Step | Boxes |\n|---|---|\n| One | touches: [form, queue] |\n| Two | touches: [export] |\n", { "wiki:map.canvas": ok(board) });
const rows = [...doc().querySelectorAll("tr[data-touches]")];
const f2 = doc().querySelector("figure.board-embed");
rows[0] && rows[0].dispatchEvent(new MouseEvent("mouseenter"));
const lit = f2 ? [...f2.querySelectorAll("g.bc.lit")].map((g) => g.dataset.id).sort().join(",") : "";
const dim = f2 && f2.classList.contains("touching");
rows[0] && rows[0].dispatchEvent(new MouseEvent("mouseleave"));
check("a touches row lights its boxes in the board above, and the cell names them", lit === "form,queue" && dim && !f2.classList.contains("touching") && rows[0].querySelector("td.touches").textContent === "Request form, Queue", `lit ${lit}; cell "${rows[0] && rows[0].querySelector("td.touches").textContent}"`);

// 5. An Arabic note: the frame takes the note's direction
await note("# ملاحظة\n\nهذه اللوحة تشرح كيف تعمل الخدمة من البداية إلى النهاية.\n\n![[map.canvas]]\n", { "wiki:map.canvas": ok(board) });
const f3 = doc().querySelector("figure.board-embed");
check("in an Arabic note the frame is right to left (buttons and caption mirrored)", f3 && f3.getAttribute("dir") === "rtl", f3 && f3.getAttribute("dir"));

// leave a plain note with one board for the host's PDF check
await note("# Print\n\n![[map.canvas]]\n", { "wiki:map.canvas": ok(board) });
await raf();
return out;
