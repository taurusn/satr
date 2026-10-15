"""Builds the Linen 2 screen sketch: docs/design/linen2-screens.html, one self-contained page.

    python3 -I docs/design/build_screens2.py

Follows PRD-2 draft 0.5, section 7. Boards are drawn at reference scale (170 boxes in ten sections) and by the
rules of BRD-8: three levels by on-screen size, no text under 9 px at rest, status as one of WORDS-2's six ink
shapes. Reuses the v1 sketch's window chrome, tokens and mark (build_screens.py). Thmanyah is named, never
embedded. Sample content only: a fictional requests service, never vault or work content.
"""
import math
import random
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import build_screens as v1  # noqa: E402

OUT = HERE / "linen2-screens.html"
window, screen, mark, icon = v1.window, v1.screen, v1.mark, v1.icon

v1.ICON.update({
    "zoom": '<path d="M3 8h10M8 3v10"/>',
    "phone": '<path d="M5 2.5h6v11H5z"/><path d="M7.3 11.5h1.4"/>',
    "gear": '<circle cx="8" cy="8" r="2.2"/><path d="M8 2.5v1.6M8 11.9v1.6M2.5 8h1.6M11.9 8h1.6M4.1 4.1l1.1 1.1M10.8 10.8l1.1 1.1M4.1 11.9l1.1-1.1M10.8 5.2l1.1-1.1"/>',
    "board": '<path d="M2.5 2.5h4.5v4.5H2.5zM9 2.5h4.5v3H9zM9 7.5h4.5v6H9zM2.5 9h4.5v4.5H2.5z"/>',
    "note": '<path d="M3.5 2.5h9v11h-9z"/><path d="M5.5 5.5h5M5.5 8h5M5.5 10.5h3"/>',
    "page": '<path d="M2.5 3h11v10h-11z"/><path d="M2.5 5.5h11M4 4.2h.01M5.5 4.2h.01"/>',
    "chev": '<path d="M10 3.5L5.5 8l4.5 4.5"/>',
    "more": '<path d="M4 8h.01M8 8h.01M12 8h.01"/>',
    "copy": '<path d="M5.5 5.5h7v8h-7z"/><path d="M3.5 10.5v-8h7"/>',
    "files": '<path d="M2.5 4.5h4l1.2 1.5h5.8v7h-11z"/>',
    "mail": '<path d="M2.5 4h11v8h-11z"/><path d="M2.5 4.5L8 9l5.5-4.5"/>',
    "airdrop": '<circle cx="8" cy="8" r="1.5"/><path d="M5 11a4.2 4.2 0 1 1 6 0M3 13a7 7 0 1 1 10 0"/>',
})

BOARD_TOOLBAR = [["back", "fwd"], ["outline"], ["find"], ["editor", "share"]]
RNG_SEED = 11

# ---------- the sample board: a readiness map of a fictional requests service, at reference scale ----------

WORDS = ["Works", "Partial", "Broken", "Missing", "Planned"]
WORD_KEY = {"Works": "works", "Partial": "partial", "Broken": "broken", "Missing": "missing", "Planned": "planned"}
WORD_AR = {"Works": "يعمل", "Partial": "جزئي", "Broken": "معطل", "Missing": "غير موجود", "Planned": "مخطط"}
QUIET = {"Works"}   # WORDS-1: the quiet word is drawn without a pill; it stays in the legend and as the outline shape
LANES = [("Intake", "Requests arrive", 16), ("Review", "First checks", 18), ("Approve", "Decisions", 17), ("Records", "What is kept", 19),
         ("Billing", "Money out", 15), ("Notify", "Who hears", 14), ("Access", "Who may", 18), ("Reports", "What is read", 17),
         ("Audit", "After the fact", 16), ("Archive", "Kept for years", 20)]
LANES_AR = [("الاستلام", "تصل الطلبات"), ("المراجعة", "أول تحقق"), ("الاعتماد", "القرارات"), ("السجلات", "ما يُحفظ"), ("الفوترة", "المدفوعات"),
            ("الإشعار", "من يُبلَّغ"), ("الصلاحيات", "من يحق له"), ("التقارير", "ما يُقرأ"), ("التدقيق", "بعد الحدث"), ("الأرشيف", "يُحفظ لسنوات")]
TITLES = ["Request form", "Intake API", "Draft save", "File upload", "Duplicate check", "Email intake", "Status page", "Rules check",
          "Review queue", "Team filter", "Return reason", "Approval page", "Approval flow", "Delegation", "Escalation", "Request store",
          "Audit log", "File store", "History view", "Ledger export", "Invoice match", "Payment run", "Refund", "Notice email",
          "Daily digest", "Text alert", "Sign-in", "Roles", "Access review", "Weekly report", "Ageing chart", "Sheet export",
          "Trail viewer", "Retention rule", "Legal hold", "Cold storage", "Restore job", "Search index", "Backup check", "Purge job"]
TITLES_AR = ["نموذج الطلب", "واجهة الاستلام", "حفظ المسودة", "رفع الملفات", "كشف التكرار", "استلام البريد", "صفحة الحالة", "فحص القواعد",
             "قائمة المراجعة", "تصفية الفريق", "سبب الإرجاع", "صفحة الاعتماد", "مسار الاعتماد", "التفويض", "التصعيد", "مخزن الطلبات",
             "سجل التدقيق", "مخزن الملفات", "عرض السجل", "تصدير الدفتر", "مطابقة الفاتورة", "دفعة السداد", "الاسترداد", "بريد الإشعار",
             "ملخص يومي", "تنبيه نصي", "تسجيل الدخول", "الأدوار", "مراجعة الصلاحيات", "تقرير أسبوعي", "مخطط الأعمار", "تصدير إلى جدول",
             "عارض الأثر", "قاعدة الاحتفاظ", "حجز قانوني", "تخزين بارد", "مهمة الاستعادة", "فهرس البحث", "فحص النسخ", "مهمة الحذف"]
BODIES = {"Works": ["Validates and stores a request.", "Seven rules, versioned.", "Email on each step.", "One row per request, JSON body.", "Sorted by age, filters by team."],
          "Partial": ["Works for one team only.", "Read in code only, never seen working.", "Shows the rules check, not the history."],
          "Broken": ["Refuses every decision with 403.", "Runs nightly; the last run failed."],
          "Missing": ["Not written yet."], "Planned": ["Planned for phase two."]}
BODIES_AR = {"Works": ["يتحقق من الطلب ويحفظه.", "سبع قواعد بإصدارات.", "بريد عند كل خطوة.", "صف لكل طلب.", "مرتب حسب العمر."],
             "Partial": ["يعمل لفريق واحد فقط.", "موجود في الشيفرة فقط.", "يعرض فحص القواعد دون السجل."],
             "Broken": ["يرفض كل قرار برمز ٤٠٣.", "يعمل ليلًا وفشل آخر تشغيل."],
             "Missing": ["لم يُكتب بعد."], "Planned": ["مخطط للمرحلة الثانية."]}

# 200 distinct titles, so find and references never meet two boxes with one name
QUALS = ["Team", "Batch", "Partner", "Night"]
QUALS_AR = ["للفريق", "الدفعي", "للشريك", "الليلي"]
POOL = TITLES + [f"{q} {t[0].lower() + t[1:]}" for q in QUALS for t in TITLES]
POOL_AR = TITLES_AR + [f"{t} {q}" for q in QUALS_AR for t in TITLES_AR]   # same order, so one index serves both

CW, CH, PAD, GX, ROW = 240, 112, 24, 24, 138      # card, section padding, column gap, row pitch
LANE_W = PAD + CW + GX + CW + PAD                   # two columns per section: 552
LGAP, ROWGAP, TOP, MARGIN = 60, 190, 190, 40
PER_ROW = 5


def build_board():
    rnd = random.Random(RNG_SEED)
    nodes, secs, order = {}, [], []
    deck = list(range(len(POOL)))
    rnd.shuffle(deck)
    lane_h = [PAD + math.ceil(n / 2) * ROW for _, _, n in LANES]
    row_h = [max(lane_h[:PER_ROW]), max(lane_h[PER_ROW:])]
    for li, (name, sub, n) in enumerate(LANES):
        r, c = divmod(li, PER_ROW)
        x = MARGIN + c * (LANE_W + LGAP)
        y = TOP + r * (row_h[0] + ROWGAP)
        for i in range(n):
            col, rr = i % 2, i // 2
            st = rnd.choices(WORDS, weights=[45, 25, 8, 12, 10])[0]
            t = deck.pop()
            b = rnd.randrange(len(BODIES[st]))
            nodes[(li, i)] = dict(x=x + PAD + col * (CW + GX), y=y + PAD + rr * ROW, w=CW, h=CH, col=col, ti=t, bi=b, st=st)
            order.append((li, i))
        secs.append(dict(x=x, y=y, w=LANE_W, h=lane_h[li], li=li))
    edges = []
    for li in range(len(LANES)):
        nxt = li + 1
        if nxt >= len(LANES) or nxt % PER_ROW == 0:
            continue
        srcs = [k for k in nodes if k[0] == li and nodes[k]["col"] == 1]
        dsts = [k for k in nodes if k[0] == nxt and nodes[k]["col"] == 0]
        for j, a in enumerate(rnd.sample(srcs, min(5, len(srcs)))):
            edges.append((a, rnd.choice(dsts), j))
    # the boxes the screens point at, fixed: the note in screen 2, the reference in screen 4
    for k, t, st in [((2, 6), "Approval flow", "Broken"), ((2, 7), "Approval page", "Partial"), ((3, 2), "Audit log", "Missing"), ((1, 5), "Rules check", "Partial")]:
        want = POOL.index(t)
        holder = next((h for h in nodes if nodes[h]["ti"] == want), None)
        if holder is not None:
            nodes[holder]["ti"] = nodes[k]["ti"]
        nodes[k].update(ti=want, st=st, bi=0)
    labels = {0: "POST", 3: "decide", 7: "SMTP", 11: "role"}
    w = MARGIN * 2 + PER_ROW * LANE_W + (PER_ROW - 1) * LGAP
    h = TOP + row_h[0] + ROWGAP + row_h[1] + MARGIN
    return nodes, secs, edges, labels, w, h


NODES, SECS, EDGES, EDGE_LABELS, BW, BH = build_board()
NOTED = {(2, 3), (2, 6), (3, 2), (1, 5), (7, 4)}


def counts():
    c = {w: 0 for w in WORDS}
    for n in NODES.values():
        c[n["st"]] += 1
    return c


def title(k, ar=False):
    return (POOL_AR if ar else POOL)[NODES[k]["ti"]]


def body(k, ar=False):
    n = NODES[k]
    pool = (BODIES_AR if ar else BODIES)[n["st"]]
    return pool[n["bi"] % len(pool)]


def word(w, ar=False):
    return WORD_AR[w] if ar else w


def num(n, ar=False):
    return str(n).translate(str.maketrans("0123456789", "٠١٢٣٤٥٦٧٨٩")) if ar else str(n)


# ---------- text fitting (the sketch's stand-in for the renderer's measuring) ----------

def wraps(text, width, size, cw=0.53):
    cpl = max(1, int(width / (size * cw)))
    lines, cur = 1, 0
    for wd in text.split():
        n = len(wd)
        if n > cpl:
            return 99
        if cur == 0:
            cur = n
        elif cur + 1 + n <= cpl:
            cur += 1 + n
        else:
            lines, cur = lines + 1, n
    return lines


def fit_size(text, width, height, base, floor=9, lines_max=2):
    for sz in range(int(base), floor - 1, -1):
        n = wraps(text, width, sz)
        if n <= lines_max and n * sz * 1.12 <= height:
            return sz
    return None


def level(s):
    return "read" if s >= 0.73 else ("map" if s >= 0.2 else "areas")


