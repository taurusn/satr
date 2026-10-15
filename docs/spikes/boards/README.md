# Spike B(a): board rendering

**Question.** Can a board drawn as DOM and SVG in WebKit (cards as absolutely placed elements in one transformed layer, connectors as one SVG) pan and zoom at 60 fps with 500 and 2,000 cards, on a phone-sized view?

**Answer so far: yes in the iOS simulator, with four rules (v4 below).** Still to measure: the Mac in an on-screen window (WebKit throttles animation frames offscreen) and a real iPhone.

## How it was tested (2026-10-14)

- `board.html` builds a board like an agent's readiness map: lanes of sections, three columns of cards each, cards of mixed length with a status word, a fifth of them with an Arabic phrase, and 1.4 connectors per card (curved SVG paths). `?n=` sets the card count, `?v=` the renderer version, `?bench=1` runs a scripted gesture set and reports frame times.
- The scripted set, 180 animation frames each: pan at 100 percent; zoom from fit to 150 percent around the centre; zoom back out; pan at the fitted overview. Each frame's time is the gap between animation frames. After each gesture the page measures the frames until the detail is back ("settle").
- `serve.py` serves the folder on 127.0.0.1:48720 and prints each report; `sim-bench.sh` opens each case in the simulator's Safari with `xcrun simctl openurl`, headless (Simulator.app stays closed): iPhone 17 Pro simulator, iOS 26, 402 x 714 CSS px at 3x, on a MacBook Air M4. `bench.swift` is the Mac host (on-screen window, not yet run).
- "Dropped" counts frames over 25 ms (a missed 60 Hz frame); `performance.now()` is rounded to 1 ms in Safari, so a 16.7 ms frame reads as 17.

```sh
python3 -I docs/spikes/boards/serve.py 48720 > /tmp/bench.out &
xcrun simctl boot <udid>
bash docs/spikes/boards/sim-bench.sh <udid> /tmp/bench.out "n=500&v=4" "n=2000&v=4"
```

## Results (p95 frame time in ms; first paint in ms)

| Version | Cards | First paint | Pan at 100% | Zoom fit to 150% | Zoom back out | Pan at overview |
|---|---|---|---|---|---|---|
| v1: everything every frame | 500 | 226 | 17 | 323 | 248 | 129 |
| v1 | 2,000 | 734 | 17 | 881 | 1,032 | 153 |
| v2: transform only mid-gesture, detail at rest | 500 | 46 | 17 | 44 | 363 | 42 |
| v2 | 2,000 | 54 | 17 | 47 | 743 | 53 |
| v3: v2, nothing mounts mid-gesture, mounting by budget at rest | 500 | 21 | 17 | 41 | 58 | 42 |
| v3 | 2,000 | 66 | 17 | 52 | 96 | 44 |
| **v4: v3, composited layer only while cards are mounted** | **500** | **16 to 21** | **17** | **17** | **17** | **17** |
| **v4** | **2,000** | **46** | **17** | **22** | **22** | **21** |

