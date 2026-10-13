# Linen PRD v0.2: round 2, fresh review

Counts come from scripts over `~/vault` (495 notes); type figures from CoreText on the installed fonts.

## Major

1. **Measure (READ-1, section 8).** Thmanyah Sans at 17 px averages 7.8 px per English character, so the 720 px column carries about 92 characters a line. Comfortable reading is 60 to 75. Fix: prose at 34em (about 74 characters, scaling with text size); headings, tables, code and diagrams keep 720 plus the wings; declare the departure.

2. **The top of a vault note (REN-6, READ-7, REN-14).** 210 notes have no h1, 478 open with the "For future Claude" h2, and in 275 the h1 follows it: the 40 px title rarely starts the page and the preamble heads nearly every outline. The strip shows on 488 notes with five tags at the median and up to 13 (142 characters), and it shows one date while the footer shows another. Fix: one note header: a Loom eyebrow (type, status, one date), the title (first h1, else the file name, as Obsidian's inline title does), then the preamble collapsed to one line at launch. Tags move to Properties.

3. **Night disagrees with itself and with Ferry (LOOK-1, 8, 8.1).** LOOK-1 says quiet text is sage, as Ferry does; section 8 says paper at 72 percent, rules at 12 percent, failures as paper text with a rust rule; Ferry uses 14 percent lines and paper text on a rust fill; 8.1 says Ferry's derivation is reused as is. Fix: write the suite's Night once in 8.1 from Ferry's values and lint Linen against Ferry's `Tokens.swift` too.

4. **Fonts have three answers (9, 11, Appendix A, spike S(f)).** The body says installed families only, no font file in repository or bundle; Appendix A says they are copied in at build time; S(f) tested bundled `@font-face`. Fifteen Thmanyah `.otf` files sit untracked in `Sources/Satr` of a public repository, and `.gitignore` does not exclude them. Fix: choose installed families, state it once, test Quick Look with them, move the files out, ignore `*.otf`.

5. **Height changes above the reader (REN-4, REN-7, PERF-3, principle 2).** Lazy Mermaid and late images change heights, so after an outline jump, scrolling up shoves the page. LIVE-4 covers reloads only, and WebKit's scroll anchoring cannot be relied on. The 50 MB cap still admits a 12,000 px image that decodes past 500 MB. Fix: the local handler returns pixel size before loading and downsamples past twice the column width; diagram heights are cached by source hash and estimated before first render; height changes above the anchor block are compensated in the same frame.

6. **Tables (READ-1, READ-4, EXP-1).** No size is set, so tables run at 17 px. This PRD has eight-column tables. At the default 1180 pt window with the outline open, 960 pt remain: the column plus both wings, with no padding. Fix: tables at 15 (Loom's body size), horizontal scroll inside the block with a faded edge, a sticky header on tables taller than the screen, scaling to page width in print, and centre the column in the pane beside the rail.

7. **File access off the happy path (LIVE-1, OPEN-2, VAULT-4, question 5).** TCC guards Desktop, Documents, Downloads, iCloud Drive and network volumes even unsandboxed: watching `~/Desktop/ferry/docs` and walking up for `.git` prompt, and the new bundle identifier resets grants, so the first launch restores ten tabs behind prompts. Reading an undownloaded iCloud file blocks until it downloads; indexing an evicted vault downloads all of it. Network volumes send no vnode events for remote writes. Fix: list expected prompts and a denied state with Open System Settings; skip dataless files and mark links to them "Not downloaded"; poll non-local volumes every 2 s; distinct unreadable and disconnected states.

8. **Copy Reference hands agents the wrong text (READ-6, EXP-2).** It quotes rendered text, but agents edit source: a rendered "Ferry" never matches the wiki link in an Edit call. Vault-relative paths mean nothing to an agent in another repo. Ranges are per top-level block, so a sentence in a 40-line list cites 40 lines; nothing tests ranges after frontmatter, a BOM or CRLF. Fix: quote source lines; repo-relative path inside git, `~/` elsewhere; narrow to list items and table rows; line-mapping fixtures shared with EXP-2 and OPEN-3.

9. **Tests that check the code against itself (13, M4, M5).** "Direction matching its letter majority" and "markers on one side" restate ARB-1; "Linked from agrees with the index" compares a view with its source. Fix: direction against hand-labelled fixtures, including the 29 notes with English lines starting in Arabic; Linked from against Obsidian's `resolvedLinks` inverted.

10. **Dollar amounts as math (REN-5).** 31 lines in 14 vault notes hold two dollar amounts, as does this PRD's section 0, and the corpus check only finds math left unrendered. Fix: write the delimiter rule (no space after the opening `$`, none before the closing one, no digit after it), add price lines as fixtures, check KaTeX node counts per note.

11. **Memory counts one tab (section 4, PERF-1).** A page per window likely means a WebContent process per tab; daily use is ten tabs and the 180 MB target covers one. Nothing says when background tabs build. Fix: build on first selection, a ten-tab memory target, unload idle tabs.

## Minor

12. **OPEN-6, LIVE-2.** A read cut inside an Arabic character fails strict UTF-8 and may be detected as Windows-1252. Detect on first open only; on reload a UTF-8 file stays UTF-8 and a failure counts as an unstable read.

13. **LIVE-5.** A note rewritten since last read marks every block; past half changed, show one line ("Rewritten since you read it on 3 October"). Marks never print or show in Present. No test covers clearing or persistence.

14. **Undeclared departures (8).** h3 is Sans 500 though Loom's card title is serif 300; popovers are solid where Loom's panels are glass; the rail is 220 against Loom's 272; callout small caps are not in Loom and Thmanyah Sans has none, so WebKit fakes them: use the eyebrow.

15. **REN-3, READ-3.** Ink and ink-2 differ by 1.3:1, so weight alone marks keywords; strings on tint-1 reuse the inline-code colour and box every JSON value: drop the wash. Find's match colours are unset.

16. **ARB-2.** Thmanyah's alef stands 0.74 em against a 0.70 em cap height, so size-adjust needs a measured basis before M4. Heading line heights of 1.15 to 1.4 will crowd vocalised Arabic. Arabic labels drop tracking.

17. **READ-8.** "Snap to a heading that is near" makes steps uneven: snap only when a heading sits in the bottom fifth. Say what Present hides.

18. **TAB-1, READ-4, READ-5.** A tab bar on single windows adds a chrome row repeating the title: show it from two tabs. With one page per window, WKWebView's swipe never fires; the custom one must not trigger from a table scrolled to its edge.

19. **VAULT-1, SAFE-2.** A repo inside a vault gets vault-relative references. Refuse the home folder or a volume root as a vault. Treat symlinked folders inside a vault as inside.

20. **OPEN-3, QL-1.** A grown file should open at its first added block, so a new review round reads from its start. The extension's `network.client` contradicts SAFE-1; remove and test.

21. **Sections 3, 12.** Spikes (e) and (f) have answers but are listed open. 143 of 495 is 28.9 percent; section 3 says 28.5.

22. **Sections 4, 13.** Twenty cold launches after login will not be run on a Mac in daily use: use five after restart. "Stalls over 100 ms" permits visible hitches: no frame over 33 ms in a scripted scroll. Missing tests: WebContent crash recovery, Quick Look's 120 MB, the 9 MB bundle, the token lint, the missing-font state.