# ---------- drawing a board ----------

def mirror(x, w, rtl):
    return BW - x - w if rtl else x


def edge_svg(s, rtl=False):
    px = 1 / s
    lv = level(s)
    out = []
    for j, (a, b, k) in enumerate(EDGES):
        na, nb = NODES[a], NODES[b]
        x1, x2 = na["x"] + CW, nb["x"]
        y1, y2 = na["y"] + CH / 2, nb["y"] + CH / 2
        gx = x1 + PAD + 8 + k * 7           # each edge gets its own lane in the gap
        if rtl:
            x1, x2, gx = BW - x1, BW - x2, BW - gx
        tip = -6 * px if not rtl else 6 * px
        d = f"M{x1:.1f} {y1:.1f}H{gx:.1f}V{y2:.1f}H{x2 + tip:.1f}"
        out.append(f'<path class="e" d="{d}" marker-end="url(#arr)"/>')
        lab = EDGE_LABELS.get(j)
        if lab and lv == "read" and 12.5 * s >= 9:
            lx = (gx + x2) / 2
            out.append(f'<foreignObject x="{lx - 40:.0f}" y="{y2 - 13:.0f}" width="80" height="26"><div class="elbl">{lab}</div></foreignObject>')
    op = {"read": .85, "map": .55, "areas": .35}[lv]
    return (f'<svg class="edges" width="{BW}" height="{BH}" viewBox="0 0 {BW} {BH}" style="opacity:{op}"><defs><marker id="arr" viewBox="0 0 10 10" refX="8" refY="5" '
            f'markerWidth="7" markerHeight="7" orient="auto"><path d="M1 1L9 5L1 9" fill="none" stroke="currentColor" stroke-width="1.6"/></marker></defs>{"".join(out)}</svg>')


def sec_label(sec, s, ar=False, rtl=False):
    name, sub = (LANES_AR[sec["li"]] if ar else LANES[sec["li"]][:2])
    avail = sec["w"] * s - 4
    room = (TOP if sec["y"] == TOP else ROWGAP) * s - 6     # vertical room above the section, on screen
    ns = max(24 * s, 15)
    lh, gap = 1.15, 8
    if ns * lh + gap > room:          # tight: set the tab tighter and let it use its own section's top padding
        lh, gap = 1.0, 2
        room += PAD * s
    while ns > 9 and (len(name) * 0.5 * ns > avail or ns * lh + gap > room):
        ns -= 1
    eb = max(11 * s, 9)
    # BRD-8: a name that would collide drops its eyebrow first, then shrinks
    show_eb = len(sub) * 0.74 * eb <= avail and ns >= 15 and eb * 1.2 + 2 + ns * lh + gap <= room
    inner = (f'<span class="eyebrow" style="font-size:{eb / s:.1f}px">{sub}</span>' if show_eb else "") + f'<b style="font-size:{ns / s:.1f}px;line-height:{lh}">{name}</b>'
    pad = gap / s
    sink = max(0.0, ns * lh + gap - ((TOP if sec["y"] == TOP else ROWGAP) * s - 6)) / s   # how far the tab sits inside its section
    side = "right" if rtl else "left"
    x = mirror(sec["x"], sec["w"], rtl)
    return (f'<div class="slbl" style="{side}:{(BW - x - sec["w"]) if rtl else x:.1f}px;top:{sec["y"] + sink:.1f}px;padding-bottom:{pad:.1f}px;max-width:{sec["w"]:.0f}px">{inner}</div>')


def card_html(k, s, changed, found, focus, selected, ar=False, rtl=False):
    n = NODES[k]
    lv = level(s)
    key = WORD_KEY[n["st"]]
    x = mirror(n["x"], n["w"], rtl)
    style = f'left:{x:.1f}px;top:{n["y"]:.1f}px;width:{n["w"]}px;height:{n["h"]}px'
    cls = ["card", "lv-" + lv, "s-" + key]
    if k in found:
        cls.append("hit")
    if k == focus:
        cls.append("focus")
    if k == selected:
        cls.append("sel")
    inner = ""
    if lv == "read":
        if k in changed:
            cls.append("chg")
        if k in NOTED:
            cls.append("noted")
        ps = max(10 * s, 9) / s
        pill = "" if n["st"] in QUIET else f'<span class="st s-{key}" style="font-size:{ps:.1f}px">{word(n["st"], ar)}</span>'
        inner = f'{pill}<h4{" class=q" if not pill else ""}>{title(k, ar)}</h4><p>{body(k, ar)}</p>'
    elif lv == "map":
        w_scr, h_scr = (CW - 2 * 3 / s) * s, (CH - 2 * 3 / s) * s
        sz = fit_size(title(k, ar), w_scr - 6, h_scr, base=min(19 * s * 1.2, 15))
        if sz:
            inner = f'<h4 style="font-size:{sz / s:.1f}px"><span>{title(k, ar)}</span></h4>'
    if k in changed and lv != "read":
        inner += '<i class="cdot"></i>'
    return f'<div class="{" ".join(cls)}" style="{style}">{inner}</div>'


def world(s, tx, ty, changed=(), found=(), focus=None, selected=None, ar=False, rtl=False):
    parts = [edge_svg(s, rtl)]
    for sec in SECS:
        x = mirror(sec["x"], sec["w"], rtl)
        parts.append(f'<div class="sec" style="left:{x:.1f}px;top:{sec["y"]:.1f}px;width:{sec["w"]}px;height:{sec["h"]}px"></div>')
    for sec in SECS:
        parts.append(sec_label(sec, s, ar, rtl))
    for k in NODES:
        parts.append(card_html(k, s, changed, found, focus, selected, ar, rtl))
    return (f'<div class="world lv-{level(s)}" dir="{"rtl" if rtl else "ltr"}" style="--px:{1 / s:.3f}px;width:{BW}px;height:{BH}px;'
            f'transform:translate({tx:.1f}px,{ty:.1f}px) scale({s:.4f})">{"".join(parts)}</div>')


def shape_swatch(key):
    return f'<i class="sw6 s-{key}"></i>'


def legend(ar=False, compact=False, selected=None):
    c = counts()
    rows = ""
    for w in WORDS:
        if selected and selected[0] == w:
            pos, tot = num(selected[1], ar), num(c[w], ar)
            step = (f'{pos} من {tot}' if ar else f'{pos} of {tot}')
            rows += (f'<span class="lg on">{shape_swatch(WORD_KEY[w])}<b>{word(w, ar)}</b><em class="lstep">{step}<span class="lnav">‹ ›</span></em></span>')
        else:
            rows += f'<span class="lg">{shape_swatch(WORD_KEY[w])}<b>{word(w, ar)}</b><i>{num(c[w], ar)}</i></span>'
    return f'<div class="legend{" compact" if compact else ""}">{rows}</div>'


def zoom_panel(s, with_legend=False, ar=False, phone=False):
    lg = legend(ar, compact=True) if with_legend else ""
    pct = (num(round(s * 100), True) + "٪") if ar else f"{round(s * 100)}%"
    fit = "ملاءمة" if ar else "Fit"
    row = (f'<span class="zr">{pct}</span><span class="fit">{fit}</span>' if phone       # pinch zooms on the phone: no minus and plus
           else f'<span>−</span><span class="zr">{pct}</span><span>+</span><span class="fit">{fit}</span>')
    return f'<div class="zpanel glass">{lg}<div class="zoomrow{" ph" if phone else ""}">{row}</div></div>'


def fit_scale(cw, ch, top=24, bottom=24, side=24):
    s = min((cw - 2 * side) / BW, (ch - top - bottom) / BH)
    return s, (cw - BW * s) / 2, top + (ch - top - bottom - BH * s) / 2


def board_outline(cur=0, dots=(), ar=False, legend_sel=None, extra=""):
    names = [l[0] for l in LANES_AR] if ar else [l[0] for l in LANES]
    items = "".join(f'<a class="{"cur" if i == cur else ""} {"chgd" if i in dots else ""}">{nm}<span class="cnt">{num(LANES[i][2], ar)}</span></a>' for i, nm in enumerate(names))
    st = "الأقسام" if ar else "Sections"
    return (f'<nav class="outline bout"><div class="bmeta">{legend(ar, selected=legend_sel)}{extra}</div>'
            f'<div class="otitle">{st}</div>{items}<div class="prog"><i style="height:30%"></i></div></nav>')


def hover_label(k, s, tx, ty, ar=False, rtl=False):
    """BRD-8 at the map and areas levels: a small solid label with the box's title and word, beside the box."""
    n = NODES[k]
    x = mirror(n["x"], n["w"], rtl)
    lx, ly = tx + (x + CW) * s + 8, ty + n["y"] * s - 4
    return f'<div class="hlabel pop" style="left:{lx:.0f}px;top:{ly:.0f}px"><b>{title(k, ar)}</b><span>{word(n["st"], ar)}</span></div>'


def board(s=None, tx=None, ty=None, outline=True, overlay="", changed=(), found=(), dots=(), cur=0, focus=None, selected=None,
          w=1176, h=760, ar=False, rtl=False, zoom=True, fit_top=24, legend_sel=None, label_for=None, rail_extra="", extra_svg=None):
    cw, ch = w - (220 if outline else 0), h - 52
    if s is None:
        s, tx, ty = fit_scale(cw, ch, top=fit_top)
    lab = hover_label(label_for, s, tx, ty, ar, rtl) if label_for else ""
    svg = extra_svg(s, tx, ty) if extra_svg else ""
    canvas = (f'<div class="canvas weave" style="background-size:{44 * s:.1f}px {44 * s:.1f}px">'
              f'{world(s, tx, ty, changed, found, focus, selected, ar, rtl)}{svg}{lab}'
              f'{zoom_panel(s, with_legend=not outline, ar=ar) if zoom else ""}{overlay}</div>')
    if outline:
        return f'<div class="bwrap">{board_outline(cur, dots, ar, legend_sel, rail_extra)}{canvas}</div>'
    return f'<div class="bwrap solo">{canvas}</div>'


def section_view(li, s, cw, top=70, side=16, rtl=False):
    sec = SECS[li]
    if rtl:   # the mirrored section's right edge at the right margin
        tx = cw - side - (BW - sec["x"]) * s
    else:
        tx = side - sec["x"] * s
    ty = top - sec["y"] * s
    return tx, ty


NOTE_CARD = '''<div class="notecard pop" style="left:{x}px;top:{y}px"><div class="eyebrow">Approve · Approval flow</div>
<div class="nt">Every decision is refused</div><p>Approve and Return both answer <code>403 decision_forbidden</code>, and the page shows nothing. The check reads the reviewer's role where it should read the approver's.</p>
<div class="refs"><div class="eyebrow">Sources</div><code>server/approvals.py:118</code><code>walk/approver.md, step 4</code><code>shots/approve-403.png</code></div></div>'''

# ---------- notes with blocks ----------

_C = counts()
TILES = (f'<div class="tiles"><div class="tile"><b>{len(NODES)}</b><span>boxes on the map</span></div><div class="tile"><b>{_C["Works"]}</b><span>work end to end</span></div>'
         f'<div class="tile"><b>{_C["Broken"]}</b><span class="tw"><i class="sw6 s-broken"></i>Broken</span></div><div class="tile"><b>{_C["Missing"]}</b><span class="tw"><i class="sw6 s-missing"></i>Missing</span></div></div>')
