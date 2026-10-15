## Round 2 findings

- B1 resolved — PAGE-3 says kit behavior “is not a script the page loads”; §9.2 uses `connect-src 'self'` for sibling JSON.
- B2 resolved — PAGE-2 requires the handler to answer “only the tab’s own random host”; P(c) tests wrong-host access and cross-page isolation.
- B3 resolved — §9.3 step 6 permits only `pair-code`, then `pair-confirm`, sends no document metadata, closes, and requires a new pinned sync session.
- M1 resolved — PAGE-10 inventories exact WebKit builds and reachable realms, with unknown-build, difference, error, timeout, and failed-control closure.
- M2 resolved — SYNC-4 specifies immutable generation directories, atomic pointer replacement, reader pinning, acknowledgements, and full comparison after manifest-ID rotation.
- M3 resolved — IOS-4 now applies PAGE-1 through PAGE-12.
- M4 resolved — PAGE-1 disclaims process placement; PAGE-12 supplies 6/10-second stress and recovery criteria while other tabs remain responsive.
- M5 resolved — §12 now gives explicit P(c), L(a), and I(a) gates.
- M6 resolved — §§11–12 split delivery into Mac 2.0 and iPhone/link 2.1.

## Round 1 partly/not-resolved items

- C1 resolved — PAGE-10 turns scripts off for an unknown exact WebKit build.
- C2 resolved — §9.3 step 6 supplies pre-approval authorization confinement.
- C4 resolved for spike-readiness — §12 makes custom-scheme `'self'`, hosts, storage, sibling resources, and sandbox behavior P(c) go/no-go conditions.
- C5 resolved — PAGE-12 replaces process guarantees with measurable recovery behavior.
- C10 resolved — SYNC-4 defines atomic switching and safe tombstone retirement.
- C13 not resolved — IOS-9 deliberately retains “Complete Unless Open,” allowing an already-open transfer handle while locked.
- C19 resolved as a delivery concern — §12 stages 2.0 and 2.1, although the combined program remains large.
- F3 not resolved — BRD-13 keeps first arrival as each device’s baseline; IOS-8 still defers traveling baselines to 2.x.
- F8 resolved — SYNC-3/4 now specify closure, link resolution, generations, and full removal comparison.
- F10 resolved — §7 now requires “about 170 boxes in ten sections” at reference scale.
- F11 resolved as a delivery concern — the cuts remain and §12 separates Mac and phone releases.
- F18 resolved — IOS-1 has no changed group; §7 no longer requires the hidden overview-map control.
- F19 resolved — BLK-1 says “never over” its block; BLK-2 shows a word once.
- F20 resolved — PAGE-3 explicitly opens kit notes “on tap on a touch screen.”

## New findings

- **Major — R3-PAGE-SAFE4 — Problem:** PAGE-11 says custom schemes and opening apps are denied, but §9.2 sends real clicks to SAFE-4, which opens `mailto`, local files in other apps, and prompted custom schemes. It also makes §1/§4’s absolute “no network” wording false when an approved HTTP link opens externally. **Fix:** define a sealed-page-specific allowlist, explicitly reject all other SAFE-4 routes, test real-click `mailto:`, `obsidian:`, executable/file links, and qualify the promise as no network without Hatim’s full-address approval.

- **Major — R3-PAGE-REALMS — Problem:** §9.2 says the CSP is sent “with the page,” while PAGE-2 permits sibling HTML and worker scripts; user scripts protect frames, not worker globals. P(c) behaviorally tests only a dedicated worker, although PAGE-10 names shared workers and worklets. The inventory records prototype methods but not accessors, static properties, symbols, or instance-owned API surfaces. **Fix:** require CSP on every scriptable document/worker response; test external and blob dedicated/shared workers plus every supported realm with positive controls; inventory complete property descriptors, not methods alone.

- **Minor — R3-LINK-STATE — Problem:** §9.3 never defines who sends `pair-confirm` or what it means; L(a)’s “right state” and “no data sent” lack an exact oracle. **Fix:** specify message direction, local-Allow transition, permitted response fields, close reason, and that “no data” means no application frame beyond those fields. No unpaired document-data path is otherwise present.

- **Minor — R3-I-GATE — Problem:** I(a)’s “10-minute scripted session” does not identify its gesture/reload sequence, and “zero errors” lacks a named log/problem set. **Fix:** reference a fixed fixture, action loop, console/problem counters, and memory sampling method.

- **Major — R3-PHASING — Problem:** §6 calls L2 “launch,” §12 says 2.0 ships after M10, yet M13—containing Mac tasks—“closes both”; §11 also says the phone work starts after 2.0 although S2 already includes four iPhone/link runs. **Fix:** define L2 as the 2.1 completion, add a distinct 2.0 release gate after M10, divide M13 by release, and say phone *product implementation* starts after 2.0.

**Not approved — resolve the sealed-page SAFE-4 contradiction and complete P(c)’s realm/response coverage before running S2; otherwise a passing spike can certify different behavior from PAGE-11 or miss a worker escape.**
