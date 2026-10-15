# Claude on the iPhone and Linen

Research for Linen 2, read 2026-10-15. Question (Hatim, 2026-10-15): can the Claude app on his iPhone see Linen on the iPhone and use it? Raw captures are in `docs/research/raw/mcp-mobile/` (kept out of the repository); every quote below was found in those files. Sources are numbered at the end.

## Two-minute read

| Question | Answer |
|---|---|
| Can the Claude iPhone app reach Linen on the iPhone directly? | **No.** Claude's connectors run from Anthropic's cloud and need a server on the public internet [1]; nothing documents an MCP server on the phone or Claude calling another app's App Intents. Claude's iOS integration covers system apps and "compatible third-party apps" for messaging and mail [3]. |
| Is there a way for Claude on the phone to use Linen today? | **Yes, through the Mac.** Remote Control connects the Claude iPhone app to a Claude Code session running on the Mac, and that session keeps its local MCP servers [6]. With Linen's Mac MCP configured in Claude Code, Claude on the phone can read, check and open the same notes and boards the phone mirrors. No inbound port, no public server [6]. |
| What does it need? | The Mac awake with `claude remote-control` running in a trusted folder, a Pro, Max, Team or Enterprise plan (API keys are not supported; on Team and Enterprise an Owner turns it on) [6]. Turning on Trusted Devices ties steering to a verified phone [6]. |
| Can a single file go from Linen iPhone to Claude? | **Probably, not proven.** The App Store listing says "Upload any photo, PDF, or screenshot" [9]; Claude reads TXT, HTML, JSON and PDF [8]. Whether Claude shows in the iOS share sheet for files, and whether it takes `.md` and `.canvas` by those names, is not documented: test on the phone. |
| Could Claude on the phone reach the Mac without Remote Control? | Yes, as a custom connector: the Mac serves Linen's MCP over HTTPS through a tunnel, with OAuth, added once on the web or desktop; it then shows on mobile [2][4], and MCP Apps render on iOS in a `WKWebView` [5]. It puts Hatim's files on the internet behind a sign-in Linen would have to build. Later. |
| Will Apple make this direct? | Unknown. iOS 26.1 beta code pointed at MCP support in App Intents (2025-09-22) [10]; no source found that it shipped. Linen's App Intents would be the way in if it does. |
| Recommendation | 2.x: document and test "Claude on the phone through Remote Control" (no Linen code beyond the Mac MCP). 2.1 as planned: the phone shares the original file (IOS-7). 2.x: App Intents for Shortcuts. Later: a remote connector, only after a security review. |

## 1. What the Claude iPhone app connects to

**Custom connectors (remote MCP).** The help center says connectors reach a server from Anthropic, not from the device: "When you add a custom connector, Claude connects to your remote MCP server from Anthropic's cloud infrastructure, rather than from your local device. This is true across every Claude client, including claude.ai, Claude Desktop, Cowork, and the mobile apps." and "This means your MCP server must be reachable over the public internet from Anthropic's IP ranges." [1]. Local servers are a Claude Desktop feature: "Local MCP servers configured in Claude Desktop via claude_desktop_config.json are a separate mechanism and do use your local network, but those aren't available in Cowork or claude.ai." [1].

**Adding a connector on the phone.** "Installing connectors on mobile is currently in beta" and desktop and web "remain the primary path for custom connectors" [2]. "Once you connect to a service on Claude or Claude Desktop, it will be available to use the next time you log in to your account on Claude for iOS or Android." [2]. Custom connectors are on "Free, Pro, Max, Team, and Enterprise plans. Free users are limited to one custom connector." [1].

**Transport and sign-in.** Claude's builder docs: "Use Streamable HTTP" and Claude "also supports the legacy HTTP+SSE transport" [4]. Authentication is OAuth 2.0, a static header (beta, "available to a limited set of organizations", entered by an organization Owner), or none [4][4a]. The hosted apps, mobile included, share one OAuth client with the redirect `https://claude.ai/api/mcp/auth_callback` [4][4a]. For a personal plan this leaves OAuth or no sign-in. Limits on the hosted surfaces: about 150,000 characters per tool result and 240 seconds per call [4].