def bar_html(width):
    """BLK-6: segments in proportion to their counts; a label that does not fit its segment moves to the key below."""
    total = sum(_C.values())
    usable = width - 2 * (len(WORDS) - 1)          # the 2 px gaps between segments
    segs, key = "", ""
    for w in WORDS:
        seg_w = usable * _C[w] / total                 # exact share, borders included
        lab = f"{w} {_C[w]}"
        fits = len(lab) * 7.4 + 18 <= seg_w
        segs += f'<span class="s-{WORD_KEY[w]}" style="width:{seg_w:.1f}px">{lab if fits else ""}</span>'
        if not fits:
            key += f'<span class="bk">{shape_swatch(WORD_KEY[w])}{lab}</span>'
    return f'<div class="bar" style="width:{width}px">{segs}</div>' + (f'<div class="barkey">{key}</div>' if key else "")


BAR = bar_html(640)

NOTE_PAGE = f'''<div class="strip"><span>assessment</span><span>updated 2026-10-14</span></div>
<h1 class="title">Requests service: where it stands</h1>
<p>The service takes a request from the form to an approver's queue. It cannot record a decision yet<sup class="fn on">1</sup>, so nothing reaches billing.</p>
{TILES}
<h2>By state</h2>
{BAR}
<p>Two of the {_C["Broken"]} broken boxes share one cause<sup class="fn">2</sup>: the approval check reads the wrong role.</p>'''
NOTE_FN = '<div class="fncard pop"><div class="eyebrow">Note 1</div><p>Approve and Return both answer 403. Source: <code>server/approvals.py:118</code>.</p></div>'

# ---------- a sealed page ----------

KIT_PAGE = '''<div class="kitpage"><div class="kp-head"><div class="eyebrow">Lab report · day 3</div><h1>What the cluster does at night</h1>
<div class="kp-tabs"><b>Timeline</b><span>Costs</span><span>Tips</span></div></div>
<div class="kp-grid"><div class="kp-line"><i style="left:4%"></i><i style="left:22%"></i><i class="bad" style="left:48%"></i><i style="left:71%"></i><i style="left:94%"></i>
<span class="a0">00:00 scale down</span><span class="a1">02:10 job retried</span><span class="a2">06:00 scale up</span></div>
<div class="kp-cards"><div class="kp-c"><b>3</b><span>nodes asleep</span></div><div class="kp-c"><b>41%</b><span>cost saved</span></div><div class="kp-c"><b>1</b><span>retry</span></div></div>
<p class="kp-p">{hint} The page's own scripts draw the timeline; Linen gives it the fonts and the look.</p></div></div>'''

# ---------- Mac: settings, iPhone pane ----------


def qr(n=29, seed=4):
    rnd = random.Random(seed)
    cells = []
    for y in range(n):
        for x in range(n):
            finder = any(x0 <= x < x0 + 7 and y0 <= y < y0 + 7 for x0, y0 in [(0, 0), (n - 7, 0), (0, n - 7)])
            if finder:
                fx = x if x < 7 else x - (n - 7)
                fy = y if y < 7 else y - (n - 7)
                on = fx in (0, 6) or fy in (0, 6) or (2 <= fx <= 4 and 2 <= fy <= 4)
            else:
                on = rnd.random() < 0.47
            if on:
                cells.append(f'<rect x="{x}" y="{y}" width="1.02" height="1.02"/>')
    return f'<svg class="qr" viewBox="-2 -2 {n + 4} {n + 4}"><rect x="-2" y="-2" width="{n + 4}" height="{n + 4}" fill="#FBF9F4"/><g fill="#284734">{"".join(cells)}</g></svg>'


def iphone_pane():
    pins = [("files", "projects/requests (folder, 14 files)", "1.4 MB", "2 references outside it: shared/logo.png, specs/rules.md"),
            ("files", "notes/plans (folder, 38 files)", "4.1 MB", "")]
    rows = "".join(f'<div class="pin">{icon(k)}<span class="pp">{p}{"<em>" + o + " · <b class=link>Also keep these 2 files</b></em>" if o else ""}</span><span class="ps">{s}</span><span class="link">Unpin</span></div>' for k, p, s, o in pins)
    body = f'''<div class="settings weave"><div class="scol wide2"><div class="eyebrow">Linen</div><h1 class="stitle">iPhone</h1>
<div class="pair"><div>{qr()}</div><div class="pairtxt"><b>Pairing with a phone</b><p>The phone scanned the code. Check that it shows the same six digits, name it, then Allow.</p>
<div class="namefield"><span class="sk">Name</span><span class="nf">iPhone</span><span class="muted small">iOS reports every phone as "iPhone"; type a name here</span></div>
<div class="digits sm">418 207</div><div class="row"><button class="btn ink">Allow</button><button class="btn line">Cancel</button></div><span class="muted small">Code valid for 1:42 · one pairing at a time</span></div></div>
<div class="eyebrow r">Paired</div><div class="srow"><span>{icon("phone")} Hatim's iPhone<span class="ps"> (named at pairing) · last seen 2 min ago · install expires in 5 days</span></span><span class="link">Forget</span></div>
<div class="srow small"><span class="sk">Reinstall before it expires</span><code>make ios-install</code></div>
<div class="eyebrow r">Kept on iPhone · 5.5 MB of 2 GB</div>{rows}
<div class="srow small"><span class="sk">Helper</span><span>Running · starts at login · local network allowed</span></div>
<div class="srow small"><span class="sk">Sealed pages</span><span>Self-test passed after macOS 26.5 · 09:02</span></div></div></div>'''
    return window("iPhone", "Settings", body, w=760, h=800, toolbar=[])


def pdf_preview():
    """Two A4 portrait pages of one tall section, split after its fifth row; body prints at 14 pt here (the floor is 9 pt)."""
    def page(rows, cont):
        cards = "".join(f'<div class="pc s-{WORD_KEY[NODES[(3, r * 2 + c)]["st"]]}"><i></i><i></i></div>' for r in rows for c in (0, 1) if (3, r * 2 + c) in NODES)
        return (f'<div class="pg"><div class="pgh">Records{", continued" if cont else ""}<span>rows {rows[0] + 1}–{rows[-1] + 1}</span></div>'
                f'<div class="pcs">{cards}</div><div class="pgf">{2 * 4 + (2 if cont else 1)} / 20</div></div>')
    return f'<div class="pdfprev">{page(range(0, 5), False)}{page(range(5, 10), True)}<span class="muted small">Records, 19 boxes: body 14 pt, split after row 5.</span></div>'


def export_sheet():
    body = board(outline=False, zoom=False, w=1176, h=700)
    sheet = f'''<div class="sheetpanel pop"><div class="eyebrow">Export</div><div class="nt">Requests readiness</div>
<div class="seg wide"><b>PDF</b><span>PNG</span></div>
<label class="opt"><i></i><span><b>Whole board</b><em>1 page · {BW:,} × {BH:,} pt · vector</em></span></label>
<label class="opt on"><i></i><span><b>Sections</b><em>20 pages · A4 portrait, chosen by the sections' shape · body never under 9 pt; a section taller than a page splits between rows</em></span></label>
{pdf_preview()}
<div class="srow small"><span class="sk">Number the notes and list their sources after</span><span class="tick">✓</span></div>
<div class="srow small"><span class="sk">Paper</span><span class="pop1">Paper · white</span></div>
<p class="muted small">Text stays searchable, Arabic included; Thmanyah is drawn as outlines, so none of its font data goes in.</p>
<div class="row" style="justify-content:flex-end;margin-top:14px"><button class="btn line">Cancel</button><button class="btn ink">Export</button></div></div>'''
    return window("Requests readiness", "projects/requests", f'<div style="position:absolute;inset:0">{body}<div class="scrim"></div>{sheet}</div>', toolbar=BOARD_TOOLBAR, w=1176, h=700)


def problems():
    """BRD-1 as round 3 asked: only not-JSON and past-limit files are fatal; anything else is drawn with its problems listed."""
    probs = ('<div class="probline"><b>3 problems</b><span class="link">Hide</span></div><ul class="probs inrail">'
             '<li><code>nodes[14]</code><span>Team refund has no position, so it is not drawn. Run <code>linen layout</code>.</span></li>'
             '<li><code>edges[6]</code><span>Ends at "audit-log", which is not on the board: drawn to a gap.</span></li>'
             '<li><code>nodes[22]</code><span>"Done" is not one of this board&#8217;s words: drawn without a word.</span></li></ul>')
    s = 0.45
    tx, ty = section_view(2, s, 1176 - 220, top=70, side=30)

    def gap(s, tx, ty):
        # edges[6] leaves Payment run for "audit-log", which is not on the board: drawn down into the empty slot below, to a gap mark
        n = NODES[(2, 15)]
        x = tx + (n["x"] + CW / 2) * s
        y1, y2 = ty + (n["y"] + CH) * s, ty + (n["y"] + ROW + CH * 0.45) * s
        return (f'<svg class="gapsvg" width="100%" height="100%"><path d="M{x:.0f} {y1:.0f}V{y2:.0f}" class="dang"/>'
                f'<path d="M{x - 7:.0f} {y2 + 3:.0f}h14M{x - 7:.0f} {y2 + 8:.0f}h14" class="gapm"/></svg>'
                f'<div class="gapchip" style="left:{x + 12:.0f}px;top:{y2 - 8:.0f}px">audit-log?</div>')
    main = window("Requests readiness", "projects/requests", board(s=s, tx=tx, ty=ty, cur=2, rail_extra=probs, extra_svg=gap), toolbar=BOARD_TOOLBAR)
    last = ('<div class="scriptsoff"><span>This version has 3 problems · showing the last good board from 14:02</span><b>Show</b></div>')
    small = window("Requests readiness", "projects/requests", f'<div style="position:absolute;inset:0">{board(outline=False, zoom=False, w=560, h=420, fit_top=60)}{last}</div>',
                   toolbar=[["back", "fwd"], ["find"]], w=560, h=420)
    return main + '<div style="height:22px"></div>' + small


# ---------- iPhone ----------

PW, PH = 390, 790   # phone body (below the status bar)


def phone(body, theme="paper", rtl=False, cls=""):
    return (f'<div class="phone {theme} {cls}" dir="{"rtl" if rtl else "ltr"}"><div class="sbar"><b>{"٩:٤١" if rtl else "9:41"}</b><span class="isl"></span><span class="sig">▪▪▪ ◔ ▮</span></div>'
            f'<div class="pbody">{body}</div><div class="home"></div></div>')


SYNC_LINES = {"ok": ("Up to date with MacBook Air · 2 min ago", ""), "away": ("Mac not nearby · copies from 09:14", ""),
              "sleep": ("MacBook Air is asleep · copies from 13:02", ""), "receiving": ("Receiving 3 of 9 files from MacBook Air", ""),
              "finishing": ("Finishing 3 files paused when you left", ""),
              "lan": ("Local network access is off for Linen", "Settings › Linen › Local Network"),
              "forgot": ("This Mac no longer knows this iPhone", "Pair again"),
              "expiry": ("This copy of Linen stops opening in 2 days", "Reinstall from your Mac"),
              "full": ("Not enough space on this iPhone · 1.2 GB needed", "")}


