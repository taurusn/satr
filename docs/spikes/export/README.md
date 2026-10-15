# Spikes X(a) and X(b): PDFs with Arabic you can search

**Question.** Can Linen export a board (X(a)) and a paginated note (X(b)) as vector PDFs that look like Thmanyah, carry no Thmanyah font data, and give back every word to search, selection and copy, Arabic included?

**Answer: yes, both pass their gates** (PRD-2 section 12), with one limit in how PDFKit reads some mixed lines (below). The code that passed is the export module itself (`Linen/Export/`), not a throwaway: the spikes drive it.

Run 2026-10-15 on a MacBook Air M4, macOS 26.5.1, release builds of the harnesses (`swiftc -O`).

```sh
swiftc -O -swift-version 6 -parse-as-library -o build/xa docs/spikes/export/xa.swift Linen/Export/DisplayList.swift \
  Linen/Export/OutlineText.swift Linen/Export/BoardPDF.swift Linen/Export/PDFCompact.swift -framework AppKit -framework PDFKit
./build/xa build/export-out 500
swiftc -O -swift-version 6 -parse-as-library -o build/xb docs/spikes/export/xb.swift Linen/Export/DisplayList.swift \
  Linen/Export/OutlineText.swift Linen/Export/BoardPDF.swift Linen/Export/PDFCompact.swift Linen/Export/NotePDF.swift \
  -framework AppKit -framework PDFKit -framework WebKit
./build/xb build/export-out
```

## How the text is drawn (`OutlineText`)

- **Visible layer:** every glyph as its outline (`CTFontCreatePathForGlyph`), so the page looks like Thmanyah and no Thmanyah font enters the file. Each distinct outline is drawn once into a `CGLayer`, which Quartz writes as one vector form and reuses. Measured on 57,600 glyph draws: paths 8.7 MB, paths rounded to 0.01 pt 8.2 MB, a one-glyph PDF page drawn per glyph 8.7 MB (Quartz inlines it), layers 2.6 MB.
- **Invisible layer:** the same line typeset again in faces whose glyphs map back to text (Geeza Pro for Arabic script, Helvetica for the rest), drawn in invisible mode. What worked, after three that did not:

| Way of drawing the invisible line | PDFKit reads an Arabic line | Mixed Arabic and English line | Inside an Arabic word |
|---|---|---|---|
| each word its own `CTLine` | backwards, one word per line | broken at each direction change | fine |
| the whole line as one run, glyphs moved onto the visible words | in order | in order | spaces appear ("لي نن"): the visible word is wider than Geeza's, the gaps read as spaces |
| one call per run, scaled by the run's average width | in order | in order | one stray space left ("الما ك") |
| **one `CTFontDrawGlyphs` call per word, each scaled to its visible word, spaces at the gaps** | **in order** | **in order** | **whole** |

  The line's direction must be the paragraph's, passed in by the caller: guessing it from the first visual run read a mixed right-to-left line as left to right and broke its copy.
- **Glyphs with no outline:** spaces are skipped; a colour emoji is the one glyph drawn as a font (an early version drew Thmanyah's space glyph as text and so embedded a Thmanyah subset).
- **File size:** drawing a layer makes Quartz reserve object numbers it never writes: the 500-node board listed 137,276 cross-reference entries (2.7 MB) for 810 objects. `PDFCompact` renumbers the objects and rewrites the table (dictionaries only, never stream bytes; anything unfamiliar keeps the original file), and the result is kept only if it reads back with every page.

## X(a): a 500-node board

A synthetic display list shaped like an agent's readiness map (the renderer's `displayList` command hands over the same shape, `Linen/Export/DisplayList.swift`): 10 sections of 50 cards, serif titles and wrapped sans bodies, a fifth of them Arabic, a status pill on each card (outline, hatched, rust, dashed, dotted), curved connectors with labels, 125 numbered notes. 4,532 items, 2,678 text lines, 643 KB of JSON (parsed in 10 ms).

