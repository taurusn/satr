# Linen 2 boards research

Research lane for the boards part of the Linen 2 PRD (`docs/PRD-2.md`, sections 3, 6.1, 8, 9.1 and 9.2). All pages were read on 2026-10-14 and saved under `raw/boards/` in this folder (paths below are relative to `docs/research/raw/`). Obsidian 1.13.7 was not run: its canvas code was read from the app's own archive, unpacked read-only. ELK.js was measured on this Mac (Apple M4, 16 GB, macOS 26.5.1) in JavaScriptCore, the engine inside WKWebView, and in Node 22 for comparison. Every quote below was checked against the saved text with a script before it went in. Legend for the tables: **Y** the source says yes. **N** the source says no, or the code shows no. **P** partial or with a caveat. **NL** not listed in the saved pages; NL does not mean the app lacks it.

## Two-minute summary

| Question | Answer | Evidence |
|---|---|---|
| 1. Is JSON Canvas 1.0 safe as Linen's file, with a `linen` object at each level? | **Yes.** The spec is silent on unknown fields, but Obsidian 1.13.7 keeps unknown keys at the top level, on every node and on every edge when it saves. Three things do not survive an Obsidian save: a node whose `type` is not one of the four spec types (dropped), an edge whose end node is missing (dropped), and a missing `fromSide` or `toSide` (Obsidian fills in its own). No sidecar is needed for status words, tours or layout hints. | Code read from the app archive [1][2]; spec [3]; open issues [4] |
| 2. Where Linen stands | No board app in the set documents a vector PDF with selectable text, reading-first semantic zoom, per-block Arabic in an open format, and an offline phone reader together. FigJam has the best Arabic (per paragraph) but a closed format and a view-only phone app. Obsidian Canvas has the open format but exports PNG only. | Section 2 table |
| 3. What users complain about | Crashes and lag, big boards that will not load on the phone, lost work, and view-only phone apps. Miro: 30 reviews on crashes or lag, 18 on lost work, 17 on zoom. Figma: 28 on a phone app that cannot edit, 21 on crashes or lag. Freeform: 10 on crashes, 4 on lost boards. | 744 saved reviews [5][6][7], counts [8] |
| 4. Layout engine | **ELK.js 0.12.0** for layered layout and orthogonal edges, loaded only when a layout is needed. In JavaScriptCore: one section of 18 nodes p50 6 ms; 176 nodes in 10 groups p50 74 ms, p95 94 ms; 2,000 nodes and 3,000 edges p50 1,399 ms, p95 1,569 ms. Lanes, grid and stack stay Linen's own code. Licence EPL-2.0: ship ELK's file unmodified, as its own file, with its licence. | Measured [9][10]; docs [11]-[16] |
| 5. tldraw and Excalidraw | tldraw's licence forbids production use without a paid key and stops drawing after five seconds without one. Excalidraw is MIT but brings React, a hand-drawn look and its own fonts. Neither reads JSON Canvas. Linen's own DOM and SVG renderer is the right call. | [17]-[24] |
| 6. FigJam and Freeform PDF export | Neither help page says vector or selectable text. FigJam lists PDF among "image formats" with a Quality setting and a solid background only. Freeform exports the whole board, or one PDF of all scenes sized to the device. Not verified by export. | [25]-[28] |
| 7. Keeping a zoomed-out board readable | Obsidian hides card content below about 31 percent zoom and shrinks group labels with the square root of the zoom. tldraw culls off-screen shapes, simplifies at small sizes, and holds its zoom-dependent drawing steady while the camera moves on boards over 500 shapes. FigJam opens every board at Zoom to fit. | [2][29][30][31] |

### What this means for Linen 2

