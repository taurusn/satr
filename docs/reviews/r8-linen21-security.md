# Round 8: Linen 2.1, LoomLink and distance (security and systems review)

| | |
|---|---|
| Reviewed | `docs/PRD-2.md` section 15 (draft for round 8), against sections 0, 4, 6.4, 6.5, 9.3, 9.4, 11, 12, 13 and Appendix B's last entry; `docs/research/iphone-sync.md` section 1; `~/Desktop/ferry/docs/PRD.md` (6.1 PAIR, 6.2 CONN, section 9 Security, build log); `~/Desktop/ferry/FerryKit/Sources/FerryKit/` (Noise, Pairing, Session, Wire) and the Ferry app code that uses it |
| Reviewer | Claude, standing in for Codex (out of credits), 2026-10-31 15:10 +03. Read-only except this file. I did not read the other round 8 reviews, to stay unanchored |
| Marks | **V** verified today from a file, the SDK headers on this Mac or `codesign` on the installed apps. **B** my belief from Apple documentation I know but did not re-read today |

## Verdict

**Not ready to start LoomLink as section 15 is written.** The transport change itself (TLS 1.3 to Ferry's Noise IK) is sound. What blocks the plan is LINK-3 with LINK-4: one private key and one writable trust list shared by Ferry, Ferry Host, Linen's helper and Linen on the phone make the four processes one principal. Linen's phone app, which runs agents' page scripts behind a seal the PRD itself calls "tested isolation, not a guarantee", would hold the credential that gives Ferry keyboard and mouse control of the Mac, and Linen's sandboxed helper could add phones to Ferry's trust. The per-app Allow in LINK-4 does not separate the apps, because the Mac identifies a device by its key, and the app on the phone chooses the prologue.

The fix is small and keeps the point of the change: **share the code, keep one identity per app.** Each app keeps its own static key in its own keychain, the Mac's QR carries both Mac keys, and "pair once" becomes one QR ceremony in which each app proves its own key with its own six digits. That also removes most of LINK-3's macOS provisioning work and Ferry's key migration.

Once section 15 is revised for the two P0s and P1-2, P1-3 and P1-5 (frame schema, proof of no behaviour change, who owns pairing), the extraction of `Noise/`, `PairingWindow`, `Link.swift` and `MemoryLink` can start; those four parts have no Ferry types in them (V). The other P1s must land in the PRD before the code they govern.

**Count: 2 P0, 8 P1, 11 P2.**

| ID | Sev | Where | In one line |
|---|---|---|---|
| P0-1 | P0 | LINK-3, LINK-4 | One phone key for Ferry and Linen lets Linen's process act as Ferry, with Input, on the Mac |
| P0-2 | P0 | LINK-3, LINK-4 | One shared, writable Mac trust list and key let the sandboxed Linen helper pair phones into Ferry Host and pose as it |
| P1-1 | P1 | LINK-3 | As written it needs provisioning profiles, the data protection keychain and a migration of Ferry Host's existing key; none is stated |
| P1-2 | P1 | LINK-1, LINK-2 | SecureChannel is built on Ferry's closed `FrameType` enum and `ferry/1` prologue; the "reserved range" collides with types Ferry uses |
| P1-3 | P1 | LINK-1, 15.5 | "Every FerryKit test passes" cannot prove "no change in Ferry's behaviour"; needs wire transcripts and mixed-version runs |
| P1-4 | P1 | LINK-1, LINK-6 | Route racing lives in the Ferry app, not in FerryKit; half of CONN-13 to CONN-27 is Ferry-only |
| P1-5 | P1 | LINK-4, 15.5, 9.3 | Two pairing state machines with opposite rules; no owner named; the gate's "second phone refused" weakens Ferry's reuse defence |
| P1-6 | P1 | 15.5, SYNC-7 | The "right state" for a forgotten or unknown phone cannot be produced: the Mac closes inside the handshake and sends nothing |
| P1-7 | P1 | RELAY-4 | "A session survives a change of route" is not what Noise over TCP or Ferry's design does |
| P1-8 | P1 | 15.5, M12, section 13 | The rewritten L(a) gate misses the family cases, has one untestable item, and the test plan still speaks of certificates |
| P2-1 | P2 | LINK-5 | Ferry already has the six digits; derive them with a label |
| P2-2 | P2 | LINK-2 | Prologue lacks LoomLink's own version; the cleartext role byte names app and role to any observer |
| P2-3 | P2 | RELAY-3 | "Nothing anyone in between can read" overclaims: the relay sees who, when, how much and which app |
| P2-4 | P2 | RELAY-1 | Raw TCP on 443 from a managed Mac running Zscaler is untested, and routing work files through a personal server is a policy question |
| P2-5 | P2 | RELAY-1, RELAY-2 | Write the relay's rules now: no pairing on relay streams, the Mac enforces "Allow from away", relay details through the session, relay abuse |
| P2-6 | P2 | 15 header | Section 15's override list misses a dozen places that still say TLS, certificates, free team or "relay is Later" |
| P2-7 | P2 | LINK-8, 15.1 | "Fuzzed decoder" is seeded random tests of two decoders; name the targets; the independent review must cover key storage and trust |
| P2-8 | P2 | LINK-1 | Ferry's link defaults (voice service class, 1 MB pre-attach buffer) are wrong for bulk sync |
| P2-9 | P2 | LINK-7 | Public repo hygiene and coordination with the other session editing Ferry |
| P2-10 | P2 | LINK-3, LINK-8 | Both installed apps are debug-signed with `get-task-allow`; keychain rules mean little until release signing |
| P2-11 | P2 | 15.1 | Make "act on nothing before the first transport message" a LoomLink row; 15.1 misdescribes what message 1 carries |

## The three questions, answered short

**1. Is TLS 1.3 to Noise IK sound, and what does it lose?** Yes, sound, for the reasons 15.1 gives, and the code backs them: the phone's handshake message 1 carries an empty payload (`SecureChannel.swift:112`), the Mac's message 2 too (`:247`), every token travels in the first transport frame (`Messages.swift:62-66`), and the Mac's `authorize` at message 1 "changes nothing" (`HostCore.swift:167-176`), so a replayed message 1 or a key-compromise forgery of it buys nothing (V). The primitives remain Apple's (CryptoKit X25519, ChaChaPoly, HMAC-SHA256); the composition is ours, about 730 lines in `Noise/` (V, 732 with the framer and errors), checked against cacophony vectors. What Linen gives up, beyond what 15.1 lists:
- *Apple maintaining the composition*: handshake state, nonce handling and framing are ours to keep right. LINK-8's independent review is the right answer.
- *Message 1 identity hiding against a later Mac key theft*: in IK the phone's static key is encrypted under a key from the phone's ephemeral and the Mac's static key, so someone who records traffic and later steals the Mac's private key learns which phone connected and when. TLS 1.3 encrypts the client certificate under the ephemeral exchange. Low value for two personal devices; worth one sentence.
- *TLS's exporter*: replaced by the handshake hash, which already mixes both static keys, both ephemerals and both payloads. Equivalent for the six digits (P2-1).
- Nothing is lost on forward secrecy for transport traffic or on mutual authentication.

Is LINK-3 feasible and safe? Feasible on iOS with the paid team; on macOS feasible only with provisioning profiles for Ferry Host and the helper, the data protection keychain, and a key migration (P1-1). It is not safe as designed (P0-1, P0-2). Does LINK-4 widen what a compromised or misbehaving app can do? Yes, a lot (P0-1, P0-2, and a buggy "forget" or "reset" in either app wipes the other's pairings). The LINK-2 prologues are right in principle and do separate apps and roles (V, by reading the code path), with two small changes (P2-2). The LINK-5 digits are sound: the Mac's message 2 is last, so the initiator cannot grind the hash, and the bias of 2^64 mod 10^6 is negligible (P2-1 for the wording). RELAY-1 to RELAY-4: the idea holds; RELAY-4 is worded against the architecture (P1-7), RELAY-3 overclaims (P2-3), and the transport through Zscaler is unproven (P2-4).

**2. Is LINK-1 feasible without behaviour change?** Yes for `Noise/`, `Pairing/PairingWindow.swift`, `Session/Link.swift` and `Testing/MemoryLink.swift`: they import only Foundation, CryptoKit, Network and Synchronization (V). `SecureChannel` is the hard part: it is written against Ferry's wire (`Frame`, `FrameType`, `FrameDecoder`, `ChannelRole`, `WireJSON`), `Liveness` against Ferry's `Ping`, and `RouteBook` against Ferry's `HostAddress`; path racing is not in FerryKit at all (P1-2, P1-4). It is a refactor of the type every Ferry connection is built on, so "no behaviour change" needs a byte-level proof (P1-3). Estimated as a few days of careful work, not an afternoon.

**3. Gaps, and is the L(a) gate complete and testable?** Not yet: see P1-5, P1-6 and P1-8, and the proposed gate table at the end.

## P0

### P0-1. One phone key makes Linen on the phone a holder of Ferry's Input credential

**Where.** LINK-3 (`PRD-2.md:449`), LINK-4 (`:450`).

**What is wrong.**
- Ferry Host decides who may open a control channel by the phone's static key alone: `authorize(role:key:)` returns `trust.isTrusted(key)` for control, video and bulk (`FerryHost/Session/HostCore.swift:168-176`), and the trust store is keyed by the public key's hash (`FerryHost/Session/TrustStore.swift:16-21, 48-51`). Permissions, including Input, hang off that key (`TrustStore.swift:11`; Ferry PRD PAIR-6, `PRD.md:116`, "Input lets a phone do anything a person at the keyboard can", `:113`). (V)
- The prologue that names the app is chosen by the client: the initiator picks its role and builds `role.prologue` (`SecureChannel.swift:83-86`); the cleartext role byte tells the responder which prologue to use (`:201-213`). So any process holding the phone's private key can open `ferry/1 control` to Ferry Host. LINK-4's "each app still asks its own Allow" is enforced per listener on the Mac and does nothing about which app on the phone is talking. (V)
- Linen on the phone runs untrusted scripts: IOS-4 (`PRD-2.md:183`) seals pages "exactly as PAGE-1 to PAGE-12", and the PRD says plainly the seal is "tested isolation, not a guarantee" (principle 10, `:93`; section 11, `:369`). Linen also parses manifests and frames from the network natively. With LINK-3, a compromise of Linen's process (a WebKit escape into the app, or a native parsing bug) reads the shared key and gets keyboard and mouse control of the Mac through Ferry. Before section 15, the same compromise could read pinned files only.
- Misbehaviour widens too: a Linen bug that deletes or rewrites the shared item ("Forget", a reset path, a migration) destroys Ferry's identity, and every Ferry pairing goes with it.

**Change.** Rewrite LINK-3: "Each app has its own long-term key, in its own keychain items, this device only, never synchronised. No app can read another app's private key. LoomLink is shared code, not a shared identity." Rewrite LINK-4's "pair once": one QR on the Mac carries one Mac key per app (both are public; 32 bytes each) and one token; the app that scans pairs itself with its own key, six digits and Allow; the sibling app pairs itself through the same QR within its 2 minutes (it may pick the scanned invite up from a shared, non-secret place such as an App Group file, or Hatim scans it twice), with its own six digits and its own Allow sheet carrying its own permissions. A compromised sibling that grabs the invite gains what a person who photographed the QR gains, which LINK-5's digits and Ferry's token-reuse rule already answer. Add a gate item: Linen's process cannot read Ferry's key (a negative keychain test on both devices).

### P0-2. One shared, writable trust list and Mac key make the sandboxed Linen helper able to pair phones into Ferry Host

**Where.** LINK-3 (`PRD-2.md:449`: "its list of paired devices live in one keychain access group ... shared by ... Ferry Host and Linen's helper"), LINK-4 (`:450`).

**What is wrong.**
- A keychain access group has no read-only members. The header says sharing works by every app listing the group in `keychain-access-groups` and passing it as `kSecAttrAccessGroup` to `SecItemCopyMatching`, `SecItemUpdate` and `SecItemDelete` alike (`MacOSX26.5.sdk/.../Security.framework/Headers/SecItem.h:201-217`). Every member can add, change and delete every item in the group. (V)
- So the helper, the least privileged and most exposed process (sandboxed, network-facing, parsing frames from the phone, SYNC-2 `PRD-2.md:198`), could add an attacker's phone key to the family list. Under LINK-4 a family-trusted phone then only needs Ferry's own first-use Allow; if Ferry's per-phone permissions live in the same shared list (LINK-3 does not say otherwise; today they sit beside the key in `phones.json`, `TrustStore.swift:7-14, 30-36`), the helper can grant Input directly. That is an escape from Linen's sandbox to full control of the user's session through Ferry Host, which is unsandboxed and holds Accessibility, Screen Recording and Apple Events (`FerryHost/FerryHost.entitlements`; Ferry PRD section 11). (V for the files; the escalation is my reading)
- The shared Mac private key lets a compromised helper listen as a fake Ferry Host (it already has a listener and Bonjour) and receive what the phone sends Ferry: typed text, clipboard, files.
- Concurrency: two processes doing read-modify-write on one list item lose updates; keychain items have no cross-process lock and no change notification, so "forgetting ... closes its sessions in both" (LINK-4) has no mechanism, and Ferry's own revocation promise is "within 1 s" (PAIR-6).

**Change.** Each Mac app keeps its own key and its own trust store, private to it (Ferry Host as today). If "forget in one, forget in both" is kept, make it a request, not shared authority: the app where Hatim clicks Forget asks the other over a signed channel (XPC with code-signature checks, which SYNC-2 already uses, or a Darwin notification that makes the other app re-read its own store), and the other app forgets in its own store; state the latency (Ferry's 1 s). Simpler alternative: "Forget offers 'Also forget this iPhone in Ferry'". Either way, no process can write another app's trust.

## P1

### P1-1. LINK-3 as written needs profiles, the data protection keychain and a key migration, none of which is stated

**Where.** LINK-3 (`PRD-2.md:449`), 15.4 (`:467`), 9.3 intro (`:327`), LINK-1 "no change in Ferry's behaviour" (`:447`).

**What is wrong.**
- On macOS, `kSecAttrAccessGroup` applies only to the data protection keychain (or synchronizable items): "kSecAttrAccessGroup (iOS; also macOS if kSecAttrSynchronizable and/or kSecUseDataProtectionKeychain set)" (`SecItem.h:88-89, 107-108, 144-145`; `:1033-1037`). The login keychain has no access groups. (V)
- Ferry Host's key is in the login keychain today: it tries the data protection keychain first and falls back (`FerryHost/Session/Identity.swift:24-38`), and the build log says it has no profile, "so its key lives in the login keychain (PAIR-4 fallback)" (`ferry/docs/PRD.md:559`). (V)
- Neither installed app has an application identifier, a `keychain-access-groups` entitlement or an embedded profile: `codesign -d --entitlements -` on `/Applications/Ferry Host.app` shows only `automation.apple-events` and `get-task-allow`; on `/Applications/Linen.app` only `get-task-allow`; neither bundle has `embedded.provisionprofile`. Linen.app is not sandboxed and no helper target exists yet (`project.yml`, targets Linen, LinenCommand, LinenQuickLook). (V)
- On macOS, `com.apple.application-identifier` and `keychain-access-groups` are restricted entitlements: they must be authorized by an embedded provisioning profile, or the app does not launch; development profiles are tied to registered Macs. (B: Apple TN3125 and TN3137.) The paid team can do it: Apple's macOS table lists Keychain sharing for the paid program (`docs/research/raw/iphone/apple-supported-capabilities-macos-table-2026-10-14.txt:21`). (V for the table)
- The sandboxed helper also needs its own profile inside its own bundle, plus `network.server` and `network.client`. (B)
- Moving Ferry Host's key into a shared data protection group is a migration. If the key is regenerated, every phone that pinned it from a QR must pair again; that is a Ferry behaviour change LINK-1 forbids. Same on the phone: Ferry's key is in its default group (`Ferry/Connection/Store.swift:8-33`, no `kSecAttrAccessGroup`), and its Mac list is a file in its own container (`Store.swift:62-79`).

**Change.** With P0-1 and P0-2 adopted, most of this disappears: Ferry keeps its key and stores untouched, and Linen's helper keeps its own key in its own keychain items (a sandboxed app can keep its own login-keychain item, B). If any shared item survives, add to LINK-3: the profiles and entitlements per target, the data protection keychain on macOS, accessibility "after first unlock, this device only" on both (Ferry needs it for Siri, Linen for background refresh), and a migration that copies the existing private key, verifies it, and only then deletes the old item, with "Hatim's iPhone, paired with Ferry on 2026-10-10, still connects without pairing again" as a gate item.

### P1-2. SecureChannel is written against Ferry's wire, and LINK-2's reserved range collides with it

**Where.** LINK-1 (`PRD-2.md:447`), LINK-2 (`:448`).

**What is wrong.**
- `FrameType` is a closed Swift enum of Ferry's types, and `FrameDecoder` throws on any value outside it (`Wire/Frame.swift:4-27, 83`) and takes each type's size limit from that enum (`:30-41, 84`). `SecureChannel` decodes with that decoder and checks sends against those limits (`SecureChannel.swift:64, 143-144, 269`). "The type space belongs to each app" therefore needs `SecureChannel` to take a frame schema (allowed types and limits) from the app. (V)
- Roles and prologues are Ferry's: `ChannelRole` is `pair, control, video, bulk` with `prologue = "ferry/1 <role>"` (`Wire/Messages.swift:7-12`), and the cleartext role bytes are a static table in SecureChannel (`SecureChannel.swift:91`). (V)
- `LinkLiveness` sends Ferry's `Ping` (`Session/Liveness.swift:30, 82`; `Ping` is in `Session/ClockSync.swift:9-24` beside Ferry's clock-sync code) and relies on the other side answering `.pong` (the phone reads pongs in `Ferry/Connection/MacConnection.swift`, case `.pong`). If liveness moves into LoomLink, ping and pong are LoomLink frames, but they already sit at 0x40 and 0x41 in the middle of Ferry's space, and `goodbye` at 0x7F. A fresh "small reserved range" would move them and break every installed Ferry build (installs now last a year). (V)
- `SecureChannel.send(_:json:)` uses `WireJSON` from Ferry's command file (`Wire/Commands.swift:324-332`). Small, but it shows the coupling. (V)

**Change.** LINK-2: "LoomLink's frame header is Ferry's exactly (`u32` little-endian length, `u8` type). Each app registers its types with their size limits; LoomLink's own frames keep the values Ferry uses today (ping 0x40, pong 0x41, and goodbye 0x7F if it becomes LoomLink's) and any new LoomLink frame takes 0xF0 to 0xFF; an unregistered type closes the session." LINK-1: name the generalisation (`SecureChannel` generic over a role table, a prologue builder and a frame schema; `ChannelRole`, `FrameType`, `Hello`, `Welcome`, `PairingInvite` stay in Ferry) and list the Ferry call sites it touches (`RouteRace.swift:124-126`, `PairingFlow.swift:53`, `ScreenSession.swift:68`, `FileSender.swift:66`, `HostCore.swift:143-151`, the host's pair session).

### P1-3. The LINK-1 gate cannot prove "no change in Ferry's behaviour"

**Where.** LINK-1 (`PRD-2.md:447`), 15.5 first gate item (`:475`), order (`:476`).

**What is wrong.** FerryKit's tests run both ends from the same code in one process (e.g. `SessionSecureChannelTests.swift`, 24 uses of Ferry frames and roles). A refactor that changes the role bytes, the prologue string, a frame's size limit or the frame header on both ends together passes every one of them and still breaks the installed iPhone build talking to a new Ferry Host, or the reverse. The vectors test the Noise core, which LINK-1 does not change. "Ferry's own gates" is not defined in section 15. (V for the tests' shape)

**Change.** Gate for LINK-1: (a) golden wire transcripts recorded from today's FerryKit with fixed ephemerals for each role (pair, control, video, bulk), byte-identical after the move; (b) on devices, the old Ferry iPhone build against the new Ferry Host and the new phone build against the old host, pairing and a control session each; (c) Ferry PRD section 13's security cases and the Connection 1.1 device pass list (`ferry/docs/design/connection-1.1.md` section 5), named. Split 15.5's order into two Ferry steps: the extraction (wire-identical, this gate) and anything that changes Ferry's identity or pairing (its own review and build-log entry in Ferry's PRD).

### P1-4. The path layer is mostly not in FerryKit, and half of CONN-13 to CONN-27 is Ferry's own

**Where.** LINK-1 ("from `Session/` ... routes and path racing", `PRD-2.md:447`), LINK-6 (`:452`).

**What is wrong.**
- The race is app code: `Ferry/Connection/RouteRace.swift` (171 lines, `@MainActor`, candidates built from the app's `PairedMac` and test overrides, `:1-60`), driven by `MacConnection.swift` (752 lines). FerryKit's `Session/Routes.swift` holds only the saved-route rules, and it depends on `HostAddress` from Ferry's `Welcome` (`Routes.swift:15, 82`; `Messages.swift:145-146, 163-179`). (V)
- Several CONN rows are Ferry behaviour, not link behaviour: CONN-19 (Siri), CONN-20 (App Nap while controlling), CONN-21 (held input after a stall), CONN-23 (keep-awake and history carried over), CONN-26 (idle state for Siri), CONN-27 (held keys pressed again, Screen restarted) (`ferry/docs/PRD.md:142-150`). (V)

**Change.** LINK-6: split the list. LoomLink gets the race engine (lifted out of `RouteRace.swift` with an app-supplied candidate list), CONN-13 (journal hooks), CONN-14 (liveness), CONN-15, CONN-16, CONN-17 (as a generic "addresses" frame), CONN-22, CONN-24, CONN-25. Ferry keeps CONN-19, 20, 21, 23, 26, 27. Say that Linen's background refresh uses the race without liveness's 0.25 s pings, or with a slower interval.

### P1-5. Two pairing state machines with opposite rules, and no owner

**Where.** LINK-4 (`PRD-2.md:450`), LINK-1 ("Ferry's frame types and messages ... stay in Ferry"), 15.5 gate (`:475`), 9.3 pairing bullets (`:330-337`, overridden by 15's header but not replaced).

**What is wrong.** "Pairing can start in either app and trusts the phone for the family" needs one pairing protocol, yet the two differ:

| | Ferry today (V) | Linen 9.3 | 15.5 gate |
|---|---|---|---|
| Concurrent pairing sessions | Several accepted; a second presentation of a consumed token cancels any pending Allow and warns (`HostCore.swift:550-576`; PAIR-3) | "One pairing at a time" | "a second phone during pairing" refused |
| Wrong token | Exponential backoff, persisted across restarts (`PairingWindow.swift:58-79`) | Three wrong codes end pairing | "a wrong token three times" |
| Frames | `hello` with `pairingToken`, then `event(pairing(...))` (`Messages.swift:62-63, 199-207`) | `pair-code`, `pair-result`, nothing else | `hello` or `want` on a pairing session refused |
| QR | `ferry://pair?d=...`, refuses any other scheme or version (`Messages.swift:238-257`) | Mac's hash, Bonjour name, code | not stated |

Refusing the second session before its token arrives (Linen's rule, kept in the gate) throws away Ferry's best defence against someone who photographed the QR and got there first: the real phone's token would be seen as a reuse and cancel the impostor's pending Allow. With refusal, safety rests on Hatim noticing that his phone shows "busy" while the Mac shows digits.

**Change.** Add a LINK row: "LoomLink owns pairing: the invite payload (decoded by both apps; `ferry://pair` invites keep working), the pair role, the token in the first transport frame, the match code, the token-reuse cancel, the persisted backoff, the flood limits, and Linen's rule that a pairing session can only pair. The app supplies the Allow sheet and its permissions." Adopt Ferry's concurrency and backoff rules; change the gate item to "a second device presenting the same token cancels the pending Allow on the Mac and both phones show why".

### P1-6. The "right state" for a forgotten or unknown phone cannot be produced

**Where.** 15.5 gate ("refused with the right state ... an unknown key after pairing, a forgotten phone", `PRD-2.md:475`), SYNC-7 ("This Mac no longer knows this iPhone · Pair again", `:203`).

**What is wrong.** When `authorize` refuses a key, the responder ends the channel before writing message 2 (`SecureChannel.swift:241-245`), and the TCP connection just closes. The phone sees the same thing as a network drop or a handshake timeout. Ferry's phone maps a `notPaired` goodbye to "The Mac does not accept this phone" (`MacConnection.swift:556-561`), but nothing in Ferry Host ever sends `notPaired` (grep finds it only on the phone). (V)

**Change.** Decide and write it down. Option A: for a well-formed IK message 1 from an unknown key on a non-pair role, the Mac completes the handshake, sends one `goodbye(notPaired)` and closes, acting on nothing else; cost: anyone who already knows the Mac's public key learns that it does not trust their key. Option B: the phone infers it (Bonjour sees the Mac and three handshakes in a row close right after message 1) and says "This Mac may no longer know this iPhone". A is exact and cheap; B changes nothing on the wire. Either way, list the expected state per refusal case in the gate (table at the end).

### P1-7. RELAY-4's "a session survives a change of route" contradicts the design it reuses

**Where.** RELAY-4 (`PRD-2.md:463`), LINK-6 (`:452`).

**What is wrong.** A LoomLink session is a Noise transport bound to one byte stream: `SecureChannel` is created on one `ByteLink` (`SecureChannel.swift:55, 76-88`), Noise transport nonces must arrive in order with no resumption (`NoiseTransport.swift:31-61`, "no rekey"), and Ferry's continuity across routes is a warm replacement session (CONN-14, CONN-23), not a session that moves. Making one session survive a route change would need a resumption layer nobody has designed. Linen does not need it: its protocol already resumes on a new session (`hello` with sequences, `want` with offsets, `.partial` files, `PRD-2.md:340-346`). (V)

**Change.** RELAY-4: "2.1 leaves room for the relay: no LAN-only assumption in Linen's frames; after a route change the phone opens a new session and the sync resumes from its sequences and partial files; the relay is one more entry in LINK-6's race."

### P1-8. The rewritten L(a) gate and the test plan are incomplete

**Where.** 15.5 (`PRD-2.md:475`), M12 (`:391`), section 13 "The link" (`:411`), section 11 risks (`:373`).

**What is wrong.**
- "Mismatched six digits" is not a refusal the system can make; the digits are compared by a person. As a gate item it is untestable.
- Missing family cases: per-app Allow (a phone paired through Ferry opening Linen gets Linen's Allow; refusing it leaves Ferry untouched), forget in one app and the effect and latency in the other, key isolation between the apps (P0-1), the helper unable to touch Ferry's trust (P0-2), Ferry's existing pairing surviving (P1-1, P1-3).
- Missing platform cases: the helper running as a sandboxed login item reading its key and listening; background refresh dialling the Mac with the phone locked (the key must be readable after first unlock); section 11 already lists background refresh as an L(a) unknown, but neither gate tests it.
- M12's exit test and section 13 still test certificates ("wrong certificate", "a phone presenting another certificate", "two phones pairing at once" with Linen's rule).

**Change.** Replace 15.5's gate with the table at the end of this review; rewrite M12's pairing list and section 13's "Trust:" sentence in key terms with the family cases.

## P2

**P2-1. LINK-5 (`PRD-2.md:451`).** "Ferry's pairing gains it too" is wrong: Ferry already shows the six digits from the handshake hash (PAIR-3, `ferry/docs/PRD.md:113`; `MatchCode.from(handshakeHash:)`, `Messages.swift:209-218`). The derivation is sound (first 8 bytes of the final hash, mod 10^6; the Mac writes the last message, so the phone cannot grind it). The same hash also binds Ferry's secondary-channel tokens (`HostCore.swift:378-391`). Change: say Ferry has it; derive the code with a label, `HKDF(h, info: "loomlink pair code v1")`, so the code and channel binding never share raw material; keep Ferry's current derivation for Ferry's existing invites if wire identity matters.

**P2-2. LINK-2 prologues (`PRD-2.md:448`).** The prologues separate apps and roles correctly: a Linen message 1 sent to Ferry's listener is read with Ferry's prologue and fails to decrypt (V, by the code path in `SecureChannel.swift:201-240`). Two changes: put LoomLink's own version in the prologue (`loomlink/1 linen/1 sync`), since LoomLink's frames and pairing will version separately from each app; and note that the role byte before the handshake is cleartext (`SecureChannel.swift:113-115`), so any network observer, and later the relay, learns "Linen sync" versus "Ferry control". Acceptable; say it.

**P2-3. RELAY-3 (`PRD-2.md:462`).** "Nothing anyone in between can read" is true for content only. The relay operator and the hosting provider see both IP addresses, times, byte counts, the rendezvous ID (stable, so linkable) and the role byte. Change: "with the relay on, a server Hatim runs carries only ciphertext; it sees when the devices talk, how much, and which app". Section 4's goal (`:65`) and non-goals ("a relay is Later", `:68`) change with it at 2.x.

**P2-4. RELAY-1 transport (`PRD-2.md:460`).** The Mac is managed and runs Zscaler (Ferry notes the `100.64.0.1` clash, `Messages.swift:169`; the vault note's relay figures were taken "at the office (Wi-Fi, Zscaler on)", `~/vault/wiki/projects/Ferry/Ferry connectivity.md:74`, and measured round trips and TCP connects, not a long-lived non-TLS stream). Whether Zscaler passes raw, non-TLS bytes on 443 is untested (B: client connectors commonly inspect or drop non-TLS traffic on 443). Change: wrap the relay hop in TLS to the relay (Noise stays inside), and spike the Mac's outbound stream through Zscaler before the relay is built. Also name the policy question beside section 11's: the relay carries work files from a managed Mac through a personal server, which is a different question from "work files on a personal phone" that Hatim answered.

**P2-5. Relay rules (`PRD-2.md:460-461`).** Write now, while RELAY-4 shapes 2.1: the Mac never accepts a pair-role handshake on a stream that arrived through its relay connection (the Mac dialled it, so it knows); "Allow from away" is enforced by the Mac on relay streams, per phone and per app; relay details reach paired phones inside an authenticated LoomLink frame (phones paired before the relay exists have no QR with them); the relay admits a Mac only with a registration secret and caps bytes and joins per ID, so it is not an open tunnel for anyone who reads the QR.

**P2-6. Stale text the 15 header does not override (`PRD-2.md:430`).** The header row "Asked for" ("Linen gets its own link, pairing and helper and shares no code with it", `:8`); 6.5's intro ("TLS 1.3 with pinned certificates", `:193`); SYNC-4 ("never changes a certificate pin", `:200`); SYNC-7 ("refuses the phone's certificate", `:203`); IOS-10's 7-day free-team expiry (`:188`); 9.3's intro ("works on the free Apple team ... TLS and the keychain need no capability", `:327`); 9.3's "framed with `NWProtocolFramer`" (`:339`); 9.4's targets (LinenKit "the link's protocol", no LoomLink, no LinenHelper entitlements, `:354`); section 11's free team and "TLS client certificates over peer-to-peer Wi-Fi" (`:370, :373`); M12 (`:391`); section 13 (`:411`). Change: list them in 15's header or edit them in place.

**P2-7. LINK-8 and 15.1's "its decoder is fuzzed" (`PRD-2.md:437, :454`).** Today's "fuzzing" is seeded random input over `FrameDecoder` (`WireBytesTests.swift:229-245`, 20 seeds of 200 chunks) and the input decoder (`WireInputTests.swift:191`), plus random re-chunking of valid streams (`NoiseFramerTests.swift:21-40`, `SessionSecureChannelTests.swift:245-254`). Nothing feeds random or mutated bytes to `NoiseHandshake.readMessage`, to the role byte path, or to the pairing state machine. (V) Change: name the fuzz targets (stream decoder, frame decoder with each app's schema, handshake read for message 1 and 2, the pair session) and the budget per build; and widen the independent review's scope to key storage, trust stores and pairing, which are where P0-1 and P0-2 sit.

**P2-8. Link defaults (LINK-1).** `TCPLink` defaults to `.interactiveVoice` (`Link.swift:53, 59`); Ferry's own bulk channel uses `.background` (`FileSender.swift:66`); Linen's sync should too. `SecureChannel` holds at most 1 MB of frames before the owner attaches and closes past it (`SecureChannel.swift:69-70, 274-279`), while Linen's manifest page may be just under 1 MB (`PRD-2.md:347`); make the buffer a parameter or attach before the first frame can arrive. Liveness pings every 0.25 s (`Liveness.swift:22`); too chatty for background refresh.

**P2-9. LINK-7 (`PRD-2.md:453`).** LoomLink will be public while Ferry is private: start LoomLink's history fresh rather than carrying Ferry's, and scrub comments that name the work environment (`Messages.swift:169` names Zscaler and "a work VPN") per section 11's public-repository rule (`:375`). Another session has uncommitted edits in Ferry's `Makefile`, `CLAUDE.md`, `docs/BUILD.md` and car files (`git status`, V); LINK-1 will touch the Makefile and `project.yml`, so agree the order with that session first.

**P2-10. Signing (LINK-3, LINK-8).** Both installed apps carry `com.apple.security.get-task-allow` (V, `codesign`). With it, a same-user debugger-capable process can read the keys from memory, which makes keychain access rules moot until release signing. Put release signing (no `get-task-allow`, hardened runtime) next to LINK-8's review as a 2.1 release gate.

**P2-11. The first-message rule (15.1, `PRD-2.md:439`).** 15.1 says the phone's first handshake message "carries only version, role, name and model" (copied from Ferry's PRD, `PRD.md:379`). The code is stricter: message 1's payload is empty (`SecureChannel.swift:112`), the role is the cleartext byte bound by the prologue, and name and model travel in `hello`, a transport frame (`Messages.swift:55-83`). Fix the sentence, and add the rule as a LoomLink row so Linen inherits it: "nothing happens on message 1: no Allow sheet, no 'last seen', no history row, no notification, no session replacement, until the first transport frame".

## Proposed L(a) gate (replaces 15.5's second bullet)

Go only if every row holds on the iPhone 15 Pro and the MacBook Air, over Wi-Fi and over peer-to-peer Wi-Fi where marked.

| Case | Expected |
|---|---|
| LINK-1 done: golden transcripts byte-identical; old Ferry phone build with new Ferry Host, and the reverse | Pairing and a control session work both ways (P1-3) |
| Pair from Linen with the QR | Six digits match on both screens; Allow; a new session proves both keys |
| Pair Ferry from the same QR within 2 minutes (or Ferry already paired) | Ferry's own digits and Allow sheet with Ferry's switches; Linen's pairing unaffected |
| Linen's process tries to read Ferry's key, and the helper tries to write Ferry Host's trust | Refused by the keychain on both devices (P0-1, P0-2) |
| Wrong token | Backoff as Ferry's; phone shows why |
| Expired QR | Refused; phone shows "This pairing code expired" |
| A second device presents the same token while an Allow is pending | Pending Allow cancelled on the Mac; both screens say why (P1-5) |
| A pairing session sends `hello`, `want` or any non-pairing frame | Session closed, nothing sent but the pairing result |
| Replayed handshake message 1 | Connection dropped; nothing logged as a session, no Allow, no "last seen" |
| Unknown key after pairing; forgotten phone | Refused; phone shows "This Mac no longer knows this iPhone" (P1-6) |
| Forget in Ferry Host | Linen's own decision as written (request or offer); Linen sessions end within the stated time |
| Ferry handshake to Linen's listener; Linen handshake to Ferry's listener | Refused at message 1 |
| Helper as a sandboxed login item, Linen closed | Reads its key, listens, serves a sync |
| Background refresh with the phone locked after first unlock | Dials the awake Mac and fetches |
| 60 KB change, app open | Within section 4's targets, over Wi-Fi and peer-to-peer Wi-Fi |
| Packet capture of the link | No readable file content |

## What I verified and what is belief

- **Verified:** every FerryKit, Ferry app and PRD line cited above; the SDK header text in `MacOSX26.5.sdk` `SecItem.h`; the saved macOS capability table; entitlements and missing profiles of the installed Ferry Host and Linen (`codesign`); Ferry's `git status`; Noise line count (732 with framer and errors).
- **Belief, not re-read today:** that `application-identifier` and `keychain-access-groups` are restricted on macOS and need an embedded profile (TN3125, TN3137); that a sandboxed app may keep its own login-keychain items; that Zscaler's client inspects or drops non-TLS on 443; that sandboxed apps can post Darwin notifications. None was tested on a device.

## Not reviewed

- SYNC-2's helper design, unchanged by section 15. One concern for its round: Linen.app is unsandboxed (`project.yml` has no app entitlements), and app-scoped security-scoped bookmarks resolve only in the app that made them (B), so passing pinned-folder grants to a sandboxed helper needs a stated mechanism (XPC-carried sandbox extensions or bookmarks the helper makes itself through an open panel).
- Section 15.4's IOS-11 (the Loom brain as first pin) and the renderer shim: no security content.
- Ferry's car work (`PRD-car.md`), out of scope.
