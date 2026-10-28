#!/usr/bin/env python3
# m2pstats.py <prefix> : summary of one m2prun.sh window (Mac) or the Linux equivalent. Reads <prefix>.m2p
# (patches/diag/wivrn-m2p-trace.patch), <prefix>.fb (wivrn-feedback-dump.patch) and <prefix>.window (monotonic ns).
# The overlay's "Estimated motion to photons latency" is the max over ~1 s of (pose time asked by the app - headset
# production time of the newest sample used), over every pose query of every device (server tracking_control).
# Prints that value, what it is made of, the app frame timeline and the stream stages, all in ms.
import statistics as st, sys
from collections import defaultdict

p = sys.argv[1]
m0, m1 = map(int, open(p + '.window').read().split())
DEV = {0: 'HEAD'}


def pct(v, q):
    v = sorted(v)
    return v[min(len(v) - 1, int(q * len(v)))] if v else float('nan')


def s(v, f=1e6):
    v = [x / f for x in v]
    return f"p50 {pct(v, .5):5.1f} p95 {pct(v, .95):5.1f} max {max(v):5.1f} (n {len(v)})" if v else 'n/a'


Q, M = [], []
P, W, Dl, L, G = {}, {}, {}, defaultdict(list), {}
for l in open(p + '.m2p', errors='replace'):
    f = l.split()
    if len(f) < 2:
        continue
    try:
        v = list(map(int, f[1:]))
    except ValueError:
        continue
    k = f[0]
    if k == 'Q' and len(v) == 4:
        Q.append(v)
    elif k == 'M' and len(v) == 2:
        M.append(v)
    elif k == 'P' and len(v) == 8:
        P[v[0]] = v
    elif k == 'W':
        W[v[0]] = v[1]
    elif k == 'D':
        Dl[v[0]] = v[1:]
    elif k == 'L':
        L[v[0]].append(v[1:])
    elif k == 'G':
        G[v[0]] = v[1]

inw = lambda t: m0 <= t <= m1
Mw = [m for t, m in M if inw(t)]
print(f"overlay M2P (value sent each ~1 s): {' '.join(f'{m / 1e6:.0f}' for m in Mw)}")
if Mw:
    print(f"  mean {st.mean(Mw) / 1e6:.1f}, median {st.median(Mw) / 1e6:.1f}, min {min(Mw) / 1e6:.1f}, max {max(Mw) / 1e6:.1f} ms")

Qw = [q for q in Q if inw(q[0]) and q[3]]
bydev = defaultdict(list)
for now, dev, at, prod in Qw:
    bydev[dev].append((now, at, prod))
print('pose queries per device (at-produced = estimate, now-produced = pose age, at-now = app horizon):')
for dev, v in sorted(bydev.items()):
    print(f"  dev {dev:2d} {len(v) / ((m1 - m0) / 1e9):6.0f}/s  est {s([a - pr for n, a, pr in v])}")
    print(f"                age {s([n - pr for n, a, pr in v])}  horizon {s([a - n for n, a, pr in v])}")
# which query sets each 1-s max
mx = defaultdict(int)
for i in range(1, len(M)):
    t0, t1 = M[i - 1][0], M[i][0]
    if not inw(t1):
        continue
    best = max((q for q in Q if t0 < q[0] <= t1 and q[3]), key=lambda q: q[2] - q[3], default=None)
    if best:
        mx[best[1]] += 1
print('  device setting the 1-s max: ' + ', '.join(f"dev {d}: {n}" for d, n in sorted(mx.items())))

