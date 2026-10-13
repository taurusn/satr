"""Builds Linen's screen sketch: docs/design/linen-screens.html, one self-contained page.

    python3 -I docs/design/build_screens.py

The Thmanyah faces are named, never embedded (their license forbids hosting the files); the sketch renders
correctly on a Mac where they are installed, as Hatim's is. Sample text only, never vault content.
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import make_mark  # noqa: E402

OUT = HERE / "linen-screens.html"

MARK = make_mark.draw(make_mark.RTL)
MX, MY, MW, MH = make_mark.bounds(make_mark.RTL, 3)


def mark(h=22, cls="mark"):
    return (f'<svg class="{cls}" height="{h}" viewBox="{MX:g} {MY:g} {MW:g} {MH:g}" fill="none" stroke="currentColor" '
            f'stroke-width="6" stroke-linecap="round" aria-hidden="true">{MARK}</svg>')


ICON = {
    "outline": '<path d="M3 4.5h2M3 8h2M3 11.5h2M7.5 4.5h6M7.5 8h6M7.5 11.5h4"/>',
    "find": '<circle cx="7" cy="7" r="4.2"/><path d="M10.2 10.2L13.5 13.5"/>',
    "size": '<path d="M2.5 12.5L5.5 4l3 8.5M3.6 9.5h3.8M10 12.5l2-5.5 2 5.5M10.7 10.7h2.6"/>',
    "share": '<path d="M8 2.5v8M5 5.5l3-3 3 3M4 8.5v5h8v-5"/>',
    "editor": '<path d="M3 13l1-3.5 6.5-6.5 2.5 2.5L6.5 12 3 13z"/>',
    "back": '<path d="M10 3.5L5.5 8l4.5 4.5"/>',
    "fwd": '<path d="M6 3.5l4.5 4.5L6 12.5"/>',
    "change": '<path d="M4 5.5l4 4 4-4"/><path d="M3 12.5h10"/>',
}


def icon(name, size=16):
    return (f'<svg class="ic" width="{size}" height="{size}" viewBox="0 0 16 16" fill="none" stroke="currentColor" '
            f'stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round">{ICON[name]}</svg>')


def window(title, subtitle, body, tabs=None, theme="paper", rtl=False, w=1180, h=760, toolbar=None, cls=""):
    tb = toolbar if toolbar is not None else [["back", "fwd"], ["outline"], ["find", "size"], ["editor", "share"]]
    groups = "".join('<span class="cap">' + "".join(f'<span class="tbi">{icon(i)}</span>' for i in g) + "</span>" for g in tb)
    tabbar = ""
    if tabs:
        tabbar = '<div class="tabs">' + "".join(f'<span class="tab{" on" if i == 0 else ""}">{t}</span>' for i, t in enumerate(tabs)) + '<span class="tab plus">+</span></div>'
    sub = f'<span class="sub">{subtitle}</span>' if subtitle else ""
    return (f'<div class="win {theme} {cls}" dir="{"rtl" if rtl else "ltr"}" style="width:{w}px;height:{h}px">'
            f'<div class="chrome"><span class="lights"><i></i><i></i><i></i></span>'
            f'<span class="ttl"><b>{title}</b>{sub}</span><span class="tools">{groups}</span></div>{tabbar}'
            f'<div class="body">{body}</div></div>')


def screen(n, name, note, content):
    return f'<section class="screen"><div class="label"><span class="no">{n}</span><h2>{name}</h2><p>{note}</p></div>{content}</section>'


# ---------- sample content ----------

STRIP = '<div class="strip"><span>project</span><span>updated 2026-10-11</span><span>active</span><span class="tag">#reading</span><span class="tag">#linen</span></div>'

PAGE_EN = f'''{STRIP}
<h1 class="title">Reading in Linen</h1>
<p>Linen opens a note as a page. The column holds the line you are reading, and nothing else on the screen asks for your eye. Wiki links read as names, like <a class="wl" title="wiki/projects/Ferry">Ferry</a> and <a class="wl" title="wiki/concepts/Product build method">Product build method</a>, with the path shown on hover.</p>
<h2>Why a reader</h2>
<p>An editor shows the source. A reader shows the page. Most of the time a note is read, not written, and the reading should feel like paper: steady type, a calm measure, a page that keeps its place while an agent rewrites the file.</p>
<div class="callout"><b>Note</b><p>Callouts are drawn in ink. Rust is kept for things that failed.</p></div>
<h3>What it keeps</h3>
<ul><li>The line you were reading, across saves and restarts.</li><li>Your text size, per file.</li><li>What changed since you last looked.</li></ul>
<p dir="rtl" class="ar">يقرأ لينن الملاحظة بالعربية والإنجليزية معًا، ويأخذ كل سطر اتجاهه مما كُتب به.</p>
<pre class="code"><span class="cl">swift</span><code><span class="k">let</span> place = store.<span class="k">place</span>(for: url)
<span class="c">// The block being read, not a pixel offset.</span>
page.restore(place, <span class="s">"smooth"</span>)</code></pre>'''

OUTLINE_EN = '''<nav class="outline"><div class="otitle">Reading in Linen</div>
<a>Why a reader</a><a class="o3 cur">What it keeps</a><a>Places and changes</a><a class="o3">Next change</a><a>Links between notes</a><a>Printing</a>
<div class="prog"><i style="height:38%"></i></div></nav>'''

FOOTER = '<div class="foot">1,240 words · 6 min · modified 14:02</div>'


def doc(page=PAGE_EN, outline=OUTLINE_EN, extra=""):
    return f'<div class="docwrap">{outline}<main class="page">{page}{extra}</main>{FOOTER}</div>'


PRD_CHANGED = f'''<h1 class="title">Ferry: product requirements</h1>
<h2>6.4 Keyboard</h2>
<p>Follow focus opens the phone's keyboard when a text field gets focus on the Mac, unless the person at the Mac moved focus in the last three seconds.</p>
<div class="chg"><p>Typing safety: a deletion only applies inside the current typing epoch, so autocorrect never deletes across a click.</p></div>
<p>The key row carries Esc, Tab, the arrows and sticky modifiers. Sticky modifiers never apply to typed text.</p>
<div class="gap" title="2 paragraphs removed"></div>
<h2>6.5 Screen</h2>
<div class="chg"><p>The stream keeps at most two frames in flight and drops before encoding when the phone falls behind; keyframes on start, on request and when the region jumps.</p></div>
<p>Zoom follows the pointer and captures the region at full resolution.</p>'''

OUTLINE_PRD = '''<nav class="outline"><div class="otitle">Ferry: product requirements</div>
<a>6.3 Trackpad</a><a class="cur chgd">6.4 Keyboard</a><a class="chgd">6.5 Screen</a><a>6.6 Media and sound</a><a>6.7 Apps and windows</a><a>6.8 System</a>
<div class="prog"><i style="height:52%"></i></div></nav>'''

PAGE_AR = '''<div class="strip"><span>ملاحظة</span><span>حُدّثت ٢٠٢٦-١٠-١١</span><span class="tag">#قراءة</span></div>
<h1 class="title">القراءة في سطر</h1>
<p>يفتح سطر الملاحظة صفحةً. العمود يحمل السطر الذي تقرؤه، ولا شيء آخر على الشاشة يطلب انتباهك. الروابط بين الملاحظات تُقرأ أسماءً، مثل <a class="wl">فيري</a>.</p>
<h2>لماذا قارئ</h2>
<p>المحرر يُظهر المصدر، والقارئ يُظهر الصفحة. أغلب الوقت تُقرأ الملاحظة ولا تُكتب، والقراءة يجب أن تشبه الورق: حرف ثابت، وعرض هادئ، وصفحة تحفظ مكانك حين يعيد وكيل كتابة الملف.</p>
<p dir="ltr" class="en">Mixed lines keep their own direction: this English sentence stays left to right inside an Arabic note.</p>
<h3>ما يحفظه</h3>
<ul><li>السطر الذي كنت تقرؤه، بعد الحفظ وبعد إعادة التشغيل.</li><li>حجم الخط لكل ملف.</li></ul>'''

OUTLINE_AR = '''<nav class="outline"><div class="otitle">القراءة في سطر</div><a class="cur">لماذا قارئ</a><a class="o3">ما يحفظه</a><a>الروابط</a><a>الطباعة</a><div class="prog"><i style="height:20%"></i></div></nav>'''

FOOTER_AR = '<div class="foot">٤٢٠ كلمة · ٢ دقيقة · عُدّلت ١٤:٠٢</div>'


def welcome(rtl=False, theme="paper"):
    if rtl:
        t, q, r, d, o = "سطر", "ماذا نقرأ؟", "آخر ما قرأت", "أفلت ملف ‎.md‎ أو ‎.txt‎ هنا", "فتح"
        rec = [("القراءة في سطر", "ملاحظات"), ("Ferry: product requirements", "ferry/docs"), ("Product build method", "vault/wiki/concepts")]
    else:
        t, q, r, d, o = "Linen", "What are we reading?", "Recent", "Drop a .md or .txt file here", "Open…"
        rec = [("Reading in Linen", "notes"), ("Ferry: product requirements", "ferry/docs"), ("Product build method", "vault/wiki/concepts"), ("Round 2 review", "linen/docs/reviews")]
    items = "".join(f'<li><b>{a}</b><span>{b}</span></li>' for a, b in rec)
    body = (f'<div class="welcome weave"><div class="wcol">{mark(40, "mark big")}<div class="eyebrow">{t}</div>'
            f'<h1 class="empty">{q}</h1><div class="drop">{d}</div><button class="btn ink">{o}</button>'
            f'<div class="eyebrow r">{r}</div><ul class="recent">{items}</ul></div></div>')
    return window("سطر" if rtl else "Linen", "", body, theme=theme, rtl=rtl, w=900, h=640, toolbar=[])


def find_bar():
    return ('<div class="findbar"><span class="fi">' + icon("find", 14) + '</span><span class="q">place</span>'
            '<span class="cnt">3 of 7</span><span class="fb">' + icon("back", 14) + '</span><span class="fb">' + icon("fwd", 14) + '</span>'
            '<span class="done">Done</span></div>')


def page_found():
    return PAGE_EN.replace("keeps its <", "keeps its <").replace("a page that keeps its place", 'a page that keeps its <mark class="cur">place</mark>').replace(
        "The line you were reading", 'The line you were reading').replace("Linen opens a note", "Linen opens a note")


PROPS = '''<div class="pop props"><div class="eyebrow">Properties</div><table>
<tr><th>type</th><td>project</td></tr><tr><th>date</th><td>2026-10-10</td></tr><tr><th>updated</th><td>2026-10-11</td></tr>
<tr><th>status</th><td>active</td></tr><tr><th>tags</th><td>reading, linen</td></tr><tr><th>related</th><td>Ferry, Product build method</td></tr></table></div>'''

LINKED = '''<section class="linked"><div class="eyebrow">Linked from · 4 notes</div>
<div class="lk"><b>Ferry</b><p>Satr and Ferry are one family; the reader is <span class="hl">Linen</span>.</p></div>
<div class="lk"><b>Product build method</b><p>The next product after Ferry was <span class="hl">Linen</span>, built the same way.</p></div>
<div class="lk"><b>2026-10-11</b><p>Renamed Satr to <span class="hl">Linen</span>; the Arabic name stays سطر.</p></div>
<div class="lk more">Show all</div></section>'''

QUICK = '''<div class="quick pop"><div class="qin">read<span class="caret"></span></div>
<div class="qr on"><b>Reading in Linen</b><span>notes</span></div>
<div class="qr"><b>Round 2 review</b><span>linen/docs/reviews</span></div>
<div class="qr"><b>Ready for review</b><span>vault/wiki/logs</span></div>
<div class="qr"><b>README</b><span>linen</span></div>
<div class="qhint">↩ open · ⌘↩ new tab</div></div>'''

BLOCKED = '''<p>The deck has three diagrams and one photo from the client's site.</p>
<div class="blocked"><span>Image from example.com</span><button class="btn line sm">Load images for this file</button></div>
<p>The second figure sits outside the vault:</p>
<div class="blocked"><span>~/Downloads/figure-2.png is outside this vault</span><button class="btn line sm">Allow files outside this vault</button></div>'''

GONE = f'''<div class="welcome weave"><div class="wcol">{mark(30, "mark big")}<h1 class="empty sm">This file is no longer here</h1>
<p class="muted">~/vault/wiki/projects/Old plan.md was moved or deleted.</p>
<div class="row"><button class="btn ink">Reveal folder</button><button class="btn line">Close</button></div></div></div>'''


def settings(rtl=False):
    if rtl:
        rows = [("المظهر", '<span class="seg"><b>ورق</b><span>ليل</span><span>حسب النظام</span></span>'),
                ("خط النص", '<span class="seg"><b>ثمانية بلا تذييل</b><span>ثمانية نص</span></span>'),
                ("حجم النص", '<span class="seg"><span>−</span><b>١٠٠٪</b><span>+</span></span>'),
                ("الفتح في محرر", '<span class="pop1">Obsidian</span>'),
                ("الصور البعيدة", '<span class="seg"><b>اسأل لكل ملف</b><span>اسمح دائمًا</span></span>')]
        head, eb = "الإعدادات", "سطر"
    else:
        rows = [("Appearance", '<span class="seg"><b>Paper</b><span>Night</span><span>Follow system</span></span>'),
                ("Body face", '<span class="seg"><b>Thmanyah Sans</b><span>Serif Text</span></span>'),
                ("Text size", '<span class="seg"><span>−</span><b>100%</b><span>+</span></span>'),
                ("Open in Editor", '<span class="pop1">Obsidian</span>'),
                ("Remote images", '<span class="seg"><b>Ask per file</b><span>Always load</span></span>')]
        head, eb = "Settings", "Linen"
    r = "".join(f'<div class="srow"><span class="sk">{a}</span>{b}</div>' for a, b in rows)
    body = f'<div class="settings weave"><div class="scol"><div class="eyebrow">{eb}</div><h1 class="stitle">{head}</h1>{r}</div></div>'
    return window(head, "", body, rtl=rtl, w=640, h=520, toolbar=[])


def quicklook(narrow=False):
    w, h = (330, 520) if narrow else (820, 600)
    page = PAGE_EN if not narrow else PAGE_EN.split('<h3>')[0]
    return (f'<div class="ql{" narrow" if narrow else ""}" style="width:{w}px;height:{h}px"><div class="qlbar"><span class="x">×</span>'
            f'<b>Reading in Linen.md</b><span class="open">Open with Linen</span></div><div class="qlbody"><main class="page">{page}</main></div></div>')


def printed():
    p = '''<div class="sheet"><div class="run"><span>Reading in Linen</span><span>notes</span></div><main class="page pr">''' + PAGE_EN.replace(STRIP, "") + '''</main><div class="pno">1</div></div>'''
    p2 = '''<div class="sheet"><div class="run"><span>Reading in Linen</span><span>notes</span></div><main class="page pr"><h2>Places and changes</h2><p>Every file remembers the block being read and its text size. A file read to its end that has grown since opens at the end.</p><h2>Next change</h2><p>Go to the next change with the Go menu. Marks clear once they have been on screen for three seconds.</p></main><div class="pno">2</div></div>'''
    return f'<div class="printrow">{p}{p2}</div>'


def present():
    body = '''<div class="present"><main class="page big"><h2>Why a reader</h2><p>An editor shows the source. A reader shows the page. Most of the time a note is read, not written, and the reading should feel like paper.</p></main><div class="pstep">2 / 9 · space moves on · Esc ends</div></div>'''
    return window("Reading in Linen", "Present", body, w=1180, h=700, toolbar=[])


CSS = '''
:root{--paper:#F6F3EB;--paper2:#FBF9F4;--ink:#284734;--ink2:#1F3328;--sage:#8FA394;--rule:#DAD5C8;--t1:#E3E7DF;--t2:#C9D3CA;--t3:#A9B8AC;--rust:#9C4A2E;
--serif:"thmanyah serif display","Thmanyah Serif Display",Georgia,serif;--sans:"thmanyah sans","Thmanyah Sans",-apple-system,sans-serif;--mono:"SF Mono",ui-monospace,"thmanyah sans",monospace;}
*{box-sizing:border-box} body{margin:0;background:#EDEAE1;color:var(--ink2);font:15px var(--sans);padding:48px 40px 80px}
.sheet-head{max-width:1180px;margin:0 auto 40px} .sheet-head h1{font:300 40px var(--serif);color:var(--ink);margin:10px 0 6px}
.sheet-head p{max-width:760px;line-height:1.6;margin:6px 0}
.screen{max-width:1260px;margin:0 auto 64px} .label{display:flex;align-items:baseline;gap:14px;margin-bottom:14px;flex-wrap:wrap}
.label .no{font:300 30px var(--serif);color:var(--ink);min-width:34px} .label h2{font:500 15px var(--sans);margin:0;color:var(--ink)} .label p{margin:0;color:var(--ink2);font-size:13.5px;flex-basis:100%;padding-left:48px}
.row2{display:flex;gap:28px;align-items:flex-start;flex-wrap:wrap}
/* window */
.win{border-radius:16px;overflow:hidden;box-shadow:0 22px 50px rgba(31,51,40,.22),0 0 0 1px rgba(31,51,40,.12);display:flex;flex-direction:column;background:var(--paper);position:relative}
.chrome{height:52px;display:flex;align-items:center;padding:0 14px;gap:16px;background:var(--paper);border-bottom:1px solid var(--rule);flex:none}
.lights{display:flex;gap:8px} .lights i{width:12px;height:12px;border-radius:50%;background:#E0DCD2;display:block;box-shadow:inset 0 0 0 .5px rgba(0,0,0,.12)}
.win .lights i:nth-child(1){background:#EC6A5E}.win .lights i:nth-child(2){background:#F4BF4F}.win .lights i:nth-child(3){background:#61C554}
.ttl{display:flex;flex-direction:column;line-height:1.2} .ttl b{font:600 13px -apple-system,var(--sans);color:var(--ink2)} .ttl .sub{font-size:11.5px;color:var(--ink2);opacity:.7}
.tools{margin-inline-start:auto;display:flex;gap:10px} .cap{display:flex;background:rgba(31,51,40,.05);border:1px solid rgba(31,51,40,.08);border-radius:999px;padding:3px}
.tbi{width:30px;height:26px;display:grid;place-items:center;color:var(--ink)}
.tabs{display:flex;gap:6px;padding:6px 10px;background:var(--paper);border-bottom:1px solid var(--rule);flex:none}
.tab{flex:1;text-align:center;font:500 12px var(--sans);padding:6px;border-radius:7px;color:var(--ink2);opacity:.75} .tab.on{background:rgba(31,51,40,.07);opacity:1} .tab.plus{flex:none;width:28px}
.body{flex:1;min-height:0;position:relative;overflow:hidden}
/* page */
.docwrap{position:absolute;inset:0;display:grid;grid-template-columns:220px 1fr;}
.win[dir=rtl] .docwrap{grid-template-columns:220px 1fr}
.outline{border-inline-end:1px solid var(--rule);padding:26px 0 0;position:relative;font-size:13.5px}
.outline .otitle{font:500 11px var(--sans);text-transform:uppercase;letter-spacing:.14em;color:var(--ink2);padding:0 22px 12px;opacity:.8}
.outline a{display:block;padding:6px 22px;color:var(--ink2);text-decoration:none;line-height:1.35}
.outline a.o3{padding-inline-start:36px;font-size:13px}
.outline a.cur{color:var(--ink);font-weight:500;background:rgba(40,71,52,.06);box-shadow:inset 2px 0 0 var(--ink)}
.win[dir=rtl] .outline a.cur{box-shadow:inset -2px 0 0 var(--ink)}
.outline a.chgd::after{content:"";display:inline-block;width:5px;height:5px;border-radius:50%;background:var(--ink);margin-inline-start:8px;vertical-align:middle}
.prog{position:absolute;inset-inline-end:-1px;top:0;bottom:0;width:1px} .prog i{display:block;width:2px;background:var(--ink);margin-inline-start:-.5px}
.page{max-width:720px;margin:0 auto;padding:30px 40px 60px;font-size:17px;line-height:1.65;color:var(--ink2)}
.docwrap .page{overflow:hidden;height:100%;width:100%}
.title{font:300 40px/1.15 var(--serif);color:var(--ink);margin:6px 0 18px} .page h2{font:300 24px/1.3 var(--serif);color:var(--ink);margin:30px 0 8px}
.page h3{font:500 19px/1.4 var(--sans);color:var(--ink);margin:22px 0 6px} .page p{margin:0 0 14px} .page ul{margin:0 0 14px;padding-inline-start:22px}
.page .ar{font-size:17px;line-height:1.8} .wl{color:var(--ink);text-decoration:none;border-bottom:1px solid var(--t3)}
.strip{display:flex;gap:14px;font-size:13.5px;color:var(--ink2);margin-bottom:10px;flex-wrap:wrap} .strip span{opacity:.85} .strip .tag{color:var(--ink)}
.callout{border-inline-start:2px solid var(--ink);background:var(--t1);padding:10px 16px;margin:0 0 16px} .callout b{font:500 11px var(--sans);text-transform:uppercase;letter-spacing:.14em;color:var(--ink)} .callout p{margin:4px 0 0;font-size:16px}
.code{background:var(--paper2);border:1px solid var(--rule);border-radius:2px;padding:14px 16px;font:14.5px/1.55 var(--mono);color:var(--ink2);position:relative;margin:0 0 16px;direction:ltr;text-align:left}
.code .cl{position:absolute;top:6px;right:10px;font:500 11px var(--sans);letter-spacing:.14em;text-transform:uppercase;color:var(--ink2);opacity:.6}
.code code{white-space:pre} .k{color:var(--ink);font-weight:600} .c{font-style:italic} .s{background:var(--t1)}
.foot{position:absolute;bottom:0;inset-inline-start:220px;inset-inline-end:0;text-align:center;font-size:13.5px;color:var(--ink2);padding:8px;opacity:.8;background:var(--paper);border-top:1px solid var(--rule)}
mark{background:var(--t2);color:inherit;padding:0 1px} mark.cur{background:var(--ink);color:var(--paper)}
.findbar{position:absolute;top:10px;inset-inline-end:16px;display:flex;align-items:center;gap:10px;background:var(--paper);border:1px solid var(--rule);box-shadow:0 10px 26px rgba(40,71,52,.18);padding:7px 10px;border-radius:2px;z-index:4;font-size:13.5px}
.findbar .q{min-width:150px;border-bottom:1px solid var(--t3);padding:2px 4px;color:var(--ink)} .findbar .cnt{color:var(--ink2)} .findbar .fb{color:var(--ink)} .findbar .done{font-weight:500;color:var(--ink);margin-inline-start:6px}
.rail{position:absolute;top:0;bottom:30px;inset-inline-end:4px;width:3px} .rail i{position:absolute;width:3px;height:3px;background:var(--ink);border-radius:1px}
.chg{position:relative} .chg::before{content:"";position:absolute;inset-inline-start:-18px;top:4px;bottom:16px;width:2px;background:var(--ink)}
.gap{height:0;border-top:1px dashed var(--t3);margin:-4px 0 14px;position:relative} .gap::before{content:"";position:absolute;inset-inline-start:-22px;top:-4px;width:9px;height:7px;border-top:2px solid var(--ink);border-bottom:2px solid var(--ink)}
.menu{position:absolute;top:0;inset-inline-start:250px;background:var(--paper);border:1px solid var(--rule);box-shadow:0 12px 30px rgba(40,71,52,.2);font-size:13.5px;padding:6px 0;width:240px;z-index:5}
.menu div{padding:5px 16px;display:flex;justify-content:space-between} .menu div.on{background:var(--ink);color:var(--paper)} .menu span{opacity:.75}
.pop{position:absolute;background:var(--paper);border:1px solid var(--rule);box-shadow:0 14px 34px rgba(40,71,52,.2);border-radius:2px;z-index:5}
.props{top:70px;inset-inline-start:calc(50% - 120px);width:380px;padding:16px 18px} .props table{width:100%;border-collapse:collapse;font-size:14px;margin-top:8px}
.props th{text-align:start;font-weight:500;color:var(--ink);padding:6px 0;border-bottom:1px solid var(--rule);width:100px} .props td{padding:6px 0;border-bottom:1px solid var(--rule)}
.linked{border-top:1px solid var(--rule);margin-top:26px;padding-top:16px} .lk{padding:8px 0;border-bottom:1px solid var(--rule)} .lk b{font:500 14px var(--sans);color:var(--ink)} .lk p{margin:2px 0 0;font-size:15px}
.lk .hl{border-bottom:1px solid var(--t3)} .lk.more{color:var(--ink);font-weight:500;font-size:14px;border:0}
.quick{top:84px;left:calc(50% - 260px);width:520px;padding:8px} .qin{font-size:19px;padding:10px 12px;border-bottom:1px solid var(--rule);color:var(--ink)} .caret{display:inline-block;width:1.5px;height:20px;background:var(--ink);vertical-align:-3px;margin-left:2px}
.qr{display:flex;justify-content:space-between;padding:9px 12px;font-size:14.5px} .qr span{color:var(--ink2);opacity:.75;font-size:13px} .qr.on{background:var(--ink);color:var(--paper)} .qr.on span{color:var(--paper)}
.qhint{font-size:12.5px;color:var(--ink2);padding:8px 12px 4px;opacity:.8}
.blocked{display:flex;align-items:center;justify-content:space-between;gap:12px;border:1px dashed var(--t3);background:var(--paper2);padding:14px 16px;margin:0 0 16px;font-size:14.5px}
.btn{font:500 13.5px var(--sans);border-radius:2px;padding:9px 16px;border:1px solid var(--ink);cursor:default} .btn.ink{background:var(--ink);color:var(--paper)} .btn.line{background:transparent;color:var(--ink)} .btn.sm{padding:6px 12px;font-size:12.5px}
.weave{background-color:var(--paper);background-image:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='44' height='44'%3E%3Cg stroke='%23284734' stroke-opacity='.13' stroke-width='1.3' stroke-linecap='round'%3E%3Cpath d='M8.5 11h5M33 8.5v5M11 30.5v5M30.5 33h5'/%3E%3C/g%3E%3C/svg%3E")}
.welcome{position:absolute;inset:0;display:grid;place-items:center} .wcol{width:420px;text-align:center;display:flex;flex-direction:column;align-items:center;gap:12px}
.mark{color:var(--ink)} .mark.big{margin-bottom:4px} .eyebrow{font:500 11px var(--sans);text-transform:uppercase;letter-spacing:.14em;color:var(--ink2);opacity:.85} .eyebrow.r{margin-top:14px;align-self:stretch;text-align:start}
.empty{font:300 40px/1.15 var(--serif);color:var(--ink);margin:0} .empty.sm{font-size:34px;white-space:nowrap}
.drop{align-self:stretch;border:1px dashed var(--t3);padding:22px;font-size:14px;color:var(--ink2);background:rgba(251,249,244,.7)}
.recent{list-style:none;padding:0;margin:0;align-self:stretch;text-align:start} .recent li{display:flex;justify-content:space-between;padding:7px 0;border-bottom:1px solid var(--rule);font-size:14px} .recent b{font-weight:500;color:var(--ink)} .recent span{color:var(--ink2);opacity:.75;font-size:13px}
.muted{color:var(--ink2);margin:0} .row{display:flex;gap:10px}
.settings{position:absolute;inset:0;padding:34px 40px} .stitle{font:300 34px var(--serif);color:var(--ink);margin:4px 0 18px}
.srow{display:flex;align-items:center;justify-content:space-between;padding:12px 0;border-bottom:1px solid var(--rule);font-size:14.5px} .sk{color:var(--ink2)}
.seg{display:flex;border:1px solid var(--rule);border-radius:2px;overflow:hidden;font-size:13px} .seg>*{padding:6px 12px} .seg b{background:var(--ink);color:var(--paper);font-weight:500}
.pop1{border:1px solid var(--rule);padding:6px 12px;font-size:13px;border-radius:2px}
.ql{border-radius:14px;overflow:hidden;background:var(--paper);box-shadow:0 22px 50px rgba(31,51,40,.25);display:flex;flex-direction:column}
.qlbar{background:#2b2b2b;color:#eee;display:flex;align-items:center;gap:12px;padding:10px 14px;font-size:12.5px} .qlbar .open{margin-left:auto;background:#444;padding:3px 10px;border-radius:6px} .qlbar .x{opacity:.7}
.qlbody{flex:1;overflow:hidden} .ql .page{padding:26px 34px} .ql.narrow .page{padding:16px 16px;font-size:15px} .ql.narrow .title{font-size:30px} .ql.narrow .strip{display:none}
.printrow{display:flex;gap:28px;background:#d8d5cc;padding:30px;border-radius:4px;width:max-content}
.sheet{width:420px;height:594px;background:#fff;box-shadow:0 8px 24px rgba(0,0,0,.18);position:relative;overflow:hidden;padding:34px 34px 30px}
.sheet .page{padding:0;font-size:11px;line-height:1.6;max-width:none} .sheet .title{font-size:26px;margin:4px 0 10px} .sheet .page h2{font-size:16px;margin:16px 0 4px} .sheet .page h3{font-size:12.5px}
.sheet .code{font-size:9.5px;padding:8px} .sheet .callout p{font-size:10.5px} .sheet .wl{border:0}
.run{display:flex;justify-content:space-between;font-size:8.5px;color:var(--ink2);border-bottom:.5px solid var(--rule);padding-bottom:5px;margin-bottom:12px;letter-spacing:.06em;text-transform:uppercase}
.pno{position:absolute;bottom:14px;left:0;right:0;text-align:center;font-size:9px;color:var(--ink2)}
.present{position:absolute;inset:0;display:grid;place-items:center} .page.big{font-size:30px;line-height:1.55;max-width:900px} .page.big h2{font-size:40px}
.pstep{position:absolute;bottom:18px;left:0;right:0;text-align:center;font-size:13.5px;color:var(--ink2);opacity:.8}
.narrowwin .docwrap{grid-template-columns:1fr} .narrowwin .outline{position:absolute;inset-block:0;inset-inline-start:0;width:220px;background:var(--paper);z-index:3;box-shadow:12px 0 30px rgba(40,71,52,.12)} .narrowwin .foot{inset-inline-start:0}
/* night */
.night{--paper:#1F3328;--paper2:#284734;--ink:#F6F3EB;--ink2:rgba(246,243,235,.86);--rule:rgba(246,243,235,.12);--t1:rgba(246,243,235,.07);--t2:rgba(246,243,235,.22);--t3:rgba(246,243,235,.3)}
.night .lights i:nth-child(n){filter:saturate(.9)} .night .cap{background:rgba(246,243,235,.06);border-color:rgba(246,243,235,.1)} .night .tab.on{background:rgba(246,243,235,.08)}
.night .outline a.cur{background:rgba(246,243,235,.07)} .night mark.cur{background:var(--ink);color:#1F3328} .night .qr.on{background:var(--ink);color:#1F3328} .night .qr.on span{color:#1F3328}
.night .weave{background-color:var(--paper)}
.win[dir=rtl] .page,.win[dir=rtl] .wcol,.win[dir=rtl] .scol{font-family:var(--sans)} .win[dir=rtl] .page .en{direction:ltr;text-align:left}
'''

HEAD = f'''<div class="sheet-head">{mark(30)}<div class="eyebrow" style="margin-top:14px">Linen · screen sketch · v0.2 PRD</div>
<h1>Linen</h1><p>The Mac's reader for Markdown, in the Loom suite next to Ferry. Loom's tokens, Thmanyah type (named, never embedded), the native title bar and tabs, one column of paper. Sample text only. Built by <code>docs/design/build_screens.py</code>.</p></div>'''


def build():
    s = []
    s.append(screen(1, "Welcome", "The empty state: the mark on the weave, the question, a drop zone, Open, the last files. Paper and Arabic.",
                    f'<div class="row2">{welcome()}{welcome(rtl=True)}</div>'))
    s.append(screen(2, "Document", "Native title and toolbar, the outline rail on the leading side with the current section, the frontmatter strip in ink-2, one column, the footer. Wiki links read as names.",
                    window("Reading in Linen", "notes", doc(), tabs=["Reading in Linen", "Ferry: product requirements", "Product build method"])))
    found = doc(page=PAGE_EN.replace("a page that keeps its place", 'a page that keeps its <mark class="cur">place</mark>').replace("The line you were reading, across saves", 'The line you were reading, across saves').replace("Linen opens a note as a page.", 'Linen opens a note as a page.'),
                extra="") + find_bar() + '<div class="rail"><i style="top:18%"></i><i style="top:31%"></i><i style="top:33%"></i><i style="top:52%"></i><i style="top:64%"></i><i style="top:71%"></i><i style="top:88%"></i></div>'
    s.append(screen(3, "Find", "The find bar in the chrome, the count, matches marked, the current match in ink, the match rail along the trailing edge (overlay scroll bars hide their track).",
                    window("Reading in Linen", "notes", found)))
    menu = '<div class="menu"><div class="on">Next Change<span>⌥⌘↓</span></div><div>Previous Change<span>⌥⌘↑</span></div><div>Back<span>⌘[</span></div><div>Forward<span>⌘]</span></div></div>'
    s.append(screen(4, "After an agent's rewrite", "Thin ink marks beside new and changed blocks, a gap mark where two paragraphs were removed, dots on changed sections in the outline, Next Change in the Go menu. Marks clear after three seconds on screen.",
                    window("Ferry: product requirements", "ferry/docs", doc(page=PRD_CHANGED, outline=OUTLINE_PRD) + menu)))
    s.append(screen(5, "Properties", "⌘I shows the full frontmatter as a table in a solid popover.",
                    window("Reading in Linen", "notes", doc() + PROPS)))
    s.append(screen(6, "Linked from", "At the foot of a note: the notes that link here, grouped by note, one sentence each, ten shown.",
                    window("Linen", "vault/wiki/projects", doc(page='<h1 class="title">Linen</h1><p>The Mac\'s reader for Markdown, in the Loom suite next to Ferry.</p>' + LINKED, outline='<nav class="outline"><div class="otitle">Linen</div><a>What it is</a><a>Current state</a><a class="cur">Linked from</a><div class="prog"><i style="height:90%"></i></div></nav>'))))
    s.append(screen(7, "Open Quickly", "⇧⌘O: note names and aliases in the vault, then recent files.",
                    window("Reading in Linen", "notes", doc() + QUICK)))
    s.append(screen(8, "Blocked remote and outside files", "Nothing loads from the network, and nothing outside the vault, until the reader allows it for this file.",
                    window("Client deck notes", "notes", doc(page='<h1 class="title">Client deck notes</h1>' + BLOCKED, outline='<nav class="outline"><div class="otitle">Client deck notes</div><a class="cur">Figures</a><a>Open questions</a><div class="prog"><i style="height:10%"></i></div></nav>'))))
    s.append(screen(9, "File no longer here", "Shown when a file is truly gone (renamed and moved files are followed).",
                    window("Old plan.md", "", f'<div style="position:absolute;inset:0">{GONE}</div>', w=900, h=520, toolbar=[])))
    s.append(screen(10, "Settings", "One pane in Ferry Host's pattern: eyebrow, serif title, ruled rows.",
                    f'<div class="row2">{settings()}{settings(rtl=True)}</div>'))
    s.append(screen(11, "Quick Look", "The same renderer in Finder: the full preview and the narrow preview pane.",
                    f'<div class="row2">{quicklook()}{quicklook(narrow=True)}</div>'))
    s.append(screen(12, "Print", "Always on white or paper, a running title and page numbers stamped natively, links as text.", printed()))
    s.append(screen(13, "Present", "⌥⌘P: large type, no outline, space moves one screen.", present()))
    s.append(screen(14, "Night", "The same screens from the same tokens: ground ink-2, text paper.",
                    '<div class="row2">' + window("Reading in Linen", "notes", doc(), theme="night", w=1180, h=640) + "</div>"))
    s.append(screen(15, "Night: find and Open Quickly", "", '<div class="row2">' +
                    window("Reading in Linen", "notes", found, theme="night", w=1180, h=560) + "</div>"))
    s.append(screen(16, "Arabic interface", "The window mirrors: the outline on the right, the toolbar on the left; each block takes its own direction.",
                    window("القراءة في سطر", "ملاحظات", f'<div class="docwrap">{OUTLINE_AR}<main class="page">{PAGE_AR}</main>{FOOTER_AR}</div>', rtl=True)))
    s.append(screen(17, "A narrow window", "When the rail does not fit beside the column, it overlays the margin when opened.",
                    window("Reading in Linen", "notes", doc(), w=820, h=640, cls="narrowwin")))
    return (f'<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width">'
            f'<title>Linen screens</title><style>{CSS}</style><body>{HEAD}{"".join(s)}</body></html>')


if __name__ == "__main__":
    OUT.write_text(build(), encoding="utf-8")
    print("wrote", OUT, OUT.stat().st_size // 1024, "KB")
