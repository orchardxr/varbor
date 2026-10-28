#!/usr/bin/env python3
# latstats.py build/lat/<label> : summary of one latrun.sh window: server latency lines, feedback dump (diag patch
# WIVRN_FEEDBACK_DUMP: per-frame present>decoded over both eyes, its tail and what makes it), client logcat, bridge fps.
import os, re, statistics as st, subprocess, sys
from collections import defaultdict

p = sys.argv[1]
D = os.path.dirname(os.path.abspath(__file__))


def pct(v, q):
    v = sorted(v)
    return v[min(len(v) - 1, int(q * len(v)))] if v else float('nan')


# server log lines in the window
lat = defaultdict(list)
extra = defaultdict(list)
for l in open(p + '.wivrn', errors='replace'):
    if 'log_latency' in l:
        for k, a, b in re.findall(r' ([a-z>-]+) (-?[\d.]+)/(-?[\d.]+)', l):
            lat[k].append((float(a), float(b)))
        m = re.search(r'safe present>decoded ([\d.]+)', l)
        if m: extra['safe'].append(float(m[1]))
        for k in ('shown late', 'repeated', 'skipped'):
            m = re.search(k + r' (\d+)', l)
            if m: extra[k].append(int(m[1]))
    m = re.search(r'stream (\d): \d+ frames in [\d.]+ s \(([\d.]+) fps\), ([\d.]+) Mbit/s', l)
    if m: extra['fps' + m[1]].append(float(m[2])); extra['mbit' + m[1]].append(float(m[3]))
print('server log_latency (mean of the 10-s p50/p95):')
print('  ' + ', '.join(f"{k} {st.mean(x[0] for x in v):.1f}/{st.mean(x[1] for x in v):.1f}" for k, v in lat.items()))
print('  safe ' + ' '.join(f'{x:.1f}' for x in extra['safe']) +
      ''.join(f"; {k} {sum(extra[k])}" for k in ('shown late', 'repeated', 'skipped') if extra[k]) +
      f"; encoded fps {st.mean(extra['fps0']):.1f}/{st.mean(extra['fps1']):.1f}, Mbit/s {st.mean(extra['mbit0']):.0f}"
      if extra['fps0'] else '')

# feedback dump
try:
    m0, m1 = map(int, open(p + '.window').read().split())
    rows = []
    with open(p + '.fb') as f:
        next(f)
        for l in f:
            v = l.split()
            if len(v) < 18: continue
            v = list(map(int, v))[:20]
            if m0 <= v[0] <= m1: rows.append(v)
except FileNotFoundError:
    rows = []
if rows:
    fr = defaultdict(dict)
    shows = defaultdict(int)
    for v in rows:
        now, idx, s, shown, b, safe, present, disp = v[:8]
        ts = dict(zip('eb ee sb se rf rl td dec bl dsp'.split(), v[8:]))
        if s == 0 and ts['bl'] and shown > 1: shows['repeat'] += 1
        if s == 0 and not ts['bl'] and ts['dec']: shows['skipped'] += 1
        if s > 1 or not present or shown != 1 or not ts['dec']: continue
        fr[idx][s] = (b, safe, present, disp, ts)
    X, comp, late, safes = [], [], 0, []
    for idx, d in fr.items():
        if 0 not in d or 1 not in d: continue
        x = []
        for s in (0, 1):
            b, safe, present, disp, t = d[s]
            x.append(((t['dec'] - b - present) / 1e6, s, t, b, present))
        worst = max(x, key=lambda e: e[0])
        X.append(worst[0]); safes.append(d[0][1] / 1e6)
        t, b, present = worst[2], worst[3], worst[4]
        comp.append((worst[0], worst[1], (t['eb'] - b - present) / 1e6, (t['ee'] - t['eb']) / 1e6, (t['se'] - t['ee']) / 1e6,
                     (t['rl'] - t['se']) / 1e6, (t['dec'] - t['td']) / 1e6, abs(x[0][0] - x[1][0])))
        b0, _, _, disp0, t0 = d[0]
        if t0['dsp'] - b0 - disp0 > 5.5e6: late += 1
    n = len(X)
    print(f"feedback dump: {n} frames with both eyes; present>decoded (max of eyes) p50 {pct(X, .5):.1f} p95 {pct(X, .95):.1f} "
          f"p99 {pct(X, .99):.1f} p99.5 {pct(X, .995):.1f} max {max(X):.1f}; safe in use {st.mean(safes):.1f}")
    print(f"  first shown later than predicted: {late} ({100 * late / n:.2f} %); stream-0 repeats {shows['repeat']}, skipped {shows['skipped']}")
    print('  frames over a fixed safe S (S = threshold incl. margin):', ' '.join(f"{S}:{sum(x > S for x in X)}" for S in (20, 22, 24, 26, 28, 30, 33, 36)))
    tail = sorted(comp)[-max(1, n // 50):]
    names = 'present>encode encode send network decode eye-gap'.split()
    print(f"  worst 2 % (>{tail[0][0]:.1f} ms), slow eye 0/1 {sum(c[1] == 0 for c in tail)}/{sum(c[1] == 1 for c in tail)}, mean ms: " +
          ', '.join(f"{k} {st.mean(c[i + 2] for c in tail):.1f}" for i, k in enumerate(names)))
    print('  all frames, mean ms: ' + ', '.join(f"{k} {st.mean(c[i + 2] for c in comp):.1f}" for i, k in enumerate(names)))
    bs = [v[4] for v in rows]
    print(f"  clock offset over the window: {(max(bs) - min(bs)) / 1e3:.0f} us range")

# client
try:
    lc = open(p + '.logcat', errors='replace').read()
    fps = [list(map(int, m)) for m in re.findall(r'VrApi.*FPS=(\d+)/\d+,Prd=(\d+)ms.*?Stale=(\d+)', lc)]
    if fps:
        print(f"client VrApi: FPS mean {st.mean(f[0] for f in fps):.1f} min {min(f[0] for f in fps)}, Stale sum {sum(f[2] for f in fps)}, "
              f"Prd median {st.median(f[1] for f in fps)} ms (n {len(fps)})")
    print(f"client 'Failed to find a common frame': {lc.count('Failed to find a common frame')}")
except FileNotFoundError:
    pass
if os.path.exists(p + '.bridge') and os.path.getsize(p + '.bridge'):
    print('bridge: ' + subprocess.run([sys.executable, D + '/bridgestats.py', p + '.bridge'], capture_output=True, text=True).stdout.strip()
          .replace('\n', '\n        '))
if os.path.exists(p + '.gpufreq'): print('gpu: ' + open(p + '.gpufreq').read().strip().replace('\n', ' | ')[:300])
if os.path.exists(p + '.reconnect'): print(open(p + '.reconnect').read().strip())
