# Spike I(a): Linen's renderer in an iOS app, on the iPhone

**Question (PRD-2 section 12, I(a)).** Does Linen's renderer (`Renderer/`), unchanged, hosted in a WKWebView inside an iOS app, render Linen's notes and boards on a real iPhone 15 Pro within PRD-2's phone targets, without memory trouble?

**Answer, 2026-10-31: the renderer runs on the iPhone unchanged and the note gate passes. The board gate passes on the renderer's own gestures. Real-finger pans miss the dropped-frame share because of one slow frame at touch-down, and the memory gate was not measured.** Hatim stopped the measuring after seeing the renderer work on his phone, so memory, the outside frame read and the 2,000-card touch run stay unmeasured by his call.

| Gate (PRD-2 section 12, I(a)) | On the iPhone 15 Pro | Result |
|---|---|---|
| 1. Note fixtures, zero console errors and zero renderer problems | 41 files (10 notes and text, 31 boards): 0 console errors, 0 page errors. Each file's problem list equals the list the same renderer files give on the Mac (41 of 41). The 19 files with no problems by design (every note except `broken.md`; the valid boards) show none. A positive control (`console.error` and an uncaught throw) is caught. Thmanyah loads (all six faces). Arabic draws right to left. | **Go** |
| 2. 500-node board, first paint p95 under 800 ms | 20 runs each. Load into an open page: p95 75 ms. Load into a fresh page: p95 116 ms. A new web view to first paint: p95 229 ms. | **Met** |
| 2. 500-node board, pan and pinch (p95 under 16.7 ms, under 1% dropped, longest under 50 ms) | Renderer's own gesture set, 2,700 frames: p95 17 ms (one 60 Hz frame at 1 ms resolution), 0.07% dropped, longest 30 ms. Real touches, 20 pans: p95 19 ms, **2.21% dropped**, longest 36 ms. Real touches, 15 pinches: p95 18 ms, 0.79% dropped, longest 29 ms. | **Met on scripted gestures; not met on real pans** (finding 2) |
| 2. Touch to frame under 30 ms | From the event that moved the board to the frame that drew it: pans p95 19 ms, pinches p95 20 ms. From the first move event of a gesture: pans p95 36 ms (moves under 3 px do not pan, by design), pinches p95 136 ms (WebKit starts gesture events only once it sees two fingers move). Both end at the frame's animation-frame callback; the step from there to the glass was not measured. | **Met on the first reading; not on the second** |
| 2. 2,000-node board (decides the cap) | First paint, fresh page p95 133 ms (under 2 s). Renderer's gesture set: p95 17 ms (pan at overview p95 20), 0.22% dropped, longest 56 ms. Memory and real touches were not measured. | **Frame and paint targets met**; memory unknown |
| 3. 10-minute loop, web content memory under 300 MB, no jetsam | The loop ran 14 rounds in 486 s (15:47:40 to 15:55:46) with 0 errors and 0 web content terminations. Then Hatim touched the phone, which broke the automation; the app was gone by 15:58:54 with no crash or jetsam report. The Activity Monitor recording never finished saving and does not export. A 12 s check earlier showed WebContent at 160 MB with the 500-card board open. | **Not measured** |

The **simulator** (iPhone 17 Pro sim, iOS 26.5, on the M4) ran the same app first. Fixtures: 0 errors and 41 of 41 equal to the Mac. 500 cards: bench p95 17 ms, 0.19% dropped; real-touch pans p95 19 ms, 0.69% dropped; touch to first moved frame p95 21 ms. 2,000 cards: bench p95 38 ms, 13% dropped. The simulator draws on the Mac, so only the device numbers above count.

Extra, outside the gate: List first paint p95 148 ms (500 cards, target 500 ms) and 535 ms (2,000 cards). In the loop, a reload after an outside change repainted within 122 ms at p95, against a 250 ms target, with the centre node 0 px from where it was (target 4 px).

## Findings

