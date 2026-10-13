# Linen PRD round 2, Codex

# Round 2 verdict

Materially improved, but not implementation-ready. Three blockers remain: the CSP/resource-loading model, Quick Look filesystem authority, and reliable incremental place preservation.

## A. Round 1 findings

1. **Partly resolved** — PERF-2 moves lexing into a worker, but batching still leaves global parser state, IDs, and page-thread stalls undefined.
2. **Resolved** — PERF-1 and M0 explicitly replace `loadHTMLString` reloads with a persistent shell and versioned bridge.
3. **Partly resolved** — content-hash LCS still fails on edited or duplicate blocks, large lists, and selection inside replaced blocks.
4. **Partly resolved** — folder watching and rearming were added, but rearm races, moves, and the 150 ms/rate-limit contradiction remain.
5. **Resolved** — security replacement is now an M0 gate.
6. **Partly resolved** — SAFE-2 promises descriptor checks but does not define race-free traversal or URL canonicalisation.
7. **Resolved** — document-authored styles and stylesheets are removed.
8. **Partly resolved** — some limits exist, but image decompression, token/DOM counts, long lines, aggregate assets, and cancellation remain uncovered.
9. **Partly resolved** — document data left scripts and `worker-src` is mentioned, but the actual CSP/origin/worker-loading design is absent.
10. **Partly resolved** — the spike proves a development-signed view extension, not reliable cold start, intended distribution, or the data-based alternative.
11. **Partly resolved** — there are aggregate bundle/RSS limits, not the requested per-component and installed/compressed budgets.
12. **Resolved** — default ownership is now explicitly user-initiated.
13. **Partly resolved** — confidence detection and overrides were added, but thresholds, ties, and fallback behavior are unspecified.
14. **Partly resolved** — MDX is gone and fixtures are required, but exact library versions and extension precedence are not stated.
15. **Partly resolved** — VAULT-2 is better, but its tie-break is incomplete and `resolvedLinks` cannot test unresolved or ambiguous cases.
16. **Resolved** — direct, unsandboxed distribution is chosen and the extension’s separate sandbox is acknowledged.
17. **Partly resolved** — signposts and percentiles help, but cold-state procedure, RSS sampling, screenshot tolerances, and several endpoints remain vague.
18. **Resolved** — LOOK-4 covers announcements, focus, selection, semantics, keyboard access, contrast, and reduced motion.
19. **Partly resolved** — MDX and media embeds moved, but launch still contains roughly 59 compound requirement rows.
20. **Partly resolved** — tests are much stronger, but several exits remain non-semantic or can pass before the risky feature exists.

## B. Appendix A disagreements

- **Change marks:** Accept keeping them at launch: they directly serve Linen’s central reviewer job. Do not accept that the diff pays “most” of their cost; persistence, deletion representation, acknowledgement, navigation, and cross-session baselines are substantial separate work.
- **Open Quickly and Linked from:** Accept Open Quickly because the name index already exists. Reject the argument for Linked from: extracting context sentences, maintaining freshness, grouping, and presenting results is additional product work unrelated to resolving a clicked link. Move VAULT-3 to 1.x.
- **View-based Quick Look:** Reject. The spike tested only one side, required read access to the entire home folder, retained an untested network entitlement, and produced blank cold previews. It establishes feasibility, not that view-based WKWebView is the safer or more reliable choice.

## C. New or newly exposed problems

| Severity | PRD ID | Problem | Fix |
|---|---|---|---|
| **Blocker** | SAFE-1, SAFE-3, PERF-2 | CSP “blocks every network load,” yet remote images may be enabled. The renderer origin, exact directives, worker URL, worker CSP, and whether `blob:` is needed are unspecified. | Publish the literal CSP and loading URLs; test it in WebKit. Keep CSP closed and fetch consented remote images through a constrained native broker. Remove Quick Look’s network entitlement unless proven necessary. |
| **Blocker** | SAFE-2, QL-1, §9 | A check followed by path-based open remains raceable. Worse, Quick Look’s `/` home read exception gives its process far more authority than the vault-bounded handler promises. | Use canonical URL parsing plus descriptor-relative traversal/final-FD validation and opaque grant IDs. Replace the home exception with shared folder bookmarks/capabilities; otherwise omit sibling images in Quick Look. |
| **Major** | SAFE-4, SAFE-5 | Remembering approval for arbitrary schemes can invoke dangerous handlers. “Yield after 3 s” cannot interrupt synchronous parsing/sanitising; plain-text fallback can still create a huge DOM. | Require a user gesture and do not persist unknown-scheme approval. Add cancellable deadlines, token/node/pixel/asset limits, and a bounded plain-text viewport. |
| **Major** | PERF-2, REN-1, REN-12 | Whole-document lexing and structured cloning finish before first paint. Batch parsing can break footnote state, reference definitions, heading IDs, and backlinks; one enormous list remains one blocking batch. | Define a document-wide render context and safe batch boundaries, split oversized nodes, cap clone size, time-slice page work, and prove first-paint latency on adversarial fixtures. |
| **Blocker** | LIVE-4, PERF-3, OPEN-3 | Naive LCS is quadratic; duplicate hashes are ambiguous; replacing an edited block destroys its selection. Lazy images/diagrams cause later reflow, and a deleted line cannot remain within 4 px. | Use a bounded Myers/patience diff with contextual anchors, DOM-range text quotes and geometry correction. Reserve media space and specify a different deterministic deletion fallback. |
| **Major** | LIVE-1–3 | Vnode events are hints and can coalesce; a save can occur between restat and rearm. Four reloads/second permits 250 ms delay, contradicting 150 ms, while LIVE-3 deliberately waits 300 ms. | Specify a generation-based state machine with post-arm restat, wake/resume recovery, rapid-save tests, and separate detection, quiet-period, and final-paint targets. |
| **Major** | LIVE-5, §9 | “Baseline of what was last seen on screen” cannot also identify all changes on reopening; stored content, acknowledgement semantics, size, and privacy are undefined. | Define a bounded whole-document token/hash baseline and an explicit acknowledgement rule; initially keep marks session-local. |
| **Major** | §11, ARB-2, EXP-1 | Research found four of fifteen font files, while the PRD says all fifteen are installed. The defining typography cannot ship, and PDF embedding remains only medium-confidence legally. | Correct the inventory; test every required face in app and extension; use redistributable fallbacks and fallback PDF fonts until written permission resolves distribution and embedding. |
| **Major** | OPEN-6, ARB-1, READ-8, VAULT-2 | “Confidence,” “close to even,” “heading near,” and the complete Obsidian tie-break are not testable. | Give numeric thresholds and total deterministic algorithms; export both resolved and unresolved Obsidian results and add duplicate/case/alias oracle fixtures. |
| **Major** | Launch tiers | Present, backlinks, persistent change history, custom footnote popovers, multi-editor line targeting, Quick Look, print, localisation, and advanced rendering make one launch too broad. | Move Present, Linked from, persistent historical marks, footnote popovers, and editor-specific line adapters to 1.x. |
| **Major** | M0, M3–M6 | M0 security tests pass trivially before Mermaid/KaTeX arrive; structural checks can accept wrong HTML; M3’s deleted-block 4 px test is impossible; “marks match” lacks an oracle; “5,400 links” conflicts with research counts. | Re-run security gates after every renderer addition; use semantic DOM/change oracles, enumerate corpus counts at runtime, automate rapid-save cases, and test a clean notarized build with intended entitlements. |
