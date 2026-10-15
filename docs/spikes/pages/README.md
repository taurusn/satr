# Spike P(a): sealed HTML pages

**Question.** Can Linen show a self-contained HTML page with its own scripts running, while nothing the page does reaches the network or the disk?

**Answer: yes, with four layers: a content rule list, a CSP response header, a navigation gate, and a document-start script in every frame that removes WebRTC and WebTransport. The first three alone let WebRTC out (P(b) below).**

## How it was tested (2026-10-14, macOS 26.5, MacBook Air M4)

- `witness.py` listens on 127.0.0.1 and logs every TCP connection (with a timestamp) and every request line, any method.
- `sealed.swift` serves one test page from a `linen-page:` scheme handler into an offscreen `WKWebView` (non-persistent data store). The page tries 30 ways out, each naming itself in the URL: `fetch` (cors and no-cors), XHR, WebSocket, EventSource, `sendBeacon`, `<img>`, `srcset`, `<picture>`, `<video>`, `<audio>`, `<object>`, `<embed>`, `<iframe src>`, `<iframe srcdoc>` with an image and a fetch inside, SVG `<image>`, CSS `background-image`, `@font-face`, `@import`, `<link rel=stylesheet|prefetch|preload|preconnect|dns-prefetch|icon>`, `<script src>`, dynamic `import()`, a blob Worker that fetches and calls `importScripts`, `FontFace` from JavaScript, a style added by script, a form POST, `<a ping>`, `window.open`, `location.href`, and `file:` reads (`fetch('file:///etc/hosts')`, a `file:` image).
- The same page runs under four seals: **none**, **rules** (a `WKContentRuleList` that blocks `.*` and lets `linen-page:`, `about:`, `blob:` and `data:` through), **csp** (a `Content-Security-Policy` response header from the scheme handler: `connect-src 'none'`, every other source limited to `linen-page:`, inline script and style allowed), and **both**.
- The navigation delegate allows only `linen-page:` and `about:` navigations and records the rest; the UI delegate refuses popups.

Build and run:

```sh
swiftc -O -o build/sealed docs/spikes/pages/sealed.swift -framework AppKit -framework WebKit
python3 -I docs/spikes/pages/witness.py 48713 /tmp/w.log & ./build/sealed 48713 /tmp/w.log
```

## Results

| Seal | Page script ran | Requests at the witness | TCP connections at the witness | Navigations the app cancelled |
|---|---|---|---|---|
| none | yes, 17 script probes started | **26** (every kind above except the `file:` probes, `window.open`, forms, frames and navigations) | 27 | 6: iframe, object, embed, form, popup, main-frame navigation |
| rules | yes | **0** | **0** | 3: iframe, form, main-frame navigation |
| csp | yes | **0** | **1** (a connection with no request: `preconnect`, which CSP does not govern) | 2: popup, main-frame navigation |
| both | yes | **0** | **0** | 1: main-frame navigation |

- The `file:` probes never loaded in any seal: a page served from a custom scheme cannot read `file:` URLs.
- `localStorage` works but lives in the non-persistent store, so it dies with the tab.

## What this means for the PRD (P(a), corrected by P(b))

1. A sealed page uses all four layers (see P(b) for the fourth): the content rule list (the only layer that stopped the TCP preconnect), the CSP header from the scheme handler (a second wall, and the one that also covers `about:srcdoc` frames), and the navigation and UI delegates (frames, forms, popups and the main frame never navigate off `linen-page:`).
2. The page's own `<meta>` CSP can only narrow the header's policy, never widen it.
3. Still to check on iOS in the simulator and on the iPhone (M10): the same page, the same seals.
4. Not covered by P(a): UDP and name lookups (P(b) covers them), and WebKit bugs. A sealed page is as safe as Safari with no network; the rule list and the data store keep it from reaching anything of the reader's.

## Spike P(b): WebRTC, WebTransport and name lookups (2026-10-14)

