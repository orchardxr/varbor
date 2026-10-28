#!/usr/bin/env python3
# pacerlatch.py <pacer trace> : compositor frames (I lines) that latched a new app frame vs repeated the old one.
# An app frame counts for compositor frame k if its GPU work was done (G) by k's wake and it wasn't used before.
import sys
G, I = [], []
for l in open(sys.argv[1], errors="replace"):
    f = l.split()
    if not f:
        continue
    if f[0] == "G" and len(f) == 3:
        G.append(int(f[2]))
    elif f[0] == "I" and len(f) == 8:
        I.append(int(f[1]))
G.sort()
gi = 0; new = rep = 0
for t in I[1:]:
    n = 0
    while gi < len(G) and G[gi] <= t:
        gi += 1; n += 1
    if n:
        new += 1
    else:
        rep += 1
print(f"compositor frames {new + rep}: new app frame {new}, repeated {rep} ({100 * rep / max(1, new + rep):.1f} %)")
