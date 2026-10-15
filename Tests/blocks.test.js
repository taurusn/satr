// Tests for Renderer/blocks.js's pure half: the YAML subset and check() (what `linen check` runs on notes).
// Run: node Tests/blocks.test.js   (the DOM half is tested in the real renderer by Tests/Harness/blocks-host.swift)
"use strict";
const fs = require("fs");
const path = require("path");
require(path.join(__dirname, "../Renderer/blocks.js"));
const B = globalThis.LinenBlocks;

let pass = 0, fail = 0;
const ok = (name, cond, detail) => { if (cond) pass++; else { fail++; console.log(`FAIL  ${name}${detail === undefined ? "" : ": " + JSON.stringify(detail)}`); } };
const parse = (s) => { try { return B.parseYAML(s); } catch (e) { return { error: e.message, line: e.line }; } };
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);

// ---------- YAML ----------
ok("block map with scalars", eq(parse("a: 1\nb: two\nc: true\nd: null\ne: \"3\""), { a: 1, b: "two", c: true, d: null, e: "3" }));
ok("flow list", eq(parse("items: [Draft, Review, \"a, b\"]"), { items: ["Draft", "Review", "a, b"] }));
ok("flow maps in a block list", eq(parse("items:\n  - {label: A, value: \"1\"}\n  - {label: B c, value: 2}"), { items: [{ label: "A", value: "1" }, { label: "B c", value: 2 }] }));
ok("block maps in a list", eq(parse("items:\n  - label: A\n    value: 1\n  - label: B\n    value: 2"), { items: [{ label: "A", value: 1 }, { label: "B", value: 2 }] }));
ok("list at the key's indent", eq(parse("items:\n- a\n- b"), { items: ["a", "b"] }));
ok("nested maps", eq(parse("linen:\n  layout: wide\n  words:\n    - {word: Works, quiet: true}"), { linen: { layout: "wide", words: [{ word: "Works", quiet: true }] } }));
ok("literal and folded scalars (clip keeps one newline, as YAML does)", eq(parse("a: |\n  one\n  two\nb: >\n  three\n  four"), { a: "one\ntwo\n", b: "three four\n" }));
ok("comments and colons in values", eq(parse("# head\na: x # note\nb: \"#1\"\nc: 10:30\nd: https://x.test/a"), { a: "x", b: "#1", c: "10:30", d: "https://x.test/a" }));
ok("a wiki link stays a value", eq(parse("link: [[Intake plan]]\nitems:\n  - {link: [[A note]], t: x}"), { link: "[[Intake plan]]", items: [{ link: "[[A note]]", t: "x" }] }));
ok("Arabic keys and values", eq(parse("الحالة: يعمل\nitems: [مسودة, نشر]"), { "الحالة": "يعمل", items: ["مسودة", "نشر"] }));
ok("escapes in double quotes", eq(parse('a: "x\\"y\\nz"'), { a: 'x"y\nz' }));
ok("single quotes double up", eq(parse("a: 'it''s'"), { a: "it's" }));
ok("an unclosed flow list names its line", eq(parse("a: 1\nitems: [a, b"), { error: 'expected "," or "]"', line: 2 }));
ok("an unclosed flow map names its line", parse("items:\n  - {label: x\n").line === 2);
ok("bad indentation names its line", parse("a: 1\n   b: 2").line === 2);
ok("a duplicate key is an error", /twice/.test(parse("a: 1\na: 2").error || ""));
ok("empty text is null", parse("") === null && parse("\n# only a comment\n") === null);

