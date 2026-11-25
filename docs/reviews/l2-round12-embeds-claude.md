# Round 12: Claude alone, on BRD-19 and BLK-8 (boards in notes, gate 4E)

2026-11-21 19:28, before building. A short self-review; E4 keeps a fresh-eyes or Codex round.

| # | Severity | Finding | Resolution |
|---|---|---|---|
| 1 | Major | "Height reserved before it draws" cannot hold if the page asks the app for a board after the note is drawn (the way images load): the frame's height depends on the board's shape. | The app reads embedded boards with the note and sends them in the same load or update, so the page knows each frame's height when it lays the note out. |
| 2 | Major | Reusing the board view (one page-wide renderer with its own state and DOM) for several frames in a note would mean a second renderer instance per embed. | Embeds draw with a small renderer of their own (an SVG built from the same model and router), static by default, so many embeds, print and PDF all work; pan and zoom move its view box. |
| 3 | Major | An embed reads a file the note names, so a note could pull in files from anywhere on the Mac. | The vault rule for images applies (inside the vault, or a file Hatim allowed); 2 MB per board; anything else is a link card that says why. |
| 4 | Minor | A board embedded in an embedded note could recurse. | Embedded notes show as links today (REN-13), and a board inside one would be a link card (BRD-19), so nothing nests. |
| 5 | Minor | `touches:` could light the wrong board when a note has several. | The nearest board above the table; ids not on that board are ignored and `linen check` names them. |
| 6 | Minor | A board file that changes while the note is open would leave a stale picture. | The note reloads its embeds when it reloads; watching each embedded board is left for later (said in the build log). |

Verdict: build with these folded into BRD-19 and BLK-8.
