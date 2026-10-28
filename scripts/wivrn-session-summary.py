#!/usr/bin/env python3
"""Per-stream summary of a scripts/wivrn-session.sh server log recorded with WIVRN_VT_LOG_TIMING=1.

Prints fps, skipped frame ids, encode percentiles, IDRs, IDR requests and the time from the first encoded
frame to the first 1-s window with >= 88 frames (time to steady 90 fps). With newer logs also the bitrate,
compositor submit to encode start, and the GPU (zero-copy) / readback fence wait.
"""
import re
import sys

for path in sys.argv[1:]:
    lines = open(path, errors="replace").read().splitlines()
    for stream in (0, 1):
        pat = re.compile(r"(\d+\.\d+) .*videotoolbox: stream %d frame (\d+) (IDR|P) (\d+) bytes, .*encode ([\d.]+) ms" % stream)
        extra = re.compile(r"submit>encode ([\d.]+) ms, (?:gpu|readback) wait ([\d.]+) ms")
        ts, ids, enc, idr, size, sub, wait = [], [], [], 0, 0, [], []
        for line in lines:
            m = pat.match(line)
            if m:
                ts.append(float(m.group(1)))
                ids.append(int(m.group(2)))
                enc.append(float(m.group(5)))
                idr += m.group(3) == "IDR"
                size += int(m.group(4))
                x = extra.search(line)
                if x:
                    sub.append(float(x.group(1)))
                    wait.append(float(x.group(2)))
        if len(ts) < 2:
            print(f"{path} stream {stream}: no per-frame lines (WIVRN_VT_LOG_TIMING=1?)")
            continue
        requests = sum(f"IDR frame needed on stream {stream}" in line for line in lines)
        skipped = sum(b - a - 1 for a, b in zip(ids, ids[1:]) if b > a + 1)
        steady, j = None, 0
        for i, t in enumerate(ts):
            while ts[j] < t - 1.0:
                j += 1
            if i - j + 1 >= 88:
                steady = max(0.0, t - 1.0 - ts[0])
                break
        e = sorted(enc)
        n = len(e)
        dur = ts[-1] - ts[0]
        print(
            f"{path.split('/')[-1]} stream {stream}: {n} frames in {dur:.1f} s ({n / dur:.2f} fps), skipped ids {skipped}, "
            f"encode p50 {e[n // 2]:.2f} p95 {e[int(n * .95)]:.2f} p99 {e[int(n * .99)]:.2f} max {e[-1]:.2f} ms, "
            f">11 ms {sum(x > 11 for x in e)}, IDR {idr}, IDR requests {requests}, "
            f"steady 90 fps after {'never' if steady is None else f'{steady:.1f} s'}, {size * 8 / dur / 1e6:.1f} Mbit/s"
        )
        if sub:
            sub.sort()
            wait.sort()
            m = len(sub)
            print(
                f"    submit>encode p50 {sub[m // 2]:.2f} p95 {sub[int(m * .95)]:.2f} max {sub[-1]:.2f} ms, "
                f"wait p50 {wait[m // 2]:.2f} p95 {wait[int(m * .95)]:.2f} max {wait[-1]:.2f} ms"
            )
