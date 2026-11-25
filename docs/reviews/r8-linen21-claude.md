# Review round 8, Claude: PRD-2 section 15 (LoomLink and distance)

Written 2026-10-31 by the lead session that drafted section 15, before reading the Codex and fresh-eyes reviews, so it is not anchored on them.

## Findings

**C1 (P1) LINK-3 is an unproven platform assumption.** One keychain access group shared by four binaries (Ferry and Linen on iOS; Ferry Host and Linen's sandboxed helper on macOS) is stated as a requirement with no evidence. On macOS a shared group needs the data protection keychain and a matching entitlement in every signed binary, and a sandboxed login item may need the app group form of the identifier; none of it has been tried on this Mac. Change: add spike **K(a)** before LoomLink's extraction: one item written by a test app and read by a second app and a sandboxed helper, on the Mac and on the iPhone, signed by team 2U8YZJV343. No-go means each app keeps its own key and the family pairs per app (LINK-4 falls back to "pair in each app"), which is still one link and one relay.

**C2 (P1) "Forget in either app forgets it for both" (LINK-4) surprises the user.** Taking Linen's access away from a phone should not silently unpair Ferry's remote control. Change: in each app, Forget removes that app's Allow only; a separate "Forget this iPhone in every app" removes the family trust and closes every session. The L(a) refusal list then tests both.

**C3 (P2) LINK-1 may touch Ferry's Makefile, which has uncommitted edits from another session.** Moving Ferry onto a package likely edits `project.yml` and maybe the `Makefile`. Change: before the extraction, list Ferry's uncommitted files again; if the extraction must edit one of them, stop and ask Hatim to commit or set them aside first.

**C4 (P2) LINK-8's "independent review" has no owner or definition.** As a 2.1 release gate it could hold the release indefinitely. Change: name what counts (a person outside this build reading LoomLink's cryptography against the Noise spec and Ferry's PRD rules) and make who and when an open question for Hatim in section 14.

**C5 (P2) The rewritten L(a) has no check that per-app Allow holds.** Add: a phone paired through Ferry opens Linen and is asked Allow on the Mac before any `hello` is answered; refusing it leaves Ferry working.

**C6 (P2) Section 15 says IOS-11 is new but 6.4 does not list it.** Change: add the IOS-11 row to 6.4 when the round closes, so the feature table stays the one place features live.

## Verdict
Sound direction; not ready to extract code until C1's spike says the shared keychain works and C2 is settled in the text.
