#!/usr/bin/env python3
# bridgestats.py <log slice> : per-frame bridge lines (WINEOPENXR_STATS=2: "F interval wait bridge", "W work lag", ms)
# -> fps, 1% low, frame-interval spikes, the bridge's time on the frame thread and on the async worker.
import statistics as st, sys

F, W = [], []
for l in open(sys.argv[1], errors="replace"):
    f = l.split()
    if len(f) == 5 and f[1] == "F":
        F.append(tuple(map(float, f[2:5])))
    elif len(f) == 4 and f[1] == "W":
        W.append(tuple(map(float, f[2:4])))
iv = [f[0] for f in F if f[0] > 0]
if not iv:
    sys.exit("no frames")


def pct(v, q):
    v = sorted(v)
    return v[min(len(v) - 1, int(q * len(v)))]


def mpm(v):
    return f"mean {st.mean(v):.2f} p99 {pct(v, .99):.2f} max {max(v):.2f}"


worst = sorted(iv)[-max(1, len(iv) // 100):]
med = st.median(iv)
print(f"frames {len(iv)}, fps {len(iv) / (sum(iv) / 1000):.1f}, 1% low {1000 / st.mean(worst):.1f} "
      f"(p99 interval {pct(iv, .99):.1f} ms), median interval {med:.2f} ms")
print(f"interval spikes: >20 ms {sum(i > 20 for i in iv)}, >25 ms {sum(i > 25 for i in iv)}, "
      f">1.5x median {sum(i > 1.5 * med for i in iv)}")
print(f"frame thread bridge ms: {mpm([f[2] for f in F])}, >4 ms {sum(f[2] > 4 for f in F)}")
print(f"frame thread xrWaitFrame (+drain) ms: {mpm([f[1] for f in F])}")
if W:
    print(f"worker ms: {mpm([w[0] for w in W])}, >4 ms {sum(w[0] > 4 for w in W)}; lag {mpm([w[1] for w in W])}")
