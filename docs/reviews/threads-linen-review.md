# Fresh-eyes review: threads-linen (L1 to L4), 2026-11-14

Scope: `git diff 1a88f53` in ~/Developer/Satr plus the new files (`Linen/Design/TitledControls.swift`, `LinenHelper/DevControl.swift`), the lane log, PRD-2's 2026-11-14 entries and the L2/L3 evidence. I read code, diffs, tests and evidence only. I ran no builds, simulators or apps.

Counts: P0 0, P1 0, P2 6, P3 8.

## P2

### P2-1. Once Bonjour reports "denied", an unreachable Mac is always reported as "local network off"
`LinenKit/Sources/LinenKit/Link/LinkRoutes.swift:142-144`, `:177-181`, `:224`

The dialer now records `denied = true` and keeps going, which is right. But nothing clears the flag. `fail()` checks `denied` before anything else.

Concrete case, a first pairing: iOS shows its local network question and Bonjour reports PolicyDenied. The person taps Allow after 4 s. The Mac still cannot be reached: the helper is not listening (the L1 bug itself), the Mac is asleep, or the phone is on another network. At 15 s the phone says local network access is off and points to Settings, where access is already on.

The same thing happens in the sync dialer, so the Library status can show "local network off" for a Mac that is only asleep.

Fix: set `denied = false` in `dial(_:)` whenever `eps` is not empty, since results mean access was granted. Also set it when a connection leaves `.waiting(localNetworkDenied)`. Or give `LinkRouteSource` an `allowed` callback on the browser's `.ready`.

### P2-2. The pairing proof rejects a real pinned session whose first frame is `changed`
`LinenKit/Sources/LinenKit/Link/MirrorLink.swift:533`, against `MacLinkServer.swift:497`, `:511`, `:585`

The new check accepts only `.pins` or `.manifest` as proof. The Mac sends `changed` to every pinned session when a pin is added or removed (`:497`, `:511`) and after every rescan that changes a manifest (`:585`). Any of these can reach the confirm session after its TLS is ready and before the Mac handles its `hello`.

Concrete case: Allow went through but the `pair-result` was lost on the way, so the phone confirms. In that window, PinWatcher rescans a pinned folder that an agent is writing to. The phone reads `changed`, shows "refused" (or "timeout"), and stores nothing. The Mac lists the phone as paired.

The window is milliseconds, but it is in the path built for flaky links.

Fix: accept any frame that only a pinned session carries:
```swift
guard f.type.session == .pinned, f.type.sender == .mac else { /* refused */ }
```
This keeps `pairResult` (busy) out. Add a loopback test for each case: busy is not proof, and `changed` first still pairs. Today neither has a test (see P3-4).

### P2-3. The restart delay goes back to 1 s on `.ready`, so a listener that reaches ready and then fails restarts about once a second for as long as the fault lasts
`LinenKit/Sources/LinenKit/Link/MacLinkServer.swift:206-209`, `:233-235`

`restartDelay = 1` runs on every `.ready`. The 11-12 failure was "ready, then failed when advertising failed". If mDNSResponder stays broken, or registration keeps failing, each new listener binds (`.ready`, delay reset to 1) and then fails, so the 1-2-4…30 s backoff never grows.

Concrete case: restarts every 1-2 s with no end. Each one calls `changed()`, which pushes state over XPC, so an open Settings › iPhone pane switches between the QR and "Getting ready for your iPhone" about every second. The log fills too.

I could not confirm without running it that a fresh NWListener reports `.ready` before a registration failure. The code path allows the loop either way.

Fix: reset the delay only once the listener has stayed ready for a while. For example, store `readyAt` and in `listenerFailed` reset only if `Date().timeIntervalSince(readyAt) > 30`. Or reset on `serviceRegistrationUpdateHandler .add`, the proof that advertising worked.

### P2-4. The confirm probe ends a still-open pairing mode as a "violation"
`MirrorLink.swift:525` (sends `hello`), `MacLinkServer.swift:356-366`, `Pairing.swift:150-155`

The phone's confirm step dials as itself and sends `hello`. When the phone is not pinned and the QR is still up, the Mac treats that session as a new pairing session. A `hello` on a pairing session is a misstep, so the Mac closes pairing mode as `.violation`.

The new 75 s deadline adds a way to reach this. Concrete case: the route carries nothing in either direction, so the `pair-code` never reached the Mac and the Mac never entered `waiting`. QR opened at t, scanned at t+10 s, deadline at t+85 s, still inside the 120 s lifetime. The phone cancels, and the Mac's session ends without `waiting`, so pairing mode stays open. The phone's confirm session is then accepted as a new pairing session, and its `hello` ends pairing mode as a violation.

The Mac shows a misstep message for what was a dead route. The phone says "timeout". The owner has to press Pair again. The lost-answer path had the same flaw before this change.

