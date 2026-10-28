#!/usr/bin/env python3
# fbseries.py <dump> [bucket s] : per-bucket present>decoded (max of both eyes) p50/p99/max, frames over 30 ms, and the
# safe value in use, over a whole WIVRN_FEEDBACK_DUMP file.
import sys
from collections import defaultdict
B = float(sys.argv[2]) if len(sys.argv) > 2 else 5
fr = defaultdict(dict); t0 = None
with open(sys.argv[1]) as f:
    next(f)
    for l in f:
        v = l.split()
        if len(v) < 18: continue
        v = list(map(int, v))
        now, idx, s, shown, b, safe, present = v[:7]
        dec, bl = v[15], v[16]
        if t0 is None: t0 = now
        if s > 1 or not present or shown != 1 or not dec or not bl: continue
        fr[idx][s] = ((now - t0) / 1e9, (dec - b - present) / 1e6, safe / 1e6)
bk = defaultdict(list); sf = {}
for idx, d in fr.items():
    if 0 in d and 1 in d:
        t = d[0][0]; k = int(t // B)
        bk[k].append(max(d[0][1], d[1][1])); sf[k] = d[0][2]
for k in sorted(bk):
    x = sorted(bk[k]); n = len(x)
    print(f"{k * B:6.0f}s n {n:4d} p50 {x[n // 2]:5.1f} p99 {x[min(n - 1, n * 99 // 100)]:5.1f} max {x[-1]:6.1f} >30 {sum(v > 30 for v in x):3d}  safe {sf[k]:5.1f}")