def library(rtl=False, state="ok"):
    line, sub = SYNC_LINES[state]
    if rtl:
        line, sub = "محدّث مع MacBook Air · قبل دقيقتين", ""
        groups = [("projects/requests", [("board", "جاهزية الطلبات", "projects/requests", "١٤:٢٠", True), ("note", "أين وصلت الخدمة", "projects/requests", "١٤:٠٢", True), ("page", "تقرير المختبر، اليوم ٣", "projects/requests", "أمس", False)]),
                  ("notes/plans", [("note", "خطة الربع", "notes/plans", "أمس", False), ("note", "ملاحظات الاجتماع", "notes/plans", "١٢ أكتوبر", False)])]
        head, eb, search = "المكتبة", "على هذا الآيفون", "ابحث بالاسم"
    else:
        groups = [("projects/requests", [("board", "Requests readiness", "projects/requests", "14:20", True), ("note", "Where it stands", "projects/requests", "14:02", True), ("page", "Lab report, day 3", "projects/requests", "Yesterday", False)]),
                  ("notes/plans", [("note", "Quarter plan", "notes/plans", "Yesterday", False), ("note", "Meeting notes", "notes/plans", "12 Oct", False)])]
        head, eb, search = "Library", "On this iPhone", "Search by name"
    rows = ""
    for g, items in groups:
        rows += f'<div class="eyebrow path grp">{g}</div>'
        for k, t, f, when, ch in items:
            rows += f'<div class="lrow{" chg" if ch else ""}">{icon(k, 18)}<span class="lt"><b>{t}</b></span><span class="lw">{when}</span></div>'
    bad = " bad" if state in ("full", "lan", "forgot", "expiry") else ""
    subl = f'<div class="syncsub">{sub}</div>' if sub else ""
    return (f'<div class="ptop"><span class="pmark">{mark(18)}</span><span class="pact">{icon("gear", 20)}</span></div>'
            f'<div class="phead"><div class="eyebrow">{eb}</div><h1>{head}</h1><div class="syncline{bad}">{line}</div>{subl}</div>'
            f'<div class="psearch">{search}</div><div class="plist">{rows}</div>')


def phone_settings():
    rows = [("Mac", "MacBook Air", "Forget this Mac"), ("Paired", "14 Oct, named “Hatim's iPhone”", ""), ("Kept here", "5.5 MB of 2 GB", ""),
            ("This copy", "Stops opening on 21 Oct", "Reinstall from your Mac"), ("Local network", "On", ""), ("Camera", "On, for pairing only", "")]
    items = "".join(f'<div class="srow"><span class="sk">{a}</span><span class="sv">{b}{"<b class=link>" + c + "</b>" if c else ""}</span></div>' for a, b, c in rows)
    return (library() + '<div class="scrim"></div><div class="psheet tall"><div class="grab"></div><div class="eyebrow">Linen on this iPhone</div>'
            f'<div class="nt">Settings</div>{items}</div>')


def phone_note():
    page = '''<div class="pnav"><span>{b}</span><span class="pnt">Where it stands</span><span>{o}{f}</span></div>
<div class="ppage"><div class="strip"><span>assessment</span><span>updated 14:02</span></div><h1 class="title">Requests service: where it stands</h1>
<p>The service takes a request from the form to an approver's queue. It cannot record a decision yet<sup class="fn on">1</sup>, so nothing reaches billing.</p>
{tiles}<h2>By state</h2>{bar}<p class="chgp">Two of the {br} broken boxes share one cause: the approval check reads the wrong role.</p></div>
<div class="psheet"><div class="grab"></div><div class="eyebrow">Note 1</div><p>Approve and Return both answer 403. Source: <code>server/approvals.py:118</code>.</p></div>'''
    return page.format(b=icon("chev", 20), o=icon("outline", 20), f=icon("find", 20), br=_C["Broken"],
                       tiles=TILES.replace('class="tiles"', 'class="tiles ph"'), bar=bar_html(356))


def pband(mode="Canvas", ar=False):
    segs = (("اللوحة", "قائمة") if ar else ("Canvas", "List"))
    a, b = (f"<b>{segs[0]}</b>", f"<span>{segs[1]}</span>") if mode == "Canvas" else (f"<span>{segs[0]}</span>", f"<b>{segs[1]}</b>")
    return f'<div class="pband glass"><span>{icon("chev", 20)}</span><span class="pseg">{a}{b}</span><span>{icon("outline", 20)}{icon("find", 20)}</span></div>'


def phone_board(view="open", ar=False, rtl=False, changed=()):
    if view == "overview":
        s, tx, ty = fit_scale(PW, PH, top=96, bottom=196, side=14)
        w = world(s, tx, ty, changed=changed, ar=ar, rtl=rtl)
        chip = ('<div class="pchip glass">3 changed since 09:14 · <b>Next</b></div>' if changed else "")
        return (f'<div class="canvas weave pcanvas" style="background-size:{44 * s:.1f}px">{w}</div>{pband("Canvas", ar)}{chip}'
                f'<div class="pzoom">{zoom_panel(s, with_legend=True, ar=ar, phone=True)}</div>')
    s = 0.74
    tx, ty = section_view(0, s, PW, top=104, side=14, rtl=rtl)
    if view == "note":
        tx, ty = section_view(2, s, PW, top=104, side=14, rtl=rtl)
        ty -= 2 * ROW * s
        w = world(s, tx, ty, focus=(2, 6), ar=ar, rtl=rtl)
        sheet = '''<div class="psheet tall"><div class="grab"></div><div class="eyebrow">Approve · Approval flow</div><div class="nt">Every decision is refused</div>
<p>Approve and Return both answer <code>403 decision_forbidden</code>, and the page shows nothing.</p><div class="eyebrow">Sources</div><code>server/approvals.py:118</code></div>'''
        return f'<div class="canvas weave pcanvas" style="background-size:{44 * s:.1f}px">{w}</div>{pband("Canvas", ar)}{sheet}'
    w = world(s, tx, ty, ar=ar, rtl=rtl)
    return f'<div class="canvas weave pcanvas" style="background-size:{44 * s:.1f}px">{w}</div>{pband("Canvas", ar)}'


def phone_board_list(ar=False):
    out = {}
    for a, b, _ in EDGES:
        out.setdefault(a, []).append(title(b, ar))
    rows = ""
    for li in (0, 1):
        name, sub = (LANES_AR[li] if ar else LANES[li][:2])
        rows += f'<div class="eyebrow grp">{sub}</div><h2 class="lsec">{name}</h2>'
        for i in range(5 if li == 0 else 2):
            k = (li, i)
            to = out.get(k)
            lead = f'<span class="lto">{"يؤدي إلى" if ar else "Leads to"} {"، ".join(to) if ar else ", ".join(to)}</span>' if to else ""
            n = NODES[k]
            pill = "" if n["st"] in QUIET else f'<span class="st s-{WORD_KEY[n["st"]]}">{word(n["st"], ar)}</span>'
            rows += (f'<div class="brow"><span class="bt">{pill}<b>{title(k, ar)}</b>'
                     f'<span>{body(k, ar)}</span>{lead}</span></div>')
    return f'{pband("List", ar)}<div class="ppage blist">{rows}</div>'


def phone_page():
    page = KIT_PAGE.format(hint="Tap any step for its log line.")
    return (f'<div class="pnav"><span>{icon("chev", 20)}</span><span class="pnt">Lab report, day 3</span><span>{icon("find", 20)}</span></div>'
            f'<div class="ppage kitph">{page}</div>')


def phone_pair(step):
    if step == 0:   # camera access off
        return (f'<div class="pnav"><span>{icon("chev", 20)}</span><span class="pnt">Pair with a Mac</span><span></span></div>'
                f'<div class="cam off"><div class="camoff"><b>Camera access is off for Linen</b><span>Linen uses the camera only to read the pairing code on your Mac.</span>'
                f'<span class="syncsub">Settings › Linen › Camera</span></div></div>')
    if step == 1:
        return (f'<div class="pnav"><span>{icon("chev", 20)}</span><span class="pnt">Pair with a Mac</span><span></span></div>'
                f'<div class="cam"><div class="vf"><i></i><i></i><i></i><i></i></div>{qr(21, 9)}</div>'
                f'<div class="pairnote"><b>Point at the code</b><p>In Linen on your Mac: Settings, iPhone, Pair. Linen will ask to find devices on your local network; that is how it reaches the Mac.</p></div>')
    return (f'<div class="pnav"><span>{icon("chev", 20)}</span><span class="pnt">Pair with a Mac</span><span></span></div>'
            f'<div class="match weave"><div class="eyebrow">MacBook Air</div><div class="digits">418 207</div><p>Check that your Mac shows the same six digits, then click Allow there.</p>'
            f'<div class="working">{mark(22)}<span>Waiting for Allow</span></div></div>')


def phone_share():
    targets = "".join(f'<span class="tg"><i>{icon(k, 22)}</i>{n}</span>' for k, n in [("airdrop", "AirDrop"), ("mail", "Mail"), ("files", "Save to Files")])
    return (phone_board("open") + '<div class="scrim"></div><div class="psheet tall share"><div class="grab"></div>'
            f'<div class="sharehead">{icon("board", 22)}<span><b>requests.canvas</b><em>JSON Canvas · 41 KB · the original file</em></span></div>'
            f'<div class="targets">{targets}</div><p class="muted small">PDF and PNG from the phone come later; the Mac exports them now.</p></div>')


def kinds():
    return '''<div class="kinds weave"><div class="card k lv-read s-works"><span class="st s-works">Works</span><h4>Card</h4><p>Title, status, Markdown body. The default.</p></div>
<div class="sticky c3 k"><b>Sticky</b> Short thoughts, one wash, no border.</div>
<div class="shape k"><svg viewBox="0 0 160 90"><path d="M80 4L156 45L80 86L4 45Z"/></svg><span>Decide</span></div>
<div class="shape k"><svg viewBox="0 0 160 90"><rect x="2" y="12" width="156" height="66" rx="33"/></svg><span>Start</span></div>
<div class="tnode k">Board title in serif</div>
<div class="card k lv-read notek"><div class="eyebrow">Note · <span class="path">plan.md</span></div><h4>Quarter plan</h4><p>Three goals and what each needs…</p></div>
<div class="card k lv-read linkk"><div class="eyebrow">Link · apple.com</div><h4>Network framework</h4></div></div>'''


def colours():
    names = ["1 · red", "2 · orange", "3 · yellow", "4 · green", "5 · cyan", "6 · purple"]
    washes = ["rule, sand", "rule at 60%", "paper-2, cream", "tint-1", "tint-2", "ink at 18%"]
    loom = "".join(f'<div class="sw loom c{i + 1}"><b>{n}</b><span>Flat wash: {washes[i]}</span></div>' for i, n in enumerate(names))
    bright = "".join(f'<div class="sw bright b{i + 1}"><b>{n}</b><span>Bright, FigJam-like</span></div>' for i, n in enumerate(names))
    return f'<div class="swatches"><div class="swrow">{loom}</div><div class="swrow">{bright}</div></div>'


def shapes_specimen(theme):
    rows = [("works", "Works", "ink outline", "9.3", "12.1"), ("partial", "Partial", "ink threads", "9.3", "12.1"), ("solid", "(spare)", "solid ink", "9.3", "12.1"),
            ("missing", "Missing", "dashed ink outline", "9.3", "12.1"), ("planned", "Planned", "dotted ink outline", "9.3", "12.1"),
            ("broken", "Broken", "rust fill (Night: plus an ink hairline)", "5.5", "2.2 → 10.8 with the hairline")]
    cells = "".join(f'<div class="spec"><div class="card lv-map s-{k}" style="--px:1px;position:relative;width:120px;height:56px"></div><b>{w}</b><span>{d}</span>'
                    f'<em>{"vs paper " + p if theme == "paper" else "vs Night ground " + n}</em></div>' for k, w, d, p, n in rows)
    return f'<div class="specs {theme} weave">{cells}</div>'


