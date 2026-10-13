# Satr competitor and font research

Research lane for the Satr PRD. All pages were read on 2026-10-11 and saved under `raw/` in this folder (paths below are relative to `docs/research/raw/`). Every quote was checked against the saved text with grep before it went in. "NL" means the pages I saved do not mention the capability. NL does not mean the app lacks it.

## Two-minute summary

Legend: **Y** the source says yes. **N** the source says no, or the code shows no. **P** partial, through a plugin or extension, or with a caveat. **NL** not listed in the saved pages. **n/a** does not apply (Quick Look extensions have no reload, tabs or folders).

| Capability | Marked 3 | MarkEdit | Typora | iA Writer | Obsidian | MacDown 3000 | Read.md | Marked QL | QLMarkdown | Peek | Satr 1.2.1 today |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Price and model | Free + IAP: $2.99/mo, $29.99/yr, $69.99 unlock (intro) | Free, MIT | $14.99 once, 3 devices | $49.99 once (Mac) | Free; Sync and Publish paid | Free, MIT | Free; Pro $24.99 once or $9.99/yr | $9.99 | Free, GPL-3.0 | $7.99 | Personal; no license chosen |
| Engine | Native, HTML preview | Native shell + CodeMirror 6 | Web editor; Electron in credits | Native (vendor) | Electron 43.1.1 | Native, Hoedown | "Native on Mac" | QL extension, Apex | QL extension, cmark-gfm | QL extension | AppKit + WKWebView |
| Offline rendering | P: MathJax local or CDN; Mermaid help says CDN | NL | NL | NL | NL | NL (old MacDown math via CDNJS) | Y | Y, bundled | P: CDN or embed | NL | Y; remote images still load |
| Mermaid | Y | P, popover or extension | Y | NL | Y | NL | Y | Y | Y | Y | Y |
| Math | MathJax, KaTeX | KaTeX via extension | MathJax | KaTeX | MathJax | Y, TeX syntax | NL | MathJax | MathJax | MathJax | N |
| Code highlighting | Y, 256 languages | P, extension | Y, ~100 languages | NL | Y, Prism | Y, Prism | Y, 180+ | Y | Y | Y | N |
| Find in document | Y, regex | NL | Y + replace | Y, Quick Search | Y + replace | NL | Y | NL | NL | Y | N |
| Outline / TOC | Y, filterable, sidebar, minimap | Y, heading menu | Y, panel + [TOC] | Y, outline in Quick Search | Y, Outline plugin | NL | Y | Y, heading sidebar | Y, sidebar option | Y, optional | P: h2/h3 dots, titles on hover |
| Live reload on change | Y, core purpose | NL | NL (tree watches) | NL | Y | NL | NL | n/a | n/a | n/a | Y, NSFilePresenter |
| Keeps scroll on reload | Y, "Scroll to edit" | NL | NL | NL | NL | NL | Remembers on reopen | n/a | n/a | Restores between previews | **N, jumps to top** |
| Wiki links / vault | Y, same folder only; backlinks | NL | NL | Y, nearest file; Mac/iOS | Native | NL | NL | NL | Y, renders links | NL | Y, walks up parent folders |
| Callouts | Y, Obsidian/Bear, foldable | NL | Y | NL | Y | NL | NL | NL | GitHub alerts | NL | N |
| Footnotes | Y + sidebar | NL | Y | Y | Y | NL | NL | Y, MMD mode | Y | NL | N |
| Frontmatter | Y, YAML/MMD/Pandoc | NL | Y | Y, as variables | Properties: show, hide, source | Jekyll | NL | NL | Optional table | NL | Hidden |
| RTL / Arabic | **Y, per element** | NL | Experimental, global CSS | NL | Global RTL setting | NL | NL | NL | NL | NL | **Y, per block** |
| Export | PDF, HTML, DOCX, EPUB, RTF, print | N (Pandoc commands) | PDF, HTML, Word, EPUB | PDF, DOCX, HTML, MD, print | PDF | HTML, PDF | PDF, HTML, DOCX (Pro) | n/a | CLI to HTML | n/a | N (print CSS, no command) |
| Quick Look extension | Separate app, $9.99 | Y | N | NL | Y (per help) | NL | NL | Y | Y | Y | N |
| Tabs | Y | NL | NL | NL | Y, split, stack | Y | NL | n/a | n/a | n/a | Y, native |
| Folder / sidebar | Folder watch (newest file) | NL | Y, file tree | Y, Library | Y | Y | Recents sidebar | n/a | n/a | n/a | N |
| Search across files | NL | NL | Y | Y | Y | NL | NL | n/a | n/a | n/a | N |
| Themes | 9 + custom CSS | CSS | 6 + CSS | Templates | Themes + CSS | Mou themes | Light/dark only | 9 + CSS | CSS | 70+ | One, follows system |
| Latest release seen | 3.2.18, 2026-10-08 | 1.36.0, 2026-09-23 (macOS 26+) | 1.14, 2026-07-19 | 8.0.9, 2026-09-25 | 1.11.7 local | 3000.0.7, 2026-07-13 | 1.3.0, 2026-10-05 | 1.0.24, 2026-10-07 | 1.5.7, 2026-10-02 | 2.6.4, 2022-04-02 | 1.2.1 |