// ---------- check() ----------
const lines = (problems) => problems.map((p) => `${p.severity[0]}${p.line}`);
const good = fs.readFileSync(path.join(__dirname, "Fixtures/blocks/blocks.md"), "utf8");
const goodSide = fs.readFileSync(path.join(__dirname, "Fixtures/blocks/blocks.md.notes.json"), "utf8");
ok("the complete fixture checks clean with its notes", B.check(good, goodSide).length === 0, B.check(good, goodSide));
ok("the Arabic fixture checks clean", B.check(fs.readFileSync(path.join(__dirname, "Fixtures/blocks/arabic.md"), "utf8")).length === 0, B.check(fs.readFileSync(path.join(__dirname, "Fixtures/blocks/arabic.md"), "utf8")));
for (const f of ["wide.md", "sheet.md"]) ok(`${f} checks clean`, B.check(fs.readFileSync(path.join(__dirname, "Fixtures/blocks", f), "utf8")).length === 0);
const broken = B.check(fs.readFileSync(path.join(__dirname, "Fixtures/blocks/broken.md"), "utf8"));
const msgs = broken.map((p) => p.message).join(" | ");
ok("broken: a layout that does not exist", /layout must be read, wide or sheet/.test(msgs));
ok("broken: seven words in the list", /7 words; a note has at most six/.test(msgs));
ok("broken: the YAML error at the file's line", broken.some((p) => p.line === 20 && p.severity === "error" && /^tiles:/.test(p.message)), broken);
ok("broken: an unknown block key is a warning", broken.some((p) => p.severity === "warning" && /colour is not a key/.test(p.message)));
ok("broken: a tone that does not exist", /tone must be one of/.test(msgs));
ok("broken: a count that is not a number", /needs a number count/.test(msgs));
ok("broken: a word nobody listed", /Eight is not one of this note's words/.test(msgs));
ok("broken: a rust word whose meaning says nothing of failure", /Three is rust/.test(msgs));
ok("a rust word that means failure is fine", B.check("---\nlinen:\n  words:\n    - {word: Down, shape: rust, meaning: The service fails}\n---\n").length === 0);
ok("an unclosed block fence", lines(B.check("```tiles\nitems: []\n")).includes("e1"));
ok("notes: ids with no note and notes nothing opens", eq(B.check("See :note[x]{#n-1}.\n", '{"n-2": "z"}').map((p) => p.message), ["the notes file has n-2, which nothing in this note opens", "no note called n-1 in the notes file"]));
ok("notes: a notes file that is not JSON", /not JSON/.test(B.check("x", "{oops").map((p) => p.message).join()));
ok("code fences of other languages are left alone", B.check("```js\nitems: [\n```\n").length === 0);
ok("steps level needs numbers", /needs a number value/.test(B.check("```steps\nkind: level\nvalue: x\nof: 5\n```\n").map((p) => p.message).join()));

// ---------- regressions from Codex's blocks review (docs/reviews/m9-blocks-codex.md), each its failing case ----------
const msgsOf = (src, side) => B.check(src, side).map((p) => `${p.severity[0]}${p.line} ${p.message}`);
// 4. NOTE-2: absent sidecar, duplicates, prototype-named ids, a list for a sidecar.
ok("R4 a :note id with no notes file is reported", msgsOf("See :note[x]{#n}.").some((m) => /no note called n: this note has no notes file/.test(m)), msgsOf("See :note[x]{#n}."));
ok("R4 a note in the file and in the sidecar is an error", msgsOf("Text[^a]\n\n[^a]: local\n", '{"a":"sidecar"}').some((m) => /^e3 a has a note here and in the notes file/.test(m)), msgsOf("Text[^a]\n\n[^a]: local\n", '{"a":"sidecar"}'));
ok("R4 a prototype name is not a note", msgsOf("See :note[x]{#toString}.", "{}").some((m) => /no note called toString/.test(m)));
ok("R4 a list is not a notes file", msgsOf("x", "[]").some((m) => /must be an object/.test(m)));
// 6. Hostile YAML: deep nesting and size end as problems, never as a crash.
const deepFlow = "items: " + "{x: ".repeat(10000) + "1" + "}".repeat(10000);
let crashed = null; let deepProblems = [];
try { deepProblems = B.check("```tiles\n" + deepFlow + "\n```\n"); } catch (e) { crashed = e.message; }
ok("R6 10,000 nested flow maps give a problem, not a crash", !crashed && deepProblems.some((p) => /nested more than 32 levels/.test(p.message)), crashed || deepProblems);
const deepBlock = "items:\n" + Array.from({ length: 200 }, (_, i) => " ".repeat(2 * i + 2) + "- a:").join("\n");
crashed = null;
try { deepProblems = B.check("```tiles\n" + deepBlock + "\n```\n"); } catch (e) { crashed = e.message; }
ok("R6 200 nested block lists give a problem, not a crash", !crashed && deepProblems.some((p) => /nested more than 32 levels/.test(p.message)), crashed || deepProblems);
ok("R6 more than 64 KB in a block is a problem", /more than 64 KB/.test(parse("a: " + "x".repeat(70000)).error || ""));
ok("R6 anchors and aliases are refused, not half-read", /anchors, aliases/.test(parse("a: &x 1\nb: *x").error || ""));
// 7. Plain values continue on more-indented lines; chomping.
ok("R7 a long body continues on the next lines", eq(parse("items:\n  - title: A\n    body: This is a long\n      Markdown paragraph.\n  - title: B"), { items: [{ title: "A", body: "This is a long Markdown paragraph." }, { title: "B" }] }));
ok("R7 chomping: |+ keeps the last newline, |- strips it", eq(parse("a: |+\n  x\nb: |-\n  y"), { a: "x\n", b: "y" }));
ok("R7 escapes: \\t, \\\\ and \\x", eq(parse('a: "1\\t2\\\\3\\x41"'), { a: "1\t2\\3A" }));
// 8. check() and the renderer use one validator: what checks clean renders, and what renders checks clean.
const v = (lang, y) => B.validate(lang, B.parseYAML(y), B.words());
ok("R8 tiles size huge is an error", v("tiles", "size: huge\nitems:\n  - {value: 1}").errors.some((e) => /size must be stat or fact/.test(e.message)));
ok("R8 a bar item without a word is an error", v("bar", "items: [{count: 99}]").errors.some((e) => /needs a word/.test(e.message)));
ok("R8 level 13 of 20 is an error, never drawn as 12 of 12", v("steps", "kind: level\nvalue: 13\nof: 20").errors.some((e) => /at most 12/.test(e.message)));
ok("R8 a level past its of is an error", v("steps", "kind: level\nvalue: 5\nof: 4").errors.some((e) => /outside 0 to 4/.test(e.message)));
ok("R8 a scalar cards item is an error in both", v("cards", "items: [just text]").errors.some((e) => /must be a map/.test(e.message)) && msgsOf("```cards\nitems: [just text]\n```\n").some((m) => /^e2 cards: item 1 must be a map/.test(m)));
ok("R8 a count above its of is an error", v("steps", "kind: count\nvalue: 40\nof: 37").errors.length === 1);
ok("R8 cols out of range is an error", v("cards", "cols: 9\nitems: [{title: A}]").errors.some((e) => /cols must be a whole number from 1 to 4/.test(e.message)));
ok("R8 current past the steps is an error", v("steps", "items: [a, b]\ncurrent: 3").errors.some((e) => /current must be/.test(e.message)));
// 9. A one-word inline note is the note's text: no warning; an id-looking note missing from the sidecar warns.
ok("R9 note: Offline is inline text, not a missing id", msgsOf("```tiles\nitems:\n  - {label: Status, value: 0, note: Offline}\n```\n", "{}").length === 0, msgsOf("```tiles\nitems:\n  - {label: Status, value: 0, note: Offline}\n```\n", "{}"));
ok("R9 note: n-gone (id-like, not in the sidecar) warns that it shows as text", msgsOf("```tiles\nitems:\n  - {label: S, value: 0, note: n-gone}\n```\n", "{}").some((m) => /n-gone is not in the notes file, so it shows as the note's text/.test(m)));
// 10. Syntax the renderer leaves as text (code, comments, escapes) is not checked as syntax.
ok("R10 :w[...] in a code span is not a word", msgsOf("Use `:w[Eight]`.").length === 0, msgsOf("Use `:w[Eight]`."));
ok("R10 :w[...] in a comment is not a word", msgsOf("%% :w[Eight] %%\n").length === 0);
ok("R10 an escaped :w is not a word", msgsOf("\\:w[Eight]").length === 0);
ok("R10 [^ghost] in a code span opens nothing, so its sidecar note is unused", msgsOf("`[^ghost]`", '{"ghost":"body"}').some((m) => /ghost, which nothing in this note opens/.test(m)));
ok("R10 a real :w outside code still counts", msgsOf("`code` and :w[Eight]").some((m) => /Eight is not one/.test(m)));
// 12. Ids in any script.
ok("R12 an Arabic note id resolves", msgsOf("انظر :note[هذا]{#مرحلة}.", '{"مرحلة": "نص"}').length === 0, msgsOf("انظر :note[هذا]{#مرحلة}.", '{"مرحلة": "نص"}'));

// ---------- regressions from Codex's verify pass (docs/reviews/m9-blocks-verify-codex.md) ----------
ok("V7 default chomping clips to one newline; an indentation digit is read", eq(parse("a: |\n  x\n\n\nb: |2\n  y"), { a: "x\n", b: "y\n" }));
ok("V4 a [^ghost] with no definition and no note is reported", msgsOf("Text[^ghost].").some((m) => /\[\^ghost\] opens nothing/.test(m)));
ok("V4 a [^a] with a definition is fine", msgsOf("Text[^a].\n\n[^a]: here\n").length === 0);
ok("V4 a [^a] answered by the sidecar is fine", msgsOf("Text[^a].", '{"a": "there"}').length === 0);
ok("V10 a %% inside a code fence does not hide a real word after it", msgsOf("```\n%%\n```\n\n:w[Eight]\n\n%%\n").some((m) => /Eight is not one/.test(m)));
ok("V10 :w in an indented code block is not a word", msgsOf("Para.\n\n    :w[Eight]\n").length === 0, msgsOf("Para.\n\n    :w[Eight]\n"));
ok("V10 :w in a link target is not a word", msgsOf("[a link](:w[Eight])").length === 0, msgsOf("[a link](:w[Eight])"));

console.log(`blocks tests: ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
