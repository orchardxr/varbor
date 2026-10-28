#!/usr/bin/env python3
# gputrace.py <trace export prefix> : per-process GPU busy time from an xctrace 'Metal System Trace'. Needs
# <prefix>.gpu.xml (metal-gpu-intervals), <prefix>.metal-gpu-submission-to-command-buffer-id.xml and
# <prefix>.metal-application-command-buffer-submissions.xml (see gpuexport.sh). hlvr.exe is split by command buffer:
# bridge(vk) = MoltenVK vkQueueSubmit (our copy), hud = Metal HUD, dxmt = the game + OpenComposite.
# Busy = union of depth-0 GPU execution intervals (all channels); also per-channel sums and process overlap.
import sys, collections, xml.etree.ElementTree as ET
def rows(path):
    ids = {}
    for ev, e in ET.iterparse(path, events=('end',)):
        if e.get('id'): ids[e.get('id')] = e
        if e.tag == 'row':
            out = []
            for x in e:
                x = ids[x.get('ref')] if x.get('ref') else x
                out.append(x)
            yield out
pre = sys.argv[1]
cb2kind = {}
for r in rows(pre + '.metal-application-command-buffer-submissions.xml'):
    l = r[10].get('fmt', '')
    cb2kind[r[-1].text] = 'bridge(vk)' if 'vkQueueSubmit' in l else 'hud' if 'MTLHud' in l else 'dxmt'
sub2p = {}
for r in rows(pre + '.metal-gpu-submission-to-command-buffer-id.xml'):
    if len(r) > 12 and r[12].tag == 'process':
        p = r[12].get('fmt').split(' (')[0]
        if p == 'hlvr.exe': p += ':' + cb2kind.get(r[1].text, '?')
        sub2p[r[2].text] = p
iv = collections.defaultdict(list); ch = collections.defaultdict(float)
for r in rows(pre + '.gpu.xml'):
    if r[5].text != '0': continue
    s, du = int(r[0].text), int(r[1].text)
    p = sub2p.get(r[-1].text, '?')
    iv[p].append((s, s + du)); ch[(p, r[2].text)] += du
def union(v):
    v = sorted(v); out = []
    for s, e in v:
        if out and s <= out[-1][1]: out[-1][1] = max(out[-1][1], e)
        else: out.append([s, e])
    return out
allv = [x for v in iv.values() for x in v]
t0, t1 = min(s for s, e in allv), max(e for s, e in allv)
span = (t1 - t0) / 1e9
print(f"span {span:.2f} s")
U = {p: union(v) for p, v in iv.items()}
for p, u in sorted(U.items(), key=lambda x: -sum(e - s for s, e in x[1])):
    print(f"{p:30s} busy {sum(e - s for s, e in u) / 1e6 / span:7.1f} ms/s")
print(f"{'ALL':30s} busy {sum(e - s for s, e in union(allv)) / 1e6 / span:7.1f} ms/s")
ps = list(U)
for i in range(len(ps)):
    for j in range(i + 1, len(ps)):
        a, b = U[ps[i]], U[ps[j]]; k = l = 0; ov = 0
        while k < len(a) and l < len(b):
            ov += max(0, min(a[k][1], b[l][1]) - max(a[k][0], b[l][0]))
            if a[k][1] < b[l][1]: k += 1
            else: l += 1
        if ov: print(f"  overlap {ps[i]} / {ps[j]}: {ov / 1e6 / span:.1f} ms/s")
for (p, c), v in sorted(ch.items(), key=lambda x: -x[1])[:12]:
    print(f"  {p[:30]:30s} {c:10s} {v / 1e6 / span:7.1f} ms/s")