| | Gate | Whole board | Sections (A4) |
|---|---|---|---|
| Time | under 3 s | **0.63 s** | **0.77 s** |
| Size | under 5 MB | **2.67 MB** (1 board page plus 12 pages of sources) | **3.26 MB** (108 pages; this board's cards stand in staggered columns, so few cuts avoid a card and pages run short; the renderer's row-aligned `big-500` below takes 70) |
| Lines read back by PDFKit, logical order, diacritics ignored | every one | **450 of 450** (Arabic 20 of 20, mixed 2 of 2) | **450 of 450** |
| Test words (`findString`, including لينن and الوكلاء) | every one | every one, each at least as often as it appears on the board | same |
| Selection boxes against the visible glyphs, 12 words | within 2 pt | **0.02 pt** horizontally; vertical centre 1.4 pt (Geeza Pro is taller than Thmanyah) | |
| Whole lines selected by their box and copied | in order | **4 of 4** (Arabic, mixed, English, serif title) | |
| Thmanyah font data (`pdffonts`) | none | **none** (Helvetica and Geeza Pro only) | **none** |
| Images (`pdfimages`) | none larger than the inputs | **0** | **0** |
| `pdfinfo` | | no errors | no errors |

At 2,000 nodes (BRD-20's cap): whole board 2.6 s and 10.5 MB, sections 3.1 s and 10.7 MB, every one of 1,605 lines read back. The board is 43,122 px tall, so the whole-board page scales to fit 14,400 pt (EXP-5); its body then prints near 5 pt, which is what Sections is for.

**Not checked:** Chrome's PDF viewer. Driving Chrome headless with its viewer's search, without a prompt, was not set up tonight; Preview's engine (PDFKit) is what the checks use. Acrobat untested.

**Seen while checking the look** (`build/export-out/xa-*.png`): Thmanyah Serif Display Light draws its hyphen as a hairline (2/100 em), so "sign-on" in a 19 px title reads as "sign on" at a glance; WebKit draws it the same.

## X(b): a paginated note

A 9-page note (18 sections of mixed Arabic and English paragraphs, bold and slanted text, inline code, lists, a code block with an Arabic comment, a table, a callout, a blockquote, footnotes) rendered by Linen's own renderer (`Renderer/page.html`) in an offscreen web view at A4's content width, with `mediaType = "print"`.

**How `NotePDF` works.** A script in its own content world measures every text node (per word, `Range.getClientRects`), groups words into lines, measures each font's baseline in the page with a zero-size inline block, records what must not be split (lines, code blocks, table rows, figures) and the headings, then wraps each text node in a `visibility: hidden` span. Linen paginates between lines and blocks (never right under a heading), asks WebKit for one vector slice per page (`createPDF` with a rect, in document coordinates; hidden text leaves no text in it), draws the slice on the page and draws every line over it from the DOM's boxes with `OutlineText`. A line that falls back to a second face (Arabic inside code) is placed word by word, with one invisible layer for the whole line.

**Alignment** was measured against a reference export with the same page breaks in which WebKit draws its own text: both rasterised at 4x and each line's ink compared.

| | Gate | Result |
|---|---|---|
| Lines aligned | within 0.5 pt | **469 of 476 lines** within 0.5 pt at the ink edges (vertical: every line within 0.25 pt; horizontal p95 0.50 pt); **471 of 476** by ink centre. The rest: the code line with Arabic (1.75 pt, SF Arabic as Core Text picks it is not WebKit's width) and a footnote line ending in Arabic (0.75 pt) |
| Time, size | | 0.30 s, 647 KB for 9 pages (WebKit's own export of the same note: 1.47 MB, with Thmanyah embedded) |
| Test words | every one | every one found (Arabic ligature words included) |
| Selection boxes against WebKit's word boxes, 10 words | within 2 pt | horizontal **1.02 pt** worst, vertical centre **1.89 pt** worst |
| Mixed line copied by its box | in order | **exact** |
| Thmanyah font data | none | **none** (Helvetica, Geeza Pro, SF Mono spaces from code, Lucida Grande for one symbol) |

Three things this spike had to find:
1. **Page breaks on whole pixels.** WebKit snaps each slice's text to the slice's own pixel grid; breaks on half pixels put every line 0.25 to 1 pt off (233 of 461 lines within 0.5 pt). On whole pixels: 451 of 455.
2. **The baseline from the page, not from metrics.** Rounding Core Text's ascent left lines up to 2 pt off; the per-font probe in the page is exact.
3. **Leave white space to WebKit.** Wrapping white-space-only text nodes in hidden spans changed the layout (the last page drifted by up to 10 pt), so they stay as they are; in code they embed SF Mono for spaces, which carries no text worth reading and no Thmanyah.

Also measured: Core Graphics draws font text about 15 percent darker than the same glyphs as paths (font smoothing) and one 4x pixel taller, which is why ink centres are the fairer measure.

**The limit: how PDFKit chooses a line's direction.** PDFKit reads a line as right to left when its rightmost letter is Arabic, whatever the paragraph's direction. So a left-to-right line that ends in Arabic comes back with its neutrals moved: "The footnote text, with Arabic: الوكلاء." reads as ".الوكلاء :The footnote text, with Arabic"; a code comment "// a comment: تعليق بالعربية" reads as "تعليق بالعربية :a comment //". Every word is still found and selected; 16 of 455 lines are affected in this note. A direction mark at the start or end of the invisible line changed nothing. Nine of the sixteen are an Arabic list item inside an English list, which the renderer lays out left to right (no per-item direction), so even the page shows its period at the wrong end: a renderer fix, not an export one.

## From the real renderer (`real.swift`)

The same export from `Renderer/board.js`'s own `displayList` on the board fixtures (`Tests/Fixtures/boards/`), loaded into Linen's renderer offscreen. Cards clip their text as the reader does (`.b-node` hides overflow), so text a card hides is neither drawn nor searchable.

| Fixture | Display list | Whole board | Sections (A4) |
|---|---|---|---|
| `big-500` | 3,924 items, 2,467 text runs, 10 sections, 108 notes, built in 0.26 s | 0.49 s, 2.0 MB, 12 pages; 2,467 of 2,467 runs read back | 0.60 s, 2.5 MB, 70 pages; 2,467 of 2,467 |
| `big-2000` | 15,729 items, 9,732 runs, 40 sections, 432 notes, built in 0.96 s | 1.84 s, 7.4 MB | 3.05 s, 9.3 MB, 276 pages |
| `arabic-rtl`, `kinds`, `connectors`, `colours`, `sections-nested`, `notes-sidecar`, `words-custom` | | every run read back | every run read back, except "State متوقف" in `words-custom` (the PDFKit direction limit above) |

No file holds Thmanyah; `pdfinfo` reports no errors on any. Sections: each top-level section on its own pages in whichever orientation needs fewer pages at the 9 pt floor (taken from the section's smallest box text, not assumed 15 px), nested sections inside their parent, and boxes outside every section on pages of their own; cuts fall at the lowest place no card crosses, however short that leaves the page; only when there is none (a card taller than the page, or staggered columns) at the place in the page's lower half that crosses the fewest cards.

**PNG** (`png.swift`, EXP-6): a 48.9-megapixel section at 4x peaked at 46 MB of memory (the full image would be 186 MB); scales past 16,384 px a side or 128 megapixels are refused with the largest scale that fits.

**Note HTML** (EXP-3): 92 KB for the X(b) note, zero resources loaded when opened in a web view, Thmanyah named (`"thmanyah sans"`) and never embedded, the Paper and Night switch working under a policy that runs only its own script (by hash).

**Pages** (EXP-7, PAGE-9): the note route works on any web view. On a page with its own web font, as one long page (595 x 6,114 pt): Linen's faces outlined, the page's own font left to WebKit and still searchable.

## Review

Codex reviewed `Linen/Export/` (`docs/reviews/m10-export-codex-final.md`): 1 blocker, 14 major, 1 minor. Its verification pass (`docs/reviews/m10-export-verify-codex-final.md`) found 9 resolved, 6 partly, 1 not, and 6 new; the second round of fixes closed every one in `Linen/Export/` except one declined: content placed left of the page's origin (`left: -1000px`) is not exported, as the reader cannot scroll to it either. Three of the new findings are in `Renderer/board.js`'s `displayList` (cards in the export stage are not given their lazy blocks, card images take the node's file and the whole card's box, edge notes are dropped) and are the board lane's. The blocker was real: the module read a display list shaped by this spike, not the renderer's (origin, weight, case and tracking, centred labels on chips, notes by box id, section names, image paths). Also fixed: the 9 pt floor per section, cuts that preferred a cut card to a short page, sources that ran off the page, image size limits, PNG geometry that could trap, `PDFCompact` checks (no comments, per-page contents and resources, 64 MB cap), `prepareForPrint` called in the wrong script world (it never ran), print-only NOTE-3 blocks skipped, wide pages cut instead of scaled, bounded work and timeouts in the page scripts, HTML images limited to local ones of image types, and outline nesting.

## What this means for the PRD

- EXP-5 and EXP-8 hold as written: outlines plus the invisible layer, at the gate's numbers. X(b) passed, so Geeza Pro in note PDFs (the fallback route) is not needed.
- New in the build log: glyph forms through `CGLayer`, `PDFCompact`, per-word invisible drawing, whole-pixel breaks, baselines measured in the page, and the PDFKit direction limit above.
