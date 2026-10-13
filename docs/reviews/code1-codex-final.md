# Linen code review 1, Codex

The literal CSP matches PRD §9, and I found no escape in the core descriptor-based `openat` walk. The release blockers sit in authorization and resource handling above it.

## Security

1. **Blocker — [DocumentWindow.swift:246](/Users/hatim/Developer/Satr/Linen/Document/DocumentWindow.swift:246), [DocumentWindow.swift:393](/Users/hatim/Developer/Satr/Linen/Document/DocumentWindow.swift:393), [page.js:319](/Users/hatim/Developer/Satr/Renderer/page.js:319)** — “Allow outside” sets one document-wide Boolean. One click grants every outside image named by the document, rather than exactly one file as SAFE-2 requires.  
   **Fix:** send the requested image identifier with the action, confirm its canonical path, and store only that file’s device/inode grant. Remove `allowOutside`.

2. **Blocker — [DocumentWindow.swift:276](/Users/hatim/Developer/Satr/Linen/Document/DocumentWindow.swift:276), [DocumentWindow.swift:298](/Users/hatim/Developer/Satr/Linen/Document/DocumentWindow.swift:298)** — local-link policy has bypasses:

   - `openLocal` navigates to any `.md`/`.txt` before checking whether it is outside the vault.
   - The vault check does not resolve symlinks.
   - `openWiki` opens non-readable targets directly, bypassing executable confirmation.
   - Ambiguous selections always call `navigate`, even for attachments.

   A clicked `../../outside.md`, an in-vault symlink, or `[[tool.command]]` bypasses SAFE-4.  
   **Fix:** route every resolved local URL through one canonical gate: resolve symlinks, test the canonical vault boundary, detect executable/package types, prompt for every outside file, then choose Linen versus `NSWorkspace`.

3. **Blocker — [lexer.js:168](/Users/hatim/Developer/Satr/Renderer/lexer.js:168), [page.js:717](/Users/hatim/Developer/Satr/Renderer/page.js:717), [worker.js:7](/Users/hatim/Developer/Satr/Renderer/worker.js:7)** — SAFE-5 is not implemented fully. There is no 20 MB pre-parse cutoff, nesting cap, DOM-node budget, or cancellation of an active worker parse. The token limit is checked only after fully lexing. Multiple updates can leave expensive obsolete parses running.  
   **Fix:** enforce the byte limit before posting, terminate/recreate the worker on superseding input, count depth/nodes during lex/render, and fail to bounded plain-text chunks before parsing.

4. **Major — [Schemes.swift:244](/Users/hatim/Developer/Satr/Linen/Document/Schemes.swift:244)** — `dataTask` buffers the entire remote response before applying the 10 MB test; MIME type is ignored and `stop` never cancels the network task. A permitted server can exhaust memory or continue downloading after navigation.  
   **Fix:** use a streaming `URLSessionDataDelegate`, reject non-image response MIME types, cancel past 10 MB, track scheme-task-to-session-task mappings, and cancel in `stop`.

5. **Major — [DocumentWindow.swift:147](/Users/hatim/Developer/Satr/Linen/Document/DocumentWindow.swift:147), [DocumentWindow.swift:243](/Users/hatim/Developer/Satr/Linen/Document/DocumentWindow.swift:243)** — the per-file remote-image button does nothing: it sets `remote.allowed = true`, then `sendLoad()` immediately resets it to `Settings.remoteImagesAlways`. SAFE-1’s one-file approval cannot work.  
   **Fix:** maintain a per-document approval flag, combine it with the global setting in `sendLoad`, and reset it only when navigating to another document.

6. **Major — [Schemes.swift:145](/Users/hatim/Developer/Satr/Linen/Document/Schemes.swift:145), [DocumentWindow.swift:414](/Users/hatim/Developer/Satr/Linen/Document/DocumentWindow.swift:414)** — pixel multiplication can overflow and trap for malicious dimensions, while SVG returns before any dimension/resource check. File extensions are also never validated as SAFE-2 requires.  
   **Fix:** validate positive dimensions with division (`width <= maxPixels / height`), rasterize SVG under fixed limits, and require both an allowed extension/MIME and matching bytes.

7. **Minor — [Schemes.swift:61](/Users/hatim/Developer/Satr/Linen/Document/Schemes.swift:61)** — `while hops <= 8` permits nine symlink dereferences.  
   **Fix:** use `hops < 8` or reject before following when `hops == 8`.

## Place keeping, marks, and watching

8. **Major — [page.js:628](/Users/hatim/Developer/Satr/Renderer/page.js:628)** — acknowledgements are not retained in renderer state. `saveBaseline` posts new hashes but never updates `state.baseline`; the next reload resets `baselineSet` from the stale sequence, resurrecting marks. Sets also collapse duplicate hashes, and removed hashes are appended at the end, losing gap positions.  
   **Fix:** keep an ordered, occurrence-aware baseline sequence, update it before posting, and diff that sequence against current blocks.