1. **Keep JSON Canvas 1.0 with one `linen` object on the canvas, each node and each edge (section 9.1).** Obsidian copies every key it does not know into `unknownData` and writes it back on save, at all three levels [2]. No sidecar is needed for status words, notes, tours or layout hints. The `<board>.notes.json` sidecar in BRD-6 and the comments file in BRD-21 can stay optional, for agents that prefer to write notes separately.
2. **Never write a new `type` value (BRD-2, BRD-3).** Obsidian skips any node whose `type` is not `text`, `file`, `link` or `group`, so the next save from Obsidian deletes it [2]. Linen's kinds must ride on the spec types: card, sticky, shape and text as `"type": "text"` with `linen.kind`; note, board, page and image as `"type": "file"`; link as `"type": "link"`; sections as `"type": "group"`. `linen check` should reject any other `type`.
3. **Dangling edges and missing sides do not survive Obsidian (BRD-4).** An edge whose `fromNode` or `toNode` is missing is removed when Obsidian loads the file, and gone after its next save. A missing side is computed from the angle between the two nodes and written into the file [2]. BRD-4's gap mark is still useful for files agents write, but `linen check` should report a dangling edge as an error. For missing sides Linen should use Obsidian's angle rule, so a board does not change shape after Hatim saves it in Obsidian.
4. **`linen layout` should write the file the way Obsidian does (CLI-3, BRD-17).** Obsidian writes tabs, puts any object whose values are all plain values on one line, drops keys whose value is undefined, and rounds positions and sizes to whole numbers [2]. Writing the same style keeps a round trip through Obsidian to a small diff.
5. **ELK.js for layered layout and edge routing; Linen's own code for lanes, grid and stack (BRD-17, BRD-25, section 9.2).** One section lays out in 6 ms (p50) in JavaScriptCore, and a 176-node board in 74 ms, fast enough on open. A 2,000-node board takes 1.4 s, so layout must run off the main thread (a Web Worker) and its result must be cached. ELK put the 176-node board's ten groups in one row 19,988 px wide [9], which supports BRD-25: sections placed by hand, contents flowed per section.
6. **Hand-placed nodes need Linen's own router (BRD-4, BRD-17).** The saved ELK pages offer options to keep existing order or a chosen layer; none of them pins a node's coordinates [11]. D2 locks positions only in its closed TALA engine [14]. Graphviz's orthogonal routing "does not handle ports or, in dot, edge labels" [15]. So hand-placed nodes stay out of the layout engine, and elbow connectors that route around cards over a hand-placed board need a small orthogonal router in Linen's renderer.
7. **Load ELK lazily and keep its licence intact (section 9.2, section 11).** `elk.bundled.js` is 1.6 MB (467 KB gzip) and takes about 37 ms to load and start in JavaScriptCore [9]. Load it only when a board asks for a layout. Under EPL-2.0 [13], Linen can ship the unmodified file beside its own code with the licence text and a note on where the source is. ELK's code must not be pasted into Linen's own files. Mermaid 12 already bundles ELK as its default layout [16], so a later Mermaid upgrade will bring ELK into the renderer anyway.
8. **Draw boards with Linen's own DOM and SVG renderer, as planned (section 9.2, section 1).** tldraw needs a commercial key in production and enforces it in code [17][18]. Excalidraw is MIT but ships React and a hand-drawn look with its own fonts [21][22]. Neither reads JSON Canvas. Loom's paper and ink look needs its own renderer anyway.
9. **Vector PDF with selectable text is the export opening (EXP, BRD-6).** FigJam calls its PDF an image format with a Quality setting [25][26], Obsidian Canvas exports PNG only and adds its logo by default [32], tldraw and Excalidraw export SVG and PNG [20][21], and Freeform's help does not say [27][28]. Section 13's text extraction from every exported PDF is what proves Linen's claim.
10. **The phone app can be read-only if it opens big boards reliably (section 6.4, BRD-20, BRD-23, BRD-24).** Phone complaints are about boards that are "too large" to load, crashes, lost work and slow loading [5][7]. Figma's view-only app draws 28 complaints about editing [8]. Linen's phone app should say plainly that it reads, open its first section fast, and offer List view.
11. **Semantic zoom goes further than anyone documents (BRD-8).** Obsidian hides card content below about 31 percent zoom and lets group labels shrink with the square root of the zoom, so at 6.25 percent a label draws at a quarter of its size [2]. BRD-8's 15 px floor for section names is stronger. tldraw's zoom value that "returns a stable value during camera movement" on boards over 500 shapes [30] matches BRD-8's rule that the level changes only when a gesture rests. tldraw keeps culled shapes in the DOM with `display: none` [29]; BRD-20 removes them, which suits 10,000 nodes better.
12. **Arabic per block is rare on boards (BRD-2).** Only FigJam documents per-paragraph direction controls [33]. tldraw's interface supports right-to-left languages and detects them on paste [30]. Obsidian has one global right-to-left setting for notes [34]. Freeform, Excalidraw and Miro: NL.

## 1. JSON Canvas 1.0 as Linen's file

### The format

The spec is version 1.0, dated 2024-03-11 [3]. The repository is MIT [35]. Its last spec change in the saved commit list is "Add default value for fromEnd and toEnd", 2024-04-11 [36].

| Level | Field | Required | Values and notes |
|---|---|---|---|
| Canvas | `nodes` | optional | Array of nodes, in ascending z-order: the first is drawn at the bottom |
| Canvas | `edges` | optional | Array of edges |
| Every node | `id` | yes | Unique string |
| Every node | `type` | yes | `text`, `file`, `link`, `group` |
| Every node | `x`, `y`, `width`, `height` | yes | Integers, pixels. The spec does not say which corner; a commenter on issue #9 reports `x`, `y` is the top-left corner [4] |
| Every node | `color` | optional | `canvasColor`: a hex string such as `"#FF0000"`, or a preset `"1"` red, `"2"` orange, `"3"` yellow, `"4"` green, `"5"` cyan, `"6"` purple. Preset values are deliberately undefined so apps can theme them |
| Text node | `text` | yes | Plain text with Markdown |
| File node | `file` | yes | Path to the file |
| File node | `subpath` | optional | Heading or block, starts with `#` |
| Link node | `url` | yes | |
| Group node | `label` | optional | |
| Group node | `background`, `backgroundStyle` | optional | Image path; `cover`, `ratio` or `repeat` |
| Edge | `id`, `fromNode`, `toNode` | yes | |
| Edge | `fromSide`, `toSide` | optional | `top`, `right`, `bottom`, `left` |
| Edge | `fromEnd`, `toEnd` | optional | `none` or `arrow`; defaults `none` at the start and `arrow` at the end |
| Edge | `color`, `label` | optional | |

