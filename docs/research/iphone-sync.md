# Linen 2: iPhone, link and export research

Research lane for Linen 2 (`docs/PRD-2.md`): how files reach the iPhone, how the link is secured, what a free Apple developer team allows, what iOS lets an app do in the background, what PDF export really produces (Arabic included), how sealed pages carry over to iOS, and which iOS readers already exist. Apple documentation, technotes, a WWDC session, WebKit source, two RFCs, the Noise specification, Syncthing's and LocalSend's protocol documents and App Store data were read on 2026-10-14 and saved under `raw/iphone/` (paths below are relative to `docs/research/raw/`, which is gitignored). Six measurements ran on this Mac (MacBook Air M4, model Mac16,12, macOS 26.5.1 build 25F80, Xcode 26.6 with the 26.5 SDKs, Swift 6.3.3, poppler 26.04.0) as headless Swift tools, with any web view in a borderless window placed off screen at (-30000, -30000) under `NSApplication.setActivationPolicy(.prohibited)`. Their sources and outputs are saved beside the captures as `measured-*`. Nothing ran on an iPhone: every iOS statement comes from Apple's documents or the iOS SDK headers, and is marked where a device test is still needed. Every quote was checked against the saved text with grep. "NL" means the pages I saved do not mention it; NL does not mean absent.

## Two-minute summary

