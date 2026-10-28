#!/usr/bin/env python3
# decodestats.py <prefix> [t0 t1] : per-frame Quest decode (to_decoder > decoded) and second-eye delay from the feedback
# dump, optionally only seconds t0..t1 of the record window; plus stream-0/1 frame sizes from <prefix>-N.sizes (ffprobe
# packet size,flags of the window).
import statistics as st, sys, os
p = sys.argv[1]
m0, m1 = map(int, open(p + '.window').read().split())
if len(sys.argv) > 3:
    m0, m1 = m0 + int(float(sys.argv[2]) * 1e9), m0 + int(float(sys.argv[3]) * 1e9)
pct = lambda v, q: sorted(v)[min(len(v) - 1, int(q * len(v)))]
fr = {}
fbf = p + '.fb.rec' if os.path.exists(p + '.fb.rec') else p + '.fb'
for l in list(open(fbf, errors='replace'))[1:]:
    v = l.split()
    if len(v) < 20: continue
    try:
        v = list(map(int, v[:20]))
    except ValueError:
        continue
    if not (m0 <= v[0] <= m1) or v[2] > 1 or not v[15] or not v[14]: continue
    fr.setdefault(v[1], {})[v[2]] = (v[15] - v[14], v[15], v[15] - v[13], v[13] - v[11])
dec = [d[s][0] / 1e6 for d in fr.values() for s in d]
both = [d for d in fr.values() if 0 in d and 1 in d]
gap = [abs(d[0][1] - d[1][1]) / 1e6 for d in both]
net = [d[s][3] / 1e6 for d in fr.values() for s in d]
w = sorted(dec)[-max(1, len(dec) // 50):]
print(f"{os.path.basename(p)} {sys.argv[2:] or ''}: frames {len(fr)}; decode p50 {pct(dec,.5):.1f} p95 {pct(dec,.95):.1f} worst-2% mean {st.mean(w):.1f}; "
      f"2nd eye after 1st mean {st.mean(gap):.1f} p95 {pct(gap,.95):.1f}; network p50 {pct(net,.5):.1f} p95 {pct(net,.95):.1f}")
for s in (0, 1):
    f = p + f'-{s}.sizes'
    if not os.path.exists(f): continue
    z = [int(l.split(',')[0]) for l in open(f) if l.strip()]
    k = sum('K' in l for l in open(f))
    m = st.mean(z)
    print(f"  stream {s} frame bytes: mean {m/1e3:.0f}k p50 {pct(z,.5)/1e3:.0f}k p95 {pct(z,.95)/1e3:.0f}k p99 {pct(z,.99)/1e3:.0f}k max {max(z)/1e3:.0f}k "
          f"(max/mean {max(z)/m:.1f}, p99/mean {pct(z,.99)/m:.2f}, CV {st.pstdev(z)/m:.2f}); keyframes {k}; {m*8*90/1e6:.0f} Mbit/s")