Fix (the owner should decide, since this touches the rule that any misstep ends pairing mode): on a pairing session, close a first-frame `hello` from an unpinned certificate quietly, with `sessionEnded(violation: false)`, no strike and nothing sent. An unknown certificate gets nothing from a `hello`, so this gives an attacker no new opening. Every other misstep stays a violation.

### P2-5. `docs/lanes/` (13 MB of machine-specific material) is untracked but not ignored, in a public repo
`.gitignore`

The tracked diff is clean: no home paths, IP addresses, UDIDs or team ID. "Hatim" in comments matches what PRD-2 already says.

But `docs/lanes/` holds build logs with `/Users/hatim/...` paths, the signing team ID, PIDs, simulator and device details, and screenshots. `docs/CHECKPOINT-2.1.md`, `docs/spikes/ios/results/` and the two `r8-linen21-*` reviews are in the same state. One `git add -A` or `git add docs` publishes all of it. The lane works next to agents that commit.

Fix: add `docs/lanes/`, `docs/CHECKPOINT-*.md`, `docs/spikes/*/results/` and this review file to `.gitignore`, or move the lane folders out of the repo.

### P2-6 (existing before this change, outside the diff). A `linen://pair` link starts pairing with no tap on the phone, and a different Mac's Allow wipes the mirror
`LinenIOS/App/AppModel.swift:122-125`, `LinenIOS/Library/PairingScreen.swift:86-90`, `MirrorLink.swift:490`

A pairing code that arrives by URL goes straight to `scanned(code)` and the phone dials. If the code names another Mac on the same network, and that Mac's owner clicks Allow, `completePairing` replaces the record and calls `mirror.wipe()`. Everything kept from Hatim's Mac is removed.

