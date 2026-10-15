### Round 3 findings

- **R3-PAGE-SAFE4 — Resolved.** PAGE-11 now uses a page-specific allowlist, permits prompted web links and in-folder Linen documents only, and refuses `mailto:`, apps, executables, and custom schemes ([PAGE-11](/Users/hatim/Developer/Satr/docs/PRD-2.md:147)).
- **R3-PAGE-REALMS — Not resolved.** Realm coverage and response CSP are fixed, but PAGE-10 inventories globals and prototypes—not instance-owned properties—and its fail-closed test mutates only a global and prototype method ([PAGE-10](/Users/hatim/Developer/Satr/docs/PRD-2.md:146), [tests](/Users/hatim/Developer/Satr/docs/PRD-2.md:376)).
- **R3-LINK-STATE — Resolved.** Step 6 defines frame direction, fields, outcomes, closure, and exactly what “no data sent” means ([§9.3 step 6](/Users/hatim/Developer/Satr/docs/PRD-2.md:311)).
- **R3-I-GATE — Resolved.** I(a) now names the action loop, console/problem counters, five-second `xctrace` sampling, memory limit, and jetsam result ([S2](/Users/hatim/Developer/Satr/docs/PRD-2.md:353)).
- **R3-PHASING — Resolved.** L2 completes at 2.1; 2.0/2.1 have separate M13 passes; spikes precede 2.0 while phone implementation follows it ([§12](/Users/hatim/Developer/Satr/docs/PRD-2.md:349)).

### New findings

- **Major — R4-TRUST-PARITY — Problem:** Yes, the manifest can make scripts run on the phone when they would not run on the Mac. PAGE-7 carries folder trust but also has a per-file toggle; SYNC-4’s manifest fields contain neither that override nor trust revision/revocation. A trusted-folder page disabled per-file on Mac can therefore run on the phone ([PAGE-7](/Users/hatim/Developer/Satr/docs/PRD-2.md:143), [SYNC-4](/Users/hatim/Developer/Satr/docs/PRD-2.md:199)). **Fix:** carry each page’s effective script policy and provenance, version trust changes atomically, propagate revocation even without file changes, and AND it with the phone’s PAGE-10 result; test all mismatched states.

- **Major — R4-SYNC-ROOTS — Problem:** “Also keep these files” adds outside files to a pin, but manifests require relative paths, the helper can read only pinned folders, and the Mac must never serve outside the pin root ([SYNC-3](/Users/hatim/Developer/Satr/docs/PRD-2.md:198), [path boundary](/Users/hatim/Developer/Satr/docs/PRD-2.md:315)). Relaxing that boundary would create a file-disclosure hole. **Fix:** model every added file as a separately granted singleton root with its own stable pin ID and destination namespace; cross-pin targets must be `(pinID, relativePath)`.

- **Major — R4-BG-PINSET — Problem:** Background refresh cannot change pairing or certificate pins: pairing requires scanning plus Mac Allow, and sync requires a new fully pinned session. But whether background sync may add/remove “Keep on iPhone” pins is undefined; the protocol has no authoritative pin-set or pin-removal frame ([SYNC-1](/Users/hatim/Developer/Satr/docs/PRD-2.md:196), [protocol](/Users/hatim/Developer/Satr/docs/PRD-2.md:314), [background](/Users/hatim/Developer/Satr/docs/PRD-2.md:318)). **Fix:** add a Mac-authored pin-set generation; background may reconcile it over an already-pinned session but may never pair, alter certificate pins, or originate pin/trust decisions.

- **Major — R4-PHONE-FIRST-PAINT — Problem:** BRD-24 opens a too-wide first board in List view, while §4 defines phone first paint as a section at reading zoom; B(a)/I(a) therefore have two possible workloads ([BRD-24](/Users/hatim/Developer/Satr/docs/PRD-2.md:128), [measure definition](/Users/hatim/Developer/Satr/docs/PRD-2.md:70)). **Fix:** give List first paint its own target and explicitly make the Canvas benchmark switch to the first section.

- **Major — R4-BRD-MALFORMED — Problem:** BRD-1 declares only three fatal classes but defines recovery only for selected malformed entries; a null, scalar, or structurally malformed array member has no skip/list rule and could still blank the board ([BRD-1](/Users/hatim/Developer/Satr/docs/PRD-2.md:105)). **Fix:** skip every malformed entry with its JSON path, render the remainder, and add wrong-shape fixtures.

PAGE-11, SYNC-1’s camera/name flow, IOS-10, the one-hour notification, and EXP-5’s section-PDF 9 pt floor otherwise remain internally consistent.

Not approved — R3-PAGE-REALMS remains incomplete, and trust parity, pin-root authority, pin-set reconciliation, and the phone first-paint gate must be specified before S2.
