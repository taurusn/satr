# Linen PRD round 3, Codex

# Round 3 sign-off

## A. Round 2 findings

1. **Partly resolved — CSP/resource loading.** The literal CSP, renderer origin, native remote-image broker, and removal of Quick Look networking are good; SAFE-3 still contradicts section 9 on hashes versus `'self'`, and worker/broker restrictions remain incomplete.
2. **Partly resolved — filesystem authority.** Quick Look is fixed, but SAFE-2 still describes validation followed by a path-based open; `O_NOFOLLOW` protects only the final component unless the recorded inode comes from the same race-free traversal. Outside-vault approval also lacks a narrowly scoped capability.
3. **Partly resolved — schemes and limits.** Unknown schemes now require every-click approval, and cancellation/DOM limits improved. Token/clone, decoded-pixel, aggregate-asset, and pathological-line limits remain absent.
4. **Partly resolved — parser batching.** Document-wide references, footnotes, line offsets, and heading IDs are defined. Whole-document lexing/cloning still precedes first paint, and one enormous top-level list cannot honor the 16 ms slicing promise.
5. **Partly resolved — place preservation.** Bounded Myers, text quotes, reserved media space, and the deletion rule are improvements. The PRD does not define how a changed hash becomes “the edited block,” deterministically distinguish repeated blocks, or restore a selection inside replaced content.
6. **Partly resolved — file watching.** The generation and timing model is coherent, but post-rearm restat, wake/resume reconciliation, and recovery from a completely missed event remain unspecified.
7. **Partly resolved — change baseline.** Stored hash sequences and the three-second acknowledgement rule are clear; retention and size are unbounded, and deletion/change pairing still inherits LIVE-4’s ambiguity.
8. **Partly resolved — fonts.** Fifteen installed faces are verified. Quick Look coverage remains deferred, and distributing raw extractable fonts or embedded PDF subsets remains legally unresolved.
9. **Resolved — thresholds and deterministic rules.** Encoding, direction, Present snapping, vault resolution, unresolved cases, and runtime corpus counts are now testable.
10. **Partly resolved — launch scope.** Present, Linked from, footnote popovers, and editor line targeting moved; persistent history remains by explicit product decision, while Quick Look, print, localisation, and advanced rendering still make launch ambitious but do not themselves block architecture.
11. **Partly resolved — exit tests.** Repeated security gates, independent change oracles, runtime counts, rapid-save cases, and intended-entitlement Quick Look tests are added. Duplicate-block selection, oversized-node, missed-event, and clean notarized-build cases remain missing.

## B. Round 2 disagreements

- **Fifteen fonts:** Appendix A is correct; all fifteen are installed. The earlier four-file conclusion confused the researched site copies with the installed inventory.
- **Fonts committed in the repository:** Appendix A is correct; none are present, and `.gitignore` excludes them.
- **Installed fonts versus bundled copies:** Technically, Appendix A is supported by the WebKit spike. Legally, it is acceptable only for Hatim’s private local build; distribution still requires permission, non-extractable packaging, or fallbacks.
- **Single-document tab bar:** Accept. This is an intentional, previously requested product behavior.
- **Persistent change marks:** Accept the product decision, but reject the “few kilobytes” and mostly-free-cost rationale without a retention cap. Persistence is additional state, migration, privacy, and diff behavior.

## C. Build blockers

1. **Race-free file authority:** specify descriptor-relative traversal—or an equivalently atomic recorded-inode procedure—and opaque, resource-scoped grants for outside-vault access.
2. **Stable reload identity:** define deterministic matching for edited and repeated blocks plus text-range selection restoration, with corresponding M3 tests.
3. **Bounded work:** define subdivision/yielding for oversized nodes and caps for parser tokens, worker cloning, decoded pixels, and aggregate assets; otherwise the M0 fail-safe and 16 ms guarantees are structurally unattainable.

**Not approved — blockers: race-free file authority, deterministic reload/place identity, and bounded rendering/resource work.**
