# Linen: product requirements

| | |
|---|---|
| Product | Linen, a native macOS reader for Markdown and plain text, with a Quick Look extension |
| Owner | Hatim Alshehri |
| Status | **v1.0, approved 2026-10-11** after five review rounds (Codex five times, two fresh-eyes reviewers, Claude; Codex round 5: "Approved to build"). Changes from here on are logged in Appendix A and the build log |
| Name | **Linen** (Hatim, 2026-10-11, from Weft, Linen, Twill and Leaf): the cloth a loom weaves, and the paper fine documents are printed on. Its Arabic name is سطر ("line"), Satr's old name, shown when the interface is in Arabic. |
| Suite | Part of Hatim's **Loom product suite**, alongside Ferry (his words, 2026-10-11: "i want to make satr under loom suites product, like ferry") |
| Design source | Loom's UI contract (`~/Desktop/Loom/loom-site/docs/DESIGN.md`), applied to native macOS exactly as Ferry applies it (`~/Desktop/ferry/docs/PRD.md` section 8) |
| Starting point | Satr 1.2.1 (`c471e47`, public at `github.com/taurusn/satr`), installed at `/Applications/Satr.app` |
| Method | `~/vault/wiki/concepts/Product build method.md` |
| Evidence | `docs/research/competitors.md` (sources saved in `docs/research/raw/`, read 2026-10-11), `docs/spikes/` (corpus, Quick Look, file watching, highlighter, print, fonts) |

## 0. Two-minute read

| Question | Answer |
|---|---|
| What is it | The Mac's reader for Markdown. Open a note, a PRD or a README and read it as a typeset page: tables, code, diagrams, Arabic and English, links between notes. It reads; it never edits. |
| Why rebuild | Satr 1.2.1 renders every note but reads poorly: the page jumps to the top on every save, there is no find, math, code highlighting, callouts, footnotes or print, 5,292 of the vault's 5,400 wiki links show as raw paths ("wiki/projects/Ferry"), English lines that start with an Arabic word flip right to left, the heading thread piles into circles on long documents, saves show up a second late, any document can read any file on the disk, and remote images load silently. |
| Who first | Hatim, reading his Obsidian vault (495 notes, 143 with Arabic), his project docs (PRDs, reviews, plans) and agent output while agents rewrite it, on his MacBook Air (macOS 26.5). |
| What it beats | Marked 3, the reference reader, now a subscription ($2.99 a month or $69.99 to unlock, as of 2026-10-11) whose wiki links only look in the current folder; Read.md, whose top complaint is no typographic control; Obsidian's reading view on speed and calm. Section 3. |
| Look | Loom's: paper and deep green, Thmanyah type, the woven mark, one column, calm chrome; Night from the same tokens. One of Hatim's Loom suite apps, next to Ferry. |
| How it is proven | The real app on real files: structural checks on every vault note (direction, links, no raw syntax left), every wiki link compared with Obsidian's own resolution, agent rewrites while reading, measured times over repeated runs, screenshots of every screen in Paper and Night, English and Arabic. |

## 1. Summary

Linen is a calm, fast, native reader for the Markdown Hatim lives in. It opens any `.md` or `.txt` file as a page set in Thmanyah type on Loom's paper, holds its place while the file is rewritten underneath it and shows what changed, finds text, follows wiki links the way Obsidian does and names them like Obsidian does, shows where a note is linked from, renders Mermaid, math and code offline, prints a clean PDF, hands an exact reference to an agent, and previews Markdown in Finder's Quick Look with the same renderer. It loads nothing from the network unless asked, runs no script from documents, and a document can only reach files inside its own vault.

**What Linen does not promise.** It does not edit (one key opens the file in an editor at the line being read). It does not sync, publish or run plugins. It does not render Obsidian plugin syntax (Dataview, Templater), Canvas or Excalidraw, MDX components, or document-authored CSS.

## 2. Who it is for and the jobs