| Question | Answer | Evidence |
|---|---|---|
| How to secure the link | **TLS 1.3 with a self-signed certificate on each side, pinned by SHA-256 at pairing.** Measured on loopback: TLS 1.3 (0x0304), suite 0x1302, ready in 10 to 17 ms; a wrong pin, an impostor on either side and a phone with no certificate all fail. The identity is made in process with `SecKeyCreateRandomKey`, a small DER builder and `SecIdentityCreate`; no keychain import, no PKCS#12, no paid team. | `iphone/measured-tls13-pinned-loopback-*` |
| Why not the PSK from the QR | Network.framework refuses TLS 1.3 with a PSK (-9858, every case). TLS 1.2 ECDHE-PSK (0xCCAC) works and has forward secrecy, but the QR then *is* the long-term secret. Apple's own sample uses a plain PSK suite (0x00A8, no forward secrecy) from a passcode; the same settings measured TLS 1.2. | `iphone/measured-tls-psk-loopback-*`, `iphone/apple-p2p-sample-NWParameters+InitWithPasscode-*` |
| What the free team allows | Everything the link needs: Bonjour and local network are Info.plist keys, peer-to-peer Wi-Fi is one parameter, App Groups, Keychain sharing, Data protection and Background modes are "yes". Push, iCloud, Associated domains, Multipath and Network extensions are "-" (confirmed). Wi-Fi Aware and the multicast entitlement are not in the table; Linen needs neither. | `iphone/apple-supported-capabilities-ios-table-*`, `-macos-table-*` |
| Local network prompt | iOS asks once, at the first local network operation, with Linen's usage text; when denied, Bonjour finds nothing and connections wait with `localNetworkDenied`. On macOS 15+, registering a Bonjour service needs the privilege, listening for TCP does not; a helper's prompt is shown under its app's name. | `iphone/apple-tn3179-*`, `iphone/wwdc2020-10110-*` |
| iOS background | The link lives while the app is open. On leaving, `beginBackgroundTask` gives time Apple does not fix in its docs. BGAppRefresh and BGProcessing run when the system decides. **BGContinuedProcessingTask (iOS 26)** fits a sync the user starts by a tap, such as the first sync after pairing, with a Live Activity and the network. | `iphone/apple-extending-background-execution-*`, `iphone/apple-performing-long-running-tasks-*` |
| PDF from `createPDF` | Vector, fonts embedded as subsets, pages split only in height at 14,400 pt (WebKit's "200 inches at 72dpi"), external links kept, internal links lost. Quartz itself writes and PDFKit reads 30,000 and 200,000 pt pages. | `iphone/measured-createpdf-macos-*`, `iphone/webkit-src-WebPage-cpp-*`, `iphone/measured-pdfkit-large-pages-*` |
| **Arabic in exported PDFs** | **Thmanyah Arabic does not come back as text.** In both `createPDF` and Core Text, PDFKit returns presentation forms with letters missing ("لينن" becomes "ﻟﻴ") and finds 0 of 4 Arabic words; SF Arabic (system-ui) fails too. **Geeza Pro works**: PDFKit returns every plain Arabic line exactly, in logical order, and finds all 4 words. **Thmanyah drawn as outlines with an invisible Geeza Pro text layer** looks right and searches right, and puts no Thmanyah data in the file. poppler mangles lam-alef in every case. | `iphone/measured-createpdf-arabic-*` |
| iOS readers | Read.md (free, Pro tier) is the closest: offline, Mermaid, opens from Files and AirDrop, PDF and HTML export. Obsidian syncs through its paid Sync or iCloud. The readers saved here get files through a cloud, a server or a manual transfer; the file movers (LocalSend, Möbius Sync) need no cloud but render nothing. | `iphone/itunes-*`, `iphone/obsidian-help-*` |
| Sync protocol | Borrow BEP's per-file hash, sequence numbers for delta manifests and temporary files; borrow LocalSend's metadata-first offer and SHA-256 check on arrival. Skip version vectors, block reuse and multicast. | `iphone/syncthing-bep-v1-*`, `iphone/localsend-protocol-readme-*` |
| Sealed pages on iOS 26 | All present: WKContentRuleList and WKURLSchemeHandler (iOS 11), `allowsContentJavaScript` (iOS 14), `securityRestrictionMode` (docs: iOS 26.4; iOS 26.5 SDK header: 26.5). The leak test stands as measured: only a document-start script removing RTCPeerConnection stopped WebRTC STUN packets. | `iphone/apple-wk*`, `iphone/sdk-greps-*`, `iphone/measured-webview-leaks-*` |

### What this means for Linen 2

1. **Section 9.3 and SYNC-1: keep "Apple's own TLS 1.3", with certificates.** The working shape in 9.3 holds, with one change: in Network.framework TLS 1.3 worked with certificates and failed with a PSK, so the PSK route stops at TLS 1.2. Pairing becomes: the QR carries the Mac's certificate hash, its Bonjour instance name and a one-time code; the phone pins the Mac, sends its own certificate and the code over the first TLS session; both screens show six digits derived from the two certificate hashes; Hatim clicks Allow; the Mac pins the phone. A photo of the QR is useless afterwards. This is the model Syncthing uses ("preshared certificate fingerprints (SHA-256)").
2. **Section 11, free team: no blocker for the link.** Every piece Linen 2 needs is free: Bonjour, peer-to-peer Wi-Fi, TLS, keychain, App Groups, background modes. The paid-only items from an earlier project's research (Multipath, Network extensions, Push, iCloud) are confirmed "-" for the free team, and Linen 2 uses none of them.
3. **SYNC-6, the cable route is unproven.** No saved document says Bonjour or a TCP link runs over the USB cable between a Mac and an iPhone without Personal Hotspot. Treat "the cable's network link" as a spike, or drop it from L2 and keep Wi-Fi and peer-to-peer Wi-Fi.
4. **SYNC-7 needs one more honest state:** "Local network access is off for Linen" with the path to Settings, because a denied phone looks exactly like "Mac not nearby" (Bonjour simply finds nothing). The phone should ask at pairing, after the QR scan, never at launch (WWDC20 10110).
5. **SYNC-2 and the Mac prompt.** The helper triggers macOS's local network alert when it first registers `_linen._tcp`; it shows under Linen's name if macOS ties the helper to the app. Ask for it from Settings in the same step as "start at login". Make the phone the side that dials, since accepting TCP needs no privilege on the Mac.
6. **SYNC-5: "changes arrive within 2 s" while the app is open is a protocol promise, and a 100 MB first sync should run as a BGContinuedProcessingTask** started by the pairing tap or "Sync now", so it survives leaving the app and shows its progress in a Live Activity. Background refresh stays as SYNC-5 already words it ("runs opportunistically").
7. **EXP-5 as written does not hold for Arabic.** "Arabic included (Thmanyah subsets embedded)" fails in every Thmanyah path measured. Two paths passed: Arabic set in Geeza Pro in exports, or Thmanyah drawn as glyph outlines with an invisible Geeza Pro text layer. The second keeps the look, keeps text searchable in Preview, and removes the font-license question for PDFs (no Thmanyah bytes in the file). It needs a native drawing path (Core Text into Quartz) for boards; a spike should confirm it at board scale.
8. **Section 10, PDF checks must read text with PDFKit.** poppler's `pdftotext` writes lam-alef as alef then lam and adds bidi marks, so it fails good Arabic PDFs; PDFKit (what Preview uses) reads them correctly. Diacritics come back with a stray space before some marks in every path, so tests should compare undiacritized text.
9. **EXP-5 and EXP-7, page size.** `createPDF` never splits width, and splits height at 14,400 pt. A whole-board PDF must be scaled to fit 14,400 pt before drawing (as EXP-5 says), or drawn natively; Quartz and PDFKit handle larger pages, but the PDF specification says viewers "should" support at most 14,400 units.
10. **IOS-4: everything PAGE-1 to PAGE-8 uses exists on iOS 26**, but `securityRestrictionMode` needs iOS 26.4 or 26.5 depending on the source, so gate it by availability. Local network privacy will not catch a page's WebRTC packets, because Apple exempts WKWebView traffic from it.
11. **Section 3, competition.** On the iPhone, Linen 2's open space is: files from your own Mac, over your own network, no cloud, no account, read offline with Arabic per block, boards and sealed pages in one reader. Read.md covers offline Markdown with Mermaid; Freeform covers boards through iCloud; nobody saved here covers both, and none reads Obsidian's JSON Canvas on the phone in the pages I saved.

## 1. Securing the link (SYNC-1, section 9.3)

### What was measured

Two loopback tests on this Mac, both as unsigned command-line tools.

**PSK test** (`iphone/measured-tls-psk-loopback-macos-2026-10-14.txt`, run earlier and reported as is):

| Case | Result |
|---|---|
| TLS 1.2, `TLS_PSK_WITH_AES_128_GCM_SHA256` (Apple's sample suite) | READY, version 0x303, suite 0xa8 |
| TLS 1.2, wrong key | WAITING -9820 "bad MAC" |
| TLS 1.2, `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256` | READY, version 0x303, suite 0xccac |
| TLS 1.2, DHE-PSK GCM requested | READY, but negotiated 0xa8 (plain PSK) |
| Server holding three PSKs, client presents "phone-b" | READY, 0xccac: the server picks the key by identity |
| TLS 1.3 with a PSK (with a suite, without, wrong key) | WAITING -9858 "handshake failed", all three |
| Default versions with a PSK | READY, TLS 1.2, 0xa8 |

**Pinned-certificate test** (`iphone/measured-tls13-pinned-loopback-macos-2026-10-14.txt`, new): each side makes a P-256 key with `SecKeyCreateRandomKey` (not stored), builds a self-signed X.509 certificate in DER, signs it with `SecKeyCreateSignature`, and turns it into an identity with `SecIdentityCreate`. TLS is fixed at 1.3, both sides require the peer's certificate, and each side's `sec_protocol_options_set_verify_block` accepts only the SHA-256 of the pinned peer certificate.

| Case | Client | Server |
|---|---|---|
| Both pins right | READY in 17 ms, TLS 1.3 (0x304), suite 0x1302, echo works | ready |
| Both pins right, second run | READY in 10 ms, same | ready |
| Client pins a different server | WAITING -9808 | failed -9825 |
| Impostor server | WAITING -9808 | failed -9825 |
| Server pins a different phone | FAILED -9825 | failed -9808 |
| Impostor phone | FAILED -9825 | failed -9808 |
| Phone without a certificate | FAILED -9829 | failed -9863 "certificate required" |

Three identities took 20 ms to make. Identity creation is lines 10 to 36 of the 129-line harness.

### The three options

| | (a) TLS 1.2 ECDHE-PSK, PSK from the QR | (b) TLS 1.3, pinned self-signed certificates | (c) Noise IK over plain TCP, CryptoKit |
|---|---|---|---|
| Works in Network.framework | Yes, TLS 1.2 only (measured) | Yes (measured) | Not applicable: app-level, under a custom framer |
| Forward secrecy | Yes: RFC 5489 says the ECDHE-PSK suites "provide Perfect Forward Secrecy" | Yes: without a PSK, TLS 1.3 uses its (EC)DHE key exchange mode (one of the three RFC 8446 lists); RFC 8446 says forward secrecy "is not satisfied" only in the "psk_ke" mode | Yes for transport messages: the spec rates IK's later payloads "strong forward secrecy" (destination property 5); the first payload only property 2, "vulnerable to replay" |
| Mutual authentication | Both prove the PSK; anyone holding the QR's secret can pose as either side | Each side proves its private key; pins decide who is accepted | Static keys on both sides; IK assumes the phone knows the Mac's static key in advance (from the QR) |
| What the QR must carry | The long-term secret | Only public data plus a one-time code | The Mac's public static key plus a one-time code |
| Code in Linen | Under 20 lines of options (Apple's `tlsOptions` function is about 18) | About 30 lines to make an identity, 10 for the verify block, plus keychain storage (not measured) | The Noise handshake, cipher and symmetric state objects and nonce handling: several hundred lines (estimate, not written) |
| What Apple's sample does | This family: plain TLS 1.2 PSK (0x00A8) from an HMAC of a passcode, `includePeerToPeer = true` | NL in the sample | NL |
| Risks | TLS 1.3 refused; the QR photographed once breaks every later session's authentication; RFC 8446 warns a "low-entropy secret, or password, is subject to dictionary attacks", which is exactly Apple's passcode sample | DER and certificate fields hand-built (or a package); certificate lifetime must be long and ignored; device test still needed on iOS and over AWDL | Custom cryptography outside Apple's stack; no Apple sample; KCI and replay of the first message to reason about |

**Recommendation: (b).** It is the only option that gives TLS 1.3, forward secrecy, real mutual authentication and a QR that holds no lasting secret, all inside Apple's TLS stack, and it measured clean on the first try. It matches Syncthing BEP ("SHALL use TLS 1.3", authentication by "preshared certificate fingerprints (SHA-256)") and LocalSend (fingerprint "is the SHA-256 hash of the certificate"). Keep (a), ECDHE-PSK, as the fallback if client certificates misbehave on a device.

**Making the identity without a paid team.** None of this touches a capability:
- `SecIdentityCreate(allocator, certificate, privateKey)` is public in the iOS 26.5 and macOS 26.5 SDKs (iOS 11.2, macOS 10.12) and "returns null if the private does not key correspond to the public key" (`iphone/apple-secidentitycreate-*`, `iphone/sdk-greps-security-pdf-*`).
- `SecPKCS12Import` also works: the header says in-memory import "is already default behavior on iOS", and `kSecImportToMemoryOnly` (macOS 15, iOS 18) skips the keychain on macOS. It needs a PKCS#12 file made somewhere, so it is the longer path.
- In the app the private key should be made permanent in the keychain with a non-synchronizing, this-device-only attribute. Plain keychain use is not a capability in Apple's tables; Keychain sharing, "yes" for the free team, is only needed if the helper and the app read the same key. Storage was not measured (the harness kept keys in memory to stay out of this Mac's keychain).

## 2. What the free team allows

From Apple's "Supported capabilities" tables (`iphone/apple-supported-capabilities-ios-table-*`, `-macos-table-*`). The column is "Apple Developer", which Apple defines as account holders with "No cost is associated with this agreement and developers can’t distribute apps". "-" means not available. Install limits (7 days, 3 apps on a device) are from PRD-2 section 11, not from these tables.

| Capability | iOS, free team | macOS, free team | Note and source |
|---|---|---|---|
| Bonjour and local network | Yes, no capability | Yes, no capability | Info.plist keys only: `NSLocalNetworkUsageDescription`, `NSBonjourServices` with `_linen._tcp` (`iphone/apple-tn3179-*`, `iphone/apple-nsbonjourservices-*`) |
| Peer-to-peer Wi-Fi (AWDL) | Yes, no capability | Yes, no capability | "Opt in to peer-to-peer Wi-Fi by setting the includePeerToPeer property" (`iphone/apple-tn3151-*`) |
| Multicast entitlement | NL in the table | Not required | Needed on iOS only for raw multicast, "arbitrary Bonjour service types" or browsing all types; WWDC20: "request this entitlement through the developer portal". Linen needs none of it (`iphone/apple-tn3179-*`, `iphone/wwdc2020-10110-*`) |
| Wi-Fi Aware | NL in the table | Unavailable | iOS 26 entitlement `com.apple.developer.wifi-aware`; the framework connects to "Wi-Fi Aware certified accessories", supported devices list no Mac; the macOS SDK marks it `macOS, unavailable` (`iphone/apple-wifiaware-*`, `iphone/sdk-greps-*`) |
| App Groups | yes | yes | table |
| Keychain sharing | yes | yes | table |
| Data protection | yes | not in table | table |
| Background modes (`fetch`, `processing`) | yes | n/a | table; BGAppRefreshTask "requires setting the `fetch` UIBackgroundModes capability" (`iphone/apple-bgapprefreshtask-*`) |
| BGContinuedProcessingTask | No capability named, except "Background GPU Access" for GPU work (not in the table, NL) | n/a | `iphone/apple-performing-long-running-tasks-*` |
| App Sandbox, Hardened runtime | n/a | yes, yes | table |
| Associated domains | - | - | table |
| Push notifications | - | - | table |
| iCloud (CloudKit, documents, key-value) | - | - | table |
| Multipath | - | not in table | table |
| Network extensions, Personal VPN | - | - | table |
| Access WiFi information, Hotspot | - | not in table | table; Linen does not need them |

## 3. Local network privacy (iOS and macOS)

From TN3179 (`iphone/apple-tn3179-local-network-privacy-*`, revised 2026-10-06) and WWDC20 10110 (`iphone/wwdc2020-10110-*`).

- **Where it applies.** iOS since 14, macOS since 15. The privilege has three states: undetermined, allowed, denied. "The first time it performs a local network operation, the system presents the local network alert", with the usage description from Info.plist.
- **What counts.** All Bonjour operations (register, browse, resolve) and outgoing TCP to a local address need it. "Listening for and accepting incoming TCP connections" does not. "Traffic originating from WKWebView, SFSafariViewController, and Safari doesn’t require local network access."
- **NSBonjourServices.** WWDC20: "if your app uses Bonjour to browse or advertise, you must provide a list of the service types"; without it the browser fails with "NoAuth" and no prompt appears. For Linen: `_linen._tcp` in both apps.
- **On denial (iOS).** WWDC20: "Whenever your app is waiting for permission, it will simply look like there are no devices nearby. Local connections that use NWConnection will stay in the waiting state". TN3179 gives the checks: Bonjour waits with `kDNSServiceErr_PolicyDenied` (-65570); an `NWConnection` waits with `unsatisfiedReason == .localNetworkDenied`. Linen can show the right state from these.
- **In the background (iOS).** If the privilege is still undetermined, a background operation is denied "without presenting the local network alert", and the decision is not recorded. A Bonjour operation with peer-to-peer Wi-Fi can trigger the alert even "off Wi-Fi".
- **When to ask.** WWDC20: "Rather than trying to browse the network when your app launches, wait for an action that requires browsing." For Linen, that is the QR scan.
- **The Mac helper.** macOS allows daemons, root and Terminal tools automatically; "The exception for `launchd` daemons doesn't apply to `launchd` agents." For a helper, "macOS considers the app to be the responsible code", which is used to "Show a meaningful app name and usage description in the local network alert" and "Record the user’s choice for the whole app". TN3179 asks only agents "not installed using `SMAppService`" to set `AssociatedBundleIdentifiers`, which implies an `SMAppService` agent is tied to its app. **Unverified:** TN3179 does not name `SMAppService` login items; how the alert reads for `LinenHelper` needs a test on the Mac with the signed app. Also from TN3179: sign with "an Apple-issued code-signing identity" so the privilege tracks the program (the free team's development certificate should qualify; not confirmed in a saved page), and a very short-lived process may never show the alert (FB16131937). `SMAppService.register()` "Registers the service so it can begin launching subject to user approval" (`iphone/apple-smappservice-*`).
- **The measurements say nothing about prompts**: they ran from Terminal, which is allowed automatically.

## 4. iOS background limits (SYNC-5)

| Mechanism | What Apple says | Use in Linen |
|---|---|---|
| Leaving the app | `applicationDidEnterBackground` "has five seconds"; "Shortly after that method returns, the system puts your app into the suspended state" (`iphone/apple-extending-background-execution-*`) | The live link ends a few seconds after Hatim leaves the app |
| `beginBackgroundTask` | "extra time"; the maximum is only readable from `backgroundTimeRemaining`, and "System conditions may end background execution earlier". No number in the saved pages (the commonly quoted 30 s is unverified) | Finish the file in flight and swap it in; never start new work |
| BGAppRefreshTask | "a short task typically used to refresh content", needs `fetch` | Ask the Mac for a fresh manifest; only if the Mac is reachable, which is rare in the background |
| BGProcessingTask | "can run for minutes", "only when the device is idle", terminated "when the user starts using the device" | Not useful for a link that needs the Mac nearby |
| BGContinuedProcessingTask (iOS 26.0) | "starts in the foreground"; submitted "as a result of a person’s action, such as tapping a button"; can "use the network"; shown "in a Live Activity" where a person can cancel it; must report progress, and tasks with "minimal or no progress" are ended first; strategy `.queue` or `.fail` (`iphone/apple-performing-long-running-tasks-*`, `iphone/apple-bgcontinuedprocessingtask*`) | The first sync after pairing (started by the Allow/pair tap) and "Sync now" qualify. Opening the app is not clearly "a person’s action"; do not rely on it for routine syncs |

**What this means for the targets.**
- A changed note on the phone within 2 s with the app open (PRD section 4): the cost is a "changed" message on an open TLS connection plus one small file. The handshake took 10 to 17 ms on loopback; Wi-Fi and AWDL latency were not measured. Reconnecting after the app returns to the front adds Bonjour resolve plus a handshake; measure on the device.
- The first sync of 100 MB in under 60 s: that is 1.7 MB/s, well inside what Wi-Fi should give, but unmeasured here. Run it as a BGContinuedProcessingTask so leaving the app does not cancel it. Whether `BGTaskSchedulerPermittedIdentifiers` must list the task identifier is NL in the saved pages.
- PRD section 11 already says "sync happens while the app is open"; the documents agree.

## 5. PDF export (EXP-5, EXP-7)

### What `createPDF` produces

- **Vector, with embedded font subsets.** Text and SVG stay vector; the only images in the board test were five rasters the size of the five cards' shadows and the 2 x 2 test PNG (`iphone/measured-createpdf-macos-*`, `pdfimages` list).
- **Splits height at 14,400 pt, never width.** A 30,000 x 20,000 board became pages of 30,000 x 14,400 and 30,000 x 5,600; a 60,000 pt tall page became five pages. WebKit's `pdfSnapshotAtSize` loops with `maxPageHeight = 72 * 200` under the comment "PDFs have a per-page height limit of 200 inches at 72dpi" (`iphone/webkit-src-WebPage-cpp-drawMainFrameToPDF-*`). The PDF 1.7 specification lists 14,400 as the maximum viewers "should" support, and `UserUnit` as the way past it (`iphone/adobe-iso32000-1-excerpt-*`); Quartz never wrote `UserUnit`.
- **Quartz goes further.** Pages of 30,000 x 30,000, 200,000 x 800 and 800 x 200,000 pt written by Quartz opened in PDFKit and poppler with their full size (`iphone/measured-pdfkit-large-pages-*`).
- **Links.** An external link survived as a link annotation with its URL; an internal `#far` link became an annotation with no destination (`iphone/measured-createpdf-macos-*`, links case). EXP-5's "links as text" avoids this.
- **The same code on iOS.** `drawToPDF` lives in `WebPageCocoa.mm`, shared by iOS and macOS, and calls the same `drawMainFrameToPDF` (`iphone/webkit-src-WebPageCocoa-mm-drawToPDF-*`). Expect the same splitting on iOS (not run on a device).

**What `uni no` means.** `pdffonts` showed `uni no` (no ToUnicode map) for Helvetica, Georgia and Times subsets in MacRoman encoding. English still came back exactly from both poppler and PDFKit in every file, because MacRoman codes map to known characters. A ToUnicode map matters when glyphs do not map one to one to characters, which is the Arabic case.

### Arabic, measured (`iphone/measured-createpdf-arabic-macos-2026-10-14.txt`)

Six lines were rendered: plain Arabic, lam-alef ligatures, Arabic-Indic digits, diacritics, mixed Arabic and Latin, and English. Each PDF was read three ways: poppler `pdftotext`, PDFKit's `PDFDocument.string`, and PDFKit `findString` (what Preview's search uses). A probe in the page confirmed which font WebKit really used.

| Path and font | Font in the PDF | PDFKit text, 5 Arabic lines | PDFKit search, 4 Arabic words | poppler |
|---|---|---|---|---|
| `createPDF`, Geeza Pro | GeezaPro TrueType subset, ToUnicode yes | 4 exact, logical order; diacritics line gets a space before one damma | 4 of 4 | Wrong: lam-alef as alef + lam ("الوكالء"), bidi marks added |
| `createPDF`, `system-ui` (SF Arabic) | `.SFArabic` subset, ToUnicode yes | Broken: dotless letters plus stray Latin ("ٮ%ڡ7رأ") | 0 of 4 | Broken |
| `createPDF`, Thmanyah Sans or Serif Text, installed or by `@font-face` | thmanyah CFF (Type 1C) subset, ToUnicode yes | Broken: presentation forms (U+FEF3 and similar) and missing letters ("لينن" to "ﻟﻴ"); lam-alef lost | 0 of 4 | Broken |
| Core Text into Quartz, Geeza Pro | GeezaPro | Same as `createPDF` Geeza Pro | 4 of 4 | Same lam-alef fault |
| Core Text into Quartz, Thmanyah Sans | thmanyah CFF | Broken, as above | 0 of 4 | Broken |
| Core Text, Thmanyah, each line tagged with `ActualText` | thmanyah CFF; `/ActualText` and `StructTreeRoot` present | Broken: neither reader used the tag | 0 of 4 | Broken |
| **Thmanyah as glyph outlines + invisible Geeza Pro text** | GeezaPro and Helvetica only; no Thmanyah | 4 exact (same diacritics space) | **4 of 4** | Same lam-alef fault |

English and Latin words ("Linen", "board.canvas") were found in every file. A rendered preview of the outline file (`pdftoppm`) showed every line in Thmanyah, correctly shaped, with the hidden layer invisible.

**Reading it.** The fault sits in the glyph-to-text mapping Quartz writes for these fonts; WebKit adds nothing to it, since Core Text alone gives the same result. Geeza Pro maps cleanly; Thmanyah and SF Arabic do not. The outline route keeps Thmanyah's look and gives Preview correct text. It also answers the open font-license point in `docs/research/competitors.md` (embedding in exported PDFs rated "Likely yes, with subsetting" at medium confidence) by not embedding them at all. Its costs: a native drawing path, a larger file (57 KB against 48 KB for the same six lines drawn with Thmanyah embedded) and selection boxes that only approximate the visible glyphs. Untested: Acrobat, Chrome's viewer, VoiceOver, and the outline route at 500 nodes.

### What iOS offers

- `createPDF(configuration:completionHandler:)`, iOS 14.0 (`iphone/apple-wkwebview-createpdf-*`), and `WebPage.exported(as: .pdf(...))`, iOS 26.0 (`iphone/apple-webpage-exported-*`).
- `UIPrintPageRenderer` (iOS 4.2) with `viewPrintFormatter()`: paginated output with header, content and footer drawing hooks (`iphone/apple-uiprintpagerenderer-*`, `iphone/apple-viewprintformatter-*`); this is the EXP-7 "paginated" route on the phone. Not measured.
- Core Text into a Quartz PDF context and the tagged-PDF calls exist on iOS 13+ (`CGPDFContextBeginTag`, `sdk-greps-security-pdf-*`), so the outline route ports. Not measured on iOS.
- Memory: a 2018 WebKit bug shows iOS once hard-coded an "840MB" jetsam limit for web content processes (`iphone/webkit-bug-188091-*`); today's limit is NL. Large board PDFs on the phone need a device test.

## 6. iOS reader competition (section 3)

App Store data from the US store on 2026-10-14 (`iphone/itunes-lookup-ios-readers-*`, `iphone/itunes-search-ios-*`, `iphone/itunes-desc-ios-*`); Obsidian from its help pages. Legend: **Y** the source says yes, **N** the source says no, **P** partial or with a condition, **NL** not listed.

| App | Price | How files reach the phone | Offline reading | Markdown rendered | Boards or canvas | Mac to phone without a cloud | Rating (count), last update |
|---|---|---|---|---|---|---|---|
| Obsidian | Free; Sync is a paid plan (1 GB Standard, 10 to 100 GB Plus; price NL) | Obsidian Sync, iCloud; Syncthing's "Recommended systems" omit iOS; Google Drive and OneDrive not officially supported on iOS | Y, "stores notes locally ... even offline" | Y (editor) | NL on iOS | P: only through third-party tools | 4.48 (2,769), 2026-10-09 |
| iA Writer | $19.99 | NL in description | NL | Y, "preview in HTML" | NL | NL | 4.56 (1,539), 2026-09-25 |
| 1Writer | $4.99 | iCloud, Dropbox, WebDAV | NL | Y, "full, rich-text preview" | NL | P: WebDAV needs a server | 4.63 (392), 2025-09-24 |
| Textastic | Free; subscription or one-time purchase | SFTP, FTP, WebDAV, Dropbox, iCloud Drive, Working Copy; "WebDAV server for easy file transfer ... over Wi-Fi" | NL | P: syntax highlighting; preview NL | NL | P: manual transfer over Wi-Fi | 4.69 (2,540), 2026-10-09 |
| Runestone | Free | Files app ("standard document browser") | NL | P: syntax highlighting | NL | NL | 4.73 (2,071), 2026-09-10 |
| Documents by Readdle | Free (paid tiers NL) | iCloud, Dropbox, Google Drive; "transfer files to your Mac or PC over Wi-Fi" | NL | NL | NL | P: manual transfer | 4.79 (631,363), 2026-10-12 |
| Freeform | Free; premium features in Apple Creator Studio | iCloud ("all your boards stay in sync") | NL | NL | Y, editor | N: iCloud | 4.55 (445,887), 2026-09-14 |
| Read.md | Free; Pro for Word, PDF, HTML export | Files, AirDrop, share sheet, email | Y, "reading works fully offline" | Y, with Mermaid | NL | N: no sync | 4.96 (92), 2026-10-05 |
| LocalSend | Free, open protocol | Local Wi-Fi or LAN, TLS, "without the cloud" | n/a (file mover) | N | N | Y, by hand, file by file | 4.52 (726), 2026-08-22 |
| Möbius Sync (Syncthing) | Free to 20 MB; one-time purchase for unlimited | Syncthing folders into the app sandbox or other apps | n/a (file mover) | N | N | Y, continuous | 3.81 (140), 2025-01-27 |
| **Linen 2 (planned)** | Personal | Pinned files mirrored by Linen's own link | Y | Y, Loom look, Arabic per block | Y, read-only | Y, automatic while the app is open | n/a |

## 7. Sync protocol shape (SYNC-4)

The smallest thing that meets SYNC-4: one writer (the Mac), one or more readers (phones), whole files, content hashes.

**Borrow from Syncthing BEP** (`iphone/syncthing-bep-v1-*`):
- **Authentication by certificate fingerprint**, after TLS 1.3 (section 1).
- **Index and delta index.** BEP sends a full Index, then Index Updates, and avoids resending by "{index ID, maximum sequence number}". Linen's manifest per pin gets a manifest ID (new when the Mac rebuilds it) and a sequence number per entry; the phone sends back the last ID and sequence it holds, and the Mac sends only newer entries.
- **Content hashes.** BEP hashes blocks of 128 KiB to 16 MiB. SYNC-4 needs one SHA-256 per file; block hashes add value only for resuming very large files, so leave them out at first.
- **Temporary files.** BEP has `from_temporary` and DownloadProgress for partial files. Linen writes into a `.partial` file named by the expected hash, resumes from its length, checks the hash, then swaps it in whole (atomic replace), so a half-written file never shows.

**Borrow from LocalSend** (`iphone/localsend-protocol-readme-*`):
- **Metadata first.** `prepare-upload` offers file metadata, including an optional `sha256`, before any bytes; the receiver accepts all, part or none. Linen's `want` message is the phone's answer to the manifest, and is where SYNC-8's space check happens.
- **Check on arrival.** LocalSend answers 422 "Checksum mismatch (sha256)". Linen discards and refetches.
- **Fingerprint to avoid finding yourself** (SHA-256 of the certificate).

**Leave out:** BEP's version vectors and conflict handling (the phone never writes), block reuse across files, the 500 MB message limit machinery, cluster configuration; LocalSend's multicast discovery on 224.0.0.167 (needs the multicast entitlement on iOS, NL for the free team), its HTTP server and session tokens (mutual TLS replaces them). LocalSend's saved document shows no resume (NL).

**Messages** (as in 9.3's working shape, framed with `NWProtocolFramer` as Apple's sample does): `hello` (protocol version, manifest IDs and sequences held), `manifest` (entries newer than the phone's sequence: path, size, modification time, SHA-256, sequence; removals as tombstones), `want` (hashes, with resume offsets), `chunk` (hash, offset, bytes), `done` (hash), `changed` (pin and new sequence, pushed by the Mac while connected).

## 8. Sealed pages on iOS (IOS-4)

| Piece | iOS | macOS | Source |
|---|---|---|---|
| `WKContentRuleList`, `WKContentRuleListStore` | 11.0 | 10.13 | `iphone/apple-wkcontentrulelist-*`, `-store-*` |
| `WKURLSchemeHandler` (serves the page and its CSP header) | 11.0 | 10.13 | `iphone/apple-wkurlschemehandler-*` |
| `allowsContentJavaScript` | 14.0 | 11.0 | `iphone/apple-allowscontentjavascript-*` |
| `limitsNavigationsToAppBoundDomains` | 14.0 | 11.0 | `iphone/apple-limitsnavigationstoappbounddomains-*` |
| `lockdownModeEnabled` (per page preferences) | 16.0 | 13.0 | SDK header, `iphone/sdk-greps-*` |
| `securityRestrictionMode` | Docs: 26.4. iOS 26.5 SDK header: `ios(26.5)` | Docs: 26.4. macOS 26.5 SDK header: `macos(26.5)` | `iphone/apple-securityrestrictionmode-*`, `iphone/sdk-greps-security-pdf-*` |
| Non-persistent data store | Used in the macOS leak harness; iOS availability NL in saved pages | Measured | `iphone/measured-webview-leaks-*.swift.txt` |
| `createPDF` | 14.0 | 11.0 | `iphone/apple-wkwebview-createpdf-*` |

- `securityRestrictionMode`: the SDK header says the compatibility mode "Disables JIT compilation and enables increased MTE adoption"; the doc page says it applies to main-frame navigations with subframes inheriting, and in Lockdown Mode "attempts to set a less restrictive mode will fail silently". Lockdown Mode can stop "web fonts" from showing (`iphone/apple-lockdown-mode-*`), which would hit the kit fonts of PAGE-3 if Hatim turns it on.
- **The leak measurement, reported as is** (`iphone/measured-webview-leaks-macos-2026-10-14.txt`): with a CSP header, a content rule list and a navigation gate (config D), every TCP probe was stopped, but WebRTC sent STUN packets to the Mac's LAN address (UDP 3481). A CSP `webrtc 'block'` directive did not stop them (config E). Only a document-start user script in all frames that removed `RTCPeerConnection` did (config F: no packets, `RTCPeerConnection=undefined`). The pages spike (`docs/spikes/pages/`) covers the fix.
- TN3179's WKWebView exemption means iOS local network privacy is no second wall for pages.
- Nothing was run on iOS.

## Not verified

- Anything on an iPhone: TLS 1.3 with client certificates over Wi-Fi and AWDL, Bonjour with `includePeerToPeer`, the local network alert wording, BGContinuedProcessingTask with a network transfer, `createPDF` and the outline route on iOS, all timings.
- The cable route (SYNC-6): no saved source.
- How macOS presents the local network alert for an `SMAppService` login item.
- Whether the free team's development certificate counts as "Apple-issued" for local network privacy tracking (very likely, no saved page).
- The exact `beginBackgroundTask` time; `BGTaskSchedulerPermittedIdentifiers` for continued tasks; non-persistent store availability text for iOS.
- Noise IK code size (estimate only).
- How Acrobat, Chrome's PDF viewer and VoiceOver read the Arabic PDFs.

## Glossary

- **AWDL** (Apple Wireless Direct Link): Apple's peer-to-peer Wi-Fi, the radio link AirDrop uses. Network.framework uses it when `includePeerToPeer` is on. Works only between Apple devices.
- **Bonjour**: Apple's way to find services on the local network by name, such as `_linen._tcp`, without typing addresses.
- **PSK** (pre-shared key): a secret both sides already hold before connecting. Here, it would come from the QR code.
- **ECDHE**: a fresh key agreement for each connection. If a long-term secret leaks later, past traffic stays safe; this is **forward secrecy**.
- **ECDHE-PSK**: a TLS 1.2 suite where the PSK authenticates a fresh ECDHE exchange.
- **Pinning**: accepting only a peer whose certificate has a hash you stored earlier, instead of trusting a certificate authority.
- **SecIdentity**: Apple's object for a certificate plus its private key, which TLS needs to present a certificate.
- **Noise IK**: a handshake pattern from the Noise framework where the initiator already knows the responder's public key and sends its own, encrypted, in the first message.
- **KCI** (key-compromise impersonation): an attacker who steals your key can pretend others are talking to you.
- **BEP** (Block Exchange Protocol): Syncthing's sync protocol.
- **Sequence number, delta index**: a counter on each change, so a peer can ask only for what changed since the last number it saw.
- **ToUnicode map**: a table inside a PDF that tells readers which characters each drawn glyph stands for. Without a correct one, copy and search return wrong text.
- **Presentation forms**: old Unicode code points for the initial, medial and final shapes of Arabic letters. Search for normal Arabic does not match them.
- **Lam-alef**: the ligature that joins lam and alef (لا) into one glyph; one glyph stands for two characters.
- **ActualText**: a PDF tag that says what text a group of glyphs stands for. Quartz wrote it; neither PDFKit nor poppler used it.
- **CFF / Type 1C**: the compact outline format of OpenType fonts like Thmanyah, as embedded in a PDF.
- **Local Network privilege**: the iOS and macOS permission an app needs before it finds or connects to devices on the local network.
- **BGContinuedProcessingTask**: an iOS 26 background task that a person starts by a tap, which keeps running with a Live Activity after they leave the app.
- **JIT, MTE**: just-in-time compilation of JavaScript (fast, a common attack surface) and Memory Tagging Extension (a hardware check on memory use).

## Sources (all read or run 2026-10-14; paths under `docs/research/raw/`)

1. `iphone/measured-tls13-pinned-loopback-macos-2026-10-14.{swift.txt,txt}`: TLS 1.3 pinned-certificate loopback test (this lane).
2. `iphone/measured-tls-psk-loopback-macos-2026-10-14.{swift.txt,txt}`: TLS PSK loopback test.
3. `iphone/measured-createpdf-arabic-macos-2026-10-14.{swift.txt,txt}`: Arabic PDF test (this lane). The PDFs stay in the session scratchpad because they hold Thmanyah subsets.
4. `iphone/measured-createpdf-macos-2026-10-14.{swift.txt,txt}`, `measured-createpdf-links-*`, `measured-createpdf-annots-*`: `createPDF` sizes, fonts, images, links.
5. `iphone/measured-pdfkit-large-pages-macos-2026-10-14.{swift.txt,txt}`: Quartz pages past 14,400 pt.
6. `iphone/measured-webview-leaks-macos-2026-10-14.{swift.txt,txt}`, `measured-webview-leaks-server-*.py.txt`: sealed-page leak test.
7. `iphone/apple-supported-capabilities-{ios,macos}-*` (and `-table-*`): developer.apple.com/help/account/reference/supported-capabilities-ios and -macos.
8. `iphone/apple-tn3179-local-network-privacy-*`: TN3179, Understanding local network privacy.
9. `iphone/wwdc2020-10110-local-network-*`: WWDC20 session 10110, Support local network privacy in your app.
10. `iphone/apple-tn3151-networking-api-*`: TN3151, Choosing the right networking API.
11. `iphone/apple-nsbonjourservices-*`, `apple-nslocalnetworkusagedescription-*`, `apple-includepeertopeer-*`.
12. `iphone/apple-p2p-sample-*` and `apple-p2p-sample-NWParameters+InitWithPasscode-*.swift.txt`: Apple sample "Building a custom peer-to-peer protocol".
13. `iphone/apple-nwprotocoltls-options-*`, `apple-sec-add-psk-*`, `apple-secidentitycreate-*`: Network and Security reference.
14. `iphone/sdk-greps-2026-10-14.txt`, `iphone/sdk-greps-security-pdf-2026-10-14.txt`: iOS 26.5 and macOS 26.5 SDK header excerpts.
15. `iphone/apple-wifiaware-*`, `apple-wifiaware-entitlement-*`: Wi-Fi Aware framework and entitlement.
16. `iphone/apple-app-groups-entitlement-*`, `apple-keychain-access-groups-*`, `apple-associated-domains-entitlement-*`.
17. `iphone/apple-extending-background-execution-*`, `apple-begin-background-task-*`, `apple-backgroundtimeremaining-*`: UIKit background time.
18. `iphone/apple-bgapprefreshtask-*`, `apple-bgprocessingtask-*`, `apple-bgcontinuedprocessingtask-*`, `apple-bgcontinuedprocessingtaskrequest-*`, `apple-performing-long-running-tasks-*`: BackgroundTasks.
19. `iphone/apple-smappservice-*`: ServiceManagement `SMAppService`.
20. `iphone/apple-wkwebview-createpdf-*`, `apple-wkpdfconfiguration-*`, `apple-webpage-exported-*`, `apple-uiprintpagerenderer-*`, `apple-viewprintformatter-*`, `apple-pagezoom-*`.
21. `iphone/webkit-src-WebPage-cpp-drawMainFrameToPDF-*`, `webkit-src-WebPageCocoa-mm-drawToPDF-*`, `webkit-src-ImageBufferCGPDFDocumentBackend-cpp-*`: WebKit source, main branch.
22. `iphone/webkit-bug-171944-*`, `webkit-bug-188091-*`: bugs.webkit.org.
23. `iphone/adobe-iso32000-1-excerpt-*`: ISO 32000-1 (PDF 1.7), Table 30 and Annex C.
24. `iphone/apple-wkcontentrulelist-*`, `apple-wkcontentruleliststore-*`, `apple-creating-a-content-blocker-*`, `apple-wkurlschemehandler-*`, `apple-allowscontentjavascript-*`, `apple-limitsnavigationstoappbounddomains-*`, `apple-securityrestrictionmode-*`, `apple-lockdown-mode-*`.
25. `iphone/ietf-rfc8446-tls13-*`: RFC 8446, TLS 1.3.
26. `iphone/ietf-rfc5489-ecdhe-psk-*`: RFC 5489, ECDHE_PSK cipher suites.
27. `iphone/noise-spec-*` (html and flattened txt): The Noise Protocol Framework, revision 34.
28. `iphone/syncthing-bep-v1-*`: docs.syncthing.net, Block Exchange Protocol v1.
29. `iphone/localsend-protocol-readme-*`: github.com/localsend/protocol README.
30. `iphone/itunes-lookup-ios-readers-*`, `itunes-search-ios-*`, `itunes-desc-ios-*`: itunes.apple.com search and lookup, US store.
31. `iphone/obsidian-help-sync-your-notes-*`, `obsidian-help-plans-storage-*`: Obsidian help, GitHub raw.
32. `docs/PRD-2.md` section 11 for the free team's install limits.
