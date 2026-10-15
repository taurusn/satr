# Writing for Linen

Linen reads three kinds of file: **notes** (Markdown), **boards** (JSON Canvas) and **pages** (self-contained HTML). You write the content; Linen draws it in Loom's look, in Paper and Night, on the Mac and the iPhone, and exports it. Never put fonts, colours or layout code in a file: Linen supplies them.

This guide is for agents. Every example below is complete and passes `linen check`.

## The author loop

```sh
linen check map.canvas                         # problems with their JSON paths and lines; exit 1 when any error
linen layout map.canvas                        # measures every card with Linen's fonts and places sections that ask for it
linen shot map.canvas --width 1176 --theme paper --out /tmp/map-1176.png
linen shot map.canvas --width 390 --theme night --out /tmp/map-390.png
linen open map.canvas                          # opens it in Linen without taking focus (add --focus to bring it forward)
```

Look at both shots before you hand a file over. `linen check --json` prints `{file, problems: [{severity, path, line, message}]}`. Exit status: 0 clean (warnings allowed), 1 errors found, 2 bad usage, 3 the renderer failed.

`linen open map.canvas --node n-approve` opens a board at one box; `linen open plan.md --line 40` opens a note at a line.

## Using Linen from an agent (MCP)

Linen's tools are also an MCP server, `linen mcp`, which coding agents add once. Linen > Install Command for Agents… sets it up; by hand:

```sh
claude mcp add --scope user linen -- ~/.local/bin/linen mcp      # Claude Code
codex mcp add linen -- ~/.local/bin/linen mcp                     # Codex
```

The tools, in the order an agent meets them:

| Tool | What it does |
|---|---|
| `format_guide` | This guide, one topic at a time (board, note, page, loop) |
| `write_board` | Makes a board from sections of boxes and connectors; Linen writes, lays out, checks and previews it |
| `edit_board` | Changes a board by box id (set, add, remove, move, connect, sections); Hatim's change marks show exactly that |
| `check_files` | The checks `linen check` runs, as a list an agent acts on |
| `preview_file` | A screenshot drawn by Linen, at 390, 1176 or 1440 px, Paper or Night, at a box or the whole board |
| `open_in_linen` | Opens a file for Hatim at a box or a line, behind his current app unless asked |
| `get_reader_state` | What Hatim has open, which box he selected, what he has not seen |
| `read_outline` | A board's boxes with ids, references and words (or a note's headings), page by page |
| `layout_board` | `linen layout` for a board edited by hand |

With the MCP, never place boxes by hand: describe sections and boxes to `write_board` and change them with `edit_board`. The format below is for agents without it and for reading what Linen writes.

## Boards (`.canvas`)

