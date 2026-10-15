# M9 sealed pages: Codex review 1 and what was done (2026-10-15)

Codex reviewed `Linen/Pages/` read-only after spike P(c) (raw transcript kept locally in `m9-pages-codex.md`). Verdict: "not fit to integrate; the mutable-root escape, host-process crash/OOM paths, incomplete self-test, and hung-page fail-closed transition are blockers." 20 findings: 5 blockers, 12 major, 3 minor. Below, each finding and what was done; then the checks rerun after the fixes.

| # | Severity | Finding | Done |
|---|---|---|---|
| 1 | blocker | The folder boundary is a path: rename the folder and put a symlink in its place, and the page reaches the new target | Fixed: `PinnedFolder` opens the folder once with `O_DIRECTORY \| O_NOFOLLOW` and keeps the descriptor for the tab's life; every file, the source view and link checks walk from that descriptor |
| 2 | blocker | `Range: bytes=0-9223372036854775807` overflows `b + 1` and traps in Linen | Fixed: the end is clamped before adding one; an unsatisfiable range answers 416 |
| 3 | blocker | No request, in-flight or total limits: many references to a 50 MB file can exhaust Linen's own process | Fixed: 64 requests in flight, 1 GB served per load, three reads at a time and each read held until delivered (at most about 150 MB in Linen's memory), everything cancelled on teardown. Not adopted: chunked streaming, since SafeOpen already caps a file at 50 MB |
| 4 | major | A disk image mounted at a custom path is a volume root but not seen as one | Fixed: `isVolume` from the file system, not the path's shape |
| 5 | major | The scheme resolved the page's symlink at one time and the policy at another | Fixed: the controller resolves the page once; policy, serving, links, reload and the source view use that one identity |
| 6 | major | A link was checked by descriptor, then handed on by its unresolved path | Fixed: opened from the pinned folder and handed on by the path the kernel reports for the open file (`F_GETPATH`) |
| 7 | major | A focused text field can receive a paste | Disagreed: a paste the person makes is their own act, like typing; PAGE-11 denies reads a page makes by itself. Covered: the async Clipboard API is removed, `execCommand('paste')` is refused (now a self-test probe), the context menu has no Paste or Services items |
| 8 | minor | Authority checks ignored port and user; `SecRandomCopyBytes` failure gave an all-zero host | Fixed: exact authority (no port, user or password) for pages and the kit; hosts from `SystemRandomNumberGenerator`, which has no failure path |
| 9 | blocker | A revocation waited on `place()` from a page that may be hung, so scripts stayed on | Fixed: a revocation tears the page down at once; only a grant tries to keep the place, with a 300 ms limit; every isolated-world call now has a timeout |
| 10 | blocker | The app's probe page was smaller than P(c), a timeout wrote success, and worker errors counted as done | Fixed: every realm P(c) measured (page, frame, srcdoc frame, SVG frame, both dedicated workers, shared worker, audio worklet) must report, with own-origin controls; IPv6 loopback added; a missing report, error or timeout fails |
| 11 | major | No PAGE-11 capability probes in the self-test | Fixed: 15 script-made probes in the sealed run, each must come back refused; a negative case where `confirm` says yes with the inventory unchanged fails closed |
| 12 | major | Paint worklets only present/absent; error strings could enter a reviewed baseline | Fixed: an inventory with any error sentinel is refused, and the check fails on one; paint worklets appearing turns scripts off until Linen can inventory them |
| 13 | major | A rerun did not clear an earlier pass first; a hung call could outlive the deadline; a cancelled listener never resumed | Fixed: "not passed" is stored before the first wait; isolated-world calls have timeouts; listener waits resume on cancel and after 5 s |
| 14 | major | A compiled rule list was taken as installed, and the removal script's run was not checked per page | Partly: after each load Linen checks in the page's own world that the removal script pinned WebRTC (a non-configurable `undefined` only it can have set before the page ran) and shows source when not. A first try with a document-start nonce raised false alarms (the order of user scripts across worlds in new frames is not fixed) and was dropped. Residual: WebKit offers no way to read back an installed rule list; a compile failure shows source and the self-test runs the same configuration code |
| 15 | major | Trusted-folder and per-file changes did not reach open tabs | Fixed: any user defaults change and the seal check's change re-evaluate the tab; a revocation applies at once |
| 16 | major | SPI used unsafely; memory accounting failing silently turned enforcement off | Fixed: engine flags only on a reviewed WebKit build (or while writing its inventory), with `respondsToSelector` guards; a scripts-on page whose memory cannot be read for 2 s has its scripts turned off |
| 17 | major | Rebuilds not serialized; ping tasks kept a hung web view and its process alive | Fixed: builds carry a generation checked after every wait; teardown drops observers, handlers and requests and ends the web content process (`_killWebContentProcess` when present); pings hold no reference to the web view. Measured: the hung page's process is gone after Stop page |
| 18 | minor | `about:`, `blob:`, `data:` links treated as in-page | Fixed: refused with a line; `javascript:` stays in the page (it is the page's own script) |
| 19 | major | PAGE-9 is not implemented in the controller | Accepted as a scope fix: the controller's print and PDF are WebKit's raw output, documented as the input to Linen/Export, which owns EXP-7 and EXP-8 |
| 20 | minor | Every off policy was reported as "untrusted" | Fixed: the reason follows the policy's source; a per-file "off" shows "Scripts are off for this page · Run this page" |

## Checks after the fixes

- `build/pagehost selftest`: passed in 8.5 s. `selftest-negative`: all 12 cases turn scripts off with their line (adds a capability granted with the inventory unchanged, and a realm that cannot start), and the reviewed build passes cleanly afterwards.
- `build/pagehost stress`: endless loop, stall line 5.2 s after the loop began (watchdog every 0.25 s), scripts-off page answering 0.2 s later, the first web content process no longer running; endless allocation stopped at 1,310 MB, its process gone; the live tab's slowest answer 27 ms.
- `pc.swift`: zero hits at the witness under the full seal (336 with no seal), same matrix as before.
- The three reference pages: still pixel-identical sealed and plain at 1176 px.

## Codex verification (review 2) and the fixes after it

Codex: 13 of 20 resolved, 6 partly, 1 not (the paste disagreement, which it accepted); 4 new defects; verdict still "not fit to integrate" on three points. All three and the four new defects were fixed the same morning:

- **The folder is pinned for the tab's life** (item 1, 5): the controller opens `PinnedFolder` once and passes it to every rebuilt handler and to the source view; nothing re-resolves the path.
- **The self-test's realms** (item 10): every realm must start and report; only the shared worker may report its own-origin fetch as failed (as P(c) measured in every seal), never "threw" or "error".
- **Each tab proves its walls before the author's page loads** (item 14, rejected residual): the tab first loads Linen's own preflight page in its exact configuration, which checks that the removal script pinned WebRTC, that the rule list blocks a canary path on the page's own origin (a rule added for this), and that the CSP reports a violation. Only then does the author's page load; otherwise the tab shows source. `pagehost preflight-negative`: with the rule list left out the author's page was never requested ("preflight failed rules"), the same with the removal script left out, and a normal tab passed all three.
- New: a symlinked `.md` to an executable is refused (the resolved file's type is checked); closing a tab during a build stops the build; the stress test's pass now requires the old process gone and the live tab under 100 ms; the witness clears its listeners.

After these: self-test passed (8.8 s), all 12 negative cases, stress PASS (loop 5.2 s, allocation stopped at 1,442 MB, old processes gone), the three reference pages pixel-identical, and `pc.swift` zero escapes under the full seal. The Mac had moved from the phone hotspot to home Wi-Fi before that last `pc.swift` run, so its Wi-Fi probes aimed at a dead address; loopback and IPv6 were witnessed (133 hits with no seal).
