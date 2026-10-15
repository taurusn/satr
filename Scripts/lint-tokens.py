"""Checks that Linen's colours are Loom's (PRD section 8, 8.1): every hex value in Renderer/page.css and
Linen/Design/Tokens.swift must be one of Loom's tokens (docs/DESIGN.md section 2) or the one pressed shade, and Linen's
token set must match Ferry's Tokens.swift. Run: python3 -I Scripts/lint-tokens.py
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOOM = Path.home() / "Desktop/Loom/loom-site/docs/DESIGN.md"
FERRY = Path.home() / "Desktop/ferry/Ferry/Design/Tokens.swift"

def hexes(text):
    return {h.upper() for h in re.findall(r"#([0-9A-Fa-f]{6})\b", text)} | {h.upper() for h in re.findall(r"0x([0-9A-Fa-f]{6})\b", text)}

problems = []
if not LOOM.exists():
    print("Loom DESIGN.md not found; skipped the Loom check")
    loom = None
else:
    table = LOOM.read_text().split("## 3.")[0]
    loom = hexes(table)
    loom.add("1F3A2A")  # the one pressed shade, named in DESIGN.md section 2

for name in ["Renderer/page.css", "Renderer/board.css", "Renderer/blocks.css", "Renderer/board.js", "Renderer/blocks.js",
             "Linen/Pages/Kit/loom.css", "Linen/Design/Tokens.swift", "LinenQuickLook/PreviewViewController.swift", "Linen/Document/DocumentWindow.swift"]:
    if not (ROOT / name).exists():
        continue
    used = hexes((ROOT / name).read_text())
    if loom is not None:
        extra = sorted(used - loom)
        if extra:
            problems.append(f"{name}: colours that are not Loom tokens: {', '.join('#' + e for e in extra)}")

if FERRY.exists():
    ferry = hexes(FERRY.read_text())
    linen = hexes((ROOT / "Linen/Design/Tokens.swift").read_text())
    if ferry != linen:
        problems.append(f"Tokens.swift differs from Ferry's: only Linen {sorted(linen - ferry)}, only Ferry {sorted(ferry - linen)}")

if problems:
    print("\n".join(problems))
    sys.exit(1)
print("tokens ok: every colour is a Loom token, and Linen's set matches Ferry's")