1. **A one-finger drag that starts on a card does not pan the board (renderer change iOS needs).** `board.js` pointerdown sets `pan: S.space || !card`. On the Mac a drag on a card selects text; on a phone at reading zoom, cards cover most of the screen. Every pan recorded as starting on a card moved the board 0 frames: 22 on the simulator and 4 on the iPhone. In the first simulator run, before the start point was recorded, all 20 pans from the centre also moved 0 frames. Linen iOS needs touch drags (`pointerType === "touch"`) to pan from anywhere, with text selection on long press. The touch test worked around this by starting pans on the board's ground.
2. **The frame in which the finger lands is slow on every pan.** On the iPhone, frame 0 of each pan took 21 to 36 ms (11 of 20 over 25 ms), which makes up 11 of the 13 dropped frames; without it, pans drop 0.37%. On the simulator, the page's own pointer and touch handlers took 0 to 1 ms per gesture (timed by wrapping the listeners, behaviour unchanged), so the cost is in rendering, not script. A candidate, not tested: pointerdown adds the `grabbing` class to the board's canvas, which restyles every mounted card for a cursor a phone does not show. Short real pans (about 26 frames) turn one slow frame per gesture into 3 to 4 percent, so the PRD's 1 percent needs either this frame fixed or the share counted over longer gestures, as B(a)'s 180-frame runs do.
3. **BRD-24 opens both big boards as a List on the phone**, as designed. The benchmark place switches to Canvas at the first section at reading zoom (s = 0.73, 24 cards mounted), as section 4 asks.
4. **Pinch overshoot, not diagnosed.** An XCUITest pinch with scale 1.8 took the board from 1.31 to the 4.0 cap, and 1/1.8 took it from 4.0 to 2.24. Worth checking with a real hand: a two-finger pointerdown overwrites `drag`, so pan and zoom may both act on a pinch that starts on the ground.
5. **What the app build can reuse as it is:**
   - the Mac `AppScheme` serving `linen-app://renderer/` from the bundle, `linen-local://` for images beside the document, and the `linen` message handler;
   - the Mac app's error and CSP listener at document start;
   - `imageInfo` and `linkStatus` answers in the Mac app's shapes;
   - `load`, `update` and `settings` messages exactly as `DocumentWindow` sends them, and `Scripts/copy-renderer.sh` for the renderer and faces.

   No renderer file needed a change to load, render or report on iOS.
6. **Console reading.** The app's own capture (`console.error`, uncaught errors, unhandled rejections, CSP) works and its positive control fires. The private switch that sends page console messages to the system log reads "on" on iOS 26.5 but logs nothing, so the log cannot serve as an outside check. Safari's Web Inspector was not used (it needs the Mac's GUI).
7. **Tool traps.**
   - `devicectl device process launch` needs `--` before the app's own arguments (`-LinenMode loop ... -LinenMinutes 10` failed with "Unknown option '-L'"; shorter argument lists happened to work).
   - xctrace finds the iPhone only by hardware id. Once it took about 3 minutes to attach and once it timed out. After a 750 s Activity Monitor recording it stayed in "ending recording" and never wrote its template.
   - A notification banner interrupts XCUITest gestures.

## Not measured, and why

- **Web content memory over the 10-minute loop, and jetsam (gate 3):** the loop's trace never saved; a rerun was stopped by Hatim's call.
- **Animation Hitches, the outside frame read:** stopped by Hatim's call. Frame times above come from the page's animation frames only.
- **Real touches and memory on the 2,000-card board:** stopped by Hatim's call.
- **Touch to glass:** the page sees the frame's start, not when it reaches the display.
- **Not built or run:** `App/Runner.swift`'s last change, which makes every mode end, let the screen sleep and quit the app. Before it, touch mode ran until killed and kept the phone awake (Hatim saw it).


## How it was tested (2026-10-31)

**The app.** `LinenSpike` (`project.yml`, XcodeGen; bundle id `com.hatim.linen.spike-ios`; Release builds; team 2U8YZJV343, automatic signing). It hosts `Renderer/page.html` the way the Mac app's `DocumentWindow` does: a non-persistent data store, `linen-app://renderer/` served from the bundle by a scheme handler (the Mac `AppScheme`), `linen-local://` for images beside the document, the `linen` message handler, and the Mac app's error and CSP listener at document start. The bridge answers what the page asks of the app (`imageInfo`, `resolveLinks`), as the Mac app and Loom's shim do. The renderer and the Thmanyah faces are copied into the app at build time by `Scripts/copy-renderer.sh` (run as is), the fixtures by rsync. Nothing in `Renderer/`, `Linen/` or the main project changed. The page fills the safe area: 393 x 759 CSS px at 3x on the iPhone, 402 x 778 on the simulator.

**Devices.** iPhone 15 Pro "Eight", iOS 26.5, over the cable, targeted by CoreDevice id `6C03C5DB-EDDC-5669-87D7-A46D7A263745` for xcodebuild and devicectl; xctrace only finds it by hardware id `00008130-000E719C2E3A001C`. Simulator: iPhone 17 Pro, iOS 26.5, booted headless with `xcrun simctl` (Simulator.app never opened). Mac: MacBook Air M4, Xcode 26.6.

**Runs** (launch arguments `-LinenMode <mode> -LinenBoard big-500|big-2000`; each writes `Documents/results/<mode>-<board>.json`, copied off with `devicectl device copy from`):

| Mode | What it does |
|---|---|
| `fixtures` | Loads every note and board fixture in one page as the app sends them; records console errors, page errors, warnings, and the renderer's own problems (`.render-failed` blocks, notices and banners, `LinenBlocks.check` for notes, the board model's problems and fatal state, what the board shows); a snapshot of each. A positive control after the counts (a `console.error` and an uncaught throw) must be caught. |
| `paint` | First paint of the first section at reading zoom in Canvas (PRD-2 section 4: "switches to Canvas ... even where BRD-24 would open List view first"; on a phone BRD-24 opens both big boards as a List). 20 loads in one page (as `board-host bench`), 20 loads into a fresh web view each (cold), 20 List first paints. Times are the app's clock from sending `load` to the page's `firstPaint`, and the page's own `paintMs`. |
| `bench` | The renderer's own B(a) gesture set (`board.js` `bench`, the command `board-host bench` drives on the Mac), 3 runs of 180 frames per gesture. |
| `touch` | The board at the first section at reading zoom, a frame recorder armed; real touches come from the UI test. |
| `loop` | The I(a) loop, below. |

