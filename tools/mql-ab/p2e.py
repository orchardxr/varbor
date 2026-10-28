#!/usr/bin/env python3
# p2e.py build/lat/<label> : split present>encode (desired present -> encode begin) into desired->compositor woke,
# woke->submitted (compositor CPU) and submitted->encode begin (encoder thread + GPU wait), median and over the
# frames in the worst 2 % of present>decoded (max of eyes).
import numpy as np, sys
from collections import defaultdict
p = sys.argv[1]
m0, m1 = map(int, open(p + '.window').read().split())
fr = defaultdict(dict)
for l in open(p + '.fb'):
    v = l.split()
    if len(v) < 20 or v[0] == 'now': continue
    v = list(map(int, v))
    if not m0 <= v[0] <= m1: continue
    now, idx, s, shown, b, safe, present, disp = v[:8]
    eb, dec, bl, woke, sub = v[8], v[15], v[16], v[18], v[19]
    if s > 1 or not present or shown != 1 or not dec or not woke or not sub: continue
    fr[idx][s] = ((dec - b - present) / 1e6, (woke - present) / 1e6, (sub - woke) / 1e6, (eb - b - sub) / 1e6)
rows = np.array([[max(d[0][0], d[1][0])] + [max(d[0][i], d[1][i]) for i in (1, 2, 3)] for d in fr.values() if 0 in d and 1 in d])
t = rows[rows[:, 0] >= np.percentile(rows[:, 0], 98)]
for name, r in (('all', rows), ('worst 2%', t)):
    print(f"{name:9s} n {len(r):5d}: X {np.median(r[:, 0]):5.1f}  desired>woke p50 {np.median(r[:, 1]):5.2f} p95 {np.percentile(r[:, 1], 95):5.2f}  "
          f"woke>submit p50 {np.median(r[:, 2]):5.2f} p95 {np.percentile(r[:, 2], 95):5.2f}  submit>encode p50 {np.median(r[:, 3]):5.2f} p95 {np.percentile(r[:, 3], 95):5.2f}")