**Testing a local server.** "Claude reaches your server from Anthropic's infrastructure, so a server running on your machine needs a public URL. Expose it with a tunnel such as Cloudflare Tunnel or ngrok" and "Keep authentication enabled on your server while tunneling" [7].

**MCP Apps on the phone.** "On mobile, Claude renders apps in a native WebView, WKWebView on iOS" and "users must add a connector on web or desktop before it appears on mobile" [5]. A Linen board could appear inside a Claude conversation this way, through a remote connector only.

**Shortcuts, Siri, share sheet.** The Ask Claude intent works from "Spotlight search", "Siri", "The Share menu" and "Any app that supports iOS intents"; the documented share example is text: "Select text and use the Share menu to send it directly to Claude" [3a]. Shortcuts can chain "Ask Claude" with other actions, for example "Add the "Share" action and select your preferred input type" then "Add the "Ask Claude" action" [3a]. iOS 18 or later [3a].

**Claude acting in other apps.** "Claude can now connect with your iOS device's system apps" and it "works with iOS system apps (Messages, Mail, Calendar, Maps, Reminders, and Location Services), as well as compatible third-party apps"; the third-party examples given are messaging and mail apps (WhatsApp, Slack, Messenger, Gmail, Outlook) [3]. Nothing there says Claude can call an arbitrary app's App Intents.

**Files.** Claude reads "PDF", "TXT", "HTML", "JSON" among other types, up to 500 MB per file and 20 files per chat [8]. The upload steps described are the "+" button and "Add files or photos" [8]; nothing iOS-specific is documented. The App Store listing (version 1.261012.20, 2026-10-13) says "Upload any photo, PDF, or screenshot for instant analysis." [9].

**Remote Control (Claude Code).** "Remote Control connects claude.ai/code or the Claude app for iOS and Android to a Claude Code session running on your machine." "your filesystem, MCP servers, tools, and project configuration all stay available" [6]. "Your local Claude Code session makes outbound HTTPS requests only and never opens inbound ports on your machine." [6]. "your computer has to stay on and the claude process has to keep running" [6]. "available on Pro, Max, Team, and Enterprise plans. API keys are not supported." [6]. While connected, "the session transcript, including your messages, Claude's responses, and tool activity, is stored on Anthropic servers" [6]. Trusted Devices requires a verified device "before they can view or steer Remote Control sessions from claude.ai, the Claude mobile apps, or Claude Desktop" [6].

**Dispatch (Claude Desktop).** It runs phone tasks on the desktop with "your local files, connectors, plugins, and apps", but "Dispatch isn't available to new users" [11]. Not a route to build on.

## 2. What Linen on the iPhone can expose (free Apple team)

| Mechanism | Free team | Reaches Claude? |
|---|---|---|
| Share sheet (share the original file, IOS-7 at 2.1) | Yes, no capability (system share sheet) | If Claude accepts the file type from the share sheet; PDF likely [9], `.md` and `.canvas` untested |
| Files app ("On My iPhone > Linen"): `UIFileSharingEnabled` with a `Documents` folder, `LSSupportsOpeningDocumentsInPlace` [12][13] | Yes, Info.plist keys only | Claude's file picker could pick from it if it uses the system picker (not documented). The mirror itself must not be exposed: files there can be changed or deleted by hand, which breaks mirror by generation (SYNC-4). Expose copies in a separate folder, if at all |
| App Intents and an App Shortcuts provider [14] | Likely yes: the Siri entitlement, which the free team lacks, is required for "Intents app extensions that handle any Siri requests other than shortcut requests" [15][16], and App Intents do not use those extensions. Confirm on the device | Through Shortcuts: a Linen intent returns a note's text or a board as a list, then "Ask Claude" takes it as text [3a] |
| File Provider extension | "FileProvider Testing Mode" is not on the free team [16]; not needed for the routes above | No |
| iCloud Drive | Not on the free team [16] | No |