### What this means for Satr

1. **Marked 3 is the reference reader, and its subscription is the opening.** It covers nearly every row, including per-element RTL detection, Obsidian callouts and a scroll-to-edit reload. It now costs $2.99 a month or $69.99 to unlock, and its wiki links only look in the current folder. A free, native, vault-aware reader with strong Arabic typography has room next to it.
2. **Satr's biggest daily bug is the reload jump.** `reader.js` calls `window.scrollTo({ top: 0, left: 0, behavior: "instant" })` after every render, and `DocumentWindowController.swift` reloads the whole page on each file change. Every save from Obsidian sends the reader back to the top. Marked keeps you at the edit and Peek restores scroll position, so readers in this category are expected to hold your place.
3. **Per-block RTL already puts Satr ahead.** Among the apps checked, only Marked 3 documents per-element RTL. Typora calls RTL "experimental" and flips the whole page with one CSS rule, and Obsidian has one global switch. 28.5% of Hatim's notes contain Arabic (measured, below), so this is the identity feature to protect and polish.
4. **The table-stakes gaps are math, code highlighting, find, callouts, footnotes and print/PDF.** Marked 3, Typora and Obsidian document all six, and iA Writer documents four. Satr has none. `reader.css` already contains `@media print` rules, so print is mostly wiring.
5. **Quick Look is a crowded, cheap category.** Free (QLMarkdown, MarkEdit, Obsidian) and paid ($1.99 to $9.99) options exist. If Satr ships a Quick Look extension it should come for free with the renderer, and it should not drive the roadmap.
6. **Read.md is the closest direct rival.** It is a reading-only app, free with a paid Pro tier, has an 87-rating average of 4.97, remembers your reading position, and supports Mermaid, TOC and search. Its top complaint is "configurable font ... is completely missing". A typographic identity built on the Thmanyah fonts answers that directly, within the license limits in the last section.
7. **Vault reality check.** On 2026-10-11 `~/vault` held 495 `.md` files, far fewer than the ~6,000 notes in the brief. Of 4,428 wikilinks outside code, 97.0% resolve under Satr's current walk-up rule, the same share as a name-anywhere rule. The other 3.0% point at missing files under both rules. The rules agree because a raw grep finds 5,343 path-style targets (`wiki/...`) against 61 bare names. 98.6% of notes have frontmatter, 23.8% have tables, 6.9% have language-tagged code fences, 2.4% have Mermaid, and fewer than 1% use callouts or block math. The largest file, `log.md`, is 730 KB, which makes it a performance test case. Source: `vault-profile-2026-10-11.txt`.

## Satr 1.2.1 today (from source)

Read from `Resources/reader.js`, `Resources/reader.html`, `Resources/reader.css`, `Sources/Satr/*.swift`, `Info.plist`, `README.md`.