**Unknown fields.** The spec says nothing about them: a search of the spec for "unknown", "additional", "ignore" and "extension" finds only the `.canvas` file extension [3]. Users have asked since launch, and the issues are still open [4]:

- #8 "Version property" (2024-03-12, open) proposes "unrecognized properties must be ignored by any implementation". A collaborator closed #41 as "a duplicate of #8".
- #13 "Custom node types or additional metadata?" (2024-03-12, open) suggests a `properties` object.
- #57 "how to handle arbitrary entities and attributes that don't fit in the spec?" (2025-05-02, open). A 2026-09-07 comment asks that any extension data "should at least be namespaced".
- #27 "Proposal: Edges additional properties" (open). A 2025-03-04 comment says "it seems the Obsidian developers aren’t too interested in extending the format" and points to the Open Canvas Working Group.

None of the saved comments carries a maintainer answer on unknown fields. So the only reliable guide is what Obsidian's code does.

### What Obsidian 1.13.7 keeps when it saves

Read from `app.js` and `app.css` inside `obsidian-1.13.7.asar` (version from its `package.json`), quoted verbatim with byte offsets in [2]; earlier excerpts in [1].

| What | Kept on save? | Code |
|---|---|---|
| Top-level keys other than `nodes` and `edges` | **Y** | Load: `n.setData(JSON.parse(e))`, and `setData` stores the whole object as `this.data`. Save: `getData` returns `m(m({},this.data),{nodes:e,edges:t})`, so every top-level key comes back and only `nodes` and `edges` are replaced |
| Unknown keys on a node | **Y** | Base node `setData`: `s=g(e,["x","y","width","height","color"])` ... `this.unknownData=s`. `getData`: `m(m({},s),{id:t,x:n,y:i,width:r,height:o})`. Text, file, link and group nodes add their own fields on top |
| A node whose `type` is not one of the four | **N, dropped** | `importData`: `if("file"===u.type)p=new j7(this,h);else if("text"===u.type)p=new _7(this,h);else if("link"===u.type)p=new G7(this,h);else{if("group"!==u.type)continue;` The node never enters the canvas, so it is missing from the next save |
| Unknown keys on an edge | **Y** | Edge `setData`: `c=g(e,["fromNode","fromSide","fromEnd","toNode","toSide","toEnd","color","label"])` ... `this.unknownData=c`. `getData` spreads `unknownData` first |
| An edge whose `fromNode` or `toNode` is missing | **N, dropped** | `if(o.has(y)&&o.has(k)){...}else d.has(h)&&this.removeEdge(d.get(h))` |
| A missing `fromSide` or `toSide` | **Filled in** | `b||(g.fromSide=b=$7(S,x)),C||(g.toSide=C=$7(x,S))`. `$7` picks the side from the angle between the two nodes' centres, and `getData` always writes both sides |
| Default ends | Omitted | `fromEnd` is written only when it is not `none`, `toEnd` only when it is not `arrow` |
| Positions and sizes | Rounded | `n=Math.round(n),i=Math.round(i),r=Math.round(r),o=Math.round(o)` |
| Group background style | `cover` omitted | `a&&"cover"!==a&&(t.backgroundStyle=a)` |
| File layout | Obsidian's own | Serializer `$d`: tab indent; an object whose values are all plain values goes on one line; keys whose value is `undefined` are dropped |

A save happens through `requestSave`, which sets `this.data=this.getData()` before the view writes the file [2]. I did not establish whether opening a board alone ever triggers a save.

**Limits of this finding.** It comes from reading minified code. Obsidian was never run, because the brief forbade opening it. Section 13 of the PRD should add a round-trip test: a board with `linen` objects at all three levels, opened in Obsidian, one card moved, saved, and the file compared.

### Recommendation

Use the planned shape: one `linen` object on the canvas, on each node and on each edge, holding status words, notes, tours, kinds and layout hints. Obsidian carries it through its saves. Add four rules, from the table above:

1. Only the four spec `type` values. Linen's kinds go in `linen.kind`.
2. `linen check` reports dangling edges and unknown `type` values as errors.
3. When a side is missing, Linen picks it with Obsidian's angle rule.
4. `linen layout` writes integers and Obsidian's file style.

If a future Obsidian dropped unknown keys, the fallback would be a sidecar `<board>.linen.json` keyed by node and edge `id`. Ids are the one thing every save keeps. There is no need for it today.

## 2. Competition table (for PRD section 3)

Source numbers in brackets. Miro's column rests on its App Store listing and user reviews only.