**Real touches.** `UITests/GestureTests.swift` runs through `xcodebuild test-without-building`; XCTest's event synthesis reaches the app as real touches. 20 one-finger pans (press 50 ms, drag 150 or 180 pt at 400 pt/s) and 10 pinch pairs (`pinch(withScale: 1.8)`, then 1/1.8). A drag that starts on a card does not pan (finding 1), so the app finds a point of the board's ground near the middle and shows it in a tiny label; the pans start there in out-and-back pairs (a pan moves the board 1:1, so the finger lifts over the same board point it started on). Four more pans start on the card under the centre to record finding 1.

**The frame recorder** (`App/recorder.js`, injected at document start; it reads `LinenBoard._state`, never writes it). From pointerdown or touchstart to the last finger up it records every animation-frame interval, and for each frame in which the board's view moved, the delay from the input event (its `event.timeStamp`) to that frame's animation-frame callback. Frame times are animation-frame intervals with WebKit's timer at whole milliseconds, so a 60 Hz frame reads 16 to 18; "dropped" counts frames over 25 ms, as in B(a) and `board-host`; quantiles as `board-host` computes them. The page's animation frames run at 60 Hz on the 120 Hz ProMotion screen.

**Memory.** xctrace's Activity Monitor template on the device, all processes, one sample about every second (finer than the 5 s the gate asks for); "web content memory" is the `com.apple.WebKit.WebContent` process's physical footprint (the template's Memory column). A jetsam or crash would show as the WebContent process ending and a new pid appearing, and in the app as `webViewWebContentProcessDidTerminate`.

**The loop** (`loop` mode, 10 minutes, repeating): open the board at the first section at reading zoom in Canvas; 20 pans and 10 pinches in and out; Canvas to List and back; open 5 notes, both 5 node notes on the board (`openNote`, the tap path) and 5 note files in the same page (Complete, Tables and Code, Deep Nesting, the Arabic and the blocks fixtures); and a reload after an outside change: one card's text changes, the board file in the app's Documents is replaced atomically, a directory watcher sees it and the app sends `update` as `DocumentWindow.sendUpdate` does. The loop's pans and pinches are wheel and ctrl-wheel events dispatched on the board's canvas at 60 per second, the renderer's own wheel path (`gesture()` mid-gesture, `rest()` after), not touches.

## Reproduce

```sh
cd docs/spikes/ios
bash scripts/sim-build.sh <sim udid>                       # Release, build-for-testing, install
bash scripts/sim-run.sh <sim udid> DONE 600 -LinenMode fixtures
bash scripts/touch.sh sim <sim udid> big-500
bash scripts/device-build.sh 6C03C5DB-EDDC-5669-87D7-A46D7A263745 6C03C5DB-EDDC-5669-87D7-A46D7A263745
bash scripts/device-run.sh 6C03C5DB-EDDC-5669-87D7-A46D7A263745 DONE 600 results/device -LinenMode paint -LinenBoard big-500
bash scripts/touch.sh device 6C03C5DB-EDDC-5669-87D7-A46D7A263745 big-500
bash scripts/device-loop.sh 00008130-000E719C2E3A001C 6C03C5DB-EDDC-5669-87D7-A46D7A263745 big-500 10 results/device
python3 -I scripts/fixtures-report.py results/device/fixtures.json
node scripts/reference.js results/device/fixtures.json        # the same problem lists computed on the Mac
python3 -I scripts/analyze.py results/device
```