def contrast_table():
    """The table printed to stdout: each shape's carrying colour against the ground, the section wash and a card."""
    def hexrgb(h):
        h = h.lstrip("#")
        return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))

    def over(fg, a, bg):
        return tuple(f * a + b * (1 - a) for f, b in zip(fg, bg))

    def lum(c):
        def ch(v):
            return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
        r, g, b = (ch(v) for v in c)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b

    def ratio(a, b):
        la, lb = sorted((lum(a), lum(b)), reverse=True)
        return (la + 0.05) / (lb + 0.05)

    looks = {"Paper": dict(ground=hexrgb("#F6F3EB"), ink=hexrgb("#284734"), rust=hexrgb("#9C4A2E"), wash=over(hexrgb("#E3E7DF"), .42, hexrgb("#F6F3EB"))),
             "Night": dict(ground=hexrgb("#1F3328"), ink=hexrgb("#F6F3EB"), rust=hexrgb("#9C4A2E"), wash=over(hexrgb("#F6F3EB"), .04, hexrgb("#1F3328")))}
    lines = ["shape                look   vs ground  vs wash"]
    for shape, key in [("ink outline", "ink"), ("ink threads", "ink"), ("solid ink", "ink"), ("dashed ink outline", "ink"), ("dotted ink outline", "ink"), ("rust fill", "rust")]:
        for look, t in looks.items():
            g, w = ratio(t[key], t["ground"]), ratio(t[key], t["wash"])
            lines.append(f"{shape:20} {look:6} {g:9.2f} {w:8.2f}{'  under 3:1' if min(g, w) < 3 else ''}")
    t = looks["Night"]
    lines.append(f"rust fill + ink hairline, Night: hairline vs wash {ratio(t['ink'], t['wash']):.2f}")
    return "\n".join(lines)