1. **The vault reader.** Hatim opens a vault note from Finder, Spotlight or a link, reads it, follows two links, comes back. Notes are Arabic and English, with frontmatter, a "For future Claude" preamble, and wiki links written as vault paths.
2. **The reviewer.** Claude or Codex writes a PRD, a review or a plan into a repo; Hatim reads it in Linen while the agent keeps rewriting it (the agents' Write and Edit tools replace the file on every save, spike S(b)). The page must not jump, he must see what changed since he last looked, and he must be able to point the agent at an exact passage.
3. **The presenter.** He shows a document to someone on the TV or in a meeting: large type, a clean page, steps through it.
4. **The skimmer.** In Finder, space bar on a `.md` file shows it typeset, including in the narrow preview pane.
5. **The keeper.** He prints or saves a PDF of a note or a PRD to send to someone, and it looks like Loom's paper.

## 3. Competition

Facts from the pages saved in `docs/research/raw/` on 2026-10-11 (see `docs/research/competitors.md` for every quote). "Not listed" means the saved pages do not mention it.

| | Marked 3 | Obsidian | Read.md | Typora | QLMarkdown | Satr 1.2.1 | **Linen at launch** |
|---|---|---|---|---|---|---|---|
| Price | $2.99/mo, $29.99/yr, $69.99 unlock (intro) | Free | Free, Pro $24.99 | $14.99 | Free | Free | Hatim's own; release terms later |
| Engine | Native, HTML preview | Electron | Native | Web editor | Quick Look extension | AppKit + WKWebView | AppKit + WKWebView |
| Keeps place on reload | Yes, scrolls to the edit | Not listed | Remembers on reopen | Not listed | n/a | **No, jumps to top** | Holds the line being read; marks changes since last seen; Next Change |
| Wiki links | Same folder only, backlinks | Native | Not listed | Not listed | Renders links | Walks up folders | Obsidian's rules across the vault, note names shown, Linked from |
| Arabic and English | Per element RTL detection | One global RTL switch | Not listed | "Experimental", global | Not listed | Per block, by first letter | Per block by letter majority, one direction per list, Thmanyah Arabic |
| Math, code, callouts, footnotes | All four | All four | Code | All four | Most | None | All four, offline |
| Find | Yes, regex | Yes | Yes | Yes | n/a | No | Yes, Arabic-aware |
| Export | PDF, HTML, DOCX, EPUB, RTF | PDF | PDF, HTML, DOCX (Pro) | PDF, HTML, Word | n/a | None | Print and PDF (launch), HTML later |
| Quick Look | Separate $9.99 app | Yes | Not listed | No | Yes | No | Included, same renderer |
| Typographic identity | 9 themes + CSS | Themes + CSS | Light/dark; "configurable font ... is completely missing" | Themes + CSS | CSS | One palette | Loom: Thmanyah, paper and ink, Paper and Night |

What this says:
- Marked 3 is the bar for reading features, and its move to a subscription leaves room for a free, native, vault-aware reader.
- Holding the place on reload is expected in this category (Marked, Peek); Satr's jump to the top is its worst daily bug.
- Per-block Arabic is the identity feature: only Marked documents per-element RTL, and 143 of the vault's 495 notes (28.9 percent) contain Arabic.
- Quick Look is cheap and crowded; Linen's should come free with the renderer and not drive the roadmap.

## 4. Goals, non-goals and measures

**Goals**
- Reading a note in Linen is calmer and faster than in Obsidian, and as good as Marked 3 on the reading features Hatim uses.
- Every note in Hatim's vault reads correctly in both languages, measured structurally, not only "without errors".
- An agent can rewrite a document while Hatim reads it; his place holds and he sees what changed.

**Non-goals**
- Editing, syncing, publishing, plugins, a theme store, iOS, document CSS.

**Measures.** MacBook Air M4, release build, 20 runs each, p50 and p95 reported, timed with signposts. "First readable" means the first screen of text painted in the final fonts, with no later font swap or layout shift over 4 px.

| Measure | Target |
|---|---|
| Launch with ten restored tabs to first readable front tab, after a restart (5 runs) | each under 700 ms; background tabs build on first selection |
| Open a 20 KB note to first readable | p95 under 250 ms |
| Open the frozen 730 KB copy of `log.md` to first readable | p95 under 600 ms; fully rendered under 2.5 s; in a scripted scroll no frame over 33 ms |
| Reload after an outside save of a 60 KB PRD, last write to repainted | p95 under 150 ms; the line being read within 4 px of where it was when that line survives (deletion rule in LIVE-4) |
| Follow a link, and Back | p95 under 150 ms each |
| Find, per keystroke, in the PRD | p95 under 50 ms |
| Vault structural run (all 495 notes) | zero failures of the checks in section 13 |
| Memory with the PRD open, app and WebContent process together | under 180 MB; with ten tabs open under 600 MB (idle background tabs unload after 10 minutes, keeping their place) |
| Quick Look preview of a 60 KB note | warm p95 under 500 ms; first preview after login under 1.5 s, with paper painted at once |

## 5. Principles

1. **The page is the product.** Type, measure and rhythm come before features. Chrome stays out of the way.
2. **Never lose the reader's place.** Reloads, zoom, resizes, renames and back and forward keep the line being read.
3. **Offline and closed by default.** No network, no document scripts, no document CSS, no file outside the vault, unless the reader opens the door for that file.
4. **Native where macOS is good.** Tabs, windows, menus, title, find keys, Quick Look, Services and printing follow macOS; the page follows Loom.
5. **Arabic is first class.** Direction by what a block is actually written in, Arabic type that matches the Latin, an Arabic interface.
6. **Honest states.** A diagram that fails says so in place, with its source; a blocked image says why and offers one click.

## 6. Features

Tiers: **L** at launch of Linen 1.0, **1** in 1.x, **Later**.

### 6.1 Opening and documents

| ID | Requirement | Tier |
|---|---|---|
| OPEN-1 | Opens `.md`, `.markdown`, `.mdown`, `.mkd` and `.txt` from Finder, Open With, drag onto the Dock icon or a window, the Open panel, and links. Linen registers as a viewer for these types; it never reclaims a default by itself. "Make Linen the Default Reader for Markdown" in the app menu sets it once on request; plain text stays an alternate viewer unless Hatim chooses it there too. | L |
| OPEN-2 | **Restores the last session:** windows, tabs, and each tab's place and text size; the front tab builds first and background tabs on first selection. Files are tracked by bookmark data, so a note renamed or moved by Obsidian reopens at its new path; a file that is truly gone shows "This file is no longer here" with Reveal Folder and Close. Files Linen may not read (privacy prompts for Desktop, Documents, Downloads, iCloud Drive and network volumes) show "Linen needs permission to read this folder" with Open System Settings. | L |
| OPEN-3 | **Every file remembers its place** (the block being read and a text quote at the reading line, not a pixel offset) and its text size, for the last 500 files, whether or not its tab was restored. A file that has grown since it was last read to its end opens at its first added block. | L |
| OPEN-4 | **Open Recent** in the File menu and on the welcome page, the last 12 files, each with its folder. | L |
| OPEN-5 | **Open Quickly** (⇧⌘O, as in Xcode): fuzzy search over note names and aliases in the current vault, then recent files; ↩ opens in the current tab, ⌘↩ in a new tab. | L |
| OPEN-6 | **Text encodings,** decided on first open: strict UTF-8 (with or without BOM) and UTF-16 with BOM; otherwise Windows-1256 when at least 3 bytes fall in its Arabic letter ranges and they outnumber Latin-1 accented bytes, else Windows-1252; shown in the footer, with View > Text Encoding to override per file. On reload a file keeps its encoding, and a read that fails UTF-8 counts as an unstable read and is retried. Malformed bytes show as replacement characters, never a failure page. | L |
| OPEN-8 | **Files off the happy path:** an iCloud file that is not downloaded is not read in the background (no surprise downloads); opening it downloads it with the mark drawing itself, and links to such notes say "Not downloaded". Network volumes are polled every 2 s for changes, since they send no events for remote writes. Unreadable and disconnected files each show their own state. | L |
| OPEN-7 | `linen` command line tool (`linen file.md`, `linen -` reads standard input), installed from the app menu; a `linen://open?path=` URL and an "Open in Linen" Service. | 1 |

### 6.2 Rendering

The dialect is pinned: CommonMark with GitHub's tables, task lists, strikethrough, autolinks, footnotes and alerts, plus Obsidian wiki links, embeds of images, callouts, highlights, comments and tags, as implemented by pinned versions of marked and its extensions. Every construct has golden DOM fixtures; a library upgrade must keep them identical or update them on purpose.

| ID | Requirement | Tier |
|---|---|---|
| REN-1 | The base dialect above: headings, emphasis, lists, read-only task lists, tables with column alignment, blockquotes, fenced and indented code, autolinks, strikethrough, footnotes, heading anchors. | L |
| REN-2 | **Callouts:** Obsidian `> [!type]` with title and fold (`+`/`-`) and GitHub alerts (`[!NOTE]`, `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]`, `[!CAUTION]`). All drawn in ink: a rule on the leading side, the label as an eyebrow (Sans 500, 11, uppercase, tracked; no tracking in Arabic), a tint-1 wash for important and warning kinds. Rust is never used for a callout; it means a failure. | L |
| REN-3 | **Code highlighting** offline with highlight.js (spike S(c)) for the 38 languages of its common set plus Dart and Dockerfile, **monochrome by design**: keywords and built-ins at weight 600, comments italic, strings and everything else regular, all in ink-2 (ink and ink-2 differ by only 1.3:1, so colour would not separate them); Night the same in paper. A language label and a Copy button show on hover. Blocks over 2,000 lines are shown plain. | L |
| REN-4 | **Mermaid** offline, themed from the tokens with Thmanyah Sans, rendered as a diagram nears the screen, its height reserved from a cache by source hash (or estimated from its line count) before first render, and kept across reloads when its source did not change. A failed diagram shows its error and source in place. Limits: 50 diagrams per document, 20 KB of source each. | L |
| REN-5 | **Math** with KaTeX, offline: `$…$` only when no space follows the opening `$`, none precedes the closing one, and no digit follows it (so "$5 and $10" stays text), `$$…$$` and ```` ```math ````; `trust: false`, `maxExpand` 1000, `maxSize` 10 em. Failed math shows its source in place. Fixtures include the 31 vault lines that carry two dollar amounts. | L |
| REN-6 | **The note header:** a Loom eyebrow line with `type`, `status` and one date (`updated`, else `date`), then the title: the first h1, or the file name when there is none, as Obsidian's inline title does; the frontmatter itself stays hidden. A section that comes before the title (the vault's "For future Claude" preamble, in 478 notes) shows collapsed to its first line and opens on a click. **Show Properties** (⌘I) opens the full YAML, tags included, as a table. | L |
| REN-7 | Local images (`![](…)`, `![[file.png]]`, `<img>`) sized to the column, with their pixel size read natively before loading so the page reserves their space; images over twice the column width are served downsampled; click for full size. | L |
| REN-8 | **Wiki links read as names:** `[[wiki/projects/Ferry]]` shows "Ferry" (the note's file name, or its first alias), with the vault path shown on hover and in the status line; an explicit `|label` always wins. | L |
| REN-9 | Raw HTML after sanitising: no scripts, event handlers, forms, iframes, objects, `style` attributes or `<style>` elements, and no `javascript:` or unknown URL schemes; `<details>`, `<kbd>`, `<sup>`, `<sub>`, `<mark>`, `<br>` render. | L |
| REN-10 | Plain text renders literally: whitespace, symbols and direction preserved, wrapped to the column; files whose lines mostly start with timestamps render in the mono face. | L |
| REN-11 | Obsidian `#tags` and `==highlight==` render; `%%comments%%` are hidden. | L |
| REN-12 | **Footnotes:** a footnote mark jumps to its note at the end and adds a back step; the note's back arrow returns. | L |
| REN-15 | **Tables** at 15 px (Loom's body size), scrolling sideways inside their block with a faded edge when wider than the page, a sticky header on tables taller than the screen, and scaled to the page width in print. | L |
| REN-16 | Footnotes open in place in a small solid popover. | 1 |
| REN-13 | Note embeds `![[Note]]` and `![[Note#Heading]]`, one level deep, framed, with a link to open. Audio, video and PDF embeds. | 1 |
| REN-14 | Fold any h2 section and remember folds per file by heading text, so a "For future Claude" preamble can stay folded. | 1 |

### 6.3 Reading

| ID | Requirement | Tier |
|---|---|---|
| READ-1 | **One column:** prose at 34em (about 74 characters a line, scaling with text size); headings, tables, code and diagrams use the full 720 px and may widen up to 120 px past it on each side; the column centres in the pane beside the outline; zooming out widens the column so more fits, as 1.2.1 does. | L |
| READ-2 | **Text size** ⌘+ (and ⌘=), ⌘− and ⌘0, 70 to 200 percent, remembered per file (OPEN-3). Full screen hides all chrome. | L |
| READ-3 | **Find** (⌘F): a find bar in the window chrome, live match count, ⌘G and ⇧⌘G, ⌘E to use the selection, matches marked in tint-2 and the current match in ink with paper text, and a thin match rail along the trailing edge (overlay scroll bars hide their track). Arabic matching folds tashkeel, hamza forms, alef maqsura, taa marbuta and tatweel by default; an option turns folding off. The search reruns after a reload and keeps the current match. Esc closes the bar and leaves the page at the current match. | L |
| READ-4 | **Outline** replaces the heading thread: a labelled list of h1 to h3 in a 220 pt rail (narrower than Loom's 272 pt sidebar, so the page keeps its width) on the interface's leading side, the current entry marked and kept in view, click to go, type to filter, shown and hidden with ⌃⌘S (Finder's sidebar key) and remembered. When the window is too narrow for the rail beside the column, the rail overlays the margin when opened, from a toolbar button. Reading progress runs along the rail's edge. Windows open at 1180 pt wide on screens that fit it. Height changes above the reading line (late images and diagrams) are compensated in the same frame, after jumps as well as reloads. | L |
| READ-5 | **Back and forward** (⌘[ and ⌘], trackpad swipe, never from a table or code block scrolled to its edge): every link followed, outline jump, anchor and footnote jump adds a step; each step restores its place. | L |
| READ-6 | **Copy Reference** (⌥⌘C): copies the path (relative to the git root inside a repository, else `~/`-relative) and the source lines of the selection, narrowed to list items and table rows, followed by those source lines quoted exactly as written in the file, so an agent can find and edit them. With no selection it copies the block being read. Line numbers count from the file's first line, through frontmatter, a BOM and CRLF endings. | L |
| READ-7 | A quiet footer: words, reading time, last modified, encoding when not UTF-8; in ink-2. | L |
| READ-8 | **Present** (⌥⌘P): in the window or full screen, at its own remembered size, outline and marks hidden; space and arrows move one screen, snapping to a heading only when one sits in the bottom fifth; Esc ends. | 1 |
| READ-9 | **Link preview** on force click or three-finger tap (the macOS Look Up gesture) and on ⌘-hover, never on plain hover: the target's first screen in a solid paper popover. | 1 |
| READ-10 | "Copy as Markdown" copies the source of the selected blocks. | 1 |

### 6.4 Live reload

| ID | Requirement | Tier |
|---|---|---|
| LIVE-1 | **Sees every save** (spike S(b)): a vnode source on the document's folder plus one on the file, rearmed on each new inode, and a stat right after every rearm so a save between the check and the rearm is not lost; in-place writes, atomic replaces, `mv` over, Vim-style saves, delete and recreate, and coordinated writes are all caught. After wake from sleep, and every 5 s while the window is key, the file's inode, size and modification date are compared with the last read, so a missed event is caught within 5 s. A missing file is treated as "being replaced" for 500 ms before the missing page shows. `NSFilePresenter` is kept for coordinated writers and moves, never waited on. | L |
| LIVE-2 | **Reads stably:** a generation counter advances on every observed change; a read starts 40 ms after the last event, uses a coordinated read, and repeats if size or modification date changed during it. During a burst, intermediate pages are shown at most every 250 ms; the last write of a burst is on screen within 150 ms of that write. The degraded cases in LIVE-3 are outside these targets. | L |
| LIVE-3 | **Keeps the last good page:** if a read in a burst is empty, or loses over half its blocks, the page stays as it was until 300 ms of quiet, then the new content is shown. | L |
| LIVE-4 | **Holds the place, deterministically:** blocks are matched by a bounded Myers diff on content hashes, which is deterministic for repeated blocks (equal blocks match in order). Between two matched blocks, the unmatched old and new blocks are paired in order as **edited** when they are the same kind and at least half their words are shared; the rest are inserted or removed. Only edited and inserted blocks are rendered again; matched blocks keep their elements, so selection, find marks and rendered diagrams in them survive. The reading line is anchored by its block and a text quote at that line: a matched block keeps its exact offset; an edited block finds the quote again inside it (else keeps its relative position); a removed block hands the place to the next surviving block, placed where the removed one began. A selection inside an edited block is restored by its text quote when the text survives, and dropped otherwise. Height changes from late images and diagrams are compensated as in READ-4. | L |
| LIVE-5 | **Shows what changed since you last looked:** per file, the content hashes of the blocks last acknowledged are kept (hashes only, never text; at most 20,000 per file, for the 500 most recent files, dropped after 180 days unread); a block is acknowledged after it has been on screen for 3 s in the key window. New and changed blocks get a thin ink mark in the leading margin, removals a small gap mark, and changed sections a dot in the outline. When more than half the blocks changed, one line replaces the marks: "Rewritten since you read it on 3 October". **Next Change** and **Previous Change** in the Go menu (⌥⌘↓ and ⌥⌘↑). Marks never print. | L |

### 6.5 Vault

| ID | Requirement | Tier |
|---|---|---|
| VAULT-1 | **Vault detection:** the nearest parent folder with `.obsidian`, else the nearest git root, else the document's folder; never the home folder or a volume root (those fall back to the document's folder). It bounds link resolution, Open Quickly and local file access. Symlinked folders inside the vault count as inside. | L |
| VAULT-2 | **Wiki links resolve deterministically,** every rule fixture-tested: names and paths compared in Unicode NFC and case-insensitively; `|label`, `#heading` and `#^block` split off; `.md` optional; (a) a path from the vault root matches exactly; (b) `./` and `../` paths are relative to the note; (c) otherwise any note whose vault path ends with the target matches: the one in the note's own folder wins, else the single shortest path, else the link is ambiguous; (d) aliases match only when no file name does; (e) targets with another extension (images) resolve the same way. Ambiguous and unresolved links are drawn dotted and say why on hover ("No note called …", "Two notes called …"). Checked against Obsidian's exported `resolvedLinks` and `unresolvedLinks` for every link in the vault, with the count taken at run time. | L |
| VAULT-3 | **Linked from** at the foot of the page: notes that link here, grouped by note, each with its first linking sentence, ten notes shown with "Show all". The index computes backlinks at launch already; the view ships in 1.x. | 1 |
| VAULT-4 | **Vault index** (note names, aliases, headings, outgoing links) builds in the background in under 2 s for 500 notes, in memory, updated from file events, skipping iCloud files that are not downloaded; nothing is written into the vault. | L |
| VAULT-5 | **Search the vault** (⇧⌘F): full text across the vault, results with context, opening at the match. | 1 |
| VAULT-6 | A folder sidebar. | Later |

### 6.6 Windows and tabs

| ID | Requirement | Tier |
|---|---|---|
| TAB-1 | Native macOS tabs as in 1.2.1: ⌘T, ⌘N, reorder, drag out, merge, Control-Tab; the tab bar shows on single-document windows. | L |
| TAB-2 | ⌘-click or middle-click on a link opens it in a new tab beside the current one; a plain click replaces the current tab and adds a back step. | L |
| TAB-3 | The native title bar stays: the document title (the first h1, else the file name) as the title, the folder as the subtitle, the proxy icon draggable. | L |

### 6.7 Export and share

| ID | Requirement | Tier |
|---|---|---|
| EXP-1 | **Print and Save as PDF** (⌘P; Page Setup ⇧⌘P): always in Paper or plain white, whatever the screen's look; page margins; running title and page numbers stamped on each page with PDFKit after WebKit writes the PDF, because WebKit's print ignores CSS page margin boxes (spike S(e)); links printed as text; diagrams, code blocks and tables kept whole where they fit; a PDF outline written from the headings; all Arabic set in Thmanyah, because with the system font the PDF's Arabic text cannot be searched or copied (spike S(e)). | L |
| EXP-2 | **Open in Editor** (⇧⌘E): the file opens in the editor chosen in Settings among apps that hold the Editor role for Markdown, Linen excluded (default: Obsidian for vault notes through `obsidian://open`, else the first other Editor). Opening at the line being read (VS Code, Zed, Xcode, BBEdit) comes in 1.x. | L |
| EXP-3 | Export HTML: one self-contained file in the same look, naming the Thmanyah families with fallbacks and never embedding them (section 11). | 1 |
| EXP-4 | Share menu (Mail, Messages, AirDrop) with the file. | 1 |

### 6.8 Quick Look and the system

| ID | Requirement | Tier |
|---|---|---|
| QL-1 | **Quick Look extension** (spike S(a)): space bar in Finder shows the note typeset with the same renderer and look; paper is painted before the renderer runs; a layout for the narrow preview pane under 500 pt (no outline, smaller margins). The extension gets only the previewed file from its sandbox, with no home-folder exception; it holds the network client entitlement only because WebKit cannot start without it (build log), and the page itself has no network source, so local images show as a quiet placeholder with their name; images arrive in 1.x through folder access shared from the app. | L |
| QL-2 | Finder thumbnails for Markdown files: the first lines typeset on paper. | 1 |
| SYS-1 | **Settings** (one pane, four groups): appearance (Paper, Night, follow the system), body face (Thmanyah Sans as in Loom, or Thmanyah Serif Text), default text size, the editor for Open in Editor, and the remote content default. | L |

### 6.9 Arabic and direction

| ID | Requirement | Tier |
|---|---|---|
| ARB-1 | **Direction by what a block is written in:** count its strong letters, leaving out inline code, links and paths; more than 60 percent Arabic is right to left, under 40 percent left to right, anything between takes the document's direction (the majority over the whole document). A list takes one direction for all its items. Inline code, paths, URLs and wiki links are isolated so they never reorder the sentence around them. Code blocks are always left to right, and name Thmanyah Sans after the mono face so Arabic inside code is set in Thmanyah. Tested against hand-labelled fixtures, including the 29 notes whose English lines start with an Arabic word. | L |
| ARB-2 | **Arabic type:** Thmanyah covers Arabic; an Arabic `unicode-range` face with `size-adjust` (its value measured in M4 from Thmanyah's alef height against the Latin cap height) makes inline Arabic read at the size of the Latin around it; Arabic blocks get line height 1.8 and Arabic headings at least 1.5; Arabic labels drop letter tracking; Arabic word spacing is judged by eye in M4 (spike S(f)). | L |
| ARB-3 | The outline rail follows the interface's direction (leading side), each entry in its own text direction; it never jumps sides between tabs. | L |
| ARB-4 | Arabic interface through String Catalogs: menus, settings, welcome, find bar, Quick Look strings; the app's name shows as سطر. | L |
| ARB-5 | Fixtures: a vocalised Arabic quote note, mixed Arabic and English lists, English lines that start with an Arabic word (about 120 such lines exist in 29 vault notes), Arabic tables. | L |

### 6.10 Appearance

| ID | Requirement | Tier |
|---|---|---|
| LOOK-1 | **Paper** and **Night,** both from Loom's tokens only, with the suite's Night defined once in 8.1 from Ferry's values. Follows the system unless fixed in Settings. | L |
| LOOK-2 | Chrome: the native title bar and toolbar (macOS 26 draws its own glass), Linen's line icons in ink, the window ground paper. Tabs stay native. | L |
| LOOK-3 | The welcome page is the empty state: the Linen mark on the weave, "What are we reading?", recent files, a drop zone, Open. | L |
| LOOK-4 | **Accessibility:** Reduce Motion stops every animation and shows the mark whole; Increase Contrast maps sage to ink-2 and rule to tint-3; no document-wide live region (a reload is announced once, "Updated, 3 changes"); VoiceOver reads the page in order with headings in the rotor, tables as tables, links by their names, the outline as a list, the find bar's count; Full Keyboard Access reaches every control; focus and selection survive reloads. | L |

### 6.11 Safety and privacy

| ID | Requirement | Tier |
|---|---|---|
| SAFE-1 | **No network, ever, from the page.** Its content security policy (section 9, literal) has `connect-src 'none'` and no network source anywhere. Remote images show a quiet placeholder ("Image from example.com"); one click allows remote images for this file, and Settings can allow them always; allowed images are fetched by the app through an ephemeral session (no cookies, no cache on disk), `http` and `https` only, at most 3 redirects, a 10 s timeout, 10 MB each, kept only if the response is an image by its type and first bytes and at most 40 megapixels when decoded (checked with ImageIO before handing it over, downsampled past twice the column width), and handed to the page through `linen-remote:`. Links open in the browser. | L |
| SAFE-2 | **Local access is bounded to the vault** (VAULT-1), race-free: the `linen-local:` handler parses the request as a URL, normalises the path relative to the vault root, then walks it from a descriptor of the vault root with `openat` one component at a time (`O_NOFOLLOW`, directories with `O_DIRECTORY`), so no step can be swapped after it is checked. A symlink met on the way is read with `readlinkat`, resolved against its folder, and followed only if the result is inside the vault; the walk then restarts from the root descriptor with that path, at most 8 times. The final descriptor must be a regular file of an image type (checked by its first bytes as well as its name), at most 50 MB and 40 megapixels; it is served from that descriptor, never reopened by path, downsampled past twice the column width, and cancelled when the page stops. **Outside the vault** a file shows a placeholder; "Allow this file" makes the app record a grant for exactly that file (device and inode) for this document while it is open, and the page loads it as `linen-local://grant/<random id>`, never by path. At most 200 MB of images load per document; past that, placeholders. | L |
| SAFE-3 | **No document script, no document CSS:** the page's scripts are files in the app bundle, allowed by `script-src 'self'` (the literal policy is in section 9); the worker loads only from the same origin; `base-uri 'none'`, `form-action 'none'`; tested as the effective policy inside WebKit. | L |
| SAFE-4 | Links: `http`, `https`, `mailto` open in their apps; local Markdown opens in Linen; other local files open in their apps without asking when inside the vault and with a confirmation outside it or when executable; other URL schemes (`obsidian:`, `vscode:`) ask every time, after the click; `javascript:`, `data:` and `file:` links never open. | L |
| SAFE-5 | **Bounded work:** documents over 20 MB, or whose lexing produces over 200,000 tokens, open as plain text in 200-line blocks, with a notice; a top-level list over 200 items or table over 500 rows is rendered as consecutive chunks (each its own page block with its own hash, sharing the source's line range); **any single block whose source exceeds 64 KB** (one giant paragraph, code block, list item, table cell or quote) is not typeset: it shows as escaped plain text in 16 KB pieces, each its own block, with a quiet note, so no unit of parsing, sanitising or rendering ever exceeds 64 KB of source; nesting over 100 levels is flattened; data URIs over 2 MB are dropped; code lines over 5,000 characters turn highlighting off for that block; at most 10,000 rendered blocks and 200,000 DOM nodes, with a notice past that; Mermaid, KaTeX and highlighting limits as in REN-3 to REN-5; rendering runs in slices of at most 16 ms between frames, and each slice checks a cancel flag so a new document or reload stops the old one; the worker sends blocks in batches of at most 500 blocks and at most 1 MB of source, so no message or structured clone is large; if the WebContent process dies, the page reloads once at the same place and says so. | L |

### 6.12 Performance

| ID | Requirement | Tier |
|---|---|---|
| PERF-1 | **The page is built once per window** and documents arrive through a versioned message bridge; a reload or a link replaces content, never the page. | L |
| PERF-2 | **Parsing off the main thread:** a Web Worker runs marked's lexer over the whole document and returns the top-level tokens with a document context (link reference definitions, footnote numbering by first reference, the frontmatter range and line offsets); the page renders and sanitises blocks in time slices, first screen first, with DOMPurify on the page's own thread, assigning heading anchors from one document-wide map so they never depend on batch order. | L |
| PERF-3 | Mermaid, math and highlighting run only for blocks near the screen, and are cached by source hash across reloads. | L |

## 7. Screens

1. Welcome (empty state): mark on the weave, "What are we reading?", recent files, drop zone, Open.
2. Document: native title and toolbar, outline rail, frontmatter strip, the column, footer.
3. Document with the find bar open, matches marked and the match rail.
4. Document after an agent's rewrite: change marks, a gap mark, outline marks, the Next Change menu.
5. Properties table.
6. Linked from at the foot of a note.
7. Open Quickly.
8. A blocked remote image and a blocked outside file.
9. File no longer here.
10. Settings.
11. Quick Look, full and in Finder's narrow preview pane.
12. Print preview.
13. Present.
14. Night variants of 2, 3 and 7; Arabic variants of 1, 2 and 10; a narrow window with the outline overlaid.

The sketch lives in `docs/design/linen-screens.html` (one self-contained file, built by a script), drawn before code and checked against the real app at each milestone.

## 8. Design: Loom's contract on native macOS

- **Tokens** exactly as Loom's section 2: paper `#F6F3EB`, paper-2 `#FBF9F4`, ink `#284734`, ink-2 `#1F3328`, sage `#8FA394`, rule `#DAD5C8`, tint-1 `#E3E7DF`, tint-2 `#C9D3CA`, tint-3 `#A9B8AC`, rust `#9C4A2E` for failures only. One token file per surface (`reader.css` custom properties, `Tokens.swift` for AppKit), no literals elsewhere, checked by a lint script against Loom's DESIGN.md.
- **Contrast rules.** In Paper, sage on paper is 2.42:1, so sage is decoration only (rules, icons, the weave), never text a person must read; quiet text and eyebrows are ink-2. In Night, sage on ink-2 is about 5:1 and serves as quiet text, as in Ferry. Night is defined once for the suite in 8.1.
- **Type** (fonts installed on the Mac, section 11). Every size below is either in Loom's scale (40, 34, 24, 19, 15, 12.5 to 14, 11) or marked as a departure for Hatim.

| Element | Face | Size and line height | Note |
|---|---|---|---|
| Document title (first h1) | Thmanyah Serif Display Light | 40, 1.15 | Loom's empty-state size |
| Other h1 | Serif Display Light | 34, 1.2 | Loom's sign-in size |
| h2 | Serif Display Light | 24, 1.3 | Loom's thread title |
| h3 | Thmanyah Sans 500 | 19, 1.4 | **departure:** Loom's card title is Serif 300 at 19; in Sans 500 it does not read lighter than 17 px body |
| h4 to h6 | Sans 500 | 17, 1.5 | **departure:** the body size, bold |
| Body | Sans 400 (or Serif Text 400, a setting) | **17, 1.65** | **departure:** Loom's 15 is a chat line; a page read for minutes needs 17 |
| Arabic body | same face | 17 with `size-adjust`, line height 1.8 | ARB-2 |
| Strip, footer, captions | Sans 400 | 13.5, ink-2 | in Loom's UI range |
| Eyebrows and labels | Sans 500, uppercase | 11, tracked .14em | Loom's eyebrow |
| Tables | Sans 400, headers 500 | 15, 1.5 | Loom's body size |
| Code | SF Mono, then Thmanyah Sans for Arabic | 14.5, 1.55 | **departure:** Loom has no code size |
| Prose measure | | 34em, about 74 characters | **departure:** Loom's column is 720 px, which carries about 92 characters at 17 px |

- **The weave** sits behind the welcome page and empty states only; the reading page is plain paper, because texture under body text tires the eye. **Departure** from Loom's "every page carries the weave", for Hatim to confirm.
- **Corners** 2 px; hairlines in rule. **Popovers** (find bar, Open Quickly, link preview) are solid paper with a rule border and the soft ink shadow, fading in over .15 s: a **departure** from Loom's glass panels, because glass over body text shows blurred words.
- **Motion:** the brand curve for the outline rail and popovers, .15 s for feedback, the mark drawing itself as the only working indicator (the vault index, a long first render), all off under Reduce Motion.
- **Mark (drawn 2026-10-11, `docs/design/linen-mark.svg`, built by `docs/design/make_mark.py`; Hatim: "i fucking liked it"):** the family's woven square used as a drop cap, with long threads as the lines of a page, two beside it and one under it, written right to left as Linen's Arabic name سطر is written. Linen is woven cloth, and "line" sits inside the word: the long threads are both. It replaces the 1.2.1 icon (a page with a heading mark), which Hatim set aside ("the current one isnt much"). Same 24-unit grid, 18-unit threads, round caps and icon construction as Loom's and Ferry's marks.
- **Copy:** Loom's voice: short, the action as the label, no exclamation marks, no em-dashes.

### 8.1 Linen in the Loom suite

Linen and Ferry are one family. Someone who uses Ferry Host on the Mac and then opens Linen should feel the same maker.
- **Same tokens, same type, same corners,** copied from Loom's contract. The lint check compares Linen's token files against Loom's DESIGN.md section 2 and against Ferry's `Tokens.swift`, so the suite cannot drift.
- **The suite's Night, defined once, from Ferry's values:** ground ink-2, raised ink, text paper, headings paper, quiet text sage, lines paper at 14 percent, the weave paper at 9 percent, a failure as paper text on a rust fill. Linen uses exactly these.
- **One mark language,** drawn on the same grid with the same threads, and the same icon construction (paper ground, faint weave, hairline, ink threads), so Loom, Ferry and Linen read as a set in the Dock.
- **Ferry Host's Mac patterns are reused:** the eyebrow and serif title header, ink and line buttons, the weave ground on empty and setup screens, the drawn mark as the working indicator, the Settings layout.
- **"A Loom product"** under the name in the About panel, and in the README.
- **Later:** a shared design package for the suite's Mac apps once a third app needs it.

## 9. Architecture

- **App:** AppKit, Swift 6 with strict concurrency, macOS 15 deployment target (tested on 26.5), built by an XcodeGen project and a Makefile like Ferry's, replacing the `swiftc` script. Targets: `Linen` (app, not sandboxed, distributed directly), `LinenQuickLook` (Quick Look preview extension, sandboxed, with a read-only exception for the home folder and `network.client`, spike S(a)), `LinenKit` (Swift package: vault index and link resolution, file watching, place and session store, settings, encodings; unit tested), `linen` (command line tool, 1.x).
- **Renderer:** one static page per tab in a `WKWebView`, served from the bundle by a `linen-app:` scheme handler and loaded once (PERF-1); a background tab builds its page on first selection and unloads after 10 idle minutes, keeping its place; documents, settings and commands cross a versioned bridge (`window.linen.receive` and a `linen` script message handler). Vendored and pinned: marked with footnote, alert and custom extensions (wiki links, callouts, highlights, comments, tags, math delimiters), DOMPurify, Mermaid, KaTeX, and a highlighter chosen in spike S(c) (a custom highlight.js build unless Shiki wins on the fixtures), each with a size budget: the renderer bundle under 9 MB uncompressed, Quick Look's resident memory under 120 MB. The same bundle serves Quick Look.
- **Blocks:** every top-level block carries its source line range and a content hash. They drive the place store (OPEN-3), the reload diff (LIVE-4), change marks (LIVE-5), Copy Reference (READ-6) and Open in Editor at a line (EXP-2).
- **File watching** as in LIVE-1 and LIVE-2, in `LinenKit`, with bookmark data for renames (OPEN-2).
- **Content security policy, literal** (SAFE-3): `default-src 'none'; script-src 'self'; worker-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' linen-local: linen-remote: data:; font-src 'self'; connect-src 'none'; media-src 'none'; object-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'`, where `'self'` is `linen-app://renderer`. Every script is a file in the bundle, so no hashes are needed. `'unsafe-inline'` styles are needed by Mermaid's SVG and KaTeX's layout; documents cannot use them, because the sanitiser removes every `style` attribute and `<style>` element first, and math and diagrams are rendered by the page after sanitising. Tested as the effective policy inside WebKit.
- **Local files** as in SAFE-2; remote images through the app as in SAFE-1.
- **Place and session store:** small JSON files in Application Support (session, places per file, change baselines per file), written on change, debounced, and on quit.
- **Vault index** in `LinenKit` on a background queue, from file events, NFC-normalised.
- **Fonts, one answer:** a build step copies the Thmanyah faces Linen uses from `~/Library/Fonts` into the built app and extension (never into the source tree; `.gitignore` excludes them), and the page declares them with `@font-face` from its bundle (spike S(f): WebKit renders in its own process, so this is the way that reaches it), with system fallbacks.

## 10. Quality bar

- Every note in the vault passes the structural checks in section 13.
- Paper and Night, English and Arabic screenshots of every screen in section 7, compared with the sketch, with edges measured in the page (title, paragraphs, tables, footer).
- No console errors; no main-thread stall over 100 ms while reading; no layout shift after first readable.
- VoiceOver and Full Keyboard Access pass the scripted checks in section 13.
- Ten scripted reading tasks (section 13) done end to end in the real app before release.

## 11. Constraints and risks

- **Fonts (research, `docs/research/competitors.md`, license read 2026-10-11, confidence stated; all fifteen faces are installed in `~/Library/Fonts`, checked 2026-10-11).** The Thmanyah license allows use "on your own devices and projects" but forbids uploading or hosting the files "on any website, server, digital platform", and forbids letting anyone "extract ... the Font Software independently as font files, including through web embedding, applications, or software products". **Hatim's decision (2026-10-11):** the repos are not commercial, so the fonts stay in Ferry's private repository. For Linen: the build copies the fonts it uses from the installed copies in `~/Library/Fonts` into the app and the Quick Look extension, as Ferry ships them; whether the files also go into Linen's repository, which is public, is Hatim's call at the first commit (the license names public download explicitly). Exported HTML names the fonts and never embeds them; PDF embedding of subsets for Hatim's own documents is likely allowed (medium). Shipping Linen to other people with the Thmanyah look needs a written exception from ask@thmanyah.com; that is a release-phase decision.
- **Quick Look** works from a Personal Team build (spike S(a)), but the first preview after registering came up blank twice; QL-1 paints paper first and M6 measures cold previews after login and after install. The spike's home-folder exception and network entitlement are dropped (QL-1). Other people need Developer ID signing and notarisation (release phase).
- **Privacy prompts:** macOS guards Desktop, Documents, Downloads, iCloud Drive and network volumes even for apps outside the sandbox, and a new bundle identifier starts with no grants; the first launch may prompt for each folder (OPEN-2 shows the denied state).
- **Place keeping** is the hardest part: block diffs on documents rewritten by agents, reflow from images and diagrams loading late, Arabic reflow. M3 tests it against scripted rewrites.
- **WKWebView find:** no find bar or match marking is provided; Linen builds its own over the page text, with its own Arabic folding.
- **Public repository:** docs, research and tests must not leak Hatim's notes. The corpus checks read the vault in place and print counts and paths only; the frozen `log.md` copy used for timing lives outside the repo.
- **Bundle size:** Mermaid is 3.4 MB today; KaTeX and a highlighter must fit the 9 MB budget.

## 12. Milestones

Every milestone ends with a run on the real app on real files, my review and a Codex review of the code, then Codex verifies the fixes.

| # | Scope | Exit test |
|---|---|---|
| S | Spikes: (a) Quick Look from a Personal Team build (**done**: yes, with the read exception and the extension's own scheme handler); (b) save signals for every writer (**done**: watch the folder, rearm on new inodes); (c) highlighter (**done**: highlight.js, 308 KB for 30 languages against Shiki's 2.1 MB); (d) the corpus in 1.2.1's renderer (**done**: no errors, `log.md` 3.97 s); (e) WebKit print (**done**: paginates through the print operation; no margin boxes or outline, so both are added with PDFKit; Arabic text survives only in Thmanyah); (f) bundled Thmanyah in WebKit (**done** for the app through `@font-face`; Quick Look checked in M6) | Each answered with evidence in `docs/spikes/` |
| M0 | XcodeGen project, Swift 6, `LinenKit`, Makefile; the static page and bridge; **safety first**: the literal CSP, network blocked, the bounded `linen-local:` handler, sanitising, limits; the structural corpus checks and fixtures; the font build step | Builds; every security case in section 13 fails safe, and the security cases rerun after every milestone that adds a renderer feature; corpus checks run and report |
| M1 | Loom redesign: chrome, page typography, Paper and Night, welcome, missing file, footer, frontmatter strip, the Linen mark and icon, Settings | Screenshots against the sketch in both looks and languages; edges measured; contrast checked |
| M2 | Reading: find, outline, back and forward, places per file, session restore, Open Recent, Open Quickly, text size, Copy Reference, footnote jumps | Each feature in the real app; session and places survive quit and relaunch; Open Quickly over the vault; Copy Reference line fixtures (frontmatter, BOM, CRLF) |
| M3 | Live reload: watching, stable reads, last good page, place holding, change marks, Next Change | A script rewrites a copy of the Ferry PRD 50 times with insertions above and below, edits inside the block being read, repeated identical blocks, renumbered headings, a truncated write, a rename, a deleted current block, a selection inside an edited block and 20 saves 20 ms apart, using the agents' own Write and Edit tools: a surviving reading line holds within 4 px every time, a deleted one follows the deletion rule, and marks match a block diff computed independently from the two file versions |
| M4 | Rendering: callouts, monochrome highlighting, math, footnotes, tags, highlights, comments, wiki link names, plain text modes, lazy themed Mermaid; Arabic direction rules and type | Golden DOM fixtures pass; the vault passes the structural checks; Arabic fixtures render as specified |
| M5 | Vault: detection, link resolution, wiki link names, the index | Every link in the vault, counted at run time, agrees with Obsidian's exported `resolvedLinks` and `unresolvedLinks`, or the difference is listed and explained; index time measured |
| M6 | Print and PDF, Open in Editor, Quick Look, Arabic interface, accessibility pass | A PDF of the PRD with outline and page numbers and searchable Arabic; Quick Look after a clean install, after login and in the narrow pane, with the intended entitlements only; VoiceOver and Full Keyboard Access scripts pass |
| Release | Install to /Applications as Linen, the rename steps Hatim approves, README and screenshots | The ten reading tasks pass; Hatim reads in it for a day |

## 13. Test plan

- **Structural corpus checks** on every `.md` under `~/vault` and `~/Desktop/*/docs`, in the real renderer offscreen, per note: no raw `[[`, `==`, `> [!`, `$$` or `%%` left in text; no KaTeX output on a line that holds two dollar amounts; nothing overflows the column outside wide blocks; no console errors; times recorded. Direction is checked against hand-labelled fixtures, never against the rule that produced it. Output: counts and paths only.
- **Golden DOM fixtures** in `Tests/Fixtures/`, one per construct (each REN row, callout kinds, 30 code languages, footnotes, tables with alignment, Arabic and mixed, broken and ambiguous links, hostile HTML, huge file, log-like text, CP1252, CP1256 and malformed encodings).
- **Link oracle:** Obsidian's `app.metadataCache.resolvedLinks`, exported once to a local file outside the repo, compared with Linen's resolution for every link.
- **Reload matrix** (M3): each writer from spike S(b) plus the agents' tools, partial writes, rename, delete and recreate, renumbered headings; the place and the marks checked after each.
- **Security cases:** a symlink swapped while a file is being served, symlinks that leave the vault, a grant reused for another file, a 40-megapixel image, 200 MB of images, a 50,000-item list, a 100,000-character line; `<script>`, event handlers, `javascript:` and unknown-scheme links, `<iframe>`, `<object>`, `style` and `<style>` with remote `url()`, `linen-local:` paths outside the vault, `..`, symlink and prefix escapes (`/vault-evil` beside `/vault`), huge data URIs, Mermaid and KaTeX bombs, remote images; none run, load or escape without the reader's allow.
- **Measures** in section 4 with signposts, 20 runs each.
- **Also tested:** WebContent crash recovery; Quick Look's 120 MB; the renderer's 9 MB; the token lint against Loom and Ferry; the font build step on a clean clone; the denied-folder and not-downloaded states; Copy Reference line ranges.
- **Accessibility scripts:** VoiceOver reading order, rotor headings, table navigation, link names, find count; Full Keyboard Access to every control; Reduce Motion and Increase Contrast screenshots.
- **Ten reading tasks** (release): open a vault note from Finder, follow three links and come back; read the PRD while an agent rewrites it and find each change; find an Arabic word with and without tashkeel; copy a reference and paste it to Codex; read a document on the TV at a large text size; print a PDF; preview a note in Quick Look in the narrow pane; reopen after a restart at the same places; open a renamed note from its old tab; read a note with the interface in Arabic.
- **Against Marked 3:** five fixed files (the PRD, a vault note, an Arabic note, a Mermaid note, the log) side by side: place on reload, direction, links, find.

## 14. Open questions for Hatim

Hatim asked on 2026-10-11 not to be asked or waited on overnight ("going further dont ask or wait or do action that needs me"), and to install Linen and delete Satr when done. Each question below proceeds with its drafted answer and is listed for his review; nothing outside this folder is changed except installing Linen in Satr's place.


1. Keys follow Mac conventions: ⌘P prints, ⇧⌘O is Open Quickly, ⌘I shows properties, ⌃⌘S the outline, ⇧⌘E opens the editor, ⌥⌘C copies a reference. Change any?
2. The reading page as plain paper (weave only on empty screens), and body text at 17 instead of Loom's 15: both departures from Loom, as drafted. Agree?
3. Body face: Thmanyah Sans (Loom's) by default, with Serif Text as a setting, or the reverse?
4. The public repository: commit the PRD, sketch and research too, or keep them local?
5. The rename reaches outside this folder: the GitHub repository `taurusn/satr` (rename to `taurusn/linen`, which GitHub redirects), the bundle identifier (`com.satr.reader` to `com.hatim.linen`, matching Ferry's `com.hatim.ferry`; macOS then asks once to make Linen the default reader again), and the folder `~/Developer/Satr`. Each is a separate step for Hatim's go.
6. Version: Linen 1.0, the successor of Satr 1.2.1.

## Appendix A. Review log

### Round 1 (2026-10-11): Codex, a fresh-eyes reviewer, Claude

Raw reviews: `docs/reviews/round1-codex.md` (final answer in `round1-codex-final.md`), `docs/reviews/round1-fresh.md` (with screenshots in `round1-fresh-shots/`). Research and spikes that also changed the draft: `docs/research/competitors.md`, `docs/spikes/corpus`, `quicklook`, `watch`.

**Accepted and changed**
- DOMPurify needs a DOM, so it cannot run in a worker, and HTML chunks break references, lists and footnotes (Codex). The worker now returns marked's tokens and the page sanitises and renders them in batches (PERF-2); first readable and fully rendered are measured apart (section 4).
- Satr reloads by replacing the whole page (Codex). One static page and a versioned bridge, in M0 (PERF-1).
- Heading-path keys break under edits, duplicates and renumbering (Codex, fresh). A content-hash sequence diff with heading lineage as a tie-break, in-block offsets, and patching only changed blocks (LIVE-4).
- File-only watching misses atomic saves; 150 ms conflicted with four reloads a second (Codex), confirmed by spike S(b). Folder and file sources with rearming, stable coordinated reads, and separate first-show and rate targets (LIVE-1, LIVE-2).
- A truncate-then-write or a streaming agent leaves empty or half files (fresh). The last good page stays until quiet (LIVE-3).
- Change marks faded before he looked back, deletions were invisible, and there was no way to step through changes (fresh). A persisted per-file baseline, marks that clear after 3 s on screen, gap marks, Next and Previous Change (LIVE-5).
- Every present safety promise is false in 1.2.1's code (Codex). Safety moves into M0: CSP with hashes, no network, no document CSS, a bounded local handler opened by descriptor, limits, process-crash recovery (SAFE-1 to SAFE-5).
- No resource limits (Codex). SAFE-5 and the limits in REN-3 to REN-5.
- Per-document data inside inline scripts breaks CSP hashes (Codex). The page carries no document data; scripts load from the bundle (SAFE-3).
- Quick Look was committed to before the spike (Codex). Spike S(a) ran: a view-based extension with WKWebView works from a Personal Team build; sibling images need the home read exception and the extension's own scheme handler; the first preview can come up blank (QL-1, section 11). Narrow preview pane layout (fresh).
- Size budgets (Codex). Renderer and Quick Look budgets in section 9; highlight.js unless Shiki wins (spike S(c)).
- "Stays the default opener" disrespects the user's choice (Codex). An explicit Make Default action; plain text stays an alternate viewer (OPEN-1). Open in Editor must not pick Linen itself and should open at the line (fresh, EXP-2).
- Windows-1256-first decoding misreads Western files (Codex). Strict UTF checks, confidence detection, an override menu (OPEN-6).
- The dialect was undefined; MDX would not stay literal (Codex). A pinned dialect with golden DOM fixtures (section 6.2); MDX dropped.
- "Same as Obsidian" was untestable (Codex, fresh). Written rules, NFC, and all 5,400 links checked against Obsidian's exported `resolvedLinks` (VAULT-2, section 13).
- The sandbox model was unstated (Codex). The app is not sandboxed and is distributed directly; only the Quick Look extension is sandboxed (section 9).
- Measures were single-run and "readable" undefined; memory missed the WebContent process (Codex, fresh). Signposts, 20 runs, p50 and p95, final fonts, ten restored tabs, link and back times, a frozen `log.md` (section 4).
- Accessibility was missing and the article was a live region (Codex). LOOK-4.
- MDX and audio, video and PDF embeds moved to 1.x (Codex).
- Exit tests would pass a broken product: 1.2.1 already renders all 513 files without errors while showing broken direction and raw link paths (Codex, fresh). Structural checks per note, golden fixtures, the reload matrix, security cases, scripted tasks, a Marked 3 comparison (sections 12, 13).
- Renamed or moved notes would show as missing, and places were kept only for restored tabs (fresh). Bookmark tracking and places per file; appended logs open at the end (OPEN-2, OPEN-3).
- Present was a named job left at 1.x with a clashing key (fresh). Present at launch on ⌥⌘P, in the window or full screen, with its own size (READ-8). ⇧⌘P is Page Setup again.
- Print had no rule for Night (this Mac runs dark) and may need native page numbers (fresh). Print is always Paper or white, links as text, a PDF outline, spike S(e) (EXP-1).
- The outline did not fit the default window, and `log.md` has 669 headings (fresh). Windows open at 1180 pt, a 220 pt rail that overlays when narrow, type to filter (READ-4).
- Hover previews would fire all over a page with 5,400 links (fresh). Force click, three-finger tap and ⌘-hover only, at 1.x (READ-9).
- Find details: overlay scroll bars hide track marks; Arabic folding; rerun after reloads (fresh). READ-3.
- Keys: ⌘= with ⌘+; ⌃⌘S credited to Finder; SAFE-4 asks only outside the vault or for executables; logs detected by timestamps only (fresh).
- Linked from would be a wall of `log.md` sentences; 478 notes put "For future Claude" above the h1 (fresh). Grouped by note, ten shown (VAULT-3); the strip at the top, `updated` before `date` (REN-6).
- Type sizes outside Loom's scale were undeclared (fresh). A full type table with every departure marked (section 8).
- Sage text and Night rust fail contrast (fresh). Sage is decoration only; Night failures use paper text with a rust rule (section 8).
- A token-only highlighter is monochrome, and rust was spent on warnings (fresh). Monochrome highlighting by weight, style and tint washes, declared as the design; callouts in ink (REN-2, REN-3).
- A custom title loses the proxy icon; glass blurs text under popovers (fresh). The native title stays; popovers are solid (TAB-3, section 8).
- Direction by first letter flips English lines that start with an Arabic word, and lists alternate sides (fresh). Majority of letters, one direction per list, isolated code and links (ARB-1); the rail follows the interface (ARB-3); size-adjusted Arabic face and NFC (ARB-2, VAULT-2).
- Path-qualified links read as paths (fresh). Note names, paths on hover (REN-8).
- No way to hand a passage to an agent (fresh). Copy Reference (READ-6).
- Folding sections and footnotes in place (fresh). Footnotes in place at launch (REN-12); folds at 1.x (REN-14).
- The comparison named Marked 2 while the App Store lists Marked 3 (fresh). Section 3 rewritten from the research.
- **Fonts** (research): the Thmanyah license forbids hosting the files anywhere and letting them be extracted from apps or web pages. Hatim decided the repos are not commercial and keeps the fonts in Ferry's private repo; Linen copies them from the installed fonts at build time, and the public repo question waits for the first commit; HTML export never embeds (section 11).

**Disagreed, with reasons**
- *Codex: move change marks (LIVE-3 then, now LIVE-5) to 1.x.* The reviewer job, reading while an agent rewrites, is the reason Linen exists for Hatim, and marks are what make a rewrite readable. They stay at launch, built on the same block diff as place keeping, so most of their cost is already paid.
- *Codex: move Open Quickly and Linked from to 1.x.* Both read the vault index that VAULT-2 needs anyway for bare-name links; Open Quickly reads only names. They stay at launch, scheduled in M2 and M5 with their own exit tests.
- *Codex: a data-based Quick Look preview with static HTML.* That would need a second Markdown renderer in Swift and would differ from the app. Spike S(a) showed the view-based extension with WKWebView works, so Linen keeps one renderer for both.

### Round 2 (2026-10-11): Codex, a second fresh-eyes reviewer, Claude

Raw reviews: `docs/reviews/round2-codex.md` (final answer in `round2-codex-final.md`), `docs/reviews/round2-fresh.md`. Spikes (c), (e) and (f) ran in the same round.

**Accepted and changed**
- The content security policy was not written down, and remote images contradicted "no network" (Codex). The literal policy is in section 9; the page never reaches the network; allowed remote images are fetched by the app (SAFE-1).
- The Quick Look extension's home-folder exception gave it more authority than the vault rule (Codex), and its network entitlement contradicted SAFE-1 (Codex, fresh). Both are dropped; Quick Look shows local images as placeholders at launch, with folder access shared from the app in 1.x (QL-1).
- Check-then-open on paths can race (Codex). URL parsing, `O_NOFOLLOW`, and a device and inode check on the open descriptor (SAFE-2).
- Unknown schemes must not be approved once and remembered (Codex). They ask every time (SAFE-4).
- "Yield after 3 s" cannot stop synchronous work, and plain text could still build a huge DOM (Codex). 16 ms slices with a cancel flag, node and block limits, plain text in 200-line blocks (SAFE-5).
- Batching left document state undefined (Codex). The worker returns a document context: references, footnote numbering, line offsets; anchors come from one document-wide map (PERF-2).
- Plain LCS is quadratic and ambiguous with duplicates, and a deleted line cannot hold within 4 px (Codex). A bounded Myers diff with neighbour disambiguation, a text quote at the reading line, and an explicit deletion rule (LIVE-4); the measure applies to surviving lines (section 4).
- The watcher's timing targets contradicted each other (Codex). A generation counter, separate quiet, intermediate and final targets, degraded cases excluded (LIVE-2).
- The change baseline was undefined (Codex). Hashes only, acknowledged after 3 s on screen; a "rewritten since" line when over half changed (fresh); marks never print (LIVE-5).
- Thresholds were not testable: encoding confidence, "close to even", the Obsidian tie-break (Codex). Numbers in OPEN-6 and ARB-1; a complete rule in VAULT-2, checked against resolved and unresolved links from Obsidian, counted at run time.
- Launch was too broad (Codex). Present, Linked from, footnote popovers and editor line targeting move to 1.x (READ-8, VAULT-3, REN-16, EXP-2).
- Security gates passed before the risky features existed, and several exit tests had no oracle (Codex). Security cases rerun after every renderer milestone; M3 marks are checked against an independent diff of the two file versions (section 12).
- The prose column carried about 92 characters a line (fresh). Prose at 34em, about 74 (READ-1, section 8).
- The top of a vault note did not work: 210 notes have no h1 and 478 open with the preamble (fresh). The note header and the collapsed preamble; tags move to Properties (REN-6).
- Night disagreed with itself and with Ferry (fresh). Defined once in 8.1 from Ferry's values and linted against Ferry's tokens.
- Late images and diagrams move the reader after jumps too, and a huge image can decode past 500 MB (fresh). Reserved heights, natively read image sizes, downsampling, same-frame compensation (REN-4, REN-7, READ-4, SAFE-2).
- Tables had no size or overflow rule (fresh). REN-15.
- Privacy prompts, undownloaded iCloud files and network volumes were not handled (fresh). OPEN-2, OPEN-8, VAULT-4, section 11.
- Copy Reference quoted rendered text that agents cannot match (fresh). It quotes the source lines, narrowed to items and rows, with repository-relative paths (READ-6).
- Some tests checked the code against itself (fresh). Hand-labelled direction fixtures; Linked from moved to 1.x.
- Dollar amounts could render as math (fresh). The delimiter rule is written and the 31 price lines are fixtures (REN-5, section 13).
- Memory covered one tab (fresh). Pages build on first selection, idle tabs unload, a ten-tab target (section 4, section 9).
- Encodings on reload, the rewritten-note line, undeclared departures (h3, solid popovers, the 220 pt rail, small caps), monochrome code by weight only, find colours, Arabic size-adjust basis and heading line heights, swipe from scrolled tables, vault roots and symlinks, a grown file opening at its first added block, spike status and the 28.9 percent figure, five cold launches and a frame budget, and the missing tests (fresh, minor). All taken in the rows named.

**Disagreed, with reasons**
- *Codex: only four of the fifteen Thmanyah faces exist.* All fifteen are installed in `~/Library/Fonts` (checked 2026-10-11); the research lane inspected the four copies in Loom's site folder.
- *Fresh: fifteen Thmanyah files sit untracked in `Sources/Satr` of the public repository.* There are none anywhere in the repository (checked with `find`); `.gitignore` now excludes `thmanyah*.otf` anyway.
- *Fresh: rely on the installed families instead of copying the faces at build time.* Hatim decided on 2026-10-11 to ship the fonts with his apps; spike S(f) showed WebKit needs `@font-face` from the bundle, and the Quick Look sandbox is not guaranteed to see user-installed fonts, so build-time copies are the one answer.
- *Fresh: show the tab bar only from two tabs.* Hatim asked in July for the tab bar on single-document windows, so a detached tab always has a place to merge back.
- *Codex: keep change marks for the session only at first.* Hashes only, a few kilobytes a file, and the reviewer job needs to see changes made while the file was closed; the persistence stays.

### Round 3 (2026-10-11): Codex sign-off, Claude

Raw review: `docs/reviews/round3-codex.md` (final answer in `round3-codex-final.md`). Codex did not approve, with three blockers; v0.4 answers each, and round 4 checks them.

**Accepted and changed**
- *Race-free file authority.* The handler walks from a descriptor of the vault root with `openat` one component at a time, follows in-vault symlinks by restarting that walk, serves from the final descriptor, and gives outside-vault files an opaque per-file grant instead of a path (SAFE-2).
- *Deterministic reload identity.* Myers on hashes matches repeated blocks in order; unmatched blocks between two matches pair in order as edited when they share half their words; edited blocks restore the reading line and any selection by text quote (LIVE-4); M3 adds repeated blocks and a selection (section 12).
- *Bounded work.* Huge lists and tables render as chunks that each fit a slice; caps on tokens, worker message size, decoded pixels, total images per document and long code lines (SAFE-2, SAFE-5).
- SAFE-3 contradicted section 9 on hashes; it now says `'self'`, as section 9 does. The remote-image broker's limits are written down (SAFE-1). A stat after every rearm, reconciliation after wake and every 5 s while key catch missed events (LIVE-1). Baselines are capped and expire (LIVE-5). New security cases cover symlink swaps, grant reuse, pixel and asset caps, and huge lists and lines (section 13).

**Disagreed, with reasons**
- *Codex: the persistence of change marks costs more than "a few kilobytes" suggests.* Agreed on the wording; the cap (20,000 hashes a file, 500 files, 180 days) now bounds it, and the product decision stands.

### Round 4 (2026-10-11): Codex, Claude

Raw review: `docs/reviews/round4-codex.md`. Race-free file authority and deterministic reload identity: resolved. Bounded work: not yet, because batches were bounded by count, not bytes, a single giant paragraph, code block, list item or cell stayed one unit, and remote images had no decoded-pixel cap.

**Accepted and changed:** batches are bounded by 1 MB of source as well as 500 blocks; any single block over 64 KB of source is shown as escaped plain text in 16 KB pieces instead of being typeset, so no unit of work exceeds 64 KB; remote images are capped at 40 megapixels decoded, as local ones are (SAFE-1, SAFE-5).

### Round 5 (2026-10-11): Codex, Claude

Raw review: `docs/reviews/round5-codex.md`. The bounded-work blocker is resolved: "SAFE-5 now bounds oversized nodes with a 64 KB cutoff and 16 KB plain-text chunks, caps worker batches by both count and source bytes, and retains document/token/DOM limits. SAFE-1 adds the missing 40-megapixel decoded-image cap." Verdict: **Approved to build.** Claude approves v1.0.

### Code review 1 (2026-10-11): Codex, then two verification passes
Raw review: `docs/reviews/code1-codex-final.md` (18 findings, 3 blockers). Verifications: `code1-verify-swift-final.md`, `code1-verify-renderer-final.md`.

**Accepted and changed:**
- "Allow outside" was one document-wide switch; it is now a grant for exactly the image clicked, bound to its canonical path, device and inode (SAFE-2).
- Local links had bypasses (outside files, symlinks, attachments by wiki link, ambiguous picks); every local link and every image click now passes one gate that judges the file after symlinks resolve (SAFE-4).
- SAFE-5 was partial: a 20 MB byte check before lexing, a 200,000-token cap counted during lexing, nesting flattened at 100, 10,000 blocks and 200,000 elements, and a superseded parse terminates the worker.
- Remote images were buffered whole; they now stream, need an image MIME type, stop past 10 MB and cancel when the page stops them (SAFE-1). The one-file approval now survives the reload it causes.
- Pixel checks could overflow, SVG skipped every check and file names were never checked; checks now divide, SVG is drawn into a bounded bitmap, and name and bytes must agree.
- Change marks: acknowledgements are kept in page state in order, with repeats and gap positions; time on screen accumulates, so blocks taller than the window acknowledge; the rewritten line waits its 3 s too (LIVE-5).
- Place restore picks the duplicate nearest the stored index and uses the quote offset; the diff is linear-space Myers (10,000 replaced blocks: about 1 MB instead of 654 MB); edited pairing needs half of both blocks' words.
- Moves refresh the vault, index, title and page; file states for denied folders, disconnected disks, unreadable files and iCloud downloads; network volumes polled every 2 s; View > Text Encoding; session restore builds only the front tab and keeps gone files as tabs (OPEN-2, OPEN-6, OPEN-8).
- Image reads and decoding moved off the main thread, two at a time, with the 200 MB budget counted before reading.
- Quick Look decodes like the app, sends no baseline, and waits for first paint.

**Disagreed, with reasons:**
- *Prompt before opening any file outside the vault.* SAFE-4 opens local Markdown in Linen without asking, since Linen only reads it; the gate still asks for other outside files and for anything that can run programs. Codex accepted this reading in verification.

### Build log (changes found while building, 2026-10-11)
- **DOMPurify drops attributes holding "-->".** Every Mermaid arrow matches its mXSS rule, so diagram and math sources live in a side table keyed by number, never in attributes.
- **Animation frames nearly stop in hidden windows.** Render slices yield through a message channel instead, so background tabs and offscreen pages finish rendering.
- **Gap marks must take no layout space.** A gap's negative margin shifted the reading line 6 px on every reload; gaps are now zero-height with the mark drawn outside the flow, and marks are applied before the place is restored. The reload test (30 rewrites of the Ferry PRD with insertions above the reader) holds the line with 0 px drift.
- **Long unbroken strings** (URLs, paths in emphasis) overflowed the column in 8 corpus notes; long words now break when they must.
- **A new app identity meets macOS privacy prompts.** Opening a Desktop file asks "Linen would like to access files in your Desktop folder", as section 11 expected; Claude does not answer privacy prompts for Hatim, so overnight tests use the vault and the repository.
- **JavaScriptCore lexes long documents in quadratic time.** marked's lexer re-scans the remaining source per token, which JavaScriptCore handles far worse than V8: the vault's 500 KB `log.md` took 3.5 s. Documents over 48 KB are now lexed in sections cut at headings and blank lines outside fences, with link reference definitions shared across sections; `log.md` lexes in 307 ms and transcripts in 246 to 573 ms.
- **Quick Look needs the network client entitlement (QL-1 amended).** Without it the sandboxed extension's WebKit content process dies at launch ("content process terminated"), so a WKWebView cannot run there at all. The entitlement stays; the page still has `connect-src 'none'` and no network source, so the preview can reach nothing, and local images stay placeholders.
- **A blank Quick Look preview was a hidden window.** `qlmanage -p` opens behind other apps, and WebKit freezes drawing in an occluded window; brought to the front, the same preview drew in 40 ms. Finder's panel is always in front. The extension logs to the unified log instead of a file, since reading an extension's container from a terminal raises a privacy prompt.
- **LaunchServices will not open a file Linen cannot read**, and a permission change does not touch the file, so the watcher never sees it. A tab in the "needs permission" or "could not read" state tries again every 2 s and loads as soon as it can.
- **Clicking an image opened any path in its app**, around the link gate: `![x](Tool.app)` showed as a missing image whose click would launch the app. Image clicks now pass the same gate as links (SAFE-4).
- **Re-reading in another encoding marked every block as changed.** Choosing an encoding now clears that file's baseline, since it is not an edit.
- **Print crashed the app.** AppKit calls the print operation's completion on its own thread, and Swift 6 traps when a main-actor method runs there; the callback now hops to the main thread. Found only by printing in the real app.
- **A reload typesets new blocks ahead of the patch** (in 12 ms slices, cancelled by a newer load or reload), so image requests and lazy fills start only for blocks that reach the page, and an answer to an older image request no longer marks newer images missing.
- **Change marks follow each block's direction**: an Arabic paragraph's mark sits on its right; code, math and diagrams count as left to right.
- **Large Arabic files are slow.** A 14 to 21 MB Arabic file takes 20 to 60 s to first paint on this Mac under memory pressure (WebKit laying out unbroken Arabic runs, and the footer's word count); bounded, but a known limit for 1.x.