v4 dropped 1 or 2 frames per 180-frame gesture at 500 cards (the gesture's first frame) and 2 to 6 at 2,000; settling took one or two frames, the longest 24 ms.

## What each version taught

1. **v1 → v2: change only the transform mid-gesture.** v1 updated a CSS variable for label size and the level-of-detail class every frame, and re-culled every sixth frame; each update re-laid out every mounted title (zoom p95 881 ms at 2,000).
2. **v2 → v3: never add cards mid-gesture.** Zooming out grows the view, and v2 kept mounting the cards it revealed until all 2,000 were in the DOM (zoom-out p95 743 ms). v3 draws cards that are in view but not mounted as their status shapes on one canvas, and at rest mounts 24 per frame, nearest the centre first.
3. **v3 → v4: the composited layer was the rest.** With `will-change: transform` on the board layer, WebKit re-rasterised the whole layer at certain zoom steps once the board was below about 25 percent: the slow frames fell on the same frame numbers with and without connectors and with no canvas. Without the hint, zooming in and panning at overview ran at 17 ms, but zooming out repainted the mounted cards' text every frame. v4 keeps the layer composited only while cards are mounted above the areas level; crossing into the areas level hides the mounted cards (the canvas draws them) and drops the layer.
4. **Connectors are not the cost.** 2,796 SVG paths changed nothing measurable; turning off `vector-effect: non-scaling-stroke` changed nothing either.

## What this means for the PRD (section 9.2)

- Mid-gesture, only the board's transform changes; the level, label sizes, culling and mounting change when the gesture rests.
- Cards in view that are not in the DOM are drawn as their status shapes on one canvas, which is also the whole board at the areas level (BRD-8).
- At rest, cards mount within a per-frame budget, nearest the centre first.
- The board layer is composited only while cards are mounted above the areas level.
- Still to prove: the same numbers on the Mac (on-screen window) and on a real iPhone; text quality of composited cards after a zoom rests (the layer re-rasterises at rest).

# Spike B(b): layout of the reference board

**Question.** Can `linen layout` lay out the reference board (about 170 boxes in ten sections, the way agents build boards today: sections placed by hand, their contents flowed in grids) in under 2 s with every text fitting its card?

**Answer: yes, go.** About 20 ms per run, every text fits, and a second run changes nothing.

## How it was tested (2026-10-15)

- **The board.** The reference page rebuilt as JSON Canvas with `linen` objects (kept outside the repository): 219 nodes, of which 182 boxes (171 cards, 10 stickies, one board title) and 37 groups (10 top-level sections and 27 nested groups, every one `layout: grid` or `stack`), 12 connectors, 131 status words in six, and 176 notes in a sidecar. Positions in the file are approximate (each child inside its own section), as an agent would write them.
- **The code.** `Renderer/layout.js` (lanes, grid, stack in Linen's own code; layered through ELK.js 0.12 in `Renderer/layout-worker.js`), `Renderer/canvas-writer.js` (Obsidian's file style; patches only the numbers that move), and `LinenLayout.run(text)`, the entry point `linen layout` calls. Widths go top down (a flowed child takes its cell), heights bottom up (a section takes the height its contents need), then rows of top-level sections are kept 180 board px apart (BRD-25), a row moving as one.
- **Measuring.** Each card is measured in the real renderer page with the board view's own card markup and `board.css` (`LinenBoard.measureCards` takes over when the view exposes it), Thmanyah loaded from the installed faces before anything is measured, all cards in one batch so the page lays out once.
- **The host.** `Tests/Harness/layout-host.swift` loads `Renderer/page.html` in an offscreen WKWebView the way the app does, waits for the faces, runs the layout 20 times with the measure cache cleared before each, then lays out its own output again.

```sh
swiftc -swift-version 5 -O -o build/layout-host Tests/Harness/layout-host.swift -framework AppKit -framework WebKit
build/layout-host <board.canvas> --runs 20 --layered 176
node Tests/layout.test.js
```

## Results (MacBook Air M4, macOS 26.5)

| Measure | Result | Gate |
|---|---|---|
| Layout of the reference board, 20 cold runs | p50 15 ms, max 34 ms (whole `run`, with measuring and writing: p50 19 ms, max 48 ms) | under 2 s |
| Items measured per run | 213 (178 flowed boxes and 35 section titles), one batch | |
| Text that does not fit its card after layout | 0 of 182 boxes | 0 |
| A second run over its own output | 0 nodes changed, the text byte for byte the same | idempotent |
| Structure after layout | every child inside its section, no two siblings overlapping, stacked sections 180 px apart | |
| A generated layered section, 176 nodes and 175 edges, through the worker | 189 ms the first time (ELK loads and starts), then 68 to 72 ms; 175 orthogonal routes | |
| The same at 18 nodes, in node | 49 to 68 ms with ELK's start | |

## What it taught

1. **Measure after the faces arrive.** The first runs differed from later ones by 168 nodes: bold text in cards asks for Thmanyah Bold, which only starts loading the first time a card using it is laid out, so the first measure used the fallback face. `run` now loads the card faces first and waits for any face the batch asked for before reading sizes.
2. **ELK's bundled file takes over a worker.** `elk.bundled.js` carries ELK's own worker code, which, when it finds itself in a worker, replaces the worker's message handler instead of exporting its engine; the first layout failed and every later one hung. The worker gives it a stand-in `document` until the engine exists (the file stays unmodified), and every worker request now times out after 20 s instead of hanging.
3. **Rows stay rows.** Pushing each section down on its own left one row staggered by up to 14 px; sections that start within 24 px of each other now move as one row to one top.
4. **The reference board needs more than six words.** The page uses nine status words; WORDS-1 allows six, so the rebuild folds code only, simulated and blocked into one word, and docs only and missing into another. Each box's note still says which. Whether six is the right cap is a question for the PRD.
5. **Formatting holds.** The writer reproduces an Obsidian-style file byte for byte, changes only the numbers that move, keeps unknown fields, and normalises any other file once, then leaves it alone.

**Not covered:** nodes without positions (BRD-17 sends them to ELK; `run` lists them as problems today), the board view's own overflow check on the laid-out board in the app, and view-time re-flow of sections whose contents no longer fit (BRD-17's 300-node rule).