**Why.** P(a)'s witness only listened for HTTP on 127.0.0.1. The iPhone research lane's own leak test (kept outside the repository) saw WebRTC STUN packets leave a page sealed with the rule list, the CSP header and the navigation gate, and even with a CSP `webrtc 'block'` directive.

**How.** `witness2.py` adds UDP and TCP listeners on the Mac's Wi-Fi address (one port per seal, so the port names the seal; WebTransport aims at its own port) and an mDNS listener that logs any lookup of a `linenprobe-*.local` name. `webrtc.swift` serves one page that makes a WebRTC peer connection (a STUN server, a STUN server by `.local` name, a TURN server over TCP) from the page and from every kind of frame a page can make: an `about:blank` frame, a frame rewritten with `document.open`, `srcdoc`, sandboxed `srcdoc`, nested `srcdoc`, `data:` and `blob:`. It also opens a WebTransport session, looks up `.local` names through an image, `dns-prefetch`, `preconnect`, `prefetch`, `fetch` and a WebSocket, and reports what still works for a kit page: a font from `linen-page:` (from CSS and from `FontFace`), WebAssembly, WebGL and a 30-million-step loop.

```sh
swiftc -O -o build/webrtc docs/spikes/pages/webrtc.swift -framework AppKit -framework WebKit
python3 -I docs/spikes/pages/witness2.py 48714 "$(ipconfig getifaddr en0)" 48800 /tmp/w2.log &
./build/webrtc 48714 "$(ipconfig getifaddr en0)" 48800 /tmp/w2.log /System/Library/Fonts/Supplemental/Arial.ttf
```

**Results** (two runs, same outcome; macOS 26.5.1, offscreen window, never activated):

| Seal | WebRTC made | At the witness | Script loop | Kit fonts | WebAssembly, WebGL |
|---|---|---|---|---|---|
| none (navigation gate only) | in all frames | STUN over UDP, TURN over TCP, WebTransport over UDP and TCP, `.local` lookups from fetch, image, preconnect and WebSocket | 21 ms | load | yes |
| **P(a) seal**: rules + CSP + gate | in all frames | **STUN over UDP and TURN over TCP**; WebTransport rejected; no lookups | 22 ms | load | yes |
| P(a) seal + **kill script** | nowhere (TypeError in every frame) | **nothing** | 22 ms | load | yes |
| P(a) seal + **lockdown** (`isLockdownModeEnabled`) | nowhere | **nothing** | **932 ms** (no JIT) | load | **no** (also no service worker) |
| rules + kill script, CSP off, gate letting `data:` and `blob:` frames through | nowhere, including the `data:` and `blob:` frames | **nothing** | 20 ms | load | yes |

- The kill script is a `WKUserScript` at document start in all frames (`forMainFrameOnly: false`) that deletes `RTCPeerConnection`, `webkitRTCPeerConnection`, the other `RTC*` constructors and `WebTransport` from `window` and pins them to `undefined` (not configurable, not writable), so a page cannot restore them. It reached every frame kind tested, including a frame rewritten with `document.open`.
- `dns-prefetch` and `prefetch` produced no lookup even with no seal, so this spike cannot say whether they would leak a name; the rule list blocks them as loads in any case.
- `securityRestrictionMode` (the newer per-navigation hardening) is macOS 26.5 only in the SDK header (`ios(NA)`), so it cannot be the iPhone's answer.

**What this changes in the PRD.** PAGE-1 gains the fourth layer. Lockdown stays a possible stricter mode only: it seals as well but makes page scripts about 40 times slower and removes WebAssembly and WebGL. The sealed probe set in section 10 now includes this page, on both devices.

## Spike P(c): the page model (2026-10-15, macOS 26.5.1 build 25F80, WebKit 21624.2.5.11.4, MacBook Air M4)

**Question.** Does the page model of PRD-2 section 9.2 hold: one random origin per opened page, a handler that answers only that host and the page's own folder, the kit as its own origin, the CSP on every response, the four walls in every script realm, PAGE-11's capability denial, links only from real clicks, and the kit's isolated world out of the page's reach?

