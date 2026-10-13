# Linen code review 1, final renderer verification, Codex

## Verdicts

1. **FIXED — finding 3.** New reload blocks render in 12 ms slices and abort on render-token change. [page.js:960](/Users/hatim/Developer/Satr/Renderer/page.js:960), [page.js:974](/Users/hatim/Developer/Satr/Renderer/page.js:974), [page.js:980](/Users/hatim/Developer/Satr/Renderer/page.js:980)

2. **FIXED — finding 13.** Empty reads and reads retaining under half the current blocks are held regardless of document size. [page.js:947](/Users/hatim/Developer/Satr/Renderer/page.js:947)

3. **FIXED — finding 18 / defect 4.** The settle timer is tracked, replaced by newer settles, and cleared during load. [page.js:851](/Users/hatim/Developer/Satr/Renderer/page.js:851), [page.js:1053](/Users/hatim/Developer/Satr/Renderer/page.js:1053)

4. **FIXED — defect 1.** Load clears acknowledgement state before assigning the new document; `tickSeen()` stops during parsing. [page.js:851](/Users/hatim/Developer/Satr/Renderer/page.js:851), [page.js:712](/Users/hatim/Developer/Satr/Renderer/page.js:712)

5. **FIXED — defect 2.** Each unmatched old block scans at most 64 remaining new blocks, advancing `j` only after a match, preserving order. [diff.js:101](/Users/hatim/Developer/Satr/Renderer/diff.js:101)

6. **PARTLY — defect 3.** Live updates now use new-plus-removed against the union, but `hashes.length > 4` remains. Deleting six blocks from ten and leaving four still produces gap marks instead of the required rewritten line. [page.js:761](/Users/hatim/Developer/Satr/Renderer/page.js:761), [page.js:768](/Users/hatim/Developer/Satr/Renderer/page.js:768), [page.js:1029](/Users/hatim/Developer/Satr/Renderer/page.js:1029)

7. **PARTLY — image staging.** Non-data sources are stashed and recovered for ordinary, title, and footnote images. However, sanitized document markup may supply its own `data-img`; `prepareImage()` trusts it, allowing one raw `<img data-img="N">` to steal another image’s numbered source. [page.js:124](/Users/hatim/Developer/Satr/Renderer/page.js:124), [page.js:337](/Users/hatim/Developer/Satr/Renderer/page.js:337), [page.js:408](/Users/hatim/Developer/Satr/Renderer/page.js:408), [page.js:1101](/Users/hatim/Developer/Satr/Renderer/page.js:1101)

8. **FIXED — swipe.** Gesture accumulation posts once and blocks gestures originating inside an actually scrollable horizontal ancestor. [page.js:655](/Users/hatim/Developer/Satr/Renderer/page.js:655)

9. **PARTLY — mark direction.** Normal wrappers and most gaps inherit direction, but wide blocks often do not: table decoration replaces the directed table with an undirected `.table-wrap`; code/math also lack a child `dir`. Trailing gaps have no next sibling to copy. [page.js:217](/Users/hatim/Developer/Satr/Renderer/page.js:217), [page.js:236](/Users/hatim/Developer/Satr/Renderer/page.js:236), [page.js:788](/Users/hatim/Developer/Satr/Renderer/page.js:788)

## New defects

1. **Major — detached async update breaks ordering and error handling.** `update()` and `quiet()` call but do not await `applyUpdate()`. During a large burst reload, `quiet()` can run while a slice awaits, see `unannounced === false`, and return; the later commit sets it true but never settles, losing the accessibility announcement. An awaited update/quiet also returns while the old DOM remains, and any rejected `applyUpdate()` bypasses `receive()`’s error handler. [page.js:951](/Users/hatim/Developer/Satr/Renderer/page.js:951), [page.js:953](/Users/hatim/Developer/Satr/Renderer/page.js:953), [page.js:980](/Users/hatim/Developer/Satr/Renderer/page.js:980), [page.js:1046](/Users/hatim/Developer/Satr/Renderer/page.js:1046)

2. **Major — speculative rendering leaks image work across cancellation.** `renderBlock()` queues images or starts approved remote loads before insertion. If an old `imageInfo` reply arrives during the await, it drains these new entries as “missing”; they are later inserted but never requested. If a load cancels the update, queued detached images survive into the new document and can be resolved/fetched there. Detached lazy-observer targets also remain registered. [page.js:253](/Users/hatim/Developer/Satr/Renderer/page.js:253), [page.js:336](/Users/hatim/Developer/Satr/Renderer/page.js:336), [page.js:369](/Users/hatim/Developer/Satr/Renderer/page.js:369), [page.js:975](/Users/hatim/Developer/Satr/Renderer/page.js:975), [page.js:982](/Users/hatim/Developer/Satr/Renderer/page.js:982)

3. **Moderate — source-table keys are document-spoofable.** Raw `<img data-img="1">` placed before the generated image carrying key `1` consumes that source first, relocating or suppressing the intended image. [page.js:129](/Users/hatim/Developer/Satr/Renderer/page.js:129), [page.js:339](/Users/hatim/Developer/Satr/Renderer/page.js:339)

4. **Moderate — wide/trailing marks can use the interface side.** An Arabic table in an LTR interface gets `dir="rtl"` on the nested table, not its `.blk`; its change mark stays left. Changed LTR code has the inverse problem in an RTL interface. [page.js:219](/Users/hatim/Developer/Satr/Renderer/page.js:219), [page.js:236](/Users/hatim/Developer/Satr/Renderer/page.js:236), [page.js:788](/Users/hatim/Developer/Satr/Renderer/page.js:788)

Syntax checks and the insertion-before-edit pairing check passed. The WebKit harness could not start its renderer process in this sandbox. No files edited.