| | FigJam | Apple Freeform | Obsidian Canvas | tldraw | Excalidraw | Miro | Linen 2 (planned) |
|---|---|---|---|---|---|---|---|
| File format and openness | **N.** `.jam`; Figma: the formats "are proprietary" and may change [37] | **NL.** `.board` package (`com.apple.freeform.board`), no format document seen [38] | **Y.** JSON Canvas 1.0, MIT [3][35] | **P.** JSON snapshots and `.tldr` files with schema migrations; no standalone spec seen [19][30] | **P.** "plaintext JSON" `.excalidraw`; top level documented, element fields not [22] | **NL** | **Y.** JSON Canvas 1.0 plus `linen` objects |
| Works offline | NL | NL; boards sync through iCloud [39] | **Y.** Notes are files "on your device" [40] | **P.** SDK can persist to IndexedDB [19] | **Y.** "PWA support (works offline)" [21] | NL; reviews say online only [7] | **Y.** Mac and iPhone, no cloud |
| Control of the look | **P.** Four font styles: Simple, Bookish, Technical, Scribbled [41] | **P.** Black or white background, dot grid; fonts per text box [42] | **Y.** Themes and CSS [43] | **Y.** Themes with palettes, fonts, sizes [44] | **P.** Dark mode; fixed font list; hand-drawn style [21][45] | NL | One look by design: Loom, Paper and Night |
| Reading at overview zoom | **NL.** Opens at Zoom to fit [31]; legibility not documented | **NL.** Zoom to Fit Content; scenes as saved views [42][28] | **P.** Card content hidden below about 31%; group labels shrink with the square root of zoom; zoom 6.25 to 200% [2] | **P.** Culling, level of detail, steady zoom while moving [29][30] | **NL.** Zoom 10 to 3000% [45] | **NL.** Reviews complain [7] | **Y.** Semantic zoom, three levels (BRD-8) |
| Phone app | **P.** iPhone: view and comment on boards [46]; FigJam editing on iPad only; "Editing isn't supported on mobile" [47] | **Y.** Create, view and edit on iPhone [39] | **Y.** Mobile app edits canvases; no image export on mobile [32] | NL | NL (web app as PWA) | **Y.** "Create, view, and edit all your boards" [48] | **P.** Reads only, offline copy over Linen's link |
| Export: PDF | **P.** PDF listed with PNG and JPG as "image formats"; Quality setting; solid background only [25][26] | **P.** Whole board, or all scenes; scenes print at the device's size [27][28] | **N.** PNG only [32] | **N.** Only in a sample app that stamps images onto a PDF [30] | NL | NL; one review: PDF "blurry" [7] | **Y.** Vector, selectable text, sources at the end |
| Export: PNG, SVG, HTML | PNG, JPG, CSV; "SVG exports from FigJam aren't currently supported" [25] | Images via Preview from the PDF [27] | PNG on desktop, Obsidian logo on by default [32] | SVG, PNG, JPEG, WebP; fonts embedded [20] | PNG, SVG, clipboard [21] | NL | PNG and one self-contained HTML file |
| Right-to-left and Arabic | **Y.** Auto direction; override per paragraph [33] | NL | **P.** One global RTL setting for notes [34] | **P.** Interface in 49 languages incl. Arabic; RTL detected on paste [30] | NL | NL | **Y.** Per block, Linen 1's rules |
| Can an agent write a board | **P.** Claude through the Figma Connector, into Figma's cloud; unclaimed files are public by link; Claude Code gets a link only [47] | NL | **Y.** Open JSON file | **Y.** SDK, `@tldraw/mermaid`, agent starter kit [30][49] | **Y.** Open JSON, element skeleton API, Mermaid converter [22][50] | NL | **Y.** File plus `linen check`, `layout`, `shot` |
| Price | NL; FigJam "available on any team or plan"; Figma app free on the App Store [51][52] | Free with the Mac; premium content in the Apple Creator Studio subscription [39][53] | Free; Sync from $4 per user per month, billed annually [54] | SDK: commercial licence, "Value-based pricing", 100-day trial, hobby licence with watermark [18][55] | Free, MIT; Excalidraw+ paid (price NL) [21] | App free; plans NL [48] | Not set |

## 3. What users complain about

Source: the 50 most recent App Store reviews per page, five pages per app, US store [5][6][7]. Counts are keyword matches over title and body, run by a script whose patterns are saved with the results [8]. A review can count in more than one row. The quotes were read by hand.

| Theme | Figma (250 reviews, 2023-11 to 2026-10, mean 2.15) | Freeform (250, 2026-08 to 2026-10, mean 4.07) | Miro (244, 2017-01 to 2026-10, mean 2.81) |
|---|---|---|---|
| Crashes, freezes, lag | 21 (20 rated 1 to 3) | 10 (9) | 30 (24) |
| Device app is view-only or cannot edit | 28 (26) | 0 | 4 (3) |
| Lost or deleted work | 2 (2) | 4 (4) | 18 (18) |
| Zoom and legibility | 6 (5) | 2 (2) | 17 (12) |
| Large boards fail to load or crash | 6 (6) | 0 | 7 (5) |
| Sign-in problems | 13 (13) | 0 | 19 (17) |
| Offline or needs internet | 2 (2) | 0 | 6 (4) |
| Export, print, save as image | 0 | 2 (1) | 6 (3) |

Figma's reviews cover the whole Figma app (Design, Slides and FigJam). Freeform's recent reviews come mostly from people who draw.