- Version: `Info.plist` has `<string>1.2.1</string>` under `CFBundleShortVersionString`.
- Engine: AppKit windows with one `WKWebView` per document; marked 18.0.7, DOMPurify 3.4.12 and Mermaid 11.16.0 are inlined into the page by `Renderer.swift`. `README.md`: "These libraries are bundled so documents render offline."
- Privacy caveat, `README.md`: "Remote images and media referenced by a document load automatically".
- Mermaid: rendered with `securityLevel: "strict"` and a theme chosen from `prefers-color-scheme`. On failure the source is shown under "Diagram could not be rendered."
- Math, syntax highlighting, callouts, footnotes: no code for any of them. `Resources/vendor/` holds only `marked.js`, `mermaid.min.js`, `purify.min.js`. marked runs with `{ gfm: true, breaks: false }` and only the wikilink extension.
- Find: the Edit menu in `AppDelegate.swift` only adds "Copy" and "Select All".
- Outline: `buildDocumentThread` uses only `h2, h3`, hides itself when there are fewer than two headings, and shows titles only as button tooltips (`button.title`).
- Live reload: `MarkdownFilePresenter.presentedItemDidChange` schedules a reload after `0.18` seconds. `loadDocument` calls `webView.loadHTMLString`, and `render()` ends with `window.scrollTo({ top: 0, left: 0, behavior: "instant" })`. Scroll position is lost on every reload.
- Wiki links: `[[target|label]]` becomes `satr-wiki:`. `openWikiLink` appends `.md` when there is no extension, then checks the document folder and each parent folder up to `/`. `[[#Heading]]` scrolls within the page. `[[Note#Heading]]` opens the note but does not use the anchor. Embeds (`![[...]]`) are not handled.
- Frontmatter: `stripFrontmatter` removes a leading `---` block before parsing. `README.md`: "YAML frontmatter is hidden in reading view."
- RTL: `markDirection` sets `dir="auto"` on `p, li, blockquote, td, th, h1-h6`; plain text renders in `<pre class="plain-text" dir="auto">`; tables get `dir="auto"` frames; `reader.css` uses `unicode-bidi: plaintext`.
- Export: none. `reader.css` has an `@media print` block, but there is no Print menu item.
- Tabs: native window tabs (`tabbingMode = .preferred`, Merge All Windows, Move Tab to New Window).
- Themes: one light and one dark palette in `reader.css`, both following the system; text zoom from 0.7 to 1.8.
- No Quick Look extension, folder sidebar or cross-file search.

## Marked 3 (and Marked 2)

- Price, `marked-pricing.txt` lists Monthly, Yearly and Permanent Unlock with "Regular: $4.99" / "Intro: $2.99", "Regular: $49.99" / "Intro: $29.99", and "Regular: $89.99" / "Intro: $69.99", plus "Introductory pricing is available for a limited time." `appstore-marked3.txt`: "Marked Monthly Subscription $2.99", "Permanent Unlock $69.99", "Marked Yearly Subscription $29.99". Legacy Marked 2: site says "a one-time purchase of $14.99" while `appstore-marked2.txt` shows "$13.99 · In‑App Purchases". These two prices do not match.
- Positioning, `appstore-marked3.txt`: "Marked is a Markdown Preview application (NOT AN EDITOR)". Native: `marked-help/Live_Markdown_Preview_on_Mac.md`: "Marked 3 is a native macOS app that watches your Markdown files and updates a live preview as you save."
- Mermaid and offline: `marked-home.txt` lists "Mermaid included by default", while `marked-help/Settings_Style.md` says "Loads [mermaid.js](https://mermaid.js) from a CDN". These conflict. MathJax: "Choose **Local** (bundled) or **CDN**".
- Math: `marked-home.txt` "MathJax and KaTeX support".
- Code: `marked-help/Features_For_Coders.md` "recognize **256** language specifiers" and "**239** syntax highlighting themes".
- Find: `marked-help/Interface_Features.md` "The find bar can be accessed with `⌘F`", with "case sensitivity, whole words only and regular expressions".
- TOC: `marked-help/Document_Navigation.md` "Pressing `⌘T` also opens (or closes) the Table of Contents", plus a type-ahead filter, docking as a sidebar and a Mini Map.
- Reload and scroll: `marked-help/Settings_Preview.md` "Marked can determine the first point where the document changed and automatically scroll to it." `marked-help/Folder_Watching.md`: "Marked scrolls toward the detected edit region".
- Wiki links: `marked-help/Wiki_Navigation.md` "Marked will search for a matching file in the **same directory** as the current document." Backlinks are scanned from "the rest of the files in the directory". History: "**Back:** `⌘[`".
- Obsidian: `marked-help/Obsidian.md` "Drag the **vault folder** ... Marked watches that tree, keeps the **most recently edited** note in the preview". There is also an "Open in Marked" Obsidian plugin.
- Callouts: `marked-help/Special_Syntax.md` "Marked supports callouts with the syntax used by Obsidian and Bear". `appstore-marked3.txt` fix: "Obsidian callouts render as styled, collapsible callouts in Apex".
- Footnotes: `marked-home.txt` "Comment/Footnote sidebar".
- Frontmatter: `marked-home.txt` "Metadata support for MMD, YAML, and Pandoc"; `marked-help/Keyboard_Shortcuts.md` "Strip YAML".
- RTL: `marked-help/Settings_Style.md` setting "Detect and style RTL text", described as "Detect language per element in document and style Right To Left accordingly."
- Export: `marked-home.txt` "Export to PDF, HTML, DOCX and more"; also "New EPUB export" and "Export to PDF, HTML, RTF, and more".
- Tabs: `marked-home.txt` "Tabbed windows with Quick Open panel". Quick Open filters "Document filenames" and "Full file paths" of open and recent documents. Search across a folder: NL.
- Themes: `appstore-marked2.txt` "Marked comes with 9 preview styles built in (including GitHub), and you can add unlimited custom styles".
- Other: `marked-home.txt` "Ask questions about the current document using Apple Intelligence", "Speed Reading".
- Reviews, praise: `appstore-marked3.txt` "Developer is impressively responsive to feedback" and "A wild monopurpose app appears!". Complaint (Marked 2), `appstore-marked2.txt`: "no free trial to evaluate the tool" on the App Store.