Concrete case: a link or QR on a web page or in a message (one tap on iOS's "Open in Linen?"), on a shared Wi-Fi network, with the attacker's Mac in pairing mode. The six digits bind the session, but they cannot protect against a Mac the attacker controls.

Fix: when the code came by URL rather than the camera, show "Pair with <Mac name>?" with Continue before dialing. When pairing would replace a paired Mac, say so: "Replaces <old Mac>; files kept from it are removed".

## P3

### P3-1. Fast ⌘+ / ⌘− starts overlapping zoom tasks; the place can drift and the column visibly jumps
`Linen/Document/DocumentWindow.swift:904-917`

Each step starts its own `Task`. Three quick presses run three tasks interleaved on the main actor. Task 2 can capture `place` after task 1 has set `pageZoom` but before task 1's `--zoom` message has landed, a half-applied layout, and then restores that place.

Each step also paints once at the new `pageZoom` with the old `--zoom` before the message arrives. For one frame the column grows or shrinks, then snaps back.

Fix: keep one zoom task in flight and coalesce presses (the latest zoom wins). Set `--zoom` in the same JS turn that takes the place, before setting `pageZoom`, so both changes land in one paint.

### P3-2. The `20em` floor resolves per element, so `.notice` falls out of line at 170 to 200 percent
`Renderer/page.css:19`, `:48`, `:176`

A custom property's `em` is resolved where it is used. Blocks get 20 × 17 = 340 px. `.notice` (14.5 px) gets 290 px.

Concrete case: at 200 percent, prose is 680 pt wide and a notice is 580 pt, so its edges no longer line up with the column.

Fix: write the floor in pixels, `max(calc(578px / var(--zoom, 1)), 340px)` (and the same for `--col`), or tie it to a `--body-size` variable.

### P3-3. The READ-1 harness check skips both extremes
`Tests/Harness/harness.swift` (READ-1 zoom)

It tests 0.8, 1.3, 2.0 and 1.0. It does not test 0.7 (826 CSS px), the 1.7 crossover where the floor takes over, or a `.blk.wide` block (`--col` and `--wing` changed too). It measures the first paragraph only.

Fix: add 0.7 and 1.7, and add a wide block's on-screen width.

### P3-4. L1 test gaps
`LinenKit/Tests/LinenKitTests/LinkLoopbackTests.swift`

- No test that a `pair-result busy` answer during confirm does not count as paired. The log names this as the fix found on the way.
- No test that a pairing session already waiting for Allow survives a listener restart. The doc comment at `MacLinkServer.swift:226` claims it does.

Also, `listenerRetriesUntilPortFree` can wait up to 40 s, which is slow for `make test`.

### P3-5. Pair in Settings does not hurry a pending restart
`MacLinkServer.swift:385-396`, `Linen/Panels/IPhoneSettings.swift:224`

Once the backoff reaches 30 s, the owner can wait up to 30 s on "Getting ready for your iPhone". Meanwhile the QR's 2-minute clock keeps running.

Fix: in `beginPairing`, if a restart is pending, cancel it, set `restartDelay = 1` and make the listener now.

### P3-6. The development helper's private key file is briefly readable by others (debug only)
`LinenHelper/DevControl.swift:74-78`

The file is written with `.atomic` under the default umask (0644) and only then changed to 0600.

Fix: create it as 0600 from the start, with `FileManager.createFile(atPath:contents:attributes: [.posixPermissions: 0o600])` or a temporary umask.

### P3-7. `LoomNSButton` gives no pressed feedback for the line style
`Linen/Design/TitledControls.swift:97-105`

`.line` ignores `isHighlighted`, so Cancel shows no press. Only `.fill` dims.

Fix: lower the stroke and label alpha while highlighted, as `.fill` does.

### P3-8. `stop()` keeps the backoff
`MacLinkServer.swift:262-274`

`restartDelay` and `restarts` survive `stop()` and `start()`, so a helper that is restarted in-process starts on its old, long delay.

Fix: reset both in `stop()`.

## Checked and found fine
- **Listener restart:**
  - Callbacks from a replaced listener are ignored (`l === self.listener`).
  - `running` is set inside the same `queue.sync` before any state callback can run.
  - A `makeListener` that throws during a restart schedules another try.
  - `stop()` cancels the pending restart.
  - Open sessions are separate connections and are not touched.
  - `HelperState.restarting` is optional, so an old helper's state still decodes.
  - The port changes on restart (`.any`). That is harmless: phones dial every `_linen._tcp` result and the certificate pin decides.
- **Phone deadlines:**
  - Each limit sits inside the next: 15 s to find the Mac, digits at 0.3 s, 75 s for the answer (longer than the Mac's 60 s), confirm 10 + 5 s, then the screen's own 30 s and 100 s above them.
  - The screen's watchdog and its Cancel cancel the task, which ends the stream, which runs `cancelPairing`.
  - The `pairingID` guard stops an old attempt's termination from cancelling a new one.
  - The pairing screen is a full-screen cover, so no swipe can dismiss it and leave the attempt running.
  - The `leavingStopsPairing` and `silentAfterDigits` tests cover both ends.
- **Proof of pairing and same-network abuse:**
  - The confirm dial pins the Mac's certificate hash from the QR, so no other device on the network can answer as the Mac.
  - The Mac accepts an unknown certificate only while the QR is up (`verify`).
  - A phone is pinned only in `answerPairing(allow: true)`.
  - With the `busy` fix, I found no path that pins a new phone without Allow. A phone already pinned is let back in without Allow, as designed.
  - Hiding the QR while the helper is not listening does not open anything new.
- **Debug-only code:** every hook below is inside `#if DEBUG`, so none is in Release:
  - `DevControl.swift` (the whole file) and the `LINEN_HELPER_DEV` read in `main.swift`
  - `failListenerForTesting`
  - `Library.folderName`'s lab branch and the self-test skip
  - `HelperClient`'s preview and `previewing`
  - the WebKit occlusion SPI call
  - the iOS `-LinenPairing` and `-LinenProbe` hooks

  The new `HelperService.init` parameters are in Release, but their defaults are harmless. The log reports the Release binary contains no `LINEN_HELPER_DEV`.
- **Keep on iPhone sheet:**
  - It uses intrinsic sizing with a 460 × 120 floor and attaches to the active document's window.
  - The list shows whole up to 6 files, then scrolls in a fixed 180 pt.
  - Its height is about 400 pt at most, which fits the smallest Mac screens.
  - In Arabic with the RTL flag it is mirrored: I checked `evidence/L2/after-menu-night-ar-rtl.png`. Checkboxes and names are on the right, sizes on the left, labels are in Arabic, and sizes use Arabic-Indic digits.
  - The checkbox appearance follows Paper or Night.
- **Zoom and the other paths that read the column:**
  - The iPhone, Quick Look and PDF export (its own host with no zoom) never set `--zoom`.
  - HTML export copies only the inner HTML of `#doc`, not the inline style on `html`.
  - Print CSS sets `max-width: none` on the header and blocks.
  - Boards get `zoom: 1`, so the board list's `.b-lcol` (which uses `--measure`) is unchanged.
  - 0.7 gives 826 CSS px, which is 578 pt on screen. 2.0 hits the floor at 680 pt.
- **Native controls:**
  - The iOS screens use the system navigation bar, toolbar, `.searchable`, segmented picker, `List`, `Form`, stepper, `ShareLink` and system button styles.
  - What stays custom has a written reason in PRD-2 Appendix B: the sync line, the toast, the change chip's position, the woven drawings and the viewfinder corners.
  - The AVFoundation QR scanner is listed as open, with its reason.
- **Strings:**
  - Every new key on the Mac and the iPhone has Arabic, including the interpolated ones (`Keep %lld Files on iPhone`, `%lld of %lld`, `%@, named “%@”`, `Paired with %@`).
  - The size-limit labels now go through `ByteCountFormatter`, so they follow the screen's digits.
  - I found no text composed in code that breaks in Arabic.
