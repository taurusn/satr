## Original 16 findings

1. **Resolved — display-list mismatch.** `origin` is applied to geometry, paths, baselines, sections, and note anchors; text now handles weight/case/tracking/centering/chips/roles; section `name/depth`, serif display, and caller-resolved image paths are supported. Evidence: [DisplayList.swift:138](/Users/hatim/Developer/Satr/Linen/Export/DisplayList.swift:138), [DisplayList.swift:195](/Users/hatim/Developer/Satr/Linen/Export/DisplayList.swift:195), [DisplayList.swift:204](/Users/hatim/Developer/Satr/Linen/Export/DisplayList.swift:204).

2. **Resolved — 9-pt body floor.** Each section uses its smallest role-less body run ≥12 px; a 13.5-px table run now forces scale ≥`9/13.5`. Evidence: [BoardPDF.swift:113](/Users/hatim/Developer/Satr/Linen/Export/BoardPDF.swift:113).

3. **Partly — card-safe cuts.** The threshold was reduced, but clean cuts before 25% of a page are still rejected. With page span 1,000 and a 950-high card at `y=100...1050`, clean cut `98` is rejected and `1000` bisects the card. Accept any progressing zero-crossing; cut only cards taller than a page. Evidence: [BoardPDF.swift:220](/Users/hatim/Developer/Satr/Linen/Export/BoardPDF.swift:220).

4. **Resolved — sources pagination.** Heading, area, body paragraphs, and references all pass through the continuation routine. Evidence: [BoardPDF.swift:452](/Users/hatim/Developer/Satr/Linen/Export/BoardPDF.swift:452).

5. **Partly — image bounds.** Per-file, pixel, and encoded aggregate limits exist, but a data URL is fully decoded before its byte limit is checked, and decoded pixels have no aggregate budget/downsampling. Six highly compressed 10,000×5,000 images can retain roughly 1.2 GB decoded. Preflight base64 length and cap/downsample aggregate decoded pixels. Evidence: [DisplayList.swift:127](/Users/hatim/Developer/Satr/Linen/Export/DisplayList.swift:127), [DisplayList.swift:204](/Users/hatim/Developer/Satr/Linen/Export/DisplayList.swift:204), [BoardPDF.swift:393](/Users/hatim/Developer/Satr/Linen/Export/BoardPDF.swift:393).

6. **Partly — PNG numeric trap.** Non-finite/extreme geometry no longer reaches `Int`, so it does not crash; however `.infinity` produces `.emptyArea`, not the promised `.tooLarge`. Add an explicit invalid-geometry/scale branch before size calculation. Evidence: [BoardPNG.swift:44](/Users/hatim/Developer/Satr/Linen/Export/BoardPNG.swift:44).

7. **Resolved — PDF comments/validation.** Any comment in rewritten dictionaries causes compaction to abort, and replacement now checks every page’s media box, contents, and resources. Evidence: [PDFCompact.swift:128](/Users/hatim/Developer/Satr/Linen/Export/PDFCompact.swift:128), [BoardPDF.swift:170](/Users/hatim/Developer/Satr/Linen/Export/BoardPDF.swift:170).

8. **Partly — compaction memory.** Secondary copies are capped at 64 MB, but `compactInPlace` reads the entire PDF before that cap is consulted. A 500 MB PDF still allocates 500 MB unnecessarily. Stat the file before `Data(contentsOf:)`. Evidence: [PDFCompact.swift:12](/Users/hatim/Developer/Satr/Linen/Export/PDFCompact.swift:12), [BoardPDF.swift:170](/Users/hatim/Developer/Satr/Linen/Export/BoardPDF.swift:170).

9. **Resolved — `prepareForPrint`.** It runs explicitly in `.page` and has a ten-second bound. Evidence: [NotePDF.swift:274](/Users/hatim/Developer/Satr/Linen/Export/NotePDF.swift:274).

10. **Resolved — print-visible `[hidden]` content.** Collection uses computed print visibility and layout boxes rather than rejecting `[hidden]` ancestors. Evidence: [NotePDF.swift:540](/Users/hatim/Developer/Satr/Linen/Export/NotePDF.swift:540).

11. **Not resolved — indivisible figure pagination.** The original 25% guard remains. On A4, a 900-px figure at `y=100...1000` still crosses the ≈979-px cut because its top is before the ≈245-px threshold. Remove the threshold for spans shorter than a page. Evidence: [NotePDF.swift:343](/Users/hatim/Developer/Satr/Linen/Export/NotePDF.swift:343).