## Marked QL (Quick Look)

- `marked-help/Quick_Look.md`: "Marked Quick Look is **not included with Marked 3**. It is a separate purchase (**$9.99** on the Mac App Store)."
- Rendering: "**Syntax highlighting**, **MathJax**, and **Mermaid** diagrams (bundled scripts; no network required)" and "nine built-in themes (GitHub by default) plus custom CSS import". Read-only, and file includes "are **not expanded**".
- Reviews, `appstore-markedql.txt`: "the navigation sidebar for headings is a genuinely useful touch". Complaints: "sidebar items take a couple of seconds to respond to clicks", and one user needed "QuickLookDoctor by the same author to get .md items to preview".

## MarkEdit

- `markedit-readme.md`: "MarkEdit is a free and **open-source** Markdown editor" with an installer of "about 4 MB". Badge: "Platform-macOS_26.0+". Older macOS builds are listed separately. `markedit-github-api.json`: license MIT.
- Engine, `markedit-wiki-why.md`: "We built the core editor with CodeMirror 6. We know what you're thinking: wow, that's not native!"
- Reading is out of scope by design: "MarkEdit doesn't even let you preview an entire Markdown document as HTML", with "popover previews" for "tables, embedded LaTeX formulas, and Mermaid diagrams".
- Full preview via the extension, `markedit-preview-readme.md`: modes "`edit`", "`side-by-side`", "`preview`", "`syntax-hidden`"; "Math and Mermaid rendering require the full build"; delimiters "for KaTeX rendering"; `"syncScroll": true`.
- TOC, `markedit-wiki-manual.md`: "⇧ ⌘ O to open the menu".
- Export: "MarkEdit doesn't support exporting Markdown files to formats such as PDF or Microsoft Word."
- Quick Look: "MarkEdit has a Quick Look extension that provides syntax highlighting for Markdown files in Finder"; with the preview extension "Quick Look can also render Markdown as HTML".
- Scope, `markedit-wiki-why.md`: "MarkEdit is not a note-taking app, a knowledge base, or your second brain."
- Wiki links, RTL, tabs, folders, cross-file search: NL. Not on the US Mac App Store under id1669953820 (`appstore-markedit.html` is an empty shell). The README points to GitHub releases and Homebrew.

## Typora

- Price, `typora-store.txt`: "$ 14.99(without tax)", "15 days free trial", "License can be used to activate at most 3 devices at one time", "one-time purchase, no subscription".
- Engine: `typora-support/Acknowledgement.txt` lists "Electron" under third-party licenses. The page does not say which platforms use it. `typora-support/Typora-on-macOS.txt`: "deeply integrated with the macOS desktop environment, like other native apps on macOS." The macOS shell type is unverified.
- Reader framing, `typora-home.txt`: "Typora — simple yet powerful Markdown reader." and "Typora gives you a seamless experience as both a reader and a writer."
- Mermaid, `typora-home.txt`: "Generation of flowchart, sequence, gantt and more by mermaid engine." Math, `typora-support/Math.txt`: "The rendering process is processed by MathJax." Code: "around 100 languages".
- Find and search, `typora-support/Search.txt`: "command + F ... to toggle Find panel"; "File Search (Search across files)"; "Open Quickly".
- Outline: `typora-support/Outline.txt` "Show / Hide Outline Panel"; `typora-home.txt` "Type `[TOC]` to insert table of contents".
- Folders, `typora-support/File-Management.txt`: "Files Sidebar"; "Typora will watch for file changes in the opened folder, and the file tree / list will be updated". Reloading an open document on external change: NL.
- Callouts and footnotes, `typora-support/Markdown-Reference.txt`: "Callouts / Github Style Alerts", "Footnotes". Frontmatter: `typora-support/YAML.txt`. Themes: "Typora has 6 built-in themes".
- RTL, `typora-support/RTL.txt`: "RTL (Right-to-Left) Support (experimental)", "This is not fully tested, since I’m not a RTL user". The fix is a custom CSS rule that sets `direction: rtl` on `#write`, which flips the whole document.
- Export, `typora-support/Export.txt`: "HTML", "PDF", "Word (.docx)", "Epub", "Export Using Pandoc".
- Quick Look, `typora-support/Typora-on-macOS.txt`: "Typora does not provide a quick look plugin for now but you can use QLMarkdown or Glance".
- Wiki links: NL (zero matches for "wiki" in `Links.txt` and `Markdown-Reference.txt`). Not on the Mac App Store, so no App Store reviews.

