# `linen mcp` evaluation runs (MCP-14)

Fresh agent sessions with only Linen's MCP server and file-reading tools, given a task in Hatim's words, judged by their transcripts and by the board they leave. Transcripts and boards are kept locally in `docs/research/raw/mcp-eval/` (not in the repository).

| Round | Agent | Task | Result | Linen calls | Errors | Turns | Time | Cost |
|---|---|---|---|---|---|---|---|---|
| 1 | Codex | A board of how Linen is built, readable on laptop and phone, opened without interrupting | Success: wrote, previewed sections at 390 and 1176, tightened wordy cards with 3 `edit_board` calls, checked clean, opened behind | 24 | 1 (a preview timed out in a long session) | n/a | n/a | n/a |
| 1 | Claude Code | Same | Success, after finding our bug (cards measured without their pills in a fresh renderer) with two test boards | 38 | 0 | 93 | 13.8 min | $5.82 |
| 2 | Claude Code | Same, after the fixes | Success; 37 to 40 parts in 8 sections; previews in both looks and widths; opened behind | 19 | 0 | 53 | 13.5 min | $4.71 |
| 2 | Codex | "I have a box selected in Linen; tell me which and update it" | Success: `get_reader_state` named the box; the word it chose was not on the board and went in with only a warning (now an error before writing); its malformed `set_board` was refused with nothing written; it then finished and opened the board at the box | 14 | 1 (refused, nothing written) | n/a | n/a | n/a |
| 2 | Codex | An Arabic board of a product launch (asked in Arabic) | Success: straight to `write_board`, removed connectors that crossed cards on the phone, opened behind | 11 | 0 | n/a | n/a | n/a |

## What the runs changed

- Round 1: `format_guide` for boards now leads with `write_board` (Codex first planned coordinates by hand); eyebrows are described as one to three words; the renderer's measure is stateless (Claude's bug); connector labels never sit on cards; lines pass under section names; Fit stays clear of the legend panel; a warning when a heavy shape covers most boxes.
- Round 2: a box word the board does not define is an error before writing, listing the board's words; `set_board` takes words by name; right-to-left boards place their first section at the right; the rust lint reads Arabic failure words.

## Still to run

Held-out tasks and repeats (three runs each), a note with Loom blocks, a sealed page once pages join the app, and the same tasks in a Claude Code session steered from the iPhone through Remote Control (MCP-15).
