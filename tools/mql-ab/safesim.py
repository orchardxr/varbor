#!/usr/bin/env python3
# safesim.py <dump>... : replay the per-frame present>decoded (max of both eyes, WIVRN_FEEDBACK_DUMP) through the pacer's
# safe estimator (percentile over a window of W frames, recomputed every 100 frames, + margin) and count frames that
# would decode after their slot. Arrival times don't depend on the safe value, so different estimators can be compared
# on the same recording.
import sys
from collections import defaultdict
import numpy as np

def load(path):
    fr = defaultdict(dict)
    with open(path) as f:
        next(f)
        for l in f:
            v = l.split()
            if len(v) < 18: continue
            v = list(map(int, v))
            idx, s, shown, b, present, dec, bl = v[1], v[2], v[3], v[4], v[6], v[15], v[16]
            if s > 1 or not present or shown != 1 or not dec or not bl: continue
            fr[idx][s] = (dec - b - present) / 1e6
    return np.array([max(d[0], d[1]) for i, d in sorted(fr.items()) if 0 in d and 1 in d])

def sim(x, q, w, m):
    safe = np.empty_like(x); cur = 0.
    for i in range(0, len(x), 100):
        if i: cur = np.percentile(x[max(0, i - w):i], q) + m
        safe[i:i + 100] = cur
    s = slice(min(len(x) // 10, w), None)  # skip the warm-up
    return (x[s] > safe[s]).mean() * 100, safe[s].mean(), np.percentile(safe[s], 50)

for path in sys.argv[1:]:
    x = load(path)
    print(f"{path}: {len(x)} frames, p50 {np.percentile(x, 50):.1f} p99 {np.percentile(x, 99):.1f} p99.5 {np.percentile(x, 99.5):.1f}")
    print(" pct window margin | miss %  per-min  safe mean")
    for q, w, m in [(99.5, 5000, 1), (99.5, 2000, 1), (99.5, 1000, 1), (99, 5000, 1), (99, 2000, 1), (99, 1000, 1),
                    (98, 5000, 1), (98, 2000, 1), (98, 1000, 1), (98, 1000, 2), (97, 1000, 2), (95, 1000, 2), (95, 1000, 3),
                    (95, 500, 3), (90, 1000, 4), (99, 500, 1), (99.5, 500, 1)]:
        miss, mean, med = sim(x, q, w, m)
        print(f" {q:5.1f} {w:5d} {m:3.0f}    | {miss:5.2f}  {miss * 54:6.1f}   {mean:5.1f}")