## iA Writer

- Price, `iawriter/pricing.txt`: Mac "$49.99", "One-Time ≠ Lifetime", "major updates may incur costs", "7-Day Free Trial". Native: `iawriter/basics_features.txt` "we develop native apps for different platforms".
- Reading model, `iawriter-home.txt`: "Write in plain text with Markdown. Switch to Preview to see it styled."
- Math, `iawriter/basics_markdown-guide.txt`: "typeset using KaTeX". Footnotes: "Add a footnote in square brackets preceded by a caret." Mermaid: NL. Code syntax highlighting: NL (its "Syntax Highlight" marks parts of speech).
- Wiki links, `iawriter/library_wikilinks.txt`: "In iA Writer for Mac, iPhone and iPad, Wikilinks make it easy to connect"; "iA Writer finds the nearest file that matches the given name"; "[[Location: link]]"; "Wikilinks are exported and published as regular text".
- Outline: `itunes-desc-775737590.txt` "Document Outline: navigate your documents using Quick Search. Type to jump to any heading, filename, or text search result." `iawriter/library_navigate-big-documents.txt`: "Exclusively on iA Writer for Windows: Dynamic Outline and Folding".
- Cross-file search: `iawriter/basics_features.txt` "Global Document Search" is ticked for iPhone/iPad and Mac.
- Frontmatter, `iawriter/editor_metadata.txt`: "Metadata must be separated from the rest of the document by three dashes".
- Export, `iawriter/preview_export-share-print.txt`: "PDF | .pdf", "MS Word | .docx", "HTML | .html", "Markdown | .md", "Project Archive | .zip".
- RTL, Quick Look, tabs, live reload: NL. Language tables list En, De, Jp, Fr, Es, It, Ru, Cn, Kr, Pt; Arabic: NL.
- Reviews, `appstore-iawriter.txt`, praise: "I have never used a more elegant writing app." Complaint: "lately it’s become frustratingly slow on the Mac" and "the only app I see the dreaded spinning beachball with".

## Obsidian reading view

- Price, `obsidian-pricing.txt`: "Free without limits." Sync "$4" "USD" "Per user, per month, billed annually". `obsidian-license.txt`: "Obsidian is free for all purposes, including personal, commercial, and non-profit use."
- Engine: `obsidian-help/all/Obsidian__Credits.md` heading "### Electron" followed by "Version `43.1.1`". `obsidian-local-app-listing.txt` shows "Electron Framework.framework" in the installed 1.11.7.
- Reading view, `obsidian-help/all/Editing_and_formatting__Views_and_editing_mode.md`: "*Reading view* shows your note without Markdown syntax".
- Mermaid, math, code (Advanced and Basic formatting syntax): "using [Mermaid]", "using [MathJax]", "Obsidian uses Prism for syntax highlighting."
- Callouts: "add `[!info]` to the first line of a blockquote"; "Foldable callouts". Footnotes: "## Footnotes".
- Frontmatter, `..._Properties.md`: "**Visible** (default)", "**Hidden**", "**Source** – displays properties in plain text YAML format."
- RTL, `obsidian-help/all/User_interface__Settings.md`: "Sets the default text direction of notes to right-to-left." This is one global setting.
- Reload, `..._How_Obsidian_stores_data.md`: "Obsidian automatically refreshes your vault to keep up with any external changes."
- Export, `..._PDFs.md`: "select **Export to PDF...**", and "Exports always use light styling, even if your theme is dark."
- Quick Look, `..._Manage_notes.md`: "Quick Look previews work even when Obsidian is closed." The locally installed 1.11.7 has no `PlugIns` folder, so this likely arrived in a later version (unverified).
- Tabs, search, outline, file explorer: separate help pages (`User_interface__Tabs.md`, `Plugins__Search.md`, `Plugins__Outline.md`, `Plugins__File_explorer.md`). Not on the Mac App Store.