# app frames
fids = sorted(i for i in P if inw(P[i][1]))
if fids:
    period = None
    fb = {}
    try:
        with open(p + '.fb') as fh:
            next(fh)
            for l in fh:
                v = l.split()
                if len(v) < 20:
                    continue
                v = list(map(int, v[:20]))
                if not inw(v[0]):
                    continue
                fb.setdefault(v[1], {})[v[2]] = v
    except FileNotFoundError:
        pass
    comp_disp = {i: d[0][7] for i, d in fb.items() if 0 in d and d[0][7]}
    disp = [P[i][3] for i in fids]
    gaps = sorted(b - a for a, b in zip(disp, disp[1:]) if b > a)
    period = pct(gaps, .5)
    dels = [Dl[i][0] for i in fids if i in Dl]
    print(f"app: {len(dels) / ((m1 - m0) / 1e9):.1f} fps delivered, period {period / 1e6:.2f} ms, "
          f"display-time steps >1.5 periods: {sum(g > 1.5 * period for g in gaps)}")
    rows = []
    for i in fids:
        fid, now, wake, d, cpu, gpu, comp, cd = P[i]
        r = dict(cpu=cpu, gpu=gpu, comp=comp, ahead=(d - cd) / period, imm=wake == now, predict=now, disp=d)
        if i in W:
            r['woke'] = W[i]
        if i in Dl:
            r['deliv'] = Dl[i][0]
        if i in G:
            r['gpu_done'] = G[i]
        if L.get(i):
            sysf = L[i][0][1]
            r['latch'] = L[i][0][0]
            r['latched_n'] = len(L[i])
            if sysf in comp_disp:
                r['comp_disp'] = comp_disp[sysf]
            if sysf in fb and 0 in fb[sysf]:
                r['fb'] = fb[sysf][0]
        rows.append(r)
    hq = defaultdict(list)
    for now, dev, at, prod in Qw:
        if dev == 0:
            hq[at].append((now, prod))
    for r in rows:
        if r['disp'] in hq:
            r['hq_now'], r['hq_prod'] = min(hq[r['disp']])

    def col(name, f):
        v = [f(r) for r in rows if all(k in r for k in name)]
        return s(v)
    print(f"  pacer cpu {s([r['cpu'] for r in rows])}\n  pacer gpu {s([r['gpu'] for r in rows])}\n  pacer comp {s([r['comp'] for r in rows])}")
    print(f"  wait branch 'app-limited, no wait': {sum(r['imm'] for r in rows)} of {len(rows)}; display periods past the "
          f"compositor's next: " + ', '.join(f"{k}: {v}" for k, v in sorted(defaultdict(int, {a: sum(round(r['ahead']) == a for r in rows) for a in {round(r['ahead']) for r in rows}}).items())))
    print(f"  xrWaitFrame return -> display      {col(('woke',), lambda r: r['disp'] - r['woke'])}")
    print(f"  first HEAD query -> display        {col(('hq_now',), lambda r: r['disp'] - r['hq_now'])}")
    print(f"  HEAD pose age at that query         {col(('hq_now',), lambda r: r['hq_now'] - r['hq_prod'])}")
    print(f"  xrWaitFrame return -> xrEndFrame    {col(('woke', 'deliv'), lambda r: r['deliv'] - r['woke'])}")
    print(f"  xrEndFrame -> GPU done              {col(('deliv', 'gpu_done'), lambda r: r['gpu_done'] - r['deliv'])}")
    print(f"  xrEndFrame -> latched by compositor {col(('deliv', 'latch'), lambda r: r['latch'] - r['deliv'])}")
    print(f"  latched -> app display time         {col(('latch',), lambda r: r['disp'] - r['latch'])}")
    print(f"  compositor display - app display    {col(('comp_disp',), lambda r: r['comp_disp'] - r['disp'])}")
    print(f"  frames latched more than once (repeats): {sum(r.get('latched_n', 1) > 1 for r in rows)}, never latched: {sum('latch' not in r for r in rows)}")
    # stream stages of the compositor frame that showed each app frame, stream 0, client times -> server (t - b)
    st_ = defaultdict(list)
    for r in rows:
        if 'fb' not in r:
            continue
        v = r['fb']
        now, idx, stream, shown, b, safe, present, dsp = v[:8]
        eb, ee, sb, se, rf, rl, td, dec, bl, dd, woke, sub = v[8:20]
        if not (present and dec and bl and dd):
            continue
        c = lambda t: t - b
        st_['safe'].append(safe)
        st_['latch>present'].append(present - r['latch'])
        st_['present>encode'].append(c(eb) - present)
        st_['encode'].append(ee - eb)
        st_['send'].append(se - sb)
        st_['send_end>recv_last'].append(rl - se)
        st_['recv_last>decoded'].append(dec - rl)
        st_['present>decoded'].append(c(dec) - present)
        st_['decoded>blit'].append(bl - dec)
        st_['blit>display'].append(dd - bl)
        st_['display - comp predicted'].append(c(dd) - dsp)
        if 'hq_prod' in r:
            st_['ACTUAL head produced>displayed'].append(c(dd) - r['hq_prod'])
            st_['estimate (app display - produced)'].append(r['disp'] - r['hq_prod'])
    print('stream 0, per shown app frame:')
    for k, v in st_.items():
        print(f"  {k:34s} {s(v)}")