CSS2 = '''
.bwrap{position:absolute;inset:0;display:grid;grid-template-columns:220px 1fr} .bwrap.solo{grid-template-columns:1fr}
.canvas{position:relative;overflow:hidden;height:100%}
.world{position:absolute;left:0;top:0;transform-origin:0 0}
.edges{position:absolute;left:0;top:0;overflow:visible;color:var(--ink2)} .edges .e{fill:none;stroke:var(--ink2);stroke-width:1.4;vector-effect:non-scaling-stroke}
.elbl{display:inline-block;font:500 12.5px var(--sans);color:var(--ink2);background:var(--paper);border:1px solid var(--rule);border-radius:2px;padding:1px 8px;white-space:nowrap;position:relative;left:50%;transform:translateX(-50%)}
.sec{position:absolute;background:rgba(227,231,223,.42);border:1px solid var(--rule);border-radius:2px}
.slbl{position:absolute;transform:translateY(-100%);display:flex;flex-direction:column;gap:2px;white-space:nowrap;overflow:hidden}
.slbl b{font-family:var(--serif);font-weight:300;line-height:1.15;color:var(--ink)} .slbl .eyebrow{line-height:1.2}
.world[dir=rtl] .slbl{align-items:flex-end;text-align:right} [dir=rtl] .eyebrow{letter-spacing:0}
.card{position:absolute;background:var(--paper);border:1px solid var(--rule);border-radius:2px;box-shadow:0 1px 2px rgba(40,71,52,.08),0 8px 20px rgba(40,71,52,.06);padding:12px 14px;box-sizing:border-box}
.card.lv-read h4{font:300 19px/1.25 var(--serif);color:var(--ink);margin:8px 0 4px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis} .card.lv-read p{margin:0;font-size:15px;line-height:1.45;color:var(--ink2)}
/* status pill at reading zoom: the word, backed by its shape */
.st{display:inline-block;font:500 10px/1 var(--sans);letter-spacing:.12em;text-transform:uppercase;padding:.4em .7em .3em;border:1px solid var(--ink);border-radius:2px;color:var(--ink);background:var(--paper)}
.st.s-partial{padding-inline-start:1.7em;background:repeating-linear-gradient(135deg,transparent 0 2.6px,var(--ink) 2.6px 3.6px) 0 0/1em 100% no-repeat,var(--paper)} [dir=rtl] .st.s-partial{background-position:100% 0}
.st.s-broken{background:var(--rust);border-color:var(--rust);color:#F6F3EB} .night .st.s-broken{border-color:var(--ink)}
.st.s-missing{border-style:dashed} .st.s-planned{border-style:dotted;border-width:1.5px}
/* the six shapes at the map and areas levels: drawn in ink, hairlines fixed on screen through --px */
.card.lv-map,.card.lv-areas{box-shadow:none;padding:calc(3*var(--px)) calc(4*var(--px));border:calc(1.5*var(--px)) solid var(--ink);background:var(--paper)}
.lv-map.s-partial,.lv-areas.s-partial,.sw6.s-partial{background:var(--paper) repeating-linear-gradient(135deg,transparent 0 calc(4.5*var(--px,1px)),var(--ink) calc(4.5*var(--px,1px)) calc(5.7*var(--px,1px)))}
.lv-map.s-solid,.lv-areas.s-solid,.sw6.s-solid{background:var(--ink)}
.lv-map.s-broken,.lv-areas.s-broken,.sw6.s-broken{background:var(--rust);border-color:var(--rust)}
.night .lv-map.s-broken,.night .lv-areas.s-broken,.night .sw6.s-broken{border-color:var(--ink)}
.lv-map.s-missing,.lv-areas.s-missing,.sw6.s-missing{border-style:dashed;background:transparent}
.lv-map.s-planned,.lv-areas.s-planned,.sw6.s-planned{border-style:dotted;background:transparent;border-width:calc(2*var(--px,1px))}
.card.lv-map h4{margin:0;font-family:var(--sans);font-weight:500;line-height:1.1;color:var(--ink);overflow:hidden}
.card.lv-map h4 span{background:var(--paper);box-shadow:0 0 0 calc(1.5*var(--px)) var(--paper);-webkit-box-decoration-break:clone;box-decoration-break:clone}
.card.lv-map.s-partial h4{background:var(--paper);margin:calc(-3*var(--px)) calc(-4*var(--px)) 0;padding:calc(3*var(--px)) calc(4*var(--px)) calc(3*var(--px));border-bottom:calc(1.5*var(--px)) solid var(--ink)} .card.lv-map.s-partial h4 span{background:transparent;box-shadow:none}
.night .card.lv-map.s-partial h4{background:#1F3328}
.card.lv-map.s-broken h4 span{background:var(--rust);box-shadow:0 0 0 calc(1.5*var(--px)) var(--rust);color:#F6F3EB}
.card.lv-map.s-missing h4 span,.card.lv-map.s-planned h4 span{background:transparent;box-shadow:none}
.sw6{display:inline-block;width:18px;height:12px;border:1.5px solid var(--ink);box-sizing:border-box;border-radius:1px;background:var(--paper);flex:none;vertical-align:-1px}
/* change marks: a thread at reading zoom, a fixed 6 px ink dot with a paper ring at the map and areas levels */
.card.chg::before{content:"";position:absolute;inset-inline-start:-8px;top:-1px;bottom:-1px;width:3px;background:var(--ink);border-radius:1px}
.cdot{position:absolute;top:calc(-3*var(--px));inset-inline-start:calc(-3*var(--px));width:calc(6*var(--px));height:calc(6*var(--px));border-radius:50%;background:var(--ink);box-shadow:0 0 0 calc(1.5*var(--px)) var(--paper)}
.card.noted::after{content:"";position:absolute;inset-inline-end:8px;bottom:8px;width:7px;height:7px;border-inline-end:1.6px solid var(--ink);border-bottom:1.6px solid var(--ink)}
.card.hit{outline:calc(1.5*var(--px,1px)) solid var(--ink);outline-offset:calc(3*var(--px,1px))} .card.hit.focus{outline-width:calc(3.5*var(--px,1px))}
.card.focus,.card.sel{outline:calc(2*var(--px,1px)) solid var(--ink);outline-offset:calc(3*var(--px,1px))}
.glass{background:rgba(246,243,235,.9);backdrop-filter:blur(8px);-webkit-backdrop-filter:blur(8px);border:1px solid var(--rule);border-radius:2px;box-shadow:0 10px 26px rgba(40,71,52,.12)}
.night .glass{background:rgba(31,51,40,.9)}
.btitle{font:300 24px/1.2 var(--serif);color:var(--ink);margin:2px 0 10px}
.legend{display:flex;flex-direction:column;gap:6px} .lg{display:flex;align-items:center;gap:8px;font-size:13px} .lg b{font-weight:500;color:var(--ink);flex:1} .lg i{font-style:normal;font-size:12.5px;color:var(--ink2)}
.legend.compact{flex-direction:row;flex-wrap:wrap;gap:6px 12px;padding-bottom:8px;margin-bottom:8px;border-bottom:1px solid var(--rule)} .legend.compact .lg b{flex:none}
.zpanel{position:absolute;bottom:14px;inset-inline-end:16px;padding:10px 12px;z-index:3;max-width:330px}
.zoomrow{display:flex;gap:14px;justify-content:space-between;font:500 12.5px var(--sans);color:var(--ink)} .zoomrow .fit{color:var(--ink2)}
.bout a{display:flex;justify-content:space-between} .bmeta{padding:0 22px 18px;margin-bottom:12px;border-bottom:1px solid var(--rule)} .bout .cnt{font-size:12.5px;color:var(--ink2);opacity:.75}
.bout a.chgd::after{display:none} .bout a.chgd .cnt::before{content:"";display:inline-block;width:6px;height:6px;border-radius:50%;background:var(--ink);margin-inline-end:8px;vertical-align:middle}
.notecard{width:340px;padding:16px 18px;z-index:6} .nt{font:300 24px/1.25 var(--serif);color:var(--ink);margin:4px 0 8px} .notecard p{margin:0 0 12px;font-size:15px;line-height:1.5}
.refs{display:flex;flex-direction:column;gap:4px;border-top:1px solid var(--rule);padding-top:10px} .refs code,.psheet code{font:13px var(--mono);color:var(--ink)}
code{font:13.5px var(--mono)}
.chip{position:absolute;bottom:18px;left:50%;transform:translateX(-50%);z-index:4;padding:8px 14px;font:500 13px var(--sans);color:var(--ink);display:flex;gap:12px;align-items:center;white-space:nowrap}
.chip b{font-weight:600} .chip .k{color:var(--ink2);font-weight:500}
.toast{position:absolute;bottom:22px;left:50%;transform:translateX(-50%);z-index:4;padding:10px 16px;font-size:13.5px;color:var(--ink2);display:flex;flex-direction:column;gap:2px;white-space:nowrap}
.toast b{font-weight:500;color:var(--ink)} .toast code{font-size:12.5px;color:var(--ink)}
.scrim{position:absolute;inset:0;background:rgba(31,51,40,.34);z-index:5}
.sheetpanel{top:0;left:calc(50% - 230px);width:460px;padding:20px 22px;z-index:6;border-top:0}
.seg.wide{display:flex;margin:6px 0 12px} .seg.wide>*{flex:1;text-align:center}
.opt{display:flex;gap:12px;align-items:flex-start;padding:10px 0;border-bottom:1px solid var(--rule)} .opt i{width:14px;height:14px;border:1.5px solid var(--ink);border-radius:50%;margin-top:3px;flex:none}
.opt.on i{background:radial-gradient(circle,var(--ink) 45%,transparent 50%)} .opt span{display:flex;flex-direction:column} .opt b{font-weight:500;color:var(--ink);font-size:14.5px} .opt em{font-style:normal;font-size:13px;color:var(--ink2)}
.srow.small{font-size:13.5px;padding:9px 0} .tick{color:var(--ink);font-weight:600}
.wide3{width:640px} .probs{list-style:none;padding:0;margin:8px 0 18px;align-self:stretch;text-align:start} .probs li{display:flex;flex-direction:column;gap:2px;padding:9px 0;border-bottom:1px solid var(--rule);font-size:14.5px}
.probs code{color:var(--ink)} .muted.small{font-size:13px}
/* notes with blocks */
.tiles{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin:6px 0 20px} .tiles.ph{grid-template-columns:repeat(2,1fr);gap:8px}
.tile{background:var(--paper);border:1px solid var(--rule);border-radius:2px;padding:12px 14px;display:flex;flex-direction:column;gap:2px;position:relative}
.tile b{font:300 34px/1.1 var(--serif);color:var(--ink)} .tile span{font-size:13.5px;color:var(--ink2)} .tile .tw{display:flex;align-items:center;gap:7px}
.tiles.ph .tile b{font-size:26px} .tiles.ph .tile{padding:10px}
.bar{display:flex;gap:2px;margin:4px 0 18px;height:30px;font:500 12px/30px var(--sans);color:var(--ink)} .bar span{border:1.5px solid var(--ink);padding:0 8px;white-space:nowrap;overflow:hidden;box-sizing:border-box;border-radius:1px;flex:none}
.bar .s-partial{padding-inline-start:20px;background:repeating-linear-gradient(135deg,transparent 0 4.5px,var(--ink) 4.5px 5.7px) 0 0/12px 100% no-repeat,var(--paper)}
.bar .s-broken{background:var(--rust);border-color:var(--rust);color:#F6F3EB} .bar .s-missing{border-style:dashed} .bar .s-planned{border-style:dotted;border-width:2px}
sup.fn{font:500 11px var(--sans);color:var(--ink);border-bottom:1px solid var(--t3);padding:0 2px;margin-inline-start:1px} sup.fn.on{background:var(--ink);color:var(--paper);border-radius:2px}
.notewrap{position:relative} .docwrap.norail{grid-template-columns:1fr} .docwrap.norail .foot{inset-inline-start:0} .fncard{top:188px;left:calc(50% + 376px);width:196px;padding:10px 12px;font-size:13.5px;line-height:1.45} .fncard p{margin:4px 0 0} .fncard code{font-size:11.5px;white-space:nowrap}
/* sealed page */
.kitpage{position:absolute;inset:0;overflow:hidden;background:var(--paper);color:var(--ink2)} .offwrap .kitpage{top:40px} .offwrap .kp-line{display:none}
.offwrap .kp-grid::before{content:"The timeline is drawn by this page's scripts";display:block;height:70px;margin-bottom:22px;border:1px dashed var(--t3);box-sizing:border-box;padding:24px 14px;font-size:13.5px;color:var(--ink2)} .kp-head{padding:34px 60px 0} .kp-head h1{font:300 40px/1.15 var(--serif);color:var(--ink);margin:6px 0 14px}
.kp-tabs{display:flex;gap:22px;border-bottom:1px solid var(--rule);font-size:14px} .kp-tabs>*{padding:8px 0} .kp-tabs b{font-weight:500;color:var(--ink);box-shadow:inset 0 -2px 0 var(--ink)} .kp-tabs span{color:var(--ink2)}
.kp-grid{padding:26px 60px} .kp-line{position:relative;height:70px;border-bottom:1px solid var(--rule);margin-bottom:22px} .kp-line i{position:absolute;bottom:-6px;width:11px;height:11px;border-radius:50%;background:var(--ink);margin-left:-5px} .kp-line i.bad{background:var(--rust)}
.kp-line span{position:absolute;top:8px;font-size:13px;color:var(--ink2);white-space:nowrap} .kp-line .a0{left:0} .kp-line .a1{left:48%;transform:translateX(-50%)} .kp-line .a2{right:0}
.kp-cards{display:grid;grid-template-columns:repeat(3,1fr);gap:14px} .kp-c{border:1px solid var(--rule);background:var(--paper);padding:14px;display:flex;flex-direction:column} .kp-c b{font:300 34px var(--serif);color:var(--ink)} .kp-c span{font-size:13.5px}
.kp-p{max-width:560px;font-size:15px;line-height:1.6;color:var(--ink2)}
.pagefoot{position:absolute;bottom:0;left:0;right:0;text-align:center;font-size:13.5px;color:var(--ink2);padding:8px;background:var(--paper);border-top:1px solid var(--rule);opacity:.9;z-index:3}
.scriptsoff{position:absolute;top:0;left:0;right:0;z-index:4;display:flex;justify-content:space-between;align-items:center;padding:9px 18px;background:var(--paper2);border-bottom:1px solid var(--rule);font-size:13.5px;color:var(--ink2)}
.scriptsoff b{font-weight:500;color:var(--ink);border-bottom:1px solid var(--t3)}
/* settings iPhone pane */
.wide2{max-width:680px} .pair{display:flex;gap:22px;align-items:center;padding:6px 0 16px;border-bottom:1px solid var(--rule)} .qr{width:150px;height:150px;display:block}
.pairtxt b{font:300 24px var(--serif);color:var(--ink);font-weight:300} .pairtxt p{margin:6px 0;font-size:14.5px;line-height:1.5} .pairtxt .row{margin:8px 0}
.digits.sm{font:300 34px var(--serif);color:var(--ink);letter-spacing:.06em}
.pin{display:flex;align-items:center;gap:10px;padding:9px 0;border-bottom:1px solid var(--rule);font-size:14px} .pin .ic{color:var(--ink)} .pp{flex:1;font-family:var(--mono);font-size:13px;display:flex;flex-direction:column} .pp em{font:12.5px var(--sans);font-style:normal;color:var(--ink2)}
.ps{color:var(--ink2);opacity:.8;font-size:13px} .link{color:var(--ink);font-weight:500;font-size:13px;border-bottom:1px solid var(--t3)}
.srow .ic{vertical-align:-3px;color:var(--ink)}
/* specimens */
.swatches{display:flex;flex-direction:column;gap:14px;background:var(--paper);padding:24px;border-radius:4px;width:max-content}
.swrow{display:flex;gap:14px} .sw{width:150px;height:110px;padding:12px;display:flex;flex-direction:column;justify-content:space-between;font-size:13px;border-radius:2px;box-sizing:border-box}
.sw b{font-weight:500;color:var(--ink)} .sw span{color:var(--ink2);font-size:12px}
.c1{background:#DAD5C8} .c2{background:rgba(218,213,200,.6)} .c3{background:#FBF9F4;box-shadow:inset 0 0 0 1px var(--rule)}
.c4{background:#E3E7DF} .c5{background:#C9D3CA} .c6{background:rgba(40,71,52,.18)}
.b1{background:#FFC7C2}.b2{background:#FFD8A8}.b3{background:#FFF1A8}.b4{background:#C3EBC6}.b5{background:#BDE9F2}.b6{background:#DCCBF5}
.specs{display:flex;gap:18px;padding:24px;border-radius:4px;width:max-content;background-size:22px 22px} .specs.night{background-color:#1F3328}
.spec{display:flex;flex-direction:column;gap:4px;width:150px;font-size:13px} .spec b{font-weight:500;color:var(--ink);margin-top:6px} .spec em{font-style:normal;font-size:12px;color:var(--ink2);opacity:.85}
.kinds{position:relative;width:1176px;height:300px;border-radius:4px;display:flex;gap:18px;padding:30px;box-sizing:border-box;align-items:flex-start;flex-wrap:wrap;background-size:22px 22px}
.kinds .k{position:relative} .kinds .card{width:220px;height:auto}
.sticky{width:160px;height:150px;padding:14px;font-size:15px;line-height:1.4;color:var(--ink2);box-sizing:border-box} .sticky b{display:block;font-weight:500;color:var(--ink)}
.shape{width:160px;height:90px;display:grid;place-items:center} .shape svg{position:absolute;inset:0;width:100%;height:100%;fill:var(--paper);stroke:var(--ink);stroke-width:1.4} .shape span{position:relative;font-size:15px;color:var(--ink)}
.tnode{font:300 40px/1.1 var(--serif);color:var(--ink);width:220px}
.notek{border-top:3px solid var(--t3)} .linkk h4{border-bottom:1px solid var(--t3);display:inline-block}
/* iPhone */
.phones{display:flex;gap:30px;flex-wrap:wrap;align-items:flex-start}
.phone{width:390px;height:844px;border-radius:56px;box-shadow:0 0 0 10px #1c1c1c,0 0 0 11px #3a3a3a,0 24px 50px rgba(31,51,40,.3);background:var(--paper);position:relative;overflow:hidden;color:var(--ink2);margin:11px;flex:none}
.sbar{height:54px;display:flex;align-items:center;justify-content:space-between;padding:0 32px;font:600 16px -apple-system,var(--sans);color:var(--ink);position:relative;z-index:8}
.isl{position:absolute;left:50%;top:11px;transform:translateX(-50%);width:122px;height:36px;border-radius:20px;background:#0c0c0c}
.sig{font-size:11px;letter-spacing:1px}
.pbody{position:absolute;inset:54px 0 0 0;overflow:hidden}
.home{position:absolute;bottom:8px;left:50%;transform:translateX(-50%);width:136px;height:5px;border-radius:3px;background:var(--ink);opacity:.8;z-index:9}
.ptop{display:flex;justify-content:space-between;padding:6px 18px;color:var(--ink)} .pmark{color:var(--ink)}
.phead{padding:6px 18px 10px} .phead h1{font:300 34px/1.15 var(--serif);color:var(--ink);margin:2px 0 6px}
.syncline{font-size:13.5px;color:var(--ink2);display:flex;align-items:center;gap:8px} .syncline::before{content:"";width:6px;height:6px;border-radius:50%;background:var(--ink);flex:none}
.syncline.bad{color:#F6F3EB;background:var(--rust);padding:6px 10px;border-radius:2px} .syncline.bad::before{background:#F6F3EB}
.syncsub{font:500 13px var(--sans);color:var(--ink);margin-top:6px;border-bottom:1px solid var(--t3);display:inline-block}
.psearch{margin:4px 18px 8px;padding:9px 12px;background:var(--paper2);border:1px solid var(--rule);border-radius:2px;font-size:16px;color:var(--ink2);opacity:.85}
.plist{padding:0 18px} .grp{padding:16px 0 6px} .lrow{display:flex;align-items:center;gap:12px;padding:11px 0;border-bottom:1px solid var(--rule);position:relative}
.lrow .ic{color:var(--ink);flex:none} .lt{flex:1;display:flex;flex-direction:column;min-width:0} .lt b{font-weight:500;font-size:16px;color:var(--ink);white-space:nowrap;overflow:hidden;text-overflow:ellipsis} .lt span{font-size:13px;color:var(--ink2);opacity:.8}
.lw{font-size:13px;color:var(--ink2);opacity:.8} .lrow.chg::before{content:"";position:absolute;inset-inline-start:-10px;top:12px;bottom:12px;width:3px;background:var(--ink);border-radius:1px}
.pnav{display:flex;align-items:center;justify-content:space-between;padding:8px 14px;color:var(--ink);border-bottom:1px solid var(--rule);background:var(--paper);position:relative;z-index:4} .pnav>span{display:flex;gap:16px;min-width:44px} .pnav>span:last-child{justify-content:flex-end}
.pnt{font:600 15px -apple-system,var(--sans);color:var(--ink);justify-content:center}
.ppage{padding:14px 16px 40px;font-size:17px;line-height:1.6} .ppage .title{font-size:30px;margin:4px 0 12px} .ppage h2{font:300 24px var(--serif);color:var(--ink);margin:18px 0 6px} .ppage p{margin:0 0 12px}
.chgp{position:relative} .chgp::before{content:"";position:absolute;inset-inline-start:-11px;top:4px;bottom:4px;width:2.5px;background:var(--ink)}
.psheet{position:absolute;left:0;right:0;bottom:0;background:var(--paper);border-top:1px solid var(--rule);box-shadow:0 -12px 30px rgba(40,71,52,.16);padding:10px 20px 34px;z-index:7;font-size:15.5px;line-height:1.5}
.psheet p{margin:6px 0 12px} .grab{width:38px;height:5px;border-radius:3px;background:var(--t3);margin:0 auto 12px}
.sharehead{display:flex;gap:12px;align-items:center;color:var(--ink);padding:4px 0 14px;border-bottom:1px solid var(--rule)} .sharehead span{display:flex;flex-direction:column} .sharehead b{font-weight:500} .sharehead em{font-style:normal;font-size:13px;color:var(--ink2)}
.targets{display:flex;gap:22px;padding:16px 0 10px} .tg{display:flex;flex-direction:column;align-items:center;gap:6px;font-size:12.5px;color:var(--ink2)} .tg i{width:56px;height:56px;border-radius:14px;background:var(--paper2);border:1px solid var(--rule);display:grid;place-items:center;color:var(--ink)}
.pcanvas{position:absolute;inset:0} .pband{position:absolute;top:6px;left:10px;right:10px;display:flex;align-items:center;justify-content:space-between;padding:9px 12px;color:var(--ink);z-index:5} .pband>span{display:flex;gap:16px}
.pzoom .zpanel{bottom:34px;left:12px;right:12px;max-width:none}
.pchip{position:absolute;top:66px;left:50%;transform:translateX(-50%);z-index:5;padding:7px 12px;font:500 13px var(--sans);color:var(--ink);white-space:nowrap}
.kitph .kitpage{position:relative} .kitph .kp-head{padding:18px 16px 0} .kitph .kp-head h1{font-size:28px} .kitph .kp-grid{padding:18px 16px} .kitph .kp-cards{grid-template-columns:1fr 1fr 1fr;gap:8px} .kitph .kp-c b{font-size:24px} .kitph .kp-line span{font-size:11.5px}
.kitph{padding:0} .kitph .kp-cards{margin-bottom:16px} .kp-cards{margin-bottom:18px}
.cam{position:absolute;top:52px;left:0;right:0;height:500px;background:#121a15;display:grid;place-items:center} .cam .qr{width:170px;height:170px;transform:rotate(-4deg);opacity:.95}
.vf{position:absolute;width:240px;height:240px} .vf i{position:absolute;width:34px;height:34px;border-color:#F6F3EB;border-style:solid;border-width:0}
.vf i:nth-child(1){top:0;left:0;border-top-width:3px;border-left-width:3px}.vf i:nth-child(2){top:0;right:0;border-top-width:3px;border-right-width:3px}.vf i:nth-child(3){bottom:0;left:0;border-bottom-width:3px;border-left-width:3px}.vf i:nth-child(4){bottom:0;right:0;border-bottom-width:3px;border-right-width:3px}
.pairnote{position:absolute;top:570px;left:24px;right:24px} .pairnote b{font:300 24px var(--serif);color:var(--ink);font-weight:300} .pairnote p{margin:4px 0;font-size:15px;line-height:1.45}
.match{position:absolute;top:52px;bottom:0;left:0;right:0;display:flex;flex-direction:column;align-items:center;padding:120px 30px 0;text-align:center;background-size:22px 22px}
.digits{font:300 52px var(--serif);color:var(--ink);letter-spacing:.06em;margin:10px 0 8px} .match p{font-size:15.5px;line-height:1.5;max-width:280px}
.working{display:flex;gap:10px;align-items:center;margin-top:26px;color:var(--ink);font-size:14px}
.pseg{display:flex;border:1px solid var(--rule);border-radius:2px;overflow:hidden;font:500 13px var(--sans)} .pseg>*{padding:5px 12px;color:var(--ink2)} .pseg b{background:var(--ink);color:var(--paper)}
.blist{position:absolute;top:58px;bottom:0;left:0;right:0;overflow:hidden} .lsec{margin:0 0 8px!important} .brow{display:flex;gap:12px;padding:10px 0;border-bottom:1px solid var(--rule);font-size:15px;line-height:1.4}
.brow .sw6{margin-top:5px}
.bt{display:flex;flex-direction:column} .bt b{font:300 19px var(--serif);color:var(--ink)} .bs{font:500 10.5px var(--sans);letter-spacing:.12em;text-transform:uppercase;color:var(--ink2);margin:2px 0} .lto{font-size:13.5px;color:var(--ink);margin-top:3px}
.night .card{background:#284734;border-color:rgba(246,243,235,.12)} .night .card.lv-map,.night .card.lv-areas{background:#1F3328;border-color:var(--ink)}
.night .lv-map.s-partial,.night .lv-areas.s-partial,.night .sw6.s-partial{background:#1F3328 repeating-linear-gradient(135deg,transparent 0 calc(4.5*var(--px,1px)),var(--ink) calc(4.5*var(--px,1px)) calc(5.7*var(--px,1px)))}
.night .lv-map.s-broken,.night .lv-areas.s-broken{background:var(--rust)} .night .lv-map.s-missing,.night .lv-areas.s-missing,.night .lv-map.s-planned,.night .lv-areas.s-planned{background:transparent}
.night .card.lv-map h4 span{background:#1F3328;box-shadow:0 0 0 calc(1.5*var(--px)) #1F3328}
.night .sec{background:rgba(246,243,235,.04)} .night .elbl{background:#1F3328} .night .edges .e{stroke:rgba(246,243,235,.75)} .night .edges{color:rgba(246,243,235,.75)}
.night .weave{background-image:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='44' height='44'%3E%3Cg stroke='%23F6F3EB' stroke-opacity='.09' stroke-width='1.3' stroke-linecap='round'%3E%3Cpath d='M8.5 11h5M33 8.5v5M11 30.5v5M30.5 33h5'/%3E%3C/g%3E%3C/svg%3E")}
.night .psearch{background:#284734} .night .home{background:#F6F3EB} .night .sw6{background:#1F3328}
.night .cdot{box-shadow:0 0 0 calc(1.5*var(--px)) #1F3328}
.night .card.lv-map.s-broken,.night .card.lv-areas.s-broken,.night .sw6.s-broken,.night .bar .s-broken{background:var(--rust);border-color:var(--ink)}
.night .card.lv-map.s-solid,.night .card.lv-areas.s-solid,.night .sw6.s-solid{background:var(--ink)} .spec span{color:var(--ink2)}
/* round 3 */
.eyebrow.path,.eyebrow .path,.path{text-transform:none;letter-spacing:.02em}
.card.lv-read h4.q{margin-top:0}
.lg.on{background:var(--ink);color:var(--paper);margin:0 -10px;padding:3px 10px;border-radius:2px} .lg.on b{color:var(--paper)} .lg.on .sw6{border-color:var(--paper)}
.lstep{font-style:normal;font-size:12.5px;display:flex;gap:8px;align-items:center} .lnav{font-weight:600;letter-spacing:.2em}
.legend .lg{cursor:default;padding:3px 10px;margin:0 -10px;border-radius:2px}
.hlabel{padding:6px 10px;z-index:6;display:flex;flex-direction:column;gap:1px;font-size:13px;white-space:nowrap;border:1px solid var(--ink)} .hlabel b{font-weight:500;color:var(--ink)} .hlabel span{color:var(--ink2);font-size:12px}
.barkey{display:flex;gap:14px;flex-wrap:wrap;margin:-10px 0 18px;font:500 12.5px var(--sans);color:var(--ink)} .bk{display:flex;gap:6px;align-items:center}
.probline{display:flex;justify-content:space-between;align-items:center;margin-top:14px;padding-top:12px;border-top:1px solid var(--rule);font-size:13.5px} .probline b{font-weight:600;color:var(--rust)}
.night .probline b{color:var(--ink)}
.probs.inrail{margin:6px 0 0;font-size:12.5px;line-height:1.4} .probs.inrail li{padding:7px 0;gap:1px;font-size:12.5px} .probs.inrail code{font-size:11.5px}
.gapsvg{position:absolute;inset:0;pointer-events:none;z-index:2} .dang{fill:none;stroke:var(--ink2);stroke-width:1.4;stroke-dasharray:4 3} .gapm{stroke:var(--ink);stroke-width:2}
.gapchip{position:absolute;z-index:3;font:500 12px var(--mono);color:var(--ink);background:var(--paper);border:1px solid var(--ink);padding:1px 6px;border-radius:2px}
.namefield{display:flex;gap:10px;align-items:center;margin:8px 0;flex-wrap:wrap} .nf{border:1px solid var(--ink);padding:5px 10px;min-width:140px;font-size:14px;color:var(--ink);background:var(--paper2)}
.honest{display:flex;flex-direction:column;gap:6px;align-items:flex-start;margin:34px 60px;padding:22px 0;border-top:1px solid var(--rule);font-size:14.5px} .honest b{font:300 24px var(--serif);color:var(--ink)} .honest .btn{margin-top:8px}
.pdfprev{display:flex;gap:14px;align-items:flex-end;margin:6px 0 4px;flex-wrap:wrap} .pdfprev .muted{flex-basis:100%}
.pg{width:118px;height:167px;background:#fff;border:1px solid var(--rule);box-shadow:0 4px 10px rgba(40,71,52,.12);padding:8px;box-sizing:border-box;display:flex;flex-direction:column;gap:5px;position:relative}
.pgh{font:300 9px var(--serif);color:var(--ink);display:flex;justify-content:space-between} .pgh span{font:500 6px var(--sans);color:var(--ink2)}
.pgh span{white-space:nowrap} .pcs{display:grid;grid-template-columns:1fr 1fr;gap:4px} .pc{height:18px;border:1px solid #284734;border-radius:1px;padding:3px;box-sizing:border-box;display:flex;flex-direction:column;gap:2px}
.pc i{display:block;height:2px;background:#284734;opacity:.7} .pc i+i{width:60%;opacity:.35} .pc.s-broken{background:#9C4A2E;border-color:#9C4A2E} .pc.s-broken i{background:#F6F3EB}
.pc.s-missing{border-style:dashed} .pc.s-planned{border-style:dotted} .pc.s-partial{background:repeating-linear-gradient(135deg,transparent 0 3px,rgba(40,71,52,.5) 3px 4px)}
.pgf{position:absolute;bottom:5px;left:0;right:0;text-align:center;font:6px var(--sans);color:var(--ink2)}
.sheetpanel .opt em{max-width:380px}
.zoomrow.ph{justify-content:space-between}
.pband{padding:3px 6px} .pband .ic,.pnav .ic{box-sizing:content-box;padding:12px} .pband>span{gap:0} .pnav{padding:0 4px} .pnav>span{gap:0}
.pseg>*{display:flex;align-items:center;min-height:44px;padding:0 16px}
.pchip{top:76px}
.brow .bt .st{align-self:flex-start;margin-bottom:4px;font-size:9.5px}
.cam.off{background:#1F3328;display:flex;align-items:center;justify-content:center} .camoff{display:flex;flex-direction:column;gap:8px;padding:0 34px;color:#F6F3EB;font-size:15px;line-height:1.45}
.camoff b{font:300 26px var(--serif);color:#F6F3EB} .cam.off .syncsub{color:#F6F3EB;border-color:rgba(246,243,235,.5)}
.sv{display:flex;flex-direction:column;align-items:flex-end;gap:2px;text-align:end;font-size:14px} .psheet .srow{padding:10px 0}
.toast.pop{background:var(--paper)}

'''