## MacDown and MacDown 3000

- Original MacDown is dormant. `macdown-github-latest-release.json`: latest "v0.7.3" published "2020-01-03"; repo last pushed "2023-07-10".
- `macdown-features.txt`: "Hoedown is used internally", "TeX-like math syntax", "Jekyll front-matter", "rendered by Prism". `macdown-github-releases.json` (v0.7): "Math support is now provided via CDNJS", so math needed a network. A dev build lists "Upgrade Mermaid".
- MacDown 3000 continues it, `macdown3000-readme.md`: "MacDown 3000 is essentially *MacDown Continued*"; "**Export to HTML or PDF**"; "A sidebar lists subfolders and Markdown files"; "open it as a tab in the same window". Latest "v3000.0.7" on "2026-07-13".
- Wiki links, callouts, RTL, Quick Look: NL.

## Read.md

- `itunes-desc-6760943472.txt`: "Read.md is a markdown reader. Not an editor, not a note-taking app, not a vault system. A reader." Rating: "averageUserRating: 4.96552", "userRatingCount: 87". Minimum macOS "15.0".
- Price: `appstore-readmd.txt` "Read.md Pro Yearly $9.99", "Read.md Pro (Lifetime) $24.99"; `readmd-home.txt` "Native on Mac — instant, offline, built for macOS."
- Features: "Syntax highlighting for 180+ programming languages", "MERMAID DIAGRAMS", "Auto-generated table of contents", "Search within any document with match highlighting", "Your scroll position is remembered when you come back to a file", export "Word (.docx)", "PDF", "self-contained HTML" (Pro).
- Privacy note: "We use anonymous, aggregate analytics".
- Reviews, praise: "it even keeps track of where I was within the document". Complaints: "configurable font to be a very basic thing for a text reader, but this is completely missing" and "trying to open it immediately crashes the app" for moved files in Recents.

## QLMarkdown, Peek and other Quick Look options

- QLMarkdown, `qlmarkdown-readme.md`: "**This application is not intended to be used as a standalone markdown file editor or viewer.**" Extensions: "`GitHub alert`", "`Math`", "`Mermaid`", "`Wikilinks`", "`YAML header`", "Table of contents", "Footnotes". Offline: libraries come "from the web (internet connection required) via `cdn.jsdelivr.net`, or to embed the source code directly". Install: "brew install --cask qlmarkdown". License GPL-3.0, latest 1.5.7 on 2026-10-02 (`qlmarkdown-*.json`).
- Peek, `itunes-desc-1554235898.txt`: $7.99; "Lazy syntax highlighting, MathJax typesetting, and Mermaid.js diagramming"; "Save and restore scroll positions"; "over 70 different light & dark themes"; "optionally generated table of contents". Last update 2.6.4 on 2022-04-02. Its site was unreachable on the read date (`peek-home-unreachable.txt`). Review: "Syntax highlighting for quick look is a must-have, but I don't feel good paying $8 USD for it."
- PreviewMarkdown, `itunes-desc-1492280469.txt`: $2.99, "QuickLook file previews and file icon thumbnails"; `previewmarkdown-home.txt`: "will optionally preview YAML front matter". Images are limited: "only to the previewed file itself".
- Glance, `glance-readme.md`: "Glance blocks remote assets" and "Local image files referenced from Markdown are therefore not loaded."
- Newer paid entrants seen in `itunes-search-markdown-quick-look.json`: "Markdown Quick Look" $4.99, "Markdown Preview - Quick Look" $1.99.

## Thmanyah font license

### Official source

- Official site: `https://font.thmanyah.com/` (`thmanyah/font.thmanyah.com.html`). The FAQ says the font is free: "نعم، الخط متاح مجانًا. سواء للاستخدام الشخصي، أو في المشاريع والأعمال التجارية المختلفة، من الطباعة أو الهوية البصرية أو واجهات المواقع والتطبيقات."
- License pages: Arabic `https://font.thmanyah.com/licenses` (`thmanyah/font.thmanyah.com_licenses.txt`), English `https://font.thmanyah.com/licenses-en` (`thmanyah/font.thmanyah.com_licenses-en.txt`). The Arabic text governs: "In the event this license is translated into another language, the Arabic version shall prevail."
- No public repository or open-source license (such as OFL) was found. The license is a custom proprietary one.

### Exact terms that decide the questions (English page, Arabic page agrees)