The free team's 7-day installs (PRD-2 section 11) apply to all of these: a lapsed Linen install removes its intents and its Files folder until reinstalled.

## 3. Routes for "Claude on the phone uses Linen"

| Route | Works today? | Needs | Risks | Effort |
|---|---|---|---|---|
| (a) The Linen iPhone app talks to the Claude app on the phone | **No** | A local MCP or App Intents client in Claude's iOS app; none documented [1][3] | n/a | n/a |
| (e) **Remote Control to the Mac's Linen MCP** | **Yes** (by the docs; not yet run with Linen) | Linen's Mac MCP in Claude Code's config; `claude remote-control` running in a trusted folder; Mac awake; a paid plan [6] | Transcripts and tool output stored on Anthropic's servers [6]; agent-written notes and pages can carry instructions that reach Claude as tool output (prompt injection); keep Linen's MCP read-mostly and mark content as data | None beyond the Mac MCP: a FORMAT.md section and one device test |
| (c) Share sheet hand-off | Probably, for PDF [9] | Linen 2.1 share (IOS-7); PDF on the phone is 2.x (IOS-7); check `.md` and `.canvas` | The file leaves the phone for Anthropic's servers, as any upload | Small, already planned |
| (d) Claude picks from the Files app | Unconfirmed | A shared copy folder in Linen iPhone [12][13] | Same as (c); must not expose the mirror | Small |
| Shortcuts glue (Linen intent, then Ask Claude) | Unconfirmed on the free team | Linen App Intents ("Find a Linen file", "Get its text or list"); iOS 18 [3a] | Same as (c) | Small to medium, 2.x |
| (b) Remote connector: the Mac's helper serves Linen's MCP over HTTPS through a tunnel | Yes in principle [1][2][4][7] | A public HTTPS address from a tunnel, an OAuth 2.0 server inside Linen (discovery metadata, dynamic registration or Claude's published identity, the fixed redirect, token refresh) [4][4a], an allowlist of what is served | Hatim's files reachable from the internet behind a sign-in Linen writes itself; Mac awake only; every request brokered by Anthropic's cloud [1]; prompt injection as above | Large; Later, after a security review |
| Apple system MCP through App Intents | **Unknown** | Apple shipping what the 2025-09 betas pointed at [10] | n/a | Linen's App Intents would be the base |

## Recommendation for the PRD

- **2.x, "Claude on the phone" (new row):** Claude on the iPhone uses Linen through Remote Control to a Claude Code session on the Mac that has Linen's MCP. Linen ships no extra code for it; FORMAT.md gets a section on setting it up, with Trusted Devices on. Exit test: from the Claude iPhone app, ask for a pinned board's broken boxes and get them from Linen's MCP, with the Mac awake.
- **2.1 as planned:** IOS-7's share of the original file; add a check that Claude accepts a note, a board and a page from the share sheet.
- **2.x:** App Intents and App Shortcuts on Linen iPhone (find a file, get a note's text, get a board as a list) for Shortcuts chains with Ask Claude.
- **Later:** a remote connector served by the Mac's helper through a tunnel, with OAuth and a read-only tool set, only after a security review. Never on by default.
- **First safe step (after the Mac MCP exists):** configure it in Claude Code, run `claude remote-control` in the vault folder, turn on Require trusted devices, and ask from the iPhone. Nothing is exposed to the internet and nothing new runs on the phone.

## Not verified

- Whether the Claude iOS app appears in the share sheet for files (PDF, `.md`, `.canvas`, `.html`) and whether its file picker shows "On My iPhone" folders of other apps.
- Whether App Intents run on the free team without any capability (inferred from the Siri entitlement's wording [15]).
- Whether Apple shipped MCP support in App Intents after the iOS 26.1 betas; the two WWDC26 App Intents session pages as fetched [17] do not contain "MCP" or "Model Context Protocol", but their transcripts may not be in the fetched HTML.
- Which plan Hatim's Claude account is on, and on a Team or Enterprise account whether the Owner allows Remote Control [6].

## Sources (read 2026-10-15; files under `docs/research/raw/mcp-mobile/`)

1. Claude Help Center, "Get started with custom connectors using remote MCP", https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp (`support-11175166-custom-connectors-2026-10-15.txt`).
2. Claude Help Center, "Use connectors to extend Claude's capabilities", https://support.claude.com/en/articles/11176164-pre-built-web-connectors-using-remote-mcp (`support-11176164-prebuilt-connectors-2026-10-15.txt`).
3. Claude Help Center, "Use Claude with iOS apps" (dated 2026-08-25), https://support.claude.com/en/articles/11869619-using-claude-with-ios-apps (`support-11869619-ios-apps-2026-10-15.txt`).
3a. Claude Help Center, "Use Claude app intents, shortcuts, and widgets on iOS" (dated 2026-07-09), https://support.claude.com/en/articles/10263469-use-claude-app-intents-shortcuts-and-widgets-on-ios (`support-10263469-ios-intents-2026-10-15.txt`).
4. Claude Docs, "Build an MCP server for Claude", https://claude.com/docs/connectors/building.md (`docs-connectors-building-2026-10-15.md`).
4a. Claude Docs, "Authentication for connectors", https://claude.com/docs/connectors/building/authentication.md (`docs-connectors-authentication-2026-10-15.md`).
5. Claude Docs, "MCP Apps design guidelines", https://claude.com/docs/connectors/building/mcp-apps/design-guidelines.md (`docs-mcp-apps-design-guidelines-2026-10-15.md`).
6. Claude Code Docs, "Continue local sessions from any device with Remote Control", https://code.claude.com/docs/en/remote-control.md (`code-docs-remote-control-2026-10-15.md`).
7. Claude Docs, "Test your connector", https://claude.com/docs/connectors/building/testing.md (`docs-connectors-testing-2026-10-15.md`).
8. Claude Help Center, "Upload files to Claude" (dated 2026-07-23), https://support.claude.com/en/articles/8241126-upload-files-to-claude (`support-8241126-uploading-files-2026-10-15.txt`).
9. App Store lookup for "Claude by Anthropic", id 6473753684, https://itunes.apple.com/lookup?id=6473753684&country=us (`itunes-lookup-claude-2026-10-15.json`).
10. 9to5Mac, "Apple working on MCP support to enable agentic AI on Mac, iPhone, and iPad", 2025-09-22, https://9to5mac.com/2025/09/22/macos-tahoe-26-1-beta-1-mcp-integration/ (`9to5mac-macos-26-1-mcp-2025-09-22-read-2026-10-15.txt`).
11. Claude Help Center, "Assign tasks from anywhere in Claude Cowork", https://support.claude.com/en/articles/13947068 (`support-13947068-dispatch-pair-2026-10-15.txt`).
12. Apple, `UIFileSharingEnabled`, https://developer.apple.com/documentation/bundleresources/information-property-list/uifilesharingenabled (`apple-uifilesharingenabled-2026-10-15.json`).
13. Apple, `LSSupportsOpeningDocumentsInPlace`, https://developer.apple.com/documentation/bundleresources/information-property-list/lssupportsopeningdocumentsinplace (`apple-lssupportsopeningdocumentsinplace-2026-10-15.json`).
14. Apple, `AppShortcutsProvider`, https://developer.apple.com/documentation/appintents/appshortcutsprovider (`apple-appshortcutsprovider-2026-10-15.json`).
15. Apple, Siri entitlement `com.apple.developer.siri`, https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.siri (`apple-siri-capability-2026-10-15.json`).
16. Apple, "Supported capabilities (iOS)", read 2026-10-14 for `iphone-sync.md` (`../iphone/apple-supported-capabilities-ios-table-2026-10-14.txt`).
17. Apple, WWDC26 sessions 345 and 343 pages, https://developer.apple.com/videos/play/wwdc2026/345/ and /343/ (`apple-wwdc26-345-app-intents-2026-10-15.html`, `apple-wwdc26-343-app-intents-siri-2026-10-15.html`).
