# Round 11: Claude alone, on PRD-2 section 17 (arranging and ENG-21)

2026-11-21 18:24, before building E2. Scope: ENG-8 to ENG-14 as written in section 17.4 and 17.5, and the new ENG-21 (line reshaping, Hatim's answer after gate 2). A short self-review, not a fresh-eyes or Codex round; E4 still asks for one on the write path.

| # | Severity | Finding | Resolution |
|---|---|---|---|
| 1 | Major | ENG-21 stores a line's corners in the file, but principle 2 says a path is "never stored" and 17.5 lists storing route points under Rejected. | Principle 2 and the Rejected line now say: computed paths are never stored; a shape Hatim made by hand is, as `via`, and only the runs at a moved box adapt. |
| 2 | Major | Principle 5 says Linen "writes only positions, sizes and pins". A reshape also writes `via`, `labelAt` and the connector's sides. | Principle 5 lists them. Text, ids, kinds, labels and relations are still never written by a drag. |
| 3 | Major | A press near a line on empty board used to pan. With ENG-21 a pan that starts within 6 px of a line would reshape it by accident. | The cursor shows the reshape (a resize cursor) only within 6 screen px of a run, and only where arranging is on; anywhere else a drag pans. An accidental reshape is one ⌘Z. |
| 4 | Major | `linen layout` and an agent's edit can move the end boxes of a shaped line far from its corners, leaving a shape that no longer fits. | The router's stretch rule moves only the end runs; a corner behind its box's side drops the shape for that drawing (the line routes as usual) and `linen check` names it. The file keeps `via` until Hatim reshapes or resets. |
| 5 | Minor | Undo after an agent edited the same box writes the old position over the agent's newer one. | Accepted: undo is about Hatim's arrangement, which wins (principle 4). It writes by id onto the current file, so the agent's text is kept. The stack is cleared when the tab leaves the board. |
| 6 | Minor | Re-routing every line of the board each drag frame would miss 16.7 ms on the 167-box flow (75 ms per full routing). | During a drag only the dragged boxes' lines route (searches cached), and the frame time is measured (ENG-16); the whole board routes on release. |
| 7 | Minor | An outside save (an agent) during a drag would reload the board under the pointer. | The page holds an update that arrives mid-drag and lets the drop's write (which applies the moves to the newest file) bring it in. |
| 8 | Minor | Obsidian keeps a canvas in memory while it is open there and may write its own copy after Linen's. | Not solvable from Linen; Linen's write is atomic and re-reads first (ENG-12), so it never writes over a version it has not seen. Said in the build log. |

Verdict: build E2 with these folded. ENG-20 keeps adding or removing a single bend, several boxes at once, the iPhone and drawing new connectors for 2.x.
