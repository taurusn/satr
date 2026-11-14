#!/usr/bin/env python3
"""Statistics for the spike app's result files, with board-host's definitions (Tests/Harness/board-host.swift):
quantile = sorted[min(n-1, int(p*n))], "dropped" = frames over 25 ms, longest = the largest frame.

    python3 -I scripts/analyze.py <results dir>     # every paint-*, bench-*, touch-*, loop-* file in it
"""
import json, os, sys


def q(xs, p):
    s = sorted(xs)
    return s[min(len(s) - 1, int(p * len(s)))] if s else float("nan")


def frames(xs):
    if not xs:
        return "no frames"
    d = sum(1 for x in xs if x > 25) / len(xs) * 100
    return f"p50 {q(xs, .5):.1f}  p95 {q(xs, .95):.1f}  p99 {q(xs, .99):.1f}  dropped {d:.2f}%  longest {max(xs):.0f} ms  ({len(xs)} frames)"


def times(xs):
    return f"p50 {q(xs, .5):.0f}  p95 {q(xs, .95):.0f}  max {max(xs):.0f} ms  (n={len(xs)})" if xs else "none"


def paint(d):
    print(f"\n== first paint, {d['board']} (opening place {d['place']['zoom']:.3f} canvas; view {d['openingView'].get('W')}x{d['openingView'].get('H')}, level {d['openingView'].get('level')}, mounted {d['openingView'].get('mounted')})")
    for k in ("warm", "cold", "list"):
        rows = d[k]
        bad = [r for r in rows if r.get("reply") != "firstPaint"]
        print(f"{k:5} load to firstPaint (app clock): {times([r['hostMs'] for r in rows])}   page's own paintMs: {times([r['pageMs'] for r in rows])}{'  TIMEOUTS ' + str(len(bad)) if bad else ''}")
    c = d["cold"]
    print(f"cold  new web view to firstPaint: {times([r['totalMs'] for r in c])}   page ready: {times([r['pageReadyMs'] for r in c])}")
    print(f"errors {len(d['errors'])}, terminations {len(d['terminations'])}")


def bench(d):
    by, settle, order = {}, {}, []
    for run in d["runs"]:
        for r in run["runs"]:
            if r["name"] not in by:
                order.append(r["name"])
            by.setdefault(r["name"], []).extend(r["frames"])
            settle.setdefault(r["name"], []).append(r["settleMs"])
    r0 = d["runs"][0] if d["runs"] else {}
    print(f"\n== renderer bench (board.js bench), {d['board']}, {len(d['runs'])} runs, view {r0.get('w')}x{r0.get('h')} @{r0.get('dpr')}x, {r0.get('n')} nodes {r0.get('e')} edges")
    for n in order:
        print(f"{n:24} {frames(by[n])}  settle max {max(settle[n]):.0f} ms")
    allf = [x for n in order for x in by[n]]
    print(f"{'all gestures':24} {frames(allf)}")
    print(f"errors {len(d['errors'])}, terminations {len(d['terminations'])}")


def touch(d):
    gs = d["gestures"]
    print(f"\n== real touches, {d['board']}: {len(gs)} gestures, written {d['at']}")
    for kind, test in (("pans from the ground (1 finger)", lambda g: g["fingers"] == 1 and g.get("on") != "card"),
                       ("pans from a card (1 finger)", lambda g: g["fingers"] == 1 and g.get("on") == "card"),
                       ("pinches (2 fingers)", lambda g: g["fingers"] >= 2)):
        sel = [g for g in gs if test(g)]
        if not sel:
            continue
        fr = [x for g in sel for x in g["frames"]]
        lat = [x for g in sel for x in g["lat"]]
        first = [g["first"] for g in sel if g["first"] is not None]
        qd = [x for g in sel for x in g["queue"]]
        st = [x for g in sel for x in (g.get("settle") or [])]
        print(f"{kind}: {len(sel)}")
        print(f"  frames during the gesture: {frames(fr)}")
        print(f"  frames while settling:     {frames(st)}")
        print(f"  moved frames per gesture: {sorted(g['moved'] for g in sel)}")
        print(f"  touch to first moved frame (per gesture), from the first move event: {times(first)}")
        print(f"  touch to first moved frame (per gesture), from the event that moved it: {times([g['firstLast'] for g in sel if g.get('firstLast') is not None])}")
        print(f"  first moved frame after touch down: {times([g['firstAfterStart'] for g in sel if g.get('firstAfterStart') is not None])}")
        print(f"  latest input to moved frame (every moved frame): {times([x for g in sel for x in g.get('latLast', [])])}")
        print(f"  input to moved frame (every moved frame): {times(lat)}")
        print(f"  event age when handled (now - timeStamp): {times(qd)}")
        worst = sorted(sel, key=lambda g: -max(g["frames"] or [0]))[:3]
        for g in worst:
            print(f"    worst #{g['n']}: longest {max(g['frames'] or [0]):.0f} ms, zoom {g['s0']} -> {g['s1']} ({g['level0']} -> {g['level1']}), frames {len(g['frames'])}, moved {g['moved']}")
    print(f"errors {len(d['errors'])}, terminations {len(d['terminations'])}")


def loop(d):
    its = d["iterations"]
    print(f"\n== loop, {d['board']}, {len(its)} iterations, {d['minutes']} min")
    print(f"first paint: {times([i['firstPaintMs'] for i in its])}")
    print(f"reload after outside change (write to repaint): {times([i['reloadMs'] for i in its if 'reloadMs' in i])}; watcher saw every write: {all(i.get('watcherSaw') for i in its)}")
    drift = [i["centreDriftPx"] for i in its if "centreDriftPx" in i]
    if drift:
        print(f"centre node drift: max {max(drift):.2f} px")
    print(f"longest synthetic pan frame {max(i['panLongestFrameMs'] for i in its):.0f} ms, pinch {max(i['pinchLongestFrameMs'] for i in its):.0f} ms")
    print(f"node notes opened per iteration: {sorted(set(i['nodeNotesOpened'] for i in its))}; list mode seen: {sorted(set(i['listMode'] for i in its))}")
    print(f"errors {its[-1]['consoleErrors'] if its else '?'} console, {its[-1]['pageErrors'] if its else '?'} page; terminations {len(d['terminations'])}")


root = sys.argv[1]
for name in sorted(os.listdir(root)):
    if not name.endswith(".json"):
        continue
    d = json.load(open(os.path.join(root, name)))
    kind = name.split("-")[0]
    {"paint": paint, "bench": bench, "touch": touch, "loop": loop}.get(kind, lambda d: None)(d)
