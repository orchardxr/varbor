#!/usr/bin/env python3
# m2pmax.py <prefix>... : for each ~1-s overlay M2P value (the max over the window), the query that set it, split into
# pose age (now - produced) and app horizon (at - now); compared with the window's median query. ms.
import statistics as st, sys
for p in sys.argv[1:]:
    m0, m1 = map(int, open(p + '.window').read().split())
    Q, M = [], []
    for l in open(p + '.m2p', errors='replace'):
        f = l.split()
        if f and f[0] == 'Q' and len(f) == 5 and f[4] != '0':
            Q.append(tuple(map(int, f[1:])))
        elif f and f[0] == 'M' and len(f) == 3:
            M.append((int(f[1]), int(f[2])))
    rows = []
    qi = 0
    for (t0, _), (t1, m) in zip(M, M[1:]):
        if not (m0 <= t1 <= m1) or not m:
            continue
        w = [q for q in Q if t0 < q[0] <= t1]
        if not w:
            continue
        top = max(w, key=lambda q: q[2] - q[3])
        med = st.median(q[2] - q[3] for q in w)
        rows.append(((top[2] - top[3]) / 1e6, (top[0] - top[3]) / 1e6, (top[2] - top[0]) / 1e6, med / 1e6))
    n = len(rows)
    if not n:
        print(p, 'no data'); continue
    f = lambda i: st.mean(r[i] for r in rows)
    spikes = [r for r in rows if r[1] > 10]
    print(f"{p.split('/')[-1]:12s} n {n}: overlay mean {f(0):.1f} = age {f(1):.1f} + horizon {f(2):.1f}; window median est {f(3):.1f}; "
          f"max-median {f(0) - f(3):.1f}; windows set by an age >10 ms: {len(spikes)} (mean {st.mean(r[0] for r in spikes) if spikes else 0:.0f})")