9. **Major — [page.js:606](/Users/hatim/Developer/Satr/Renderer/page.js:606), [page.js:650](/Users/hatim/Developer/Satr/Renderer/page.js:650)** — blocks taller than twice the viewport can never meet the 50% intersection threshold and therefore never acknowledge. Conversely, the “rewritten” branch saves its baseline immediately without three visible seconds.  
   **Fix:** accumulate time while any meaningful portion is visible in the key window, and apply the same timer to the rewritten notice.

10. **Major — [page.js:508](/Users/hatim/Developer/Satr/Renderer/page.js:508), [page.js:739](/Users/hatim/Developer/Satr/Renderer/page.js:739)** — stored-place restoration chooses the first matching duplicate hash. If the hash disappeared, first-screen rendering targets index 0, but restoration accesses the possibly unrendered stored index and can throw on `b.el`. Quote restoration ignores `qoff`; when the quote is gone it moves to the block top instead of preserving relative position.  
    **Fix:** choose the matching occurrence nearest the stored index, otherwise render through the stored index; disambiguate quotes using the saved offset and preserve proportional offset on failure.

11. **Major — [page.js:569](/Users/hatim/Developer/Satr/Renderer/page.js:569)** — “bounded” Myers stores up to 4,001 full vectors. At 10,000 replaced blocks this is roughly 640 MB.  
    **Fix:** use linear-space Myers/patience anchors, or cap trace bytes and fall back before allocation.

12. **Major — [page.js:861](/Users/hatim/Developer/Satr/Renderer/page.js:861)** — edited pairing uses unique-word sets and half of the smaller set. A one-word old paragraph contained in a 100-word replacement qualifies as edited, attaching place/selection to unrelated content.  
    **Fix:** use word multisets and require at least half of both blocks’ words to be shared.

13. **Major — [page.js:789](/Users/hatim/Developer/Satr/Renderer/page.js:789)** — degraded content is held only when `inBurst` is already true. A truncate event delivered before a later write can blank the page before the 300 ms quiet boundary.  
    **Fix:** hold every empty/>50%-loss generation until its matching `.quiet`, replacing it earlier only with a non-degraded generation.

14. **Major — [DocumentWindow.swift:131](/Users/hatim/Developer/Satr/Linen/Document/DocumentWindow.swift:131), [DocumentWindow.swift:136](/Users/hatim/Developer/Satr/Linen/Document/DocumentWindow.swift:136)** — a move updates only `url`; vault, index, encoding/plain mode, document identity, and page metadata remain stale. Burst updates may also never reach the index because `.quiet` does not update it.  
    **Fix:** recompute all document context and perform a full load after moves; record index dirtiness and update on quiet.

## Concurrency and remaining launch gaps

15. **Major — [DocumentWindow.swift:393](/Users/hatim/Developer/Satr/Linen/Document/DocumentWindow.swift:393), [Schemes.swift:184](/Users/hatim/Developer/Satr/Linen/Document/Schemes.swift:184)** — local files up to 50 MB are read and decoded/downsampled synchronously on `@MainActor`, twice per image.  
    **Fix:** perform descriptor reads and ImageIO work on a dedicated actor/queue; return immutable results to the main actor.

16. **Major — OPEN-2, OPEN-6, OPEN-8:** [AppDelegate.swift:127](/Users/hatim/Developer/Satr/Linen/App/AppDelegate.swift:127) skips missing restored files and selects every restored tab, causing each to build; [Menus.swift:57](/Users/hatim/Developer/Satr/Linen/App/Menus.swift:57) has no encoding override; [DocumentWindow.swift:114](/Users/hatim/Developer/Satr/Linen/Document/DocumentWindow.swift:114) has no denied-folder, undownloaded-iCloud, disconnected-volume, or network polling states.  
    **Fix:** restore missing-state tabs, build/select only the front tab, add encoding selection, and implement the specified storage states/polling.

17. **Major — QL-1/OPEN-6:** [PreviewViewController.swift:27](/Users/hatim/Developer/Satr/LinenQuickLook/PreviewViewController.swift:27) always decodes UTF-8, passes an empty baseline that produces false change marks/notices, and waits an arbitrary 150 ms instead of first paint.  
    **Fix:** use LinenKit decoding, omit the baseline for first load, and await a `firstPaint` continuation.

18. **Minor — OPEN-1, OPEN-4, READ-3, READ-5, LOOK-4:** plain text is silently made default at [AppDelegate.swift:181](/Users/hatim/Developer/Satr/Linen/App/AppDelegate.swift:181); Welcome shows five rather than twelve recents at [Welcome.swift:37](/Users/hatim/Developer/Satr/Linen/Panels/Welcome.swift:37); Arabic folding is hard-coded on at [page.js:932](/Users/hatim/Developer/Satr/Renderer/page.js:932); trackpad navigation is disabled at [DocumentWindow.swift:94](/Users/hatim/Developer/Satr/Linen/Document/DocumentWindow.swift:94); reload announcements are ignored.  
    **Fix:** expose the required choices, enable guarded swipe history, and announce one summarized update.
