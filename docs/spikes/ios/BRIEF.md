# Spike I(a): Linen's renderer inside an iOS app, on Hatim's iPhone

Lane brief, written 2026-10-31 by the Linen 2.1 lead session. Your log is `docs/spikes/ios/LOG.md`; your result is `docs/spikes/ios/README.md`.

## The question
Does Linen's existing renderer (`Renderer/`), hosted in a WKWebView inside an iOS app, render Linen's notes and boards on a real iPhone 15 Pro within PRD-2's phone targets, without memory trouble? The answer decides whether Linen on iPhone (2.1, PRD-2 section 6.4) can reuse the renderer as it is.

## The gate (PRD-2 section 12, I(a); the targets are section 4's table)
Go only if all hold on the real iPhone 15 Pro "Eight":
1. The note fixtures render with **zero console errors** and **zero renderer problems** (the page's own problem log): `Tests/Fixtures/*.md`, `Tests/Fixtures/Plain Text.txt`, `Tests/Fixtures/blocks/`, and the valid files in `Tests/Fixtures/boards/`.
2. A **500-node board with real cards** (card text, status words, Arabic on some, connectors as in spike B(a)) meets the phone targets: first paint p95 under 800 ms; pan and pinch p95 frame under 16.7 ms, under 1 percent dropped, longest hitch under 50 ms, touch to frame under 30 ms. Also report the 2,000-node board (p95 frame under 25 ms, under 3 percent dropped, web content memory under 300 MB); it decides the cap, not the go.
3. A **10-minute scripted loop** (open the board, 20 pans, 10 pinches in and out, Canvas to List and back, open 5 notes, reload after an outside change, repeat) keeps web content memory under 300 MB, sampled every 5 s with `xctrace`'s Activity Monitor template on the device, with no jetsam.
Write each gate's result with its numbers, 20 runs where the PRD asks for p95, and say plainly what was not measured. If a gate fails, say what failed and the smallest change that might pass it; do not tune the renderer to pass.

## Read first
- `docs/PRD-2.md` sections 4 (measures), 6.4 (IOS rows), 9.2 (renderer), 9.4 (targets), 12 (I(a) and B(a)).
- `docs/spikes/boards/README.md`: spike B(a) on the simulator, its four rendering rules (v4), its bench page and how frames were timed. Reuse its harness ideas.
- How the Mac app hosts the renderer: the WKWebView setup, custom schemes and the native bridge in `Linen/` (search for `WKWebView`, `WKURLSchemeHandler`, `linen-page`, `linen-kit`), and `Tests/Harness/board-host.swift`, `Tests/Harness/blocks-host.swift`.
- The Loom site already runs this renderer in a browser through a shim for Linen's native side: `~/Desktop/Loom/v2/spikes/M0.md` and the shim under `~/Desktop/Loom/v2/spikes/m0b/`. Useful for the bridge; do not edit anything under `~/Desktop/Loom/`.
- Vault notes for traps: `~/vault/wiki/concepts/Product build method.md` ("Traps hit on Ferry"), and Ferry's `~/Desktop/ferry/docs/BUILD.md` for how Ferry builds and installs to this iPhone (read only).

## Where you may write
- Only inside `~/Developer/Satr/docs/spikes/ios/`: a small spike app (its own `project.yml` for XcodeGen or its own Xcode project; bundle id `com.hatim.linen.spike-ios`), a shim for the native bridge, fixture generators, bench scripts, `LOG.md`, `README.md`, build output under `docs/spikes/ios/build/`.
- Read-only everywhere else, including `Renderer/`, `Linen/`, `LinenKit/`, `project.yml`, `Makefile` and Ferry. The spike copies or references the renderer files; it never changes them. If the renderer needs a change to run on iOS, write the change down in the README as a finding.
- No git commits, no pushes, no branch changes. Nothing in the main Linen project changes.

## Devices and machine rules
- **iPhone:** "Eight", iPhone 15 Pro, iOS 26.5, CoreDevice id `<coredevice-id>`, paired and available as of 2026-10-31 14:5x. Target it by that id, never by name (a device name with a trailing space once hung `xcodebuild`). Signing: Hatim's paid team `2U8YZJV343` (automatic signing, the Apple Development certificate on this Mac). If a launch fails because the phone is locked, write that in the log, continue with the simulator work, and retry later; do not wait idle.
- **Simulator:** shared with other work. No simulator is booted right now. Boot one iPhone simulator by UDID with `xcrun simctl`, drive it with `xcrun simctl` or `idb` only, never open or raise Simulator.app (it steals Hatim's typing), and shut your simulator down by UDID when you finish. Do not install simulator runtimes.
- **Disk:** about 4.7 GB free. Keep derived data inside `docs/spikes/ios/build/`, delete large intermediate outputs you no longer need, and stop and report if free space goes under 2 GB.
- **Processes:** stop only processes you started, by their exact PID. Never `pkill` or `killall`.
- **Mac input:** do not send synthetic keys or clicks to the Mac's GUI; Hatim is using it.
- **Timestamps:** every time you write into a file comes from `date`.

## How to work
- Do not create agents. Do the work yourself.
- Keep a `## CHECKPOINT` block at the top of `LOG.md` (what is proven with numbers, what is in progress, the exact next step, files you own) and rewrite it at every milestone and at least every 20 minutes, so a fresh lane can continue if you stop.
- Measure your own context with `python3 ~/Desktop/Kit/ctx-meter/ctx.py <your transcript>` now and then; at 800k tokens finish the current item, write the checkpoint and stop.
- Proof comes from independent reads: frame times from the page's own animation-frame timing plus signposts or xctrace, memory from xctrace on the device, render problems from the renderer's own problem log and the web inspector console. The app's own claims never count as proof.
- Order: the simulator first (app shell, renderer loading every fixture with zero errors, the bench running), then the device (install, first paint, frame runs, the 10-minute loop).

## Report back
When done, or when blocked, reply with: each gate's go or no-go with its numbers, what ran on the device versus the simulator, anything not measured and why, renderer changes iOS would need, and the paths of `README.md` and `LOG.md`.