12. **Partly — wide content.** Rightward scroll overflow is measured and both dimensions constrain scaling, but this is not a full content-bound calculation. For `position:absolute; left:-1000px; width:2000px`, export still starts at `x=0` and loses the negative half. Measure `minX/maxX` and translate the PDF rectangle by `minX`. Evidence: [NotePDF.swift:185](/Users/hatim/Developer/Satr/Linen/Export/NotePDF.swift:185), [NotePDF.swift:217](/Users/hatim/Developer/Satr/Linen/Export/NotePDF.swift:217), [NotePDF.swift:644](/Users/hatim/Developer/Satr/Linen/Export/NotePDF.swift:644).

13. **Partly — bounded page work.** Image/font waits and layout queries are bounded, and long tokens avoid per-character measurement after 2,000 characters. Characters, produced segments/spans, pages, collector runtime, and `web.pdf` calls remain uncapped. A 30,000,000-px spacer causes roughly 30,000 PDF slices. Add output/page caps and an overall deadline. Evidence: [NotePDF.swift:534](/Users/hatim/Developer/Satr/Linen/Export/NotePDF.swift:534), [NotePDF.swift:548](/Users/hatim/Developer/Satr/Linen/Export/NotePDF.swift:548), [NotePDF.swift:640](/Users/hatim/Developer/Satr/Linen/Export/NotePDF.swift:640).

14. **Resolved — HTML line notes.** Generated source blocks and note numbers are preserved and made visible in the artifact. Evidence: [NoteHTML.swift:158](/Users/hatim/Developer/Satr/Linen/Export/NoteHTML.swift:158).

15. **Resolved — HTML image resolver/MIME injection.** Only `linen-local:` reaches the callback; MIME values must exactly match a fixed image set before interpolation. Evidence: [NoteHTML.swift:50](/Users/hatim/Developer/Satr/Linen/Export/NoteHTML.swift:50).

16. **Resolved — outline nesting.** A heading-level stack now nests each heading below its nearest lower-level predecessor. Evidence: [NotePDF.swift:374](/Users/hatim/Developer/Satr/Linen/Export/NotePDF.swift:374).

## Newly found defects

- **Major — expanded board blocks export incorrectly.** The export scratch card calls `readContent` but omits the screen path’s `expandBlocks`/lazy filling. A card containing a fenced `tiles`, math, or Mermaid block exports its placeholder/source rather than the displayed result. Expand and await lazy rendering before collecting marks. [board.js:2150](/Users/hatim/Developer/Satr/Renderer/board.js:2150).

- **Major — embedded board images use the wrong source and rectangle.** Every descendant `<img>` becomes a full-card image using `n.file`. A text card containing `![x](photo.png)` therefore emits `src:""` and a card-sized missing-image frame. Use the image element’s resolved local path and its actual rectangle. [board.js:2162](/Users/hatim/Developer/Satr/Renderer/board.js:2162).

- **Major — edge notes disappear.** Edges are emitted, but the notes array iterates nodes only. An edge with `linen.note` has neither a source entry nor marker. Include edge notes with an explicit anchor from `edgeGeom(...).mid`. [board.js:2132](/Users/hatim/Developer/Satr/Renderer/board.js:2132), [board.js:2169](/Users/hatim/Developer/Satr/Renderer/board.js:2169).

- **Major — HTML image work has no aggregate limit.** Each image is capped at 25 MB, but count and total bytes are unlimited, and the whole HTML string is rescanned for every distinct source. Seven maximum-size images already produce roughly 233 MB of base64; thousands can exhaust memory quadratically. Apply count/aggregate budgets and replace sources in one pass. [NoteHTML.swift:52](/Users/hatim/Developer/Satr/Linen/Export/NoteHTML.swift:52).

- **Major — concurrent exports can corrupt one another.** `write` mutates a shared `WKWebView` and uses global `window.__linenExport`, with actor reentrancy across awaits. Concurrent reference and normal exports can let the normal export hide text before the reference export snapshots it, producing missing text. Serialize per web view or require a dedicated host per export. [NotePDF.swift:151](/Users/hatim/Developer/Satr/Linen/Export/NotePDF.swift:151), [NotePDF.swift:638](/Users/hatim/Developer/Satr/Linen/Export/NotePDF.swift:638).

- **Major — malformed numeric handoff can trap.** Newly parsed `depth`, note number, and weight use unchecked floating-point-to-`Int` conversion. For example, `depth: 1e100` crashes instead of rejecting the display list. Use range-checked `Int(exactly:)`. [DisplayList.swift:155](/Users/hatim/Developer/Satr/Linen/Export/DisplayList.swift:155), [DisplayList.swift:197](/Users/hatim/Developer/Satr/Linen/Export/DisplayList.swift:197).

No new exported-HTML code-execution or passive network-fetch path was found: the local resolver/MIME gate and restrictive CSP remain effective. [NoteHTML.swift:80](/Users/hatim/Developer/Satr/Linen/Export/NoteHTML.swift:80)

Verdict: **Not ready—9/16 findings are resolved, 6 are partial, 1 remains unfixed, and new board-data-loss, resource-bound, crash, and concurrency defects are ship-blocking.**