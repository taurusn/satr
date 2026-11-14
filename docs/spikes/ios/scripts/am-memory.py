#!/usr/bin/env python3
"""Memory per process from an xctrace Activity Monitor recording on the iPhone.

Reads the exported `activity-monitor-process-live` table (xctrace's XML with id/ref compression), keeps the processes
whose name matches the filters (WebKit's WebContent, GPU and Networking processes and the spike app by default), and
prints each process's samples: the interval, the physical footprint ("Memory" column) min / max / last, and every
sample at 5 s spacing or finer. A process that disappears and reappears with a new pid (a jetsam or crash) shows as
two lines with different pids.

    xcrun xctrace export --input X.trace --xpath '/trace-toc/run[@number="1"]/data/table[@schema="activity-monitor-process-live"]' > live.xml
    python3 -I scripts/am-memory.py live.xml [--json out.json] [--every 5]
"""
import json, re, sys
import xml.etree.ElementTree as ET

path = sys.argv[1]
want = ("WebContent", "WebKit.GPU", "GPU", "Networking", "LinenSpike")
every = float(sys.argv[sys.argv.index("--every") + 1]) if "--every" in sys.argv else 5.0
root = ET.parse(path).getroot()
ids = {}


def resolve(el):
    if el is None:
        return None
    if "ref" in el.attrib:
        return ids.get(el.attrib["ref"], el)
    if "id" in el.attrib:
        ids[el.attrib["id"]] = el
    for c in el:
        resolve(c)
    return el


cols = [c.findtext("mnemonic") for c in root.iter("col")]
series = {}
for row in root.iter("row"):
    cells = [resolve(c) for c in row]
    rec = dict(zip(cols, cells))
    proc = rec.get("process")
    name = proc.attrib.get("fmt", "") if proc is not None else ""
    if not any(w in name for w in want):
        continue
    t = int(rec["start"].text) / 1e9 if rec.get("start") is not None and rec["start"].text else None
    mem = rec.get("memory-physical-footprint")
    b = int(mem.text) if mem is not None and mem.text and mem.text.isdigit() else None
    series.setdefault(name, []).append((t, b))

out = {}
for name, pts in sorted(series.items()):
    pts = sorted(p for p in pts if p[0] is not None and p[1] is not None)
    if not pts:
        continue
    gaps = [b[0] - a[0] for a, b in zip(pts, pts[1:])]
    mb = [p[1] / 1048576 for p in pts]
    print(f"{name}: {len(pts)} samples over {pts[-1][0] - pts[0][0]:.0f} s (t {pts[0][0]:.1f} to {pts[-1][0]:.1f}), "
          f"interval max {max(gaps) if gaps else 0:.1f} s; footprint min {min(mb):.1f} MB, max {max(mb):.1f} MB, last {mb[-1]:.1f} MB")
    thin, last = [], None
    for t, b in pts:
        if last is None or t - last >= every - 0.01:
            thin.append((round(t, 1), round(b / 1048576, 1)))
            last = t
    out[name] = {"samples": [(round(t, 2), b) for t, b in pts], "every": thin, "maxMB": max(mb), "maxGapS": max(gaps) if gaps else 0}
if "--json" in sys.argv:
    json.dump(out, open(sys.argv[sys.argv.index("--json") + 1], "w"), indent=1)