**Answer: go on the Mac, with one change.** Zero escapes under the full seal in every realm and every probe, against a witness that saw 321 to 336 hits from the same page unsealed (two full runs; counts vary with WebRTC retries). The change: WebTransport inside a dedicated worker was stopped by the CSP alone (the content rule list does not cover WebTransport, and the removal script cannot reach worker globals), so the seal gains a fifth wall: WebKit's own feature flags turn WebTransport, WebRTC and service workers off for the page's configuration. With the flags, either the CSP or the rule list alone also gives zero escapes. `sandbox allow-scripts` is not adopted: it breaks sibling JSON, workers from files, frames' scripts and storage, and adds nothing the walls lack. The iOS simulator half was not run tonight.

### How it was tested

- `pc.swift` is a driver compiled with Linen's own `Linen/Pages/*.swift` (PageScheme, KitScheme, PageSeal, SealedPageController), `SafeOpen` and `TrustedFolders`, so the spike tests the code the app ships, not a copy. `pc-witness.py` listens for HTTP and WebSocket on 127.0.0.1, ::1 and the Wi-Fi address; UDP and TCP on all three for 240 ports (each seal and realm aims at its own port, so a packet names its source); and mDNS queries for `linenprobe-*.local`.
- One probe page (`build/pc/sites/site-a/page.html`, written by the driver) runs the same probe in nine realms: the page, a same-origin frame, a srcdoc frame, an SVG document frame, a dedicated worker from a file, a dedicated worker from a blob, a shared worker, an audio worklet and a paint worklet. Each realm tries fetch (CORS and no-cors) to loopback, ::1, the Wi-Fi address and a `.local` name, XHR, WebSocket (three addresses), EventSource, WebTransport, WebRTC (STUN on three addresses and TURN over TCP), `importScripts` off origin, `sendBeacon`, images, another `linen-page:` host and an unlisted kit file, beside a positive control that fetches `data.json` from its own origin.
- The page also checks its siblings (image, script, style, JSON) and the kit (stylesheet, font, an unlisted kit file, a path escape from the kit), the isolated world (page globals, a forged post to the kit's handler, the theme attribute and `linen:theme` event), the PAGE-11 capability probes, and script-made clicks. The driver then puts the window on screen and sends real mouse clicks and hovers (`NSEvent` into the window) at each link.
- Seals: **open** (control: no walls), **full** (rule list, CSP, removal script, navigation gate, engine flags), **csponly** and **rulesonly** (one network wall each, no removal script, no flags), **sandbox** (full plus `sandbox allow-scripts`), **flagscsp** and **flagsrules** (one network wall plus the engine flags).
- A writer page and a reader page from two folders, open at the same time, check storage and file isolation.

```sh
swiftc -swift-version 6 -parse-as-library -o build/pc/pc docs/spikes/pages/pc.swift Linen/Pages/*.swift Linen/Document/Schemes.swift \
  Linen/Document/SafeOpen.swift Linen/System/Log.swift Linen/App/TrustedFolders.swift Linen/Design/Tokens.swift -framework AppKit -framework WebKit
python3 -I docs/spikes/pages/pc-witness.py 48731 "$(ipconfig getifaddr en0)" 48900 build/pc/witness.log &
./build/pc/pc 48731 "$(ipconfig getifaddr en0)" 48900 build/pc/witness.log build/pc/sites    # results: build/pc/pc-results.txt
```

### Results

| Seal | Hits at the witness | What got out |
|---|---|---|
| open (control) | **321 to 336** | everything: HTTP from every realm on all three addresses, WebSocket upgrades, beacons, images, `importScripts`, mDNS lookups from fetch and images, STUN and TURN, QUIC from WebTransport |
| **full** | **0** | nothing |
| csponly (no rule list, no removal, no flags) | 52 to 64 | WebRTC STUN and TURN from the page and its frames (the CSP does not govern WebRTC, as P(b) found) |
| rulesonly (no CSP, no removal, no flags) | 184 to 190 | WebRTC from the page and frames, and **WebTransport QUIC from the page, frames and both dedicated workers**: the rule list does not cover WebTransport |
| sandbox | 0 | nothing, but the model breaks (below) |
| flagscsp (CSP + flags only) | **0** | nothing: WebRTC and WebTransport are gone from every realm |
| flagsrules (rule list + flags only) | **0** | nothing |

**Every realm, full seal:** each off-origin probe was blocked (fetch `TypeError`, WebSocket and EventSource `SecurityError`, XHR error, `importScripts` `NetworkError`, beacon queued but nothing arrived). Positive controls: the own-origin fetch worked in the page, frame, srcdoc frame, SVG frame and both dedicated workers. Realm by realm:

- **Shared worker:** its script loads through the handler, but nothing it fetches reaches the custom scheme, in any seal including open (its own-origin control and `importScripts('probe.js')` fail with no seal at all). Unsealed it reached the network; under the full seal, and under the CSP or the rule list alone, nothing. So shared workers run, are walled by both network walls, and cannot load files from the page's folder.
- **Audio worklet:** loads from the page's origin; fetch, XHR, WebSocket, EventSource, WebTransport, WebRTC and `importScripts` do not exist in it, sealed or not.
- **Paint worklet:** `CSS.paintWorklet` does not exist in this build (WebKit's "CSS Painting API" flag is off by default). No realm to wall.
- **Workers and WebTransport:** in the full seal before the flags, WebTransport existed in both dedicated workers and was rejected by the CSP only. With the flags it does not exist in any realm.

**The handler and the kit (full seal):**
- Siblings load: image, script, style (`width: 123px` from the sibling CSS), JSON by fetch. `'self'` matches the per-open origin on the custom scheme (`connect-src 'self'` lets `data.json` through; `script-src 'self'` lets `sibling.js` run). `isSecureContext` is true.
- Another random `linen-page:` host: refused by the CSP first (`img-src`/`connect-src 'self'`) and by the handler when the CSP is off ("another host", 6 refusals in the open and rulesonly runs).
- The kit: `loom.css` applies (`--paper` is `#F6F3EB`), Thmanyah Sans loads from the kit origin (159 px against 217 px in the fallback face); an unlisted kit file is refused by the kit's handler (the `<link>` keeps an empty `sheet` object, which is why the page itself reported it as loaded); fonts are not readable by `fetch` under the CSP (`connect-src 'self'`), only through `font-src`.
- Paths: `..`, `%2e%2e`, an encoded separator (`%2F`), a NUL, a hidden file, a dot-folder and a symlink that leaves the folder are all refused; a symlink inside the folder is served. The home folder, `/`, a volume root and the tops of Desktop, Documents and Downloads are broad roots (only the page itself is served). Every response carries the CSP and `nosniff` (page, frame, SVG, worker, shared worker, worklets, images).

**Two pages:** the reader found nothing of the writer: `localStorage` and `sessionStorage` null, no IndexedDB database, no cookie, no BroadcastChannel message; fetching the writer's origin, `../`, `%2e%2e`, an encoded separator, a symlink out and `file:` all refused; a frame pointed at the writer's origin stayed `about:blank`. Separate web content processes (two pids).

**Capabilities (PAGE-11), full seal, script-made:** `alert`, `confirm` and `prompt` dropped by the UI delegate (0 to 1 ms, `confirm` false, `prompt` null); the file input's script click opened nothing; `getUserMedia`, `getDisplayMedia`, geolocation, `Notification`, clipboard read, `share` and `credentials` are removed (in csponly, where the removal script is off, `getUserMedia` reached the delegate and was denied, clipboard read failed `NotAllowedError`, geolocation failed); fullscreen refused; `window.open` returned null with no delegate call; frames to `mailto:` and `obsidian:` and `location.href = 'obsidian://...'` cancelled by the gate; a download by script cancelled; `a.click()` on an `https:` and a `mailto:` link went nowhere and asked nothing. No file drop types are registered on the web view.

**Real clicks (full seal, on screen):**

| Link | What Linen did |
|---|---|
| `mailto:`, `obsidian:` | refused with one line naming the scheme; the gate also cancelled the navigation |
| `file:///System/Applications/Calculator.app`, `file:///etc/hosts` | refused, naming the file; nothing launched |
| `https://example.com/linen/full-address?q=1#frag` | asked with the full address, query and fragment included; declined in the test, nothing opened |
| `sub/inner.html`, `notes.md` (in the page's folder) | handed to Linen to open; the page itself stayed |
| `#out` | scrolled in the page |
| `<a download>` | refused (in one of four runs the driver's click, sent while the page was still scrolling after the fragment jump, missed the link; nothing happened either way) |
| a button whose real click calls `window.open` | `window.open` returned null; no delegate call, no prompt |
| `<input type=file>` | the open panel was refused by the delegate; no panel appeared |

**The isolated world:** page scripts see `typeof __linenKit === 'undefined'` and no `webkit` object; posting to the kit's handler from the page throws `ReferenceError`. The kit set `data-linen-theme="paper"`, and after `setTheme("night")` the page saw the attribute change and a `linen:theme` event with detail `"night"`. A real hover over a `data-note` element showed the note card after 300 ms in a closed shadow root; the page could see the card's host element but not its text.

**Scripts off (untrusted folder):** no page script ran (not the inline one, not the probe), while the kit's isolated world still did (theme attribute set, ping answered).

**sandbox allow-scripts:** zero escapes, but sibling JSON fails (`TypeError`: the opaque origin makes its own folder cross-origin), a worker from a file fails, the frame and SVG frame never report, the shared worker fails. Not adopted.

### What this changes in the PRD

1. PAGE-1 and 9.2 gain a fifth wall: **engine flags** (WebKit's `WebTransportEnabled`, `PeerConnectionEnabled` and `ServiceWorkersEnabled` turned off for the page's configuration). They are WebKit SPI, applied only when present; when a future WebKit drops them the other four walls stand and PAGE-10's inventory notices the APIs coming back. Without them WebTransport in a dedicated worker has one wall (the CSP), measured.
2. "The removal script reaches frames, not worker globals, so workers rely on the CSP and the rule list" is only half true: the rule list does not cover WebTransport. With the flags, workers have two walls for every probe.
3. Shared workers cannot read the page's folder on a custom scheme (WebKit), and paint worklets do not exist in this build; PAGE-10's realm list keeps both so a change is noticed.
4. `sandbox allow-scripts` is not adopted (breaks the page model, adds nothing).
5. Not covered here: the iOS simulator and the iPhone (M11), unicast DNS (only `.local` lookups are witnessed; a full packet capture is still Hatim's run).

## The pages module after P(c): self-test, stress and the reference pages (2026-10-15)

Run with `build/pagehost` (`docs/spikes/pages/pagehost.swift`, compiled with `Linen/Pages/*.swift` the same way as `pc.swift`).

**Inventory (PAGE-10).** `pagehost inventory Linen/Pages/Inventory/webkit-21624.2.5.11.4.txt` walks every realm in the sealed configuration: page 15,311 lines, frame 15,332, dedicated worker 6,176, blob worker 6,176, shared worker 5,279, audio worklet 1,734, paint worklet absent. Walked twice in 2.0 s, identical; a second process's self-test matched it, so the walk is stable across launches. 2.2 MB of text. Reviewed: every removed constructor (`RTC*`, `WebTransport*`, `Notification`, `Payment*`) is pinned to `undefined` in the window realms, `Clipboard.prototype.read` and `readText` are `undefined`, WebTransport is absent from the workers (engine flags), and the audio worklet has no network API. A frame's walk stops at its parent's window (that realm is walked on its own), which keeps the frame realm the same size as the page's.

**Self-test (PAGE-10).** `pagehost selftest <inventory>` passed in 8.5 s after Codex review 1 (`docs/reviews/m9-pages-codex-final.md`): the inventory check, the realm walk, then probe pages in every realm P(c) measured (page, frame, srcdoc frame, SVG frame, both dedicated workers, shared worker, audio worklet) aimed at a loopback witness on IPv4 and IPv6, a control run with no walls that its witness must see from every realm, and a sealed run against a fresh witness that must see nothing, with own-origin controls and 15 script-made PAGE-11 capability probes that must all come back refused. `pagehost selftest-negative <inventory>` runs PRD-2 section 13's cases plus two more; each turned page scripts off with its line:

| Case | Line | Time |
|---|---|---|
| a WebKit build with no reviewed inventory | "this version of WebKit (...) has not been reviewed for Linen yet" | 0.0 s |
| an innocently named global | "WebKit changed what pages can reach (5 new, 0 gone in page)" | 1.5 s |
| an extra prototype method | "(1 new, 0 gone in page)" | 0.5 s |
| an accessor | "(1 new, 0 gone in page)" | 0.5 s |
| an instance-owned property on `navigator` | "(3 new, 0 gone in page)" | 0.5 s |
| a method on a prototype not exposed as a global (StorageManager hidden in both builds, the method reached only through `navigator.storage`) | "(1 new, 0 gone in page)"; the same build without the method passed | |
| one escape at the witness (the sealed run made with no walls) | "a test page got through the seal" | 16.1 s |
| a witness that is down (probes aimed one port off) | "the seal check could not see its own test traffic" | 2.4 s |
| a probe page that never reports | "the seal check did not finish" | 20.2 s |
| a capability granted (`confirm` replaced by an arrow function that says yes, which leaves the inventory unchanged) | "a test page was given something pages must not have (confirm)" | 8.7 s |
| a realm that cannot start (`Worker` throws) | "the seal check could not reach every part of a page (worker)" | 0.4 s |
| the reviewed build afterwards | passed cleanly | |

**A page cannot take Linen down (PAGE-12).** `pagehost stress` opens a live page (a counter every 100 ms) beside each bad page:
- An endless loop: "This page stopped responding · Stop page" 5.2 s after the loop began (a ping unanswered for 4.75 s, checked every 0.25 s; 6.0 s with the first, 0.5 s cadence); Stop page rebuilt it with scripts off and it answered 0.2 s later; the first web content process was gone (Linen ends it with WebKit's `_killWebContentProcess`); the live tab's slowest answer was 2 ms.
- An endless allocation: it kept answering pings, so the stall line never came (4.5 GB in 25 s in a first run with no limit). The watchdog now also reads the web content process's footprint (WebKit's process id, an SPI, and `proc_pid_rusage`) every second and stops a page past 1 GB: stopped at 1,310 MB, its process gone, reopened with scripts off and "This page used too much memory; opened without scripts"; the live tab's slowest answer was 27 ms. A scripts-on page whose footprint cannot be read for 2 s has its scripts turned off.

**Reload holding the place (PAGE-5).** With the view at section 30 of 60, 200 words were inserted above it and the file reloaded: section 30's top moved from 0.5 px to 1.3 px from the top of the view.

**Hatim's three reference pages, sealed with scripts on against plain WebKit loading the same file** (read in place from their folders, never copied; screenshots kept outside the repository): pixel-identical at 1176 px for all three (the readiness map 2352 x 1800 device px, the HLD 2352 x 9850, the lab report 2352 x 24000, full length), and for the map also at 390 and 1440 px. The map draws with its own script (its notes are built into the file, so nothing is fetched). No request was refused for any of them.

**Failing closed, seen by accident:** a rerun of `pc.swift` before it learned to run the seal check first got "NO REPORT" from every seal: with no passed check for this build, the controller ran no page script at all. The driver now runs the check first (it passed), as the app does at launch.

**After Codex review 2** (`docs/reviews/m9-pages-codex-final.md`): every tab loads Linen's preflight page in its own configuration before the author's page and proves its rule list (a canary path on its own origin the rule list blocks), removal script and CSP; with the rule list or the removal script left out the author's page was never requested and the tab showed source (`pagehost preflight-negative`).

**Not tested here:** the context menu filter (a real right click opens a modal menu that would stop the driver), the iOS simulator and the iPhone, and how the app's own tab, menus and Settings host the controller (main thread).
