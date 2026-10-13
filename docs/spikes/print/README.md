# Spike S(e): printing through WebKit

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
- Arabic must be set in Thmanyah, never left to the system font: with `-apple-system` the PDF looks right but its Arabic cannot be searched or copied. Code blocks name Thmanyah Sans after the mono face, so Arabic inside code also comes from Thmanyah. Satr 1.2.1 sets everything in `-apple-system`.