A board is [JSON Canvas 1.0](https://jsoncanvas.org), the format Obsidian uses, with Linen's own fields in one `linen` object on the canvas, on a node or on an edge. Obsidian keeps those fields when it saves.

Rules:

1. Use only the four spec `type` values: `text`, `file`, `link`, `group`. Linen's kinds go in `linen.kind`. Obsidian deletes a node of any other type.
2. Every node needs `id`, `x`, `y`, `width`, `height`. Write approximate positions and run `linen layout`.
3. Every edge's `fromNode` and `toNode` must exist. Obsidian deletes an edge to a missing node.
4. Ids are stable names (`n-approve`, `s-intake`), not counters: change marks and references follow ids.
5. Positions and sizes never count as a change. Only text, status, notes, kind and connections do.

### Node kinds

| What you want | Write |
|---|---|
| Card (raised paper, serif title, Markdown body) | `"type": "text"`, text starting with `# Title`, or `linen.title` |
| Sticky (square wash, no border) | `"type": "text"`, `"linen": {"kind": "sticky"}` |
| Shape | `"type": "text"`, `"linen": {"kind": "shape", "shape": "diamond"}`; shapes: rect, rounded, ellipse, diamond, pill, cylinder, hexagon |
| Big text (a board title) | `"type": "text"`, `"linen": {"kind": "text"}` |
| A note, board or page as a card | `"type": "file"`, `"file": "plans/intake.md"` (`.md`, `.canvas`, `.html`) |
| An image | `"type": "file"`, `"file": "shots/approve.png"` (local files only) |
| A web link | `"type": "link"`, `"url": "https://..."` (never fetched; opens in the browser when chosen) |
| A section | `"type": "group"`, `"label": "Intake"` |

Colours: `"color": "1"` to `"6"` (red, orange, yellow, green, cyan, purple) or `"#RRGGBB"`. Linen draws them as calm Loom washes. Colour is never a status: use a status word.

### Status words

A board has at most six words. Each card carries at most one, in `linen.word`. Without a list, Linen uses:

| Word | Shape at overview |
|---|---|
| Works (quiet: no pill on the card) | ink outline |
| Partial | ink threads |
| Broken | rust fill |
| Missing | dashed ink |
| Planned | dotted ink |

Your own list goes on the canvas: `"linen": {"words": [{"word": "Live", "shape": "outline", "quiet": true}, {"word": "Failing", "shape": "rust", "meaning": "Fails when used"}]}`. Shapes: `outline`, `threads`, `solid`, `dashed`, `dotted`, `rust`. Use rust only for a word that means failure. Words may be Arabic.

### Notes with sources

Any node or edge can carry a note that opens on hover: `"linen": {"note": {"area": "Approve", "title": "Every decision is refused", "body": "Markdown.", "refs": ["server/approvals.py:118"]}}`. For many notes, keep them beside the board in `map.canvas.notes.json`, keyed by id: `{"n-approve": {"title": "...", "body": "...", "refs": ["..."]}}`. A note in both places is an error. References that are paths with lines open in the editor at that line.

### Laying out sections

Place sections by hand and let Linen place what is inside: `"linen": {"layout": "grid", "cols": 2}` on a group (also `stack`, `lanes`, `layered`). `linen layout` sizes every card to fit its text with Linen's fonts, places the cards, grows the section and writes the numbers back. It changes only the numbers it moves. Keep rows of sections about 180 px apart so their names stay readable zoomed out.

In a grid, `"linen": {"span": 2}` (or `"all"`) on a card makes it span columns, and `"linen": {"ratios": [2, 1]}` on the group sets the columns' relative widths. Linen keeps any other `linen` field it does not use, such as `"ref"` on a group.

### Edges

`"fromSide"`/`"toSide"`: `top`, `right`, `bottom`, `left` (Linen picks by angle when missing, as Obsidian does). `"toEnd": "arrow"` is the default; `"fromEnd": "arrow"` for two-way. A `label` sits on a paper chip. Kinds in `linen.kind`: `works` (default), `main` (heavier), `code` (dashed: exists in code, not seen working), `plan` (dotted), `fail` (rust). `linen.route`: `straight`, `elbow`, `curved`.

### Direction

An Arabic board reads right to left: set `"linen": {"dir": "rtl"}` on the canvas (Linen also picks it when most text is Arabic).

### A complete small board

```json
{
	"nodes":[
		{"id":"s-intake","type":"group","x":0,"y":0,"width":620,"height":420,"label":"Intake","linen":{"layout":"grid","cols":2}},
		{"id":"n-form","type":"text","text":"# Request form\nValidates and stores a request.","x":20,"y":40,"width":280,"height":120,"linen":{"word":"Works"}},
		{"id":"n-api","type":"text","text":"# Night intake API\nRuns nightly; the last run failed.","x":320,"y":40,"width":280,"height":120,"linen":{"word":"Broken"}},
		{"id":"n-plan","type":"file","file":"plans/intake.md","x":20,"y":180,"width":280,"height":120},
		{"id":"n-idea","type":"text","text":"Ask finance about the batch window","x":320,"y":180,"width":180,"height":180,"linen":{"kind":"sticky"},"color":"3"}
	],
	"edges":[
		{"id":"e-1","fromNode":"n-form","fromSide":"right","toNode":"n-api","toSide":"left","label":"queues","linen":{"kind":"code"}}
	],
	"linen":{"title":"Requests readiness"}
}
```

With `map.canvas.notes.json` beside it:

```json
{"n-api": {"area": "Intake", "title": "The nightly run fails", "body": "The job stops at the export step.", "refs": ["jobs/nightly.py:42"]}}
```

## Notes (`.md`)

Any Markdown reads as it always has. A note can also use Loom blocks: fenced blocks whose body is a small YAML subset (maps, lists, flow maps like `{label: X, value: "3"}`, quoted and block strings), so the file stays readable as text in Obsidian and git. A block Linen cannot read shows its source and the problem in place.

### Page settings

```yaml
---
linen:
  layout: wide          # read (the column), wide (1180 px, prose kept at its measure), sheet (wide with a side column)
  eyebrow: Readiness · October
  lead: One paragraph that sits under the title.
  words:
    - {word: Works, shape: outline, quiet: true}
    - {word: Broken, shape: rust, meaning: Fails when used}
---
```

### Blocks

````markdown
```tiles
size: stat              # fact or stat (stat sets the value large in serif)
cols: 4
items:
  - {label: Use cases, value: "32"}
  - {label: Working, value: "8", word: Works}
  - {label: Broken, value: "4", word: Broken, note: n-broken}
```

```cards
cols: 3
items:
  - {eyebrow: Step 1, title: Intake, body: "Validates and stores a **request**.", tone: paper, word: Works}
  - {eyebrow: Step 2, title: Review, body: "Reads the reviewer's role.", tone: tint, word: Partial}
  - {eyebrow: Next, title: Approve, body: "The hub everything waits on.", tone: ink}
```

```steps
kind: steps             # steps (a chevron strip), level (n of m), count ("12 of 37")
items: [Draft, Review, Approve, Publish]
current: 2
```

```steps
kind: count
value: 12
of: 37
label: use cases work
```

```bar
items:
  - {word: Works, count: 8}
  - {word: Partial, count: 12}
  - {word: Broken, count: 4}
```
````

Tones for cards: `paper`, `tint`, `ink` (the dark "Next" band), `dashed`, `sticky`.

With `layout: sheet`, a `side` block holds Markdown for the 320 px side column (a summary, sources, a legend); on a narrow window it falls into the main column:

````markdown
```side
**At a glance:** 8 of 32 use cases work. Sources are at the end.
```
````

A `note` on a tile or card is either the id of a note in `report.md.notes.json` or the note's text itself.

### Words, notes and tables

- A status word anywhere in prose or a table cell: `:w[Broken]`.
- Footnotes (`[^1]`) open as cards on hover and stay numbered at the end and in print.
- A note on a term: `:note[the approval check]{#n-approve}`, with the note in `report.md.notes.json` keyed by id.
- In a table, `{#id}` after a row's first cell anchors the row; `{good}` or `{bad}` in a cell adds a quiet verdict mark; `[^id]` in a cell opens that note.

## Pages (`.html`)

A page is any self-contained HTML file. Linen opens it sealed: its scripts run only when its folder is trusted (Settings > Pages), and it cannot reach the network or any file outside its folder. Sibling files in the page's folder load, and the page may `fetch` them (a sidecar JSON keeps working).

Written for Linen, a page links the Loom kit and carries no fonts or tokens of its own:

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Readiness</title>
<link rel="stylesheet" href="linen-kit://kit/loom.css">
</head>
<body>
<main class="loom-page">
  <p class="loom-eyebrow">Readiness · October</p>
  <h1 class="loom-title">Requests</h1>
  <p>Approvals <span data-note="server/approvals.py:118 refuses every decision">fail today</span>.</p>
</main>
</body>
</html>
```

- `linen-kit://kit/loom.css` gives the tokens (`var(--paper)`, `var(--ink)`, `var(--rule)`, `var(--sans)`, `var(--serif)`), Thmanyah, base type and Paper and Night (Linen sets `data-linen-theme` on the root and sends a `linen:theme` event). Outside Linen the link fails quietly and the page falls back to system fonts.
- Any element with `data-note` opens its text as a note card on hover or tap. No script is needed for it.
- Do not inline fonts as base64: the font licence forbids sharing them, and Linen serves them.
- Check the phone version with `linen shot page.html --width 390`.

Prefer a board or a note with blocks when the content fits them: Linen then draws the phone version, change marks and exports for you.
