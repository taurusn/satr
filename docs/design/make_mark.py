"""Builds Linen's mark and icon on Loom's grid (24-unit cells, 18-unit threads, round caps), the way
Loom's and Ferry's marks are built. The woven square is a drop cap; long threads are the lines of a page.

    python3 -I docs/design/make_mark.py

Writes linen-mark.svg (right to left, the chosen mark), linen-mark-ltr.svg (the alternative), the Mac icons
and linen-mark.html, a comparison page with Loom and Ferry.
"""
from pathlib import Path

HERE = Path(__file__).resolve().parent
LINE_START = 81  # where the two lines beside the drop cap begin; the square's threads end at 48 and 57


def H(cx, cy):
    return (cx - 9, cy, cx + 9, cy)


def V(cx, cy):
    return (cx, cy - 9, cx, cy + 9)


def block(ox, oy):
    """One woven square, exactly as in Loom's and Ferry's marks."""
    return [H(ox + 24, oy + 24), V(ox + 48, oy + 24), V(ox + 24, oy + 48), H(ox + 48, oy + 48)]


LOOM = block(0, 0) + block(48, 0) + block(0, 48) + block(48, 48)
FERRY = block(0, 0) + [(66, 36, 102, 36)] + block(96, 0)
LTR = block(0, 0) + [(LINE_START, 24, LINE_START + 72, 24), (LINE_START, 48, LINE_START + 60, 48), (15, 72, 117, 72)]
AXIS = (15 + LINE_START + 72) / 2
RTL = [(2 * AXIS - c, d, 2 * AXIS - a, b) for a, b, c, d in LTR]


def bounds(lines, pad):
    xs = [v for l in lines for v in (l[0], l[2])]
    ys = [v for l in lines for v in (l[1], l[3])]
    return min(xs) - pad, min(ys) - pad, max(xs) - min(xs) + 2 * pad, max(ys) - min(ys) + 2 * pad


def draw(lines):
    return "".join(f'<line x1="{a:g}" y1="{b:g}" x2="{c:g}" y2="{d:g}"/>' for a, b, c, d in lines)


def mark_svg(lines, title):
    x, y, w, h = bounds(lines, 3)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{x:g} {y:g} {w:g} {h:g}" fill="none" stroke="#284734" '
            f'stroke-width="6" stroke-linecap="round" role="img" aria-label="Linen"><title>{title}</title>{draw(lines)}</svg>\n')


def icon_svg(lines, size=1024, uid="a", standalone=True):
    """Ferry's icon construction: paper squircle, faint weave, hairline, soft ink shadow, the mark centred."""
    x, y, w, h = bounds(lines, 5)
    s = min(560 / w, 330 / h)
    tx, ty = 512 - (x + w / 2) * s, 512 - (y + h / 2) * s
    ns = 'xmlns="http://www.w3.org/2000/svg" ' if standalone else ""
    return (f'<svg {ns}width="{size}" height="{size}" viewBox="0 0 1024 1024">'
            f'<defs><filter id="s{uid}" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="12" stdDeviation="14" flood-color="#1F3328" flood-opacity=".32"/></filter>'
            f'<pattern id="w{uid}" width="66" height="66" patternUnits="userSpaceOnUse" x="100" y="100"><g fill="none" stroke="#284734" stroke-opacity=".12" stroke-width="2" stroke-linecap="round"><path d="M13 16.5h7.5M49.5 13v7.5M16.5 46v7.5M46 49.5h7.5"/></g></pattern></defs>'
            f'<rect x="100" y="100" width="824" height="824" rx="185" fill="#F6F3EB" filter="url(#s{uid})"/>'
            f'<rect x="100" y="100" width="824" height="824" rx="185" fill="url(#w{uid})"/>'
            f'<rect x="100.5" y="100.5" width="823" height="823" rx="184.5" fill="none" stroke="#DAD5C8"/>'
            f'<g transform="translate({tx:.1f} {ty:.1f}) scale({s:.3f})" fill="none" stroke="#284734" stroke-width="10" stroke-linecap="round">{draw(lines)}</g></svg>\n')


def small(lines, h=30, color="#284734"):
    x, y, w, hh = bounds(lines, 3)
    return (f'<svg height="{h}" viewBox="{x:g} {y:g} {w:g} {hh:g}" fill="none" stroke="{color}" stroke-width="6" '
            f'stroke-linecap="round">{draw(lines)}</svg>')


def page():
    rows = ""
    for name, lines, u in [("Chosen: right to left, as its Arabic name سطر is written", RTL, "r"), ("Alternative: left to right", LTR, "l")]:
        icons = "".join(icon_svg(lines, s, f"{u}{s}", False) for s in (240, 96, 48, 32))
        rows += (f'<section><h2>{name}</h2><div class="r">{icons}<div class="sm">{small(lines)}<span class="t">Linen</span></div>'
                 f'<div class="sm dark">{small(lines, color="#F6F3EB")}<span class="t" style="color:#F6F3EB">سطر</span></div></div>'
                 f'<div class="dock">{icon_svg(LOOM, 110, u + "d1", False)}{icon_svg(FERRY, 110, u + "d2", False)}{icon_svg(lines, 110, u + "d3", False)}<span>Loom, Ferry, Linen</span></div></section>')
    return f'''<!doctype html><meta charset="utf-8"><title>Linen mark</title>
<style>body{{margin:0;background:#F6F3EB;color:#284734;font:15px -apple-system;padding:40px}} h1{{font:300 34px Georgia;margin:0 0 6px}} p{{color:#1F3328;max-width:720px;line-height:1.6}}
section{{border-top:1px solid #DAD5C8;padding:20px 0}} h2{{font:600 15px -apple-system;margin:0 0 12px}} .r{{display:flex;align-items:center;gap:24px;flex-wrap:wrap}}
.sm{{display:flex;align-items:center;gap:10px;padding:12px 16px;border:1px solid #DAD5C8;border-radius:2px}} .sm.dark{{background:#1F3328}} .t{{font-size:19px}}
.dock{{display:flex;align-items:center;gap:6px;margin-top:16px;padding:10px 14px;background:#E3E7DF;border-radius:2px;width:max-content}} .dock span{{margin-left:12px;color:#1F3328}}</style>
<h1>Linen's mark</h1><p>Built like Loom's and Ferry's: the same woven square, the same 18-unit threads with round caps on a 24-unit grid, the same icon construction. The woven square is a drop cap, and long threads are the lines of a page: two beside it, one running under it. Linen is woven cloth with a line inside its name; in Arabic it is سطر, a line.</p>{rows}'''


if __name__ == "__main__":
    (HERE / "linen-mark.svg").write_text(mark_svg(RTL, "Linen: a woven initial and the lines of a page, written right to left"))
    (HERE / "linen-mark-ltr.svg").write_text(mark_svg(LTR, "Linen, left to right alternative"))
    (HERE / "linen-icon-mac.svg").write_text(icon_svg(RTL, uid="r"))
    (HERE / "linen-icon-mac-ltr.svg").write_text(icon_svg(LTR, uid="l"))
    (HERE / "linen-mark.html").write_text(page())
    print("written", AXIS)
