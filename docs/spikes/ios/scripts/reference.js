// The renderer's own problem lists computed on the Mac in node (Renderer/board-model.js and Renderer/blocks.js, read
// only), in the same text form the spike app's probe writes, then compared with a fixtures.json from the simulator or
// the iPhone. Equal lists mean the phone's renderer reports exactly the problems the fixture was written to have.
//   node scripts/reference.js <fixtures.json>
const fs = require("fs"), path = require("path"), vm = require("vm");
const ROOT = path.resolve(__dirname, "../../../..");
for (const f of ["Renderer/board-model.js", "Renderer/blocks.js"]) vm.runInThisContext(fs.readFileSync(path.join(ROOT, f), "utf8"), { filename: f });
const FIX = path.join(ROOT, "Tests/Fixtures");
const got = JSON.parse(fs.readFileSync(process.argv[2], "utf8")).results;
let same = 0, differ = 0;
const clean = [];
for (const r of got) {
  const file = path.join(FIX, r.file);
  const text = fs.readFileSync(file, "utf8");
  let sidecar = null;
  try { sidecar = fs.readFileSync(file + ".notes.json", "utf8"); } catch (_) { /* none */ }
  const p = r.probe || {};
  let want, have;
  if (r.kind === "board") {
    const m = globalThis.LinenCanvas.parse(text, { sidecarText: sidecar });
    want = { problems: (m.problems || []).map((x) => `${x.severity || ""} ${x.path || ""}: ${x.message}`), fatal: m.fatal ? m.fatal.reason : null };
    have = { problems: p.modelProblems || [], fatal: p.modelFatal ? p.modelFatal.reason : null };
    // What the page holds for the loaded board must equal the model's list (a fatal board holds none).
    if (!m.fatal && JSON.stringify(p.boardProblems || []) !== JSON.stringify(want.problems)) have.boardHeld = p.boardProblems;
  } else if (r.file.endsWith(".txt")) {
    want = { check: [] }; have = { check: p.check || [] };
  } else {
    want = { check: globalThis.LinenBlocks.check(text, sidecar).map((x) => `${x.severity} line ${x.line}: ${x.message}`) };
    have = { check: p.check || [] };
  }
  const ok = JSON.stringify(want) === JSON.stringify(have);
  ok ? same++ : differ++;
  const n = (want.problems || want.check || []).length + (want.fatal ? 1 : 0);
  if (!n && !(p.failed || []).length) clean.push(r.file);
  console.log(`${ok ? "SAME  " : "DIFFER"} ${r.file}: ${n} problem(s) by design${(p.failed || []).length ? `, ${p.failed.length} render-failed block(s)` : ""}`);
  if (!ok) console.log("   want " + JSON.stringify(want).slice(0, 400) + "\n   have " + JSON.stringify(have).slice(0, 400));
}
console.log(`\n${same} same, ${differ} differ. Files with no problems by design (${clean.length}): ${clean.join(", ")}`);
