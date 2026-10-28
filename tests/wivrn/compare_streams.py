#!/usr/bin/env python3
"""Compare two WiVRn stream dumps (WIVRN_DUMP_VIDEO) of xr_empty_frames --pattern frame by frame.

The pattern's content only depends on the app's frame counter, but the two runs encode different
frame ids, so every sampled frame of A is matched to the frame of B with the closest luma in a 256x256 centre crop,
then both are compared at full resolution (PSNR Y/Cb/Cr, 10-bit peak).

  compare_streams.py A.h265 B.h265 [--frames N] [--every K] [--size WxH]
"""
import argparse
import subprocess

import numpy as np


def frames(path, w, h, limit):
    """Yields (index, y, cb, cr) as uint16 arrays, decoded with ffmpeg (yuv420p10le)."""
    cmd = ["ffmpeg", "-v", "quiet", "-i", path, "-frames:v", str(limit), "-f", "rawvideo", "-pix_fmt", "yuv420p10le", "-"]
    size = w * h * 3 // 2
    with subprocess.Popen(cmd, stdout=subprocess.PIPE) as p:
        i = 0
        while True:
            buf = p.stdout.read(size * 2)
            if len(buf) < size * 2:
                break
            a = np.frombuffer(buf, np.uint16)
            yield i, a[: w * h].reshape(h, w), a[w * h : w * h * 5 // 4].reshape(h // 2, w // 2), a[w * h * 5 // 4 :].reshape(h // 2, w // 2)
            i += 1


def small(y):
    """Full-resolution centre crop: the pattern's detail is a few pixels, downscaling would hide the pan offset."""
    h, w = y.shape
    return y[h // 2 - 128 : h // 2 + 128, w // 2 - 128 : w // 2 + 128].astype(np.float32)


def psnr(a, b):
    mse = np.mean((a.astype(np.float64) - b.astype(np.float64)) ** 2)
    return float("inf") if mse == 0 else 10 * np.log10(1023.0**2 / mse)


ap = argparse.ArgumentParser()
ap.add_argument("a")
ap.add_argument("b")
ap.add_argument("--frames", type=int, default=2000, help="decode at most N frames (ffmpeg fails past POC 2048)")
ap.add_argument("--every", type=int, default=50)
ap.add_argument("--skip", type=int, default=200, help="ignore the first frames (rate control settling)")
ap.add_argument("--size", default="1152x1152")
args = ap.parse_args()
w, h = map(int, args.size.split("x"))

samples = {}
for i, y, cb, cr in frames(args.a, w, h, args.frames):
    if i >= args.skip and (i - args.skip) % args.every == 0:
        samples[i] = (small(y), y, cb, cr)

b_small = [small(y) for _, y, _, _ in frames(args.b, w, h, args.frames)]
match = {}
for i, (s, *_) in samples.items():
    d = np.array([((b - s) ** 2).mean() for b in b_small])
    order = np.argsort(d)
    match[i] = (int(order[0]), float(d[order[0]]), float(d[order[1]]))

want = {j for j, _, _ in match.values()}
b_full = {i: (y, cb, cr) for i, y, cb, cr in frames(args.b, w, h, args.frames) if i in want}

rows = []
for i, (_, y, cb, cr) in samples.items():
    j, d0, d1 = match[i]
    by, bcb, bcr = b_full[j]
    rows.append((i, j, psnr(y, by), psnr(cb, bcb), psnr(cr, bcr), d0, d1))
    print(f"A {i:5d} <-> B {j:5d}: PSNR Y {rows[-1][2]:6.2f} Cb {rows[-1][3]:6.2f} Cr {rows[-1][4]:6.2f} dB  (match mse {d0:.1f}, next {d1:.1f})")
r = np.array([x[2:5] for x in rows])
print(f"{len(rows)} frames: PSNR Y mean {r[:, 0].mean():.2f} min {r[:, 0].min():.2f}, Cb mean {r[:, 1].mean():.2f}, Cr mean {r[:, 2].mean():.2f} dB")
