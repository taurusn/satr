#!/usr/bin/env python3
"""Summarises a fixtures.json from the spike app: per file, console errors, page errors, warnings, and the renderer's
own problems (render-failed blocks, notices and banners, LinenBlocks.check for notes, the board model's problems
and fatal state for boards), and faces that failed to load.

    python3 -I scripts/fixtures-report.py results/<where>/fixtures.json
"""
import json, sys

data = json.load(open(sys.argv[1]))
rows = data["results"]
total_console = total_page = 0
for r in rows:
    p = r.get("probe", {})
    console, page, warns = r.get("console", []), r.get("pageErrors", []), r.get("warnings", [])
    total_console += len(console)
    total_page += len(page)
    probs = []
    if p.get("failed"): probs.append(f"{len(p['failed'])} render-failed")
    if p.get("notice"): probs.append("notice: " + p["notice"][:80])
    if p.get("banner"): probs.append("banner: " + p["banner"][:80])
    if p.get("check"): probs.append(f"check {len(p['check'])}: " + " | ".join(x[:70] for x in p["check"][:3]))
    if p.get("modelProblems"): probs.append(f"model problems {len(p['modelProblems'])}: " + " | ".join(x[:70] for x in p["modelProblems"][:2]))
    if p.get("modelFatal"): probs.append(f"fatal {p['modelFatal']['reason']}: " + " | ".join(x[:60] for x in p["modelFatal"]["problems"][:2]))
    if p.get("fatalShown"): probs.append("fatal panel shown")
    if p.get("lines"): probs.append("line: " + " | ".join(x[:60] for x in p["lines"]))
    if p.get("fontsFailed"): probs.append("faces failed: " + ", ".join(p["fontsFailed"]))
    extra = f" nodes {p.get('nodes')} mounted {p.get('mounted')} {p.get('mode')}" if r["kind"] == "board" else f" blocks {p.get('blocks')}"
    print(f"{r['file']:40} {r['reply']:10} {r['ms']:5} ms  console {len(console)}  page {len(page)}  warn {len(warns)} {extra}")
    for x in console + page: print("      ERR " + x[:200])
    for x in warns: print("      WARN " + x[:200])
    for x in probs: print("      " + x)
print(f"\n{len(rows)} files, console errors {total_console}, page errors {total_page}, terminations {len(data.get('terminations', []))}")
first = rows[0].get("probe", {})
print(f"view {first.get('width')}x{first.get('height')} @{first.get('dpr')}x; faces loaded on the last file: {rows[-1].get('probe', {}).get('fontsLoaded')}")
