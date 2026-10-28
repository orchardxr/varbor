#!/usr/bin/env python3
# pacertrace.py <trace> [-v] : summarise a WiVRn app-pacer trace (diag patch, WIVRN_PACER_TRACE): per app frame the
# predict call, chosen branch, wake target, actual wake, delivery, GPU done and display time; spikes in context.
import sys, statistics as st
fr = {}
comp = []
for l in open(sys.argv[1], errors="replace"):
    f = l.split()
    if not f:
        continue
    k = f[0]
    try:
        if k == "P":
            d = fr.setdefault(int(f[1]), {})
            d.update(now=int(f[3]), cpu=int(f[5]), gpu=int(f[7]), comp=int(f[9]), cd=int(f[11]), L=int(f[13]),
                     minr=int(f[15]), br=f[16])
        elif k == "R":
            fr.setdefault(int(f[1]), {}).update(wake=int(f[3]), disp=int(f[5]))
        elif k == "W":
            fr.setdefault(int(f[1]), {})["woke"] = int(f[2])
        elif k == "D":
            fr.setdefault(int(f[1]), {})["deliv"] = int(f[2])
        elif k == "S":
            fr.setdefault(int(f[1]), {})["sub"] = int(f[2])
        elif k == "G":
            fr.setdefault(int(f[1]), {})["gpu_done"] = int(f[2])
        elif k == "I":
            comp.append((int(f[1]), int(f[3]), int(f[5]), int(f[7])))
    except (IndexError, ValueError):
        pass
ids = sorted(i for i in fr if all(x in fr[i] for x in ("now", "wake", "woke", "disp")))
ms = lambda ns: ns / 1e6
rows = []
for a, b in zip(ids, ids[1:]):
    if b != a + 1:
        continue
    A, B = fr[a], fr[b]
    rows.append(dict(id=b, iv=ms(B["woke"] - A["woke"]), wait=ms(B["woke"] - B["now"]), br=B["br"],
                     dstep=ms(B["disp"] - A["disp"]), slack=ms(B["L"] - B["minr"]), cpu=ms(B["cpu"]), gpu=ms(B["gpu"]),
                     comp=ms(B["comp"]), lat=ms(B["disp"] - B["woke"]),
                     work=ms(B["deliv"] - B["woke"]) if "deliv" in B else 0,
                     tail=ms(B["gpu_done"] - B["deliv"]) if "gpu_done" in B and "deliv" in B else 0,
                     hold=ms(B["sub"] - B["deliv"]) if "sub" in B and "deliv" in B else 0))
if not rows:
    sys.exit("no frames")
iv = [r["iv"] for r in rows]
wait = sorted(r["wait"] for r in rows)
pct = lambda v, q: sorted(v)[min(len(v) - 1, int(q * len(v)))]
print(f"frames {len(rows)}, fps {len(iv) / (sum(iv) / 1e3):.1f}, interval p50 {pct(iv, .5):.2f} p99 {pct(iv, .99):.2f}, "
      f">20ms {sum(i > 20 for i in iv)}; wait p50 {pct(wait, .5):.2f} p90 {pct(wait, .9):.2f} p99 {pct(wait, .99):.2f}, "
      f">20ms {sum(w > 20 for w in wait)}; imm {sum(r['br'] == 'imm' for r in rows)}")
steps = {}
for r in rows:
    s = round(r["dstep"] / (1e3 / 72) if r["dstep"] else 0)
    steps[s] = steps.get(s, 0) + 1
print("display step (periods):", dict(sorted(steps.items())))
for k in ("cpu", "gpu", "comp", "lat", "work", "tail", "hold", "slack"):
    v = [r[k] for r in rows]
    print(f"  {k:5s} p1 {pct(v, .01):7.2f} p50 {pct(v, .5):7.2f} p99 {pct(v, .99):7.2f}")
if comp:
    ex = [ms(c[3]) for c in comp]
    dd = [ms(b[1] - a[1]) for a, b in zip(comp, comp[1:])]
    print(f"compositor: extra p1 {pct(ex, .01):.2f} p50 {pct(ex, .5):.2f} p99 {pct(ex, .99):.2f}; "
          f"display step p1 {pct(dd, .01):.2f} p50 {pct(dd, .5):.2f} p99 {pct(dd, .99):.2f}")
if "-v" in sys.argv:
    for i, r in enumerate(rows):
        if r["iv"] > 20:
            for q in rows[max(0, i - 3):i + 2]:
                print(" ".join(f"{k}={v:.2f}" if isinstance(v, float) else f"{k}={v}" for k, v in q.items()))
            print("--")