> PERMITTED USES
> You are granted a non-exclusive, non-transferable license to:
> Use the Font Software for personal projects.
> Use the Font Software commercially in logos, branding, websites, applications, printed materials, and any other design work.
> Embed the Font Software in documents, applications, or products you create.
> Embed the Font Software in websites, web applications, mobile applications, or software products only as part of a compiled, packaged, or obfuscated product.

> PROHIBITED ACTIONS
> You may NOT:
> Sell, resell, rent, lease, or sublicense the Font Software by itself or as a standalone product.
> Redistribute, share, upload, host, or make the Font Software available for download on any website, server, digital platform, or file-sharing service. The Font Software may only be downloaded from the official thmanyah website (font.thmanyah.com) and used on your own devices and projects.
> Make the Font Software available in any manner that allows end users or third parties to extract, download, access, reuse, or redistribute the Font Software independently as font files, including through web embedding, applications, or software products.
> Modify, edit, adapt, translate, or reverse-engineer the Font Software in any way.

Arabic, governing (`font.thmanyah.com_licenses.txt`):

> إعادة توزيع برنامج الخط أو مشاركته أو رفعه أو استضافته أو إتاحته للتنزيل على أي موقع إلكتروني أو خادم أو منصة رقمية أو خدمة مشاركة ملفات.

> إتاحة برنامج الخط بأي طريقة تُمكّن المستخدمين النهائيين أو الأطراف الثالثة من استخراج برنامج الخط أو تنزيله أو الوصول إليه أو إعادة استخدامه أو إعادة توزيعه بشكل مستقل كملفات خطوط، بما في ذلك عبر التضمين على الويب أو التطبيقات أو المنتجات البرمجية.

> ولتجنب الشك، يُعد أي استخدام لبرمجية الخط لم يرد نص صريح في هذا الترخيص يجيزه استخدامًا مخالفًا

Exceptions: "For license exceptions, extended rights, or customized use cases not expressly stated in this License, please contact the Company at: ask@thmanyah.com." Changes count only in writing: "No amendment to, or exception from, this License is effective unless made in writing and issued by the Company."

### What the font files say (inspected read-only)

Tools: `fc-scan` (present) and a standard-library parser of the `name` and `OS/2` tables, run with `python3 -I`. fontTools and otfinfo are not installed. Outputs: `fonts-fc-scan.txt`, `fonts-name-table.txt`, `fonts-license-nameid13-full.txt`, `fonts-sha256.txt`.

- All four files (`thmanyahsans-Regular`, `thmanyahsans-Medium`, `thmanyahserifdisplay-Light`, `thmanyahserifdisplay-Regular`) are CFF OpenType ("OTTO"), "Version 1.003", with identical license strings (same hash).
- nameID 0 (copyright): "thmanyah LLC". nameID 7 (trademark): "thmanyah". nameID 14 (license URL): "https://company.thmanyah.com/". This is the company home page. The license itself lives at font.thmanyah.com.
- nameID 13 (license) embeds the full Arabic and English license, the same text as the web pages, including "Embed the Font Software in websites, web applications, mobile applications, or software products only as part of a compiled, packaged, or obfuscated product."
- Small differences from the web: the file says "Copyright © 2026" where the web says "Copyright © 2016". The file's English text names the download site as "(https://thmanyah.com)" and its Arabic text as "(https://font.thmanyah.com)"; the web says "font.thmanyah.com".
- OS/2 `fsType=0x0000` (installable embedding) on all four files. This is a technical flag only. The license text is narrower and controls.
- `fc-scan` reports script support "otlayout:arab otlayout:grek otlayout:latn". The official site lists three families (Serif Display, Serif Text, Sans) with "5 أوزان" each. Hatim has 4 of the 15 files.

### Verdicts