## B(a) on the Mac with real cards (2026-10-15)

**Gate: passed on the Mac.** The real board renderer (`Renderer/board.js`, `board.css`) with real cards: Markdown through Linen's pipeline, DOMPurify, Thmanyah, status pills, note threads, Arabic per block. `Tests/Harness/board-host.swift` hosts `Renderer/page.html` as the app does, in an on-screen window (1176 x 760, Retina, 60 Hz, MacBook Air M4, macOS 26.5), with other build lanes running on the machine. 20 fresh loads for first paint; the gesture set run 3 times (540 frames per gesture). Boards: `Tests/Fixtures/boards/big-500.canvas` (500 nodes, 700 edges) and `big-2000.canvas` (2,000 nodes, 3,000 edges); both open at their first section at reading zoom (BRD-24).

```sh
swiftc -swift-version 5 -O -o build/board-host Tests/Harness/board-host.swift -framework AppKit -framework WebKit
./build/board-host bench Tests/Fixtures/boards/big-500.canvas --onscreen --rail --runs 20 --gesture-runs 3
./build/board-host checks Tests/Fixtures/boards/*.canvas      # structural checks, 12 zoom steps, 1176 and 390 px
./build/board-host measurecheck Tests/Fixtures/boards/*.canvas # measuring with no board loaded = with it loaded
```

| Board | First paint p50 / p95 | Pan at reading zoom | Zoom fit to 150% | Zoom back out | Pan at overview | Pinch at reading zoom |
|---|---|---|---|---|---|---|
| 500 | 14 / 120 ms | p95 19, 0% dropped, longest 19 | p95 18, 0%, 20 | p95 18, 0%, 19 | p95 18, 0%, 19 | p95 18, 0%, 19 |
| 2,000 | 37 / 94 ms | p95 18, 0%, 20 | p95 20, 1.5%, 46 | p95 19, 0%, 19 | p95 19, 0%, 23 | p95 19, 0%, 19 |

Frame times are animation-frame intervals with WebKit's timer rounded to whole milliseconds, so a 60 Hz frame reads 16 to 19; "dropped" counts frames over 25 ms. Section 4's targets: 500 nodes, first paint under 400 ms, under 1 percent dropped, longest hitch under 50 ms (met); 2,000 nodes, first paint under 1.2 s, p95 under 25 ms, under 3 percent dropped (met). Offscreen windows get no animation frames at all, so frame times are measured on screen only; the renderer races each frame with a timer so mounting, flights and `linen shot` still finish offscreen.

**What the Mac taught (folded into the renderer):**

1. **Connectors on a screen canvas, not SVG.** With 700 connectors in one SVG, every zoom step repainted it: 100 to 300 ms hitches (`vector-effect: non-scaling-stroke` or not). Connectors are now drawn on the shapes canvas under the cards each frame, from geometry cached per edge; only label chips are DOM.
2. **Section washes on the ground canvas.** Large translucent section boxes in a layer that moves every frame caused 80 to 90 ms hitches at fixed frame numbers; drawn on the weave canvas they cost nothing. Section names stay DOM in their own layer above the connectors, on a ground band.
3. **Stroke only what is in view, and batch.** On the 2,000 board every frame cost 28 to 40 ms: long dashed connectors (up to 18,000 board px) were stroked whole, and 2,000 shapes were drawn one call each. Connectors are sampled into polylines, stroked only where they cross the view, with dashes generated along the stretch and anchored to the edge's start (no crawl while panning); shapes and connectors are batched into one fill or stroke per style.
4. **Rules 1 to 4 of the simulator spike hold on the Mac** with real cards: transform-only mid-gesture, unmounted cards as shapes, 24 cards per frame at rest nearest the centre, the card layer composited only while cards are mounted above the areas level.

**Structural checks** (`board-host checks`, every fixture and two boards written by agents, at 1176 and 390 px, 12 zoom steps from 5 to 250 percent, 62 of 62 pass): no text under 9 px on screen at rest (found and fixed: pills and eyebrows fell to 7.4 to 8.1 px just above the reading threshold; they now have a 9 px floor), every card's title in the DOM at the read level, no label chip under or over a card (a chip goes to the nearest clear point along its path, then beside the line; with no clear point it hides and shows while its box is lit), section names above the connector layer on a ground band, Fit clear of the zoom panel, the change chip and a floating rail, and no console errors.

**Not covered here:** a real iPhone (B(a) on the phone and I(a) wait for the device); VoiceOver scripts; the 10,000-node case (2.x).