HEAD = f'''<div class="sheet-head">{mark(30)}<div class="eyebrow" style="margin-top:14px">Linen 2 · screen sketch · PRD draft 0.5</div>
<h1>Linen 2</h1><p>Boards, sealed pages, notes with blocks and export on the Mac; Linen on the iPhone with its own link to the Mac. Boards are drawn at reference scale (170 boxes in ten sections) by BRD-8's rules: no text under 9 px at rest, state as one of six ink shapes. Loom's tokens only, Thmanyah named and never embedded, sample content only. Built by <code>docs/design/build_screens2.py</code> on top of the v1 sketch.</p></div>'''


def build():
    s = []
    c = counts()
    mix = ", ".join(f"{c[w]} {w.lower()}" for w in WORDS)
    broken = sorted(k for k in NODES if NODES[k]["st"] == "Broken")
    s.append(screen(1, "A board at overview", f"The reference-scale board (170 boxes: {mix}) at Fit on a 13-inch window, 20 percent: a box is 48 px wide, so no title fits at 9 px and each box shows its state as its shape, while section names keep 15 px. The rail starts at the legend, and its rows work like find: Broken is selected, its boxes are ringed, ‹ › steps through them, and the current one shows its title and word in a small solid label.",
                    window("Requests readiness", "projects/requests", board(found=set(broken), focus=broken[0], legend_sel=("Broken", 1), label_for=broken[0]), toolbar=BOARD_TOOLBAR)))
    s.append(screen("1·ar", "An Arabic board at overview", "The same board written in Arabic reads right to left (BRD-27): sections from the right, names and change dots at the top-right corner, the rail on the right.",
                    window("جاهزية الطلبات", "projects/requests", board(ar=True, rtl=True), rtl=True, toolbar=BOARD_TOOLBAR)))
    s.append(screen("1·night", "Night", "The six shapes are drawn in ink, so Night draws them light on the dark ground; Broken keeps its rust and gains an ink hairline (rust alone is 2.2:1 on the Night ground).",
                    window("Requests readiness", "projects/requests", board(), theme="night", toolbar=BOARD_TOOLBAR)))
    zs = 1.0
    ztx, zty = section_view(2, zs, 1176 - 220, top=86, side=30)
    fn = NODES[(2, 6)]
    nx, ny = ztx + (fn["x"] + CW) * zs + 14, zty - 2 * ROW + fn["y"] * zs   # beside the card, on the side with room
    zoomed = board(s=zs, tx=ztx, ty=zty - 2 * ROW, cur=2, focus=(2, 6), overlay=NOTE_CARD.format(x=f"{nx:.0f}", y=f"{ny:.0f}"))
    s.append(screen(2, "Zoomed into a section, a note open", "At reading zoom cards show their word, title and body. Hovering a card with the corner thread (it has a note) opens its note as a solid paper card beside it: area, title, what is true, sources as paths with lines.",
                    window("Requests readiness", "projects/requests", zoomed, toolbar=BOARD_TOOLBAR)))
    changed = {(2, 6), (3, 2), (1, 5)}
    chip = '<div class="chip glass"><span>3 changed since 09:14</span><b>Next Change</b><span class="k">⌥⌘↓</span></div>'
    s.append(screen(3, "After an agent's rewrite", "At Fit a changed box gets a 6 px ink dot at its leading top corner, the same size at any zoom; the outline dots its sections; the chip steps through them, flying to reading zoom, where the thread on the box's edge takes over. Hovering a box at this zoom shows its title and word. Moving a box or running linen layout marks nothing.",
                    window("Requests readiness", "projects/requests", board(changed=changed, dots={1, 2, 3}, overlay=chip, label_for=(3, 2)), toolbar=BOARD_TOOLBAR)))
    toast = '<div class="toast pop"><b>Copied reference</b><code>projects/requests/requests.canvas#approval-flow · line 412 · notes key approval-flow · its text</code></div>'
    sel = board(s=zs, tx=ztx, ty=zty - 2 * ROW, cur=2, selected=(2, 6), overlay=toast)
    s.append(screen(4, "Pointing an agent at a box", "A click selects a box (an ink ring, the same as Tab focus); ⌥⌘C copies its reference: the path with the node id, its one line in the file, its key in the notes sidecar and its text. [[requests.canvas#approval-flow]] in a note, or linen open --node, flies back to it.",
                    window("Requests readiness", "projects/requests", sel, toolbar=BOARD_TOOLBAR)))
    hits = {k for k in NODES if "approv" in title(k).lower()}
    fb = '<div class="findbar" style="top:14px"><span class="q">approv</span><span class="cnt">2 of ' + str(len(hits)) + '</span><span class="fb">‹ ›</span><span class="done">Done</span></div>'
    focus = sorted(hits)[1] if len(hits) > 1 else None
    s.append(screen(5, "Find on a board", "Matches across titles, bodies, labels and notes, ringed at any zoom; the current one in ink. ⌘G flies to the next at reading zoom.",
                    window("Requests readiness", "projects/requests", board(found=hits, focus=focus, overlay=fb, fit_top=70), toolbar=BOARD_TOOLBAR)))
    s.append(screen(6, "A board with problems", "An agent saved a board with three problems. Linen still draws it: the problems line sits in the rail under the legend, a connector to a missing box ends at a gap mark, a box with no position is listed, not drawn. Only a file that is not JSON, or past BRD-20's limits, is fatal; then Linen keeps the last good board with one line (below).",
                    problems()))
    page_on = (f'<div style="position:absolute;inset:0">{KIT_PAGE.format(hint="Hover any step for its log line.")}'
               '<div class="pagefoot">Sealed · scripts on: trusted folder <span class="path">~/Developer/requests</span>, its git root</div></div>')
    page_off = ('<div class="kitpage"><div class="kp-head"><div class="eyebrow">Lab report · day 3</div><h1>What the cluster does at night</h1></div>'
                '<div class="honest"><b>This page draws with scripts</b><span>Scripts are off for pages from Downloads.</span><button class="btn ink sm">Run this page</button></div></div>')
    s.append(screen(7, "A sealed page", "A page in a trusted folder runs its own scripts with nothing reaching out; Linen suggested trusting the project's git root, not the agent's task folder, so new task folders inside it need no prompt (left). The same page from Downloads opens with scripts off; a page that draws everything with scripts says so plainly, with one button, instead of showing an empty page (right, Night).",
                    '<div class="row2">' + window("Lab report, day 3", "requests/tasks/night-run", page_on, toolbar=[["back", "fwd"], ["find"], ["share"]], w=576, h=600)
                    + window("Lab report, day 3", "Downloads", page_off, theme="night", toolbar=[["back", "fwd"], ["find"], ["share"]], w=576, h=600) + "</div>"))
    note = (f'<div class="docwrap norail"><main class="page"><div class="notewrap">{NOTE_PAGE}</div></main>{NOTE_FN}'
            f'<div class="foot">640 words · 3 min · modified 14:02</div></div>')
    s.append(screen(8, "A note with blocks", "Tiles and a bar from blocks, each state named once with its shape; a footnote opens as a card in the margin beside the line it explains, never over the text (the outline rail is hidden here, so the margin has room).",
                    window("Where it stands", "projects/requests", note)))
    s.append(screen(9, "Settings: iPhone", "Pairing: the phone scanned the QR and both screens show the same six digits; the phone is named here, since iOS calls every phone \"iPhone\"; Allow pins it. Paired phones with the install's expiry and the command that renews it; pinned folders with their size, the references that point outside them and one action to keep those too; the helper and the sealed-page self-test.",
                    iphone_pane()))
    s.append(screen(10, "Export", "Sections as pages: the orientation follows each section's shape, body text never prints under 9 pt, and a section taller than a page splits between rows (preview). Notes become numbered sources. Thmanyah is drawn as outlines over searchable text.",
                    export_sheet()))
    phones11 = '<div class="phones">' + phone(library()) + phone(library(state="receiving"), theme="night") + phone(library(rtl=True), rtl=True) + phone(phone_settings()) + "</div>"
    s.append(screen(11, "iPhone: Library and Settings", "Groups by the folder they came from (rows do not repeat it), the most recently changed first; a thread on a file that changed since it was read; the one sync line (Night: files arriving). Arabic. The gear opens the phone's own Settings: which Mac, forget it, what is kept, when this copy stops opening.", phones11))
    phones12 = '<div class="phones">' + phone(phone_note()) + phone(phone_note(), theme="night") + "</div>"
    s.append(screen(12, "iPhone: a note", "Screen 8's note on the phone: all four tiles, two across, and the bar with its key; a footnote opens as a sheet on tap. Night.", phones12))
    phones13 = ('<div class="phones">' + phone(phone_board_list()) + phone(phone_board("open")) + phone(phone_board("overview", changed={(2, 6), (3, 2), (1, 5)}))
                + phone(phone_board("note")) + "</div>")
    s.append(screen(13, "iPhone: a board", "Its first section is wider than the phone at reading size, so the first open is List view: sections as headings, boxes as rows in reading order, a word only where the state is not the quiet Works. Canvas is one tap away, at reading zoom on the first section; pinch out for the overview, where boxes are shapes, names keep 15 px and the legend sits in the zoom panel; a tap at reading zoom opens a box's note as a sheet.", phones13))
    phones13b = ('<div class="phones">' + phone(phone_board_list(ar=True), rtl=True) + phone(phone_board("open", ar=True, rtl=True), rtl=True)
                 + phone(phone_board("overview", ar=True, rtl=True), rtl=True) + phone(phone_board("overview"), theme="night") + "</div>")
    s.append(screen("13·ar", "An Arabic board on the iPhone, and Night", "Right to left throughout, with Arabic digits in every Arabic panel: List first, then the first section (the rightmost) and the overview. The last phone: the overview in Night.", phones13b))
    phones14 = '<div class="phones">' + phone(phone_page()) + "</div>"
    s.append(screen(14, "iPhone: a page", "A sealed page on the phone: its notes open on tap, and the page's own layout keeps to 390 px.", phones14))
    phones15 = '<div class="phones">' + phone(phone_pair(1)) + phone(phone_pair(2)) + phone(phone_pair(0)) + "</div>"
    s.append(screen(15, "iPhone: pairing", "The camera finds the QR (iOS asks for local network access at this tap, never at launch); then the six digits, while the Mac waits for Allow. If camera access is off, the screen says so and where to turn it on.", phones15))
    phones16 = '<div class="phones">' + phone(phone_share()) + "</div>"
    s.append(screen(16, "iPhone: sharing a file", "At launch the phone shares the original file; PDF and PNG come from the Mac.", phones16))
    phones17 = ('<div class="phones">' + phone(library(state="receiving")) + phone(library(state="finishing")) + phone(library(state="away"))
                + phone(library(state="sleep")) + phone(library(state="lan")) + phone(library(state="forgot")) + phone(library(state="expiry"))
                + phone(library(state="full")) + "</div>")
    s.append(screen(17, "iPhone: sync states", "One line, in one place: receiving, finishing files paused when he left, Mac not nearby, Mac asleep. Rust only when something needs Hatim: local network access off, a Mac that no longer knows this phone (pair again), this copy's last two days before it stops opening (reinstall from the Mac), and out of space.", phones17))
    s.append(screen("A", "Status shapes", "WORDS-2's six shapes, drawn in ink so both looks hold them; each carrying colour's contrast against the ground (all at least 3:1 against paper and section wash; rust needs its hairline in Night).",
                    shapes_specimen("paper") + '<div style="height:14px"></div>' + f'<div class="night" style="display:inline-block">{shapes_specimen("night")}</div>'))
    s.append(screen("B", "Board kinds", "Card, sticky, shape, board title, a note file node, a web link. All drawn from the tokens.", kinds()))
    s.append(screen("C", "Board colours, for Hatim to choose", "JSON Canvas has six preset colours. Drafted: six flat washes taken from the tokens, sand and sage at different depths, with no pattern (threads, dashes and dots belong to the status shapes) and no rust (it means failure). They differ by depth more than by hue, which is the cost of staying in Loom's palette (top). The alternative: bright FigJam-like stickies (bottom), outside the palette (open question 1).",
                    colours()))
    return (f'<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width">'
            f'<title>Linen 2 screens</title><style>{v1.CSS}{CSS2}</style><body>{HEAD}{"".join(s)}</body></html>')


if __name__ == "__main__":
    OUT.write_text(build(), encoding="utf-8")
    print("wrote", OUT, OUT.stat().st_size // 1024, "KB")
    print(f"board: {len(NODES)} boxes in {len(SECS)} sections, {len(EDGES)} connectors, {BW} x {BH} px; words {counts()}")
    print(contrast_table())