- **Big boards on the phone.** Miro, 2026-09-23: "CONSTANTLY crashes on my iPhone because it’s an older phone and the board is large". Miro, 2024-11-12: "Every single board says it’s “too large” and won’t load". Figma, 2025-11-19, title: "“files too big for this device”".
- **Crashes and slow loading.** Figma, 2026-10-06: "Fails to load properly and constantly restarts for larger files". Figma, 2024-06-19: "it still loads all my drawings very, very slow". Freeform, 2026-09-10: "If you run this more than ten minutes the app WILL crash on you."
- **Lost work and sync.** Miro, 2023-05-06: "I lose the last 5 minutes of changes". Freeform, 2026-10-10: "all my boards were gone and it said Syncing with iCloud. I had 103 boards".
- **Zoom and legibility.** Miro, 2026-03-19: "trackpad pinch-to-zoom still just zooms the entire interface (not the board)". Miro, 2024-03-10: "can't see anything unless you zoom in to 400 %". Freeform, 2026-09-07: "We should be able to zoom in more than 400%."
- **View-only phone apps.** Figma, 2026-01-16: "It should be called FigView, because that’s all you can do." Figma, 2025-03-12: "Can’t find content on figjam file."
- **Offline.** Miro, 2021-06-24: "the app is unusable without a WiFi connection". Miro, 2024-05-14, title: "Needs Offline Mode ASAP".
- **Export.** Miro, 2022-02-14: "I tried downloading it into pdf and when i opened it everything was blurry". Freeform, 2026-09-20: "Can’t save to pictures".

For a reader, the lesson is reliability on big boards, never losing anything, and finding things on a large board from a phone. A read-only phone app is acceptable only if it is honest about it and fast.

## 4. Layout engine for `linen layout` and flowed sections

### Candidates

Sizes are bundlephobia's minified and gzip sizes for the package's main entry [12], except where measured.

