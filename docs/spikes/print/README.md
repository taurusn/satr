# Spike S(e): printing through WebKit

> **Correction, 2026-10-14: the Thmanyah rows below are wrong.** The page was loaded with `loadHTMLString` and named Thmanyah by a `file:` URL that WebKit did not read, so those cases ran in a fallback face (note they paginate exactly like generic `serif`). Rerun with the page loaded by `loadFileURL` with read access to its folder and a probe confirming `LinenSans:loaded`: through the print operation and through `createPDF`, Thmanyah Arabic reads back from PDFKit as presentation forms with letters missing ("يقرأ لينن" became "ﻳﻘﺮأ ﻟﻴ"), and `findString` found 0 of 8 Arabic words; Geeza Pro found 6 of 8 through the print operation (لينن and الوكلاء failed, their ligatures read back as "لي>" and "الوك8ء"); `-apple-system` 0 of 8. The iPhone research lane measured the same in `createPDF` and in Core Text alone, and found one route that keeps the look and the text: Thmanyah drawn as glyph outlines with an invisible Geeza Pro text layer (`docs/research/iphone-sync.md` section 5). Linen 2 takes that route (PRD-2 EXP-5, EXP-8).

Run 2026-10-11, macOS 26.5. `print.swift` prints a 12-section page (Latin and Arabic paragraphs) through `WKWebView.printOperation(with:)` to a PDF with no panel, then reads the PDF back with PDFKit. A4, CSS `@page` margins and an `@bottom-center` margin box with `counter(page)`.

| Case | Pages | CSS page margin box drawn | PDF outline | Arabic text layer |
|---|---|---|---|---|
| System font (`-apple-system`), print operation | 7 | no | no | **garbled** (presentation forms, wrong letters: ".ٮ.ﻄٮ,ﻊ اﻟﺼڡ & ﺤﺔ") |
| Thmanyah Sans by `@font-face`, print operation | 5 | no | no | intact ("يطبع الصفحة" found) |
| Thmanyah Sans, `createPDF` | 1 (not paginated) | no | no | intact |
| Generic `serif`, print operation | 5 | no | no | intact |

## What it means for EXP-1
- Print through the print operation; `createPDF` does not paginate.
- WebKit's print ignores CSS page margin boxes, so the running title and page numbers are drawn natively: after WebKit writes the PDF, Linen stamps each page with PDFKit (title, page number) and writes the outline from the headings (their text found page by page).
- (Superseded, see the correction above.) Arabic must be set in Thmanyah, never left to the system font: with `-apple-system` the PDF looks right but its Arabic cannot be searched or copied. Code blocks name Thmanyah Sans after the mono face, so Arabic inside code also comes from Thmanyah. Satr 1.2.1 sets everything in `-apple-system`.