| Question | Answer | Confidence |
|---|---|---|
| Commit the .otf files to a PUBLIC GitHub repository? | **No.** A public repo makes the files "available for download on any website, server, digital platform", and the license allows download only "from the official thmanyah website". | **stated** |
| Bundle the raw .otf files inside Satr.app? | **Not as plain files.** A standard `.app` keeps them readable in `Contents/Resources`, which lets "end users or third parties ... extract ... the Font Software independently as font files". | **high** |
| Bundle in a form that cannot be extracted (font data encrypted or obfuscated inside the binary, registered in memory at launch)? | Probably allowed under "only as part of a compiled, packaged, or obfuscated product". The license does not define how strong the obfuscation must be. | **medium** |
| Use the fonts for Hatim's own copy only, installed from font.thmanyah.com, with Satr referencing them by family name and falling back to system fonts? | **Yes.** The license allows use "on your own devices and projects" and "for personal projects". The public repo then contains no font files. | **high** |
| Embed the fonts in exported HTML (base64 `@font-face` or files beside the HTML)? | **No.** Anyone opening the HTML can extract the font, which the license prohibits "including through web embedding". Exported HTML should name the families with fallbacks. | **high** |
| Embed the fonts in exported PDF? | **Likely yes, with subsetting**, under "Embed the Font Software in documents ... you create". Two open points: PDF fonts can be pulled out with tools, and the license is "non-transferable", so other Satr users would need their own download. | **medium** |
| Ship Satr to other people with the Thmanyah look? | Only with a written exception from ask@thmanyah.com, or with the obfuscated route above. The license says exceptions take effect only when "made in writing and issued by the Company". | **high** that written permission removes the doubt |

Adjacent risk (outside this lane, flagged for Hatim): the source fonts sit in `~/Desktop/Loom/loom-site/web/public/fonts/`. A `public/` folder is normally served as-is to every visitor, which fits the prohibited "web embedding" that lets users download "font files". Confidence **high** if that folder is deployed to loom.seet.cloud. I did not check the deployment or the repo's visibility.

## Sources (all read 2026-10-11)

| Saved file(s) in `raw/` | URL or origin |
|---|---|
| `itunes-search-*.json`, `itunes-lookup-*.json`, `itunes-desc-*.txt` | `https://itunes.apple.com/search` and `/lookup` (country=us, entity=macSoftware) |
| `appstore-marked2.*`, `appstore-marked3.*`, `appstore-markedql.*`, `appstore-iawriter.*`, `appstore-peek.*`, `appstore-previewmarkdown.*`, `appstore-readmd.*`, `appstore-markedit.html` | `https://apps.apple.com/us/app/...` (ids 890031187, 6747497179, 6787414592, 775737590, 1554235898, 1492280469, 6760943472, 1669953820) |
| `marked-home.*`, `marked-pricing.*`, `marked-markdown-preview.*`, `marked-help-index.*`, `marked-help/*.md` | `https://markedapp.com/`, `/pricing/`, `/markdown-preview/`, `/help/`, `/help/md/<Page>.md` |
| `markedit-readme.md`, `markedit-wiki-manual.md`, `markedit-wiki-why.md`, `markedit-preview-readme.md`, `markedit-github.*`, `markedit-extensions.html`, `markedit-*.json` | `raw.githubusercontent.com/MarkEdit-app/...`, GitHub wiki raw, `api.github.com/repos/MarkEdit-app/MarkEdit` |
| `typora-home.*`, `typora-store.*`, `typora-support-index.html`, `typora-support/*` | `https://typora.io/`, `https://store.typora.io/`, `https://support.typora.io/<Page>/` |
| `iawriter-home.*`, `iawriter/*` | `https://ia.net/writer`, `/writer/pricing`, `/writer/support/...` |
| `obsidian-pricing.*`, `obsidian-license.*`, `obsidian-help-tree.json`, `obsidian-help/*`, `obsidian-help/all/*`, `obsidian-local-app-listing.txt` | `https://obsidian.md/pricing`, `/license`, `raw.githubusercontent.com/obsidianmd/obsidian-help/master/en/...`, local `ls` of `/Applications/Obsidian.app` |
| `macdown-home.*`, `macdown-features.*`, `macdown-readme.md`, `macdown-github-*.json`, `macdown3000-readme.md`, `macdown3000-*.json` | `https://macdown.uranusjr.com/`, GitHub MacDownApp/macdown and schuyler/macdown3000 |
| `readmd-home.*` | `https://read-md.app` |
| `qlmarkdown-readme.md`, `qlmarkdown-*.json`, `glance-readme.md`, `previewmarkdown-home.*`, `peek-home-unreachable.txt` | GitHub sbarex/QLMarkdown, chamburr/glance, `https://smittytone.net/previewmarkdown/`, `https://www.bigzlabs.com/peek` (no response) |
| `thmanyah/*` | `https://font.thmanyah.com/`, `/licenses`, `/licenses-en`, `https://company.thmanyah.com/` (thmanyah.com returned HTTP 429) |
| `fonts-*.txt` | Local font files in `~/Desktop/Loom/loom-site/web/public/fonts/`, inspected read-only |
| `vault-profile-2026-10-11.txt` | Read-only scan of `~/vault` (script kept in the session scratchpad, not in the repo) |