| Engine | Licence | Size (min / gzip) | Latest release | Layered, with ports | Compound groups | Orthogonal routing | Fixed positions |
|---|---|---|---|---|---|---|---|
| **ELK.js** (`elkjs`) | EPL-2.0 OR GPL-3.0-or-later [13][56] | 1.45 MB / 433 KB; `elk.bundled.js` measured 1.61 MB / 467 KB [9] | 0.12.0, 2026-07-17 [57] | **Y.** "arbitrary port constraints are respected" with orthogonal routing [11] | **Y.** "full layout of compound graphs with cross-hierarchy edges" [11] | **Y** [11] | **P.** Options to keep existing order or a chosen layer and position index (interactive layout, layer and position choice constraints); pinning coordinates NL [11] |
| **dagre** (`@dagrejs/dagre`) | MIT [58] | 47 KB / 16 KB | 3.1.1, 2026-08-08 [57] | **P.** Layered; ports NL | **P.** Clusters [59]; D2: container-to-child edges "do not work in Dagre" [14] | **N.** Edges get control `points` [59] | NL |
| **Graphviz WASM** (`@hpcc-js/wasm-graphviz`, `@viz-js/viz`) | Wrappers Apache-2.0 and MIT; Graphviz itself EPL [60][61] | 814 KB / 631 KB and 1.36 MB / 486 KB | 1.29.2, 2026-09-29; 3.31.0, 2026-09-28 [57] | **P.** `dot`, but orthogonal routing "does not handle ports or, in dot, edge labels" [15] | **P.** `cluster` and `clusterrank` attributes listed [15] | **P.** `splines=ortho`, same limits [15] | **P.** `pos` sets initial positions "In neato and fdp" [62] |
| **D2** (`@terrastruct/d2`) | MPL-2.0 [63] | 8.19 MB / 5.99 MB | 0.1.33, 2025-08-17 [57] | Through dagre or ELK shims | **P.** Container sizes only in TALA and ELK [14] | Through ELK | **P.** "top and left to lock positions only work in TALA" [14] |
| **TALA** (D2's engine) | "closed-source", paid for commercial use, watermark without a licence [64] | NL | NL | NL | NL | NL | **Y**, but closed [14] |
| **Mermaid with ELK** | MIT [65] | Mermaid's main entry 710 KB / 174 KB [12] | 12.2.0, 2026-10-13 [66] | ELK inside Mermaid's own diagram syntax | | | **N.** Mermaid places everything |

Mermaid lays out its own diagram text only, so it cannot place board nodes. Its relevance is that "ELK is bundled and default from v12.0.0" [16], and Mermaid 12.2.0 depends on `elkjs` ^0.9.3 [65]. Linen 1 ships Mermaid 11.16.0 today (`package.json`).

### Measurements

Script `raw/boards/measured-elk-2026-10-14.js`, output `raw/boards/measured-elk-2026-10-14.txt` [9][10]. ELK 0.12.0, `layered`, direction right, orthogonal edge routing, compound cases with `hierarchyHandling: INCLUDE_CHILDREN`, no Web Worker. Each case ran 20 times on a fresh copy of the same seeded graph. Cards were 220 to 300 px wide and 72 to 160 px tall. Every run placed every node with no overlapping siblings and routed every edge with only horizontal and vertical segments.

| Case | JavaScriptCore p50 | JavaScriptCore p95 | Node (V8) p50 | Node p95 | Board size ELK produced |
|---|---|---|---|---|---|
| S. One section: 18 nodes, 20 edges | **6 ms** | 14 ms | 9 ms | 16 ms | 1,358 × 1,194 px |
| A. 176 nodes in 10 groups, 250 edges (200 inside, 50 across) | **74 ms** | 94 ms | 85 ms | 115 ms | 19,988 × 2,606 px |
| B. 2,000 nodes, 3,000 edges, flat | **1,399 ms** | 1,569 ms | 1,629 ms | 1,719 ms | 86,318 × 54,186 px |
| B20. 2,000 nodes in 20 groups, 3,000 edges | **2,601 ms** | 2,904 ms | 2,902 ms | 2,990 ms | 155,658 × 32,522 px |

- The first layout in a process, with a cold JIT, took 51 ms in JavaScriptCore for case S [9].
- Loading `elk.bundled.js` took about 20 ms and constructing ELK about 17 ms, over ten fresh JavaScriptCore processes [9][10].
- An earlier run of the same graphs gave JavaScriptCore p50 67 ms (A) and 1,079 ms (B), so expect up to 30 percent spread between runs [9].
- JavaScriptCore here is the system `jsc` shell. WKWebView runs the same engine, but timings inside a page may differ.

### Recommendation

**ELK.js**, for three reasons:

- It is the only open engine in the set with layered layout, ports, compound groups with cross-group edges, and orthogonal routing together.
- It is maintained (three releases since September 2025).
- It is fast enough in Linen's own engine: per-section layout in single-digit milliseconds, a whole 176-node board under 100 ms.

Use it this way:

- Only for `layered` sections, for nodes without positions, and for routing edges inside a laid-out section.
- Lanes, grid and stack are simple enough to stay Linen's own code (BRD-25).
- Lay sections out one at a time inside their hand-placed frames. One global compound layout puts groups in a long row.
- Run ELK in a Web Worker and cache the result by content hash, because 2,000 nodes take more than a second.
- Never pass hand-placed nodes to ELK.
- Route connectors across a hand-placed board with Linen's own orthogonal router.
- Ship `elk.bundled.js` unmodified, as its own file, with the EPL-2.0 text and a line saying where its source is (EPL-2.0 sections 3.1 and 3.2 [13]).

dagre is the fallback if size matters more than routing: 16 KB gzip and MIT, but no orthogonal routing.

## 5. tldraw and Excalidraw: embed or draw our own?

**tldraw.**

- The licence permits "Development Environments" and forbids "Production Environments" without a trial or commercial key [17].
- The licence names "Technical enforcement", including watermark display, and the SDK "may collect and transmit usage data" [17].
- The docs say "The tldraw SDK requires a license key to work in production." Without one, the SDK "logs errors to the console and, after five seconds, stops rendering the editor" [18].
- Hobby licences keep the "made with tldraw" watermark and send "License ID, license type, SDK version, and page URL" [18].
- Pricing is "Value-based pricing" with a 100-day trial [55].
- Its format is JSON snapshots with migrations. `.tldr` files appear in the changelog, but no standalone format document was saved [19][30].
- Its main entry is 1.78 MB minified (530 KB gzip) and needs React as a peer dependency [12][23].

**Excalidraw.**

- MIT [21][67]. Its file is "plaintext JSON", with only the top level documented [22].
- It brings 31 dependencies plus React as a peer dependency, 1.12 MB minified (353 KB gzip) [12][24].
- Its look is hand-drawn, with a fixed font list (Excalifont by default, Nunito, Lilita One, Comic Shanns, Liberation Sans and others) [45].

**Conclusion.** Neither renders JSON Canvas. tldraw cannot ship inside a public app without a paid key and its enforcement code. Excalidraw's look and fonts fight Loom's. The PRD's choice stands: boards drawn by Linen's own DOM and SVG renderer in `Renderer/page.js`, no tldraw or Excalidraw files (section 1).

## 6. Freeform and FigJam PDF export

| | FigJam | Freeform |
|---|---|---|
| How | File > Export as, or Export selection; PNG, JPG or PDF [25] | File > Export Board as PDF [27]; File > Export Scenes as PDF for all scenes [28] |
| Vector or raster | NL. FigJam lists "PNG, JPG, and PDF image formats" [26] and says "If exporting as JPG or PDF, select the Quality of the exported image." [25], which suggests raster but does not prove it | NL |
| Selectable text | NL | NL |
| One page or many | NL for a board; pages exist, and "There is no limit to the amount of pages" [68] | One page per scene is implied but never stated; "Printed scenes default to the size of the device you’re using" [28] |
| Background | Solid only for PDF (no transparent, no grid) [25] | Black or white board [42] |
| Other | No SVG [25]; CSV for stickies and tables | Images by opening the PDF in Preview [27] |

**Not verified.** Both answers need a real export: one board from each app, checked with `pdffonts` and `pdftotext`. That needs the apps open, which this lane did not do.

## 7. How the big apps keep a zoomed-out board readable

1. **Obsidian hides content and shrinks labels slowly** [2].
   - Zoom is a power of two clamped to `-4..1`, which is 6.25 to 200 percent.
   - Below the breakpoint `T7=-1.7` (about 31 percent) cards hide their content. The setting "Zoom threshold for hiding card content" moves it: "Lower values will increase performance but hide card content sooner when zooming out" [1][2].
   - Group labels and edge labels are scaled by `--zoom-multiplier`, set to `Math.sqrt(1/v)`, so they shrink with the square root of the zoom.
   - Group labels are cut to the group's width with an ellipsis.
   - Lesson for BRD-8: a counter-scaled label alone still fades at overview; Linen's minimum on-screen size for section names is the stronger rule.
2. **tldraw culls, simplifies and holds its zoom steady while moving** [29][30].
   - Off-screen shapes get `display: none`.
   - At low zoom, stickies drop shadows, hatch fills turn solid, and "Text outlines turn off below the `textShadowLod` threshold (default 0.35)".
   - On boards with more than 500 shapes, `getEfficientZoomLevel` "returns a stable value during camera movement" and updates when the camera stops.
   - The tldraw 4.4.0 release notes include "Improve frame label sizing on smaller viewports and when zoomed out."
   - Lessons for BRD-8 and BRD-20: change level only at rest, and simplify by on-screen size.
3. **FigJam and Freeform lean on fit and saved views.**
   - FigJam opens every file at "Zoom to fit" [31] and groups content into titled sections that can be linked to [69].
   - Freeform has Zoom to Fit Content and scenes, saved views to present "section by section" [42][28].
   - Neither documents what happens to text at low zoom.
   - Lesson for BRD-14 and BRD-24: tours and a sensible opening view matter as much as zoom rendering.

## Glossary

- **JSON Canvas**: an open file format for infinite canvases, made for Obsidian; files end in `.canvas`.
- **Node, edge, group**: a box on the board, a line between two boxes, and a box that contains others (Linen calls groups sections).
- **Unknown field**: a key in the file that the reading app does not define. Keeping it on save is what lets two apps share one file.
- **Round trip**: open a file in another app, edit, save, and check what changed.
- **Semantic zoom**: showing different detail at different zoom levels (all text, then titles, then section names) as the view zooms out.
- **Culling**: not drawing what is outside the view.
- **Level of detail**: drawing a simpler version of something that is small on screen.
- **Layered layout**: a layout that puts nodes in columns or rows so most edges point one way (the Sugiyama method).
- **Port**: a fixed attachment point on a node's border.
- **Compound graph**: a graph whose nodes can contain other nodes.
- **Orthogonal routing**: connectors made only of horizontal and vertical segments.
- **p50, p95**: the time half the runs beat, and the time 95 percent of runs beat.
- **JavaScriptCore**: Apple's JavaScript engine, the one inside WKWebView.
- **Web Worker**: a background thread for page scripts, so heavy work does not freeze the page.
- **EPL-2.0**: the Eclipse Public License. Changes to its files must stay open; the unmodified files can ship inside other software with the licence and a pointer to their source.

## Sources

All paths relative to `docs/research/raw/`.

1. `boards/obsidian-1.13.7-canvas-code-excerpts-2026-10-14.txt`: earlier excerpts (zoom breakpoint, i18n strings, getData, importData).
2. `boards/obsidian-1.13.7-canvas-roundtrip-excerpts-2026-10-14.txt`: save round trip, node and edge `unknownData`, serializer, zoom and label CSS, with byte offsets.
3. `boards/jsoncanvas-spec-1.0-source-2026-10-14.md` (also `jsoncanvas-spec-1.0-2026-10-14.txt`).
4. `boards/jsoncanvas-issues-all-2026-10-14.json`, `boards/jsoncanvas-issue-{7,8,9,13,15,27,41,55,57}-comments-2026-10-14.json`.
5. `boards/appstore-reviews-figma-2026-10-14.txt`.
6. `boards/appstore-reviews-freeform-2026-10-14.txt`.
7. `boards/appstore-reviews-miro-2026-10-14.txt`.
8. `boards/measured-review-counts-2026-10-14.txt`.
9. `boards/measured-elk-2026-10-14.txt`.
10. `boards/measured-elk-2026-10-14.js`, `boards/measured-elk-load-2026-10-14.js`.
11. `boards/elk-layered-2026-10-14.txt`, `boards/elk-home-2026-10-14.txt`, `boards/elkjs-readme-2026-10-14.md`.
12. `boards/bundlephobia-*-2026-10-14.json` (elkjs, dagrejs-dagre, hpcc-js-wasm-graphviz, viz-js-viz, terrastruct-d2, mermaid, tldraw, excalidraw-excalidraw).
13. `boards/elkjs-license-2026-10-14.md` (Eclipse Public License 2.0).
14. `boards/d2-layouts-2026-10-14.txt`.
15. `boards/graphviz-attr-splines-2026-10-14.txt`.
16. `boards/mermaid-layouts-2026-10-14.md`, `boards/mermaid-layout-elk-readme-2026-10-14.md`.
17. `boards/tldraw-license-md-2026-10-14.md`.
18. `boards/tldraw-sdk-features-license-key-2026-10-14.txt`.
19. `boards/tldraw-sdk-features-persistence-2026-10-14.txt`.
20. `boards/tldraw-sdk-features-image-export-2026-10-14.txt`.
21. `boards/excalidraw-readme-2026-10-14.md`.
22. `boards/excalidraw-docs-json-schema-2026-10-14.txt`, `boards/excalidraw-docs-skeleton-2026-10-14.txt`.
23. `boards/npm-tldraw-2026-10-14.json`.
24. `boards/npm-excalidraw-excalidraw-2026-10-14.json`.
25. `boards/figma-help/4407699832855-Export-your-FigJam-board-2026-10-14.txt`.
26. `boards/figma-help/1500007927941-Import-and-export-with-FigJam-2026-10-14.txt`.
27. `boards/freeform/mac-export-pdf-2026-10-14.txt`.
28. `boards/freeform/mac-scenes-2026-10-14.txt`.
29. `boards/tldraw-sdk-features-culling-2026-10-14.txt`.
30. `boards/tldraw-llms-full-2026-10-14.txt` (level of detail, debounced zoom, right-to-left, PDF example, changelog).
31. `boards/figma-help/1500004414582-Pan-and-zoom-in-FigJam-2026-10-14.txt`.
32. `boards/obsidian-help-canvas-2026-10-14.md`.
33. `boards/figma-help/4972283635863-Add-right-to-left-text-2026-10-14.txt`.
34. `obsidian-help/all/User_interface__Settings.md` (Linen 1 research).
35. `boards/jsoncanvas-readme-2026-10-14.md`, `boards/jsoncanvas-api-2026-10-14.json`.
36. `boards/jsoncanvas-commits-2026-10-14.json`.
37. `boards/figma-help/8403626871063-Save-a-local-copy-of-files-2026-10-14.txt`.
38. `boards/freeform-infoplist-2026-10-14.txt`.
39. `boards/itunes-search-freeform-2026-10-14.json` (App Store description), `boards/freeform-mac-guide-2026-10-14.txt`.
40. `obsidian-help/How_Obsidian_stores_data.md` (Linen 1 research).
41. `boards/figma-help/1500004291281-Create-text-and-links-in-FigJam-2026-10-14.txt`.
42. `boards/freeform/mac-appearance-2026-10-14.txt`, `boards/freeform/mac-sticky-note-2026-10-14.txt`.
43. `obsidian-help/Themes.md` (Linen 1 research).
44. `boards/tldraw-sdk-features-themes-2026-10-14.txt`.
45. `boards/excalidraw-src-constants-2026-10-14.txt`.
46. `boards/figma-help/1500007537281-Guide-to-the-Figma-mobile-app-2026-10-14.txt`, `boards/figma-help/4502073572247-FigJam-for-iPad-2026-10-14.txt`.
47. `boards/figma-help/37883260397975-Create-FigJam-diagrams-with-Claude-2026-10-14.txt`.
48. `boards/itunes-search-miro-2026-10-14.json`.
49. `boards/tldraw-docs-mermaid-2026-10-14.txt`.
50. `boards/excalidraw-docs-mermaid-2026-10-14.txt`.
51. `boards/figma-help/1500004362321-Guide-to-FigJam-2026-10-14.txt`.
52. `boards/itunes-search-figma-2026-10-14.json`.
53. `boards/freeform/mac-creator-studio-2026-10-14.txt`.
54. `obsidian-pricing.txt` (Linen 1 research).
55. `boards/tldraw-dev-pricing-2026-10-14.txt`.
56. `boards/npm-elkjs-2026-10-14.json`, `boards/elkjs-github-api-2026-10-14.json`.
57. `boards/npm-time-{elkjs,dagrejs-dagre,hpcc-js-wasm-graphviz,viz-js-viz,terrastruct-d2,mermaid-js-layout-elk}-2026-10-14.json` (release dates from the npm registry).
58. `boards/dagre-license-2026-10-14.txt`, `boards/dagre-readme-2026-10-14.md`, `boards/npm-dagrejs-dagre-2026-10-14.json`.
59. `boards/dagre-wiki-home-2026-10-14.md`.
60. `boards/npm-hpcc-js-wasm-graphviz-2026-10-14.json`, `boards/npm-viz-js-viz-2026-10-14.json`, `boards/vizjs-readme-2026-10-14.md`.
61. `boards/graphviz-license-2026-10-14.txt`.
62. `boards/graphviz-attr-pos-2026-10-14.txt`.
63. `boards/npm-terrastruct-d2-2026-10-14.json`, `boards/d2-github-api-2026-10-14.json`.
64. `boards/d2-tala-github-2026-10-14.md`, `boards/d2-tala-2026-10-14.txt`.
65. `boards/npm-mermaid-2026-10-14.json`, `boards/npm-mermaid-js-layout-elk-2026-10-14.json`.
66. `boards/mermaid-releases-2026-10-14.json`.
67. `boards/excalidraw-github-api-2026-10-14.json`.
68. `boards/figma-help/24005082123159-Create-and-manage-pages-in-FigJam-2026-10-14.txt`.
69. `boards/figma-help/4939765379351-Organize-your-FigJam-board-with-sections-2026-10-14.txt`.
