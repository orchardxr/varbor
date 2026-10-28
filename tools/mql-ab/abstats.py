#!/usr/bin/env python3
# abstats.py build/ab/<label> : summary of one abrecord.sh window
import os, re, sys, statistics as st
p = sys.argv[1]
def pct(v, q):
    v = sorted(v); return v[min(len(v) - 1, int(q * len(v)))] if v else float('nan')
def fmt(v, d=1):
    return f"mean {st.mean(v):.{d}f} p95 {pct(v, .95):.{d}f} (n {len(v)})" if v else "-"
hud = []
for l in open(p + '.hud'):
    m = re.search(r'(\d\d):(\d\d):(\d\d\.\d+) .*metal-HUD: (\d+),', l)
    if m: hud.append((int(m[1]) * 3600 + int(m[2]) * 60 + float(m[3]), int(m[4])))
hud = [h for i, h in enumerate(hud) if i == 0 or h[1] != hud[i - 1][1]]
fps = [(b[1] - a[1]) / (b[0] - a[0]) for a, b in zip(hud, hud[1:]) if b[0] > a[0]]
low = [f for f in fps]
print("game fps (Metal HUD frame counter, 1-s windows):", f"mean {st.mean(fps):.1f} min {min(fps):.1f} p5 {pct(fps, .05):.1f}" if fps else "-")
if len(hud) > 1: print(f"  overall {(hud[-1][1] - hud[0][1]) / (hud[-1][0] - hud[0][0]):.2f} fps over {hud[-1][0] - hud[0][0]:.0f} s")
groups = {'hlvr': 'hlvr.exe', 'wineserver': 'wineserver', 'vrserver': 'vrserver.exe', 'vrcompositor': 'vrcompositor.exe',
          'vrwebhelper': 'vrwebhelper', 'vrmonitor': 'vrmonitor', 'A-encoder': os.environ.get('AB_ENCODER_PROC', 'ab-encoder'), 'wivrn-server': 'wivrn-server',
          'VTEncoderXPC': 'VTEncoderXPCService', 'steam.exe': 'steam.exe', 'WindowServer': 'WindowServer'}
samples, cur = [], None
for l in open(p + '.ps'):
    if l.startswith('#'):
        cur = {}; samples.append(cur); continue
    f = l.split(None, 3)
    for k, pat in groups.items():
        if pat in f[3]: cur[k] = cur.get(k, 0) + float(f[1])
print("CPU % (ps, 2-s samples):")
for k in groups:
    v = [s.get(k, 0) for s in samples]
    if any(v): print(f"  {k}: {fmt(v, 0)}")
def nums(file, rx):
    try: return [tuple(map(float, m.groups())) for m in re.finditer(rx, open(file).read())]
    except FileNotFoundError: return []
e = nums(p + '.encoder', r'([\d.]+) fps, avg ([\d.]+) ms encode, ([\d.]+) Mbit/s')
if e: print(f"A stream: fps {fmt([x[0] for x in e])}, encode ms {fmt([x[1] for x in e], 2)}, Mbit/s {fmt([x[2] for x in e])}")
s = nums(p + '.shim', r'total ([\d.]+)/([\d.]+)')
if s: print(f"A frame path avg/max ms: {fmt([x[0] for x in s], 2)} / max {max(x[1] for x in s):.1f}")
txt = open(p + '.vrlink').read() if e else ''
bad = re.findall(r'Bad link event.*?ping ([\d.]+)', txt)
if e: print(f"A vrlink Bad link events: {len(bad)} pings {bad[:10]}")
w = nums(p + '.wivrn', r'\(([\d.]+) fps\), ([\d.]+) Mbit/s, (\d+) IDR, encode p50 ([\d.]+) p95 ([\d.]+)')
if w: print(f"B stream (per stream, 10-s): fps {fmt([x[0] for x in w])}, Mbit/s {fmt([x[1] for x in w])}, encode p50 {fmt([x[3] for x in w], 2)} p95 {fmt([x[4] for x in w], 2)}, IDR {sum(x[2] for x in w):.0f}")
lat = nums(p + '.wivrn', r'network ([\d.]+)/([\d.]+) decode [\d./]+ decoded>blit [\d./]+ blit>display [\d./]+ present>decoded ([\d.]+)/([\d.]+)')
if lat: print(f"B latency: network p50 {fmt([x[0] for x in lat])} p95 {fmt([x[1] for x in lat])}; present>decoded p50 {fmt([x[2] for x in lat])} p95 {fmt([x[3] for x in lat])}")
