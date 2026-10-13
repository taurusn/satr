# Spike S(c): which highlighter

Run 2026-10-11 in a scratch folder (`npm install highlight.js@11.11.1 shiki@3.13.0 katex@0.16.25`).

Languages: the 30 Linen needs, led by what the corpus uses (fence counts across `~/vault` and `~/Desktop/*/docs`: python 103, bash 87, tsx 40, json 26, yaml 19, sh 19, ts 11, sql 7, css 4, swift 3, html 2, dart 2), plus the common rest (go, rust, java, kotlin, c, cpp, ruby, php, xml, diff, dockerfile, makefile, csharp, graphql, scss, lua, ini, markdown, plaintext).

| | Size for 30 languages |
|---|---|
| highlight.js core + 30 languages | 308 KB unminified (core 74 KB) |
| Shiki | `onig.wasm` 455 KB + grammars 1,686 KB for 29 languages |
| KaTeX (for REN-5) | `katex.min.js` 270 KB + fonts 1,051 KB (KaTeX's own fonts, OFL) |

## Answer
highlight.js. Linen's highlighting is monochrome by design (REN-3: keywords, strings, comments), so Shiki's TextMate accuracy buys little, and highlight.js is a seventh of the size with no WebAssembly start-up. With Mermaid (3.4 MB), KaTeX (1.3 MB), marked and DOMPurify the renderer stays near 5.5 MB, inside the 9 MB budget.
