# Linen code review 1, renderer verification, Codex

Renderer audit only; Swift-only verdicts marked † are carried from the supplied [Swift verification](/Users/hatim/Developer/Satr/docs/reviews/code1-verify-swift-final.md:3), not re-audited.

## Verdicts

1. **FIXED** — “Allow this file” posts that image’s exact request; Swift grant binding was already verified. [page.js:350](/Users/hatim/Developer/Satr/Renderer/page.js:350), [page.js:355](/Users/hatim/Developer/Satr/Renderer/page.js:355)

2. **DISAGREE-ACCEPTED†** — the PRD explicitly permits outside Markdown/text to open in Linen after canonicalization. [PRD.md:223](/Users/hatim/Developer/Satr/docs/PRD.md:223)

3. **PARTLY FIXED** — byte/token/nesting/DOM limits and worker replacement exist, but reloads synchronously render up to 10,000 replacement blocks without slicing or a cancellation check. A large superseded reload can freeze the page. [page.js:78](/Users/hatim/Developer/Satr/Renderer/page.js:78), [lexer.js:165](/Users/hatim/Developer/Satr/Renderer/lexer.js:165), [page.js:925](/Users/hatim/Developer/Satr/Renderer/page.js:925)

4. **FIXED†** — streaming, MIME/size limits, cancellation and stopped-task suppression. [Swift verification:11](/Users/hatim/Developer/Satr/docs/reviews/code1-verify-swift-final.md:11)

5. **FIXED†** — per-document remote approval. [Swift verification:13](/Users/hatim/Developer/Satr/docs/reviews/code1-verify-swift-final.md:13)

6. **FIXED†** — name/bytes agreement, safe pixel arithmetic and bounded SVG rasterization. [Swift verification:15](/Users/hatim/Developer/Satr/docs/reviews/code1-verify-swift-final.md:15)

7. **FIXED†** — eight-hop limit. [Swift verification:17](/Users/hatim/Developer/Satr/docs/reviews/code1-verify-swift-final.md:17)

8. **FIXED** — baseline state is updated before posting; sequences preserve occurrences and gap positions. [page.js:681](/Users/hatim/Developer/Satr/Renderer/page.js:681), [page.js:693](/Users/hatim/Developer/Satr/Renderer/page.js:693), [page.js:717](/Users/hatim/Developer/Satr/Renderer/page.js:717)

9. **FIXED** — visibility time accumulates, tall blocks use a viewport-relative threshold, and rewritten notices use the same timer. [page.js:646](/Users/hatim/Developer/Satr/Renderer/page.js:646), [page.js:669](/Users/hatim/Developer/Satr/Renderer/page.js:669), [page.js:681](/Users/hatim/Developer/Satr/Renderer/page.js:681)

10. **FIXED** — nearest duplicate selection, render-through-index, `qoff`/`qdy`, and proportional fallback are present. [page.js:553](/Users/hatim/Developer/Satr/Renderer/page.js:553), [page.js:575](/Users/hatim/Developer/Satr/Renderer/page.js:575), [page.js:592](/Users/hatim/Developer/Satr/Renderer/page.js:592)

11. **FIXED** — Myers uses two bounded vectors rather than retaining every trace. [diff.js:7](/Users/hatim/Developer/Satr/Renderer/diff.js:7), [diff.js:21](/Users/hatim/Developer/Satr/Renderer/diff.js:21)

12. **FIXED** — similarity uses word multisets and requires half of both blocks. [diff.js:78](/Users/hatim/Developer/Satr/Renderer/diff.js:78), [diff.js:91](/Users/hatim/Developer/Satr/Renderer/diff.js:91)

13. **PARTLY FIXED** — degraded reads are held, except nonempty documents with four or fewer old blocks. A four-block file truncated to one block is shown before quiet. [page.js:893](/Users/hatim/Developer/Satr/Renderer/page.js:893), [page.js:895](/Users/hatim/Developer/Satr/Renderer/page.js:895)

14. **PARTLY FIXED†** — per supplied Swift verification. [Swift verification:31](/Users/hatim/Developer/Satr/docs/reviews/code1-verify-swift-final.md:31)

15. **FIXED†** — off-main image work and stopped-response suppression. [Swift verification:33](/Users/hatim/Developer/Satr/docs/reviews/code1-verify-swift-final.md:33)

16. **PARTLY FIXED†** — per supplied Swift verification. [Swift verification:35](/Users/hatim/Developer/Satr/docs/reviews/code1-verify-swift-final.md:35)

17. **PARTLY FIXED†** — per supplied Swift verification. [Swift verification:37](/Users/hatim/Developer/Satr/docs/reviews/code1-verify-swift-final.md:37)

18. **PARTLY FIXED** — folding follows `foldArabic`, the find-bar toggle persists it, and a hidden status region announces settled updates. Missing: the delayed announcement is not canceled on navigation, so an old document can announce inside the new one. Native parts were verified. [page.js:1218](/Users/hatim/Developer/Satr/Renderer/page.js:1218), [page.js:1339](/Users/hatim/Developer/Satr/Renderer/page.js:1339), [page.js:983](/Users/hatim/Developer/Satr/Renderer/page.js:983), [page.html:41](/Users/hatim/Developer/Satr/Renderer/page.html:41)

## New renderer defects

1. **Major — acknowledgement can cross document loads.** `load()` changes `docId` before canceling/resetting the old visibility timer. If an old mark reaches three seconds while the new document is parsing, old hashes are posted under the new `docId` and then used to mark the new page. [page.js:802](/Users/hatim/Developer/Satr/Renderer/page.js:802), [page.js:669](/Users/hatim/Developer/Satr/Renderer/page.js:669), [page.js:702](/Users/hatim/Developer/Satr/Renderer/page.js:702)

2. **Major — edit pairing is insertion-asymmetric.** The new-block pointer advances only after a successful pair. For old `A` → new `X, A′`, testing `A` against inserted `X` fails and `A′` is never considered; reading place and selection are lost instead of following the edit. [diff.js:101](/Users/hatim/Developer/Satr/Renderer/diff.js:101), [diff.js:104](/Users/hatim/Developer/Satr/Renderer/diff.js:104)

3. **Major — live rewrites do not select rewritten mode.** `applyUpdate()` calls `applyMarks(false)`, while the rewritten branch requires `fresh || state.rewritten`; it also counts only unmatched new blocks, ignoring deletion-heavy rewrites. Replacing or deleting most of a live document produces individual marks/gaps instead of one rewritten notice. [page.js:720](/Users/hatim/Developer/Satr/Renderer/page.js:720), [page.js:961](/Users/hatim/Developer/Satr/Renderer/page.js:961)

4. **Moderate — stale accessibility announcement timer.** `settle()` schedules an untracked timeout. Navigating within 100 ms—or two rapid settles—can emit an obsolete or duplicate announcement. [page.js:986](/Users/hatim/Developer/Satr/Renderer/page.js:986), [page.js:995](/Users/hatim/Developer/Satr/Renderer/page.js:995)

Syntax checks passed. Exhaustive small-sequence testing found the new Myers implementation produces valid optimal LCS pairs. The full harness could not start its WebKit process under this restricted environment, so its 26 checks were not independently confirmed. No files were edited.
