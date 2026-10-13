# Spike S(f): bundled Thmanyah faces in WebKit

Run 2026-10-11, macOS 26.5. An offscreen `WKWebView` loaded a page from a folder that held copies of two Thmanyah faces (Sans Regular, Serif Display Light), declared with `@font-face` under alias family names (`LinenSansSpike`, `LinenSerifSpike`) so that the installed copies in `~/Library/Fonts` could not satisfy them by name.

## Answer
- **Yes for the app.** `document.fonts.check('28px "LinenSansSpike"')` returned true, and the aliased lines render in Thmanyah, identical to the line that names the installed family (`thmanyah sans`) and unlike the monospace fallback line. WebKit renders in its own process, so registering fonts in the app process would not reach it; `@font-face` from the bundle is the way.
- **Quick Look not yet tested:** the extension must declare the faces the same way from its own bundle; to be checked when the extension is built (M6).
- **Typography note for M4:** Thmanyah Sans's Arabic word space is tight, and a final ر visually closes the gap before the next word ("سطر يقرأ"); the order and spaces are correct. M4 judges a small Arabic `word-spacing` by eye against the vault's Arabic notes.

Font files were copied to a scratch folder for the test and are not in this repository.
