# Spike S(d): the whole corpus in Satr 1.2.1's renderer

Run 2026-10-11 on the MacBook Air M4 (macOS 26.5), offscreen WKWebView at 980 × 760, the installed 1.2.1 renderer (`/Applications/Satr.app/Contents/Resources`).

```
./docs/spikes/corpus/corpus /Applications/Satr.app/Contents/Resources ~/vault ~/Desktop/ferry/docs
```

The tool prints counts and file paths only, never note content (the repository is public).

## Result

- 513 files (495 vault notes plus the Ferry docs): all render, zero script errors, zero Mermaid failures, no timeouts.
- Time from load to rendered: p50 30 ms, p90 53 ms, p99 622 ms, max 3,968 ms.
- Slowest: `log.md` (713 KB) 3,968 ms; the raw Codex review transcripts (600 KB to 1 MB) 622 to 1,569 ms.

## What it means for the PRD

- Correctness on today's corpus is not the problem; speed on big files is. The renderer parses and sanitises the whole document on the main thread before the first paint.
- The measure "first screen of `log.md` under 600 ms" needs progressive rendering (PERF-1): parse off the main thread and paint the first chunk first.
- The first version of this spike reported 6 ms per file because it read the previous page before the new one committed; it now waits for a page marked with the new file. Keep that check in the M0 corpus test.
