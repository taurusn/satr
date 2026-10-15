# ELK.js 0.12.0

`elk.bundled.js` is the unmodified file `lib/elk.bundled.js` from the npm package `elkjs@0.12.0`
(SHA-256 `1222e44f953ce7746af23801e723708f8e6f436b8b377a6a5fc7552f34a307b3`).

- Source: https://github.com/kieler/elkjs (built from the Eclipse Layout Kernel, https://github.com/eclipse-elk/elk)
- Licence: Eclipse Public License 2.0, in `LICENSE.md` beside this file (elkjs offers EPL-2.0 or GPL-3.0-or-later).

Linen loads it only inside `Renderer/layout-worker.js`, and only when a board has a section with `"layout": "layered"`
(PRD-2 section 9.2). None of its code is copied into Linen's own files. To update it, replace the file with the one
from a newer package, record the new version and hash here, and rerun `Tests/layout.test.js` and the B(b) gate.
