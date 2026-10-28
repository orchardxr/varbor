#!/usr/bin/env python3
# vcq.py '<command>' ... : like tools/vconsole.py, but prints every reply line, minus the controller-name spam
import os, socket, struct, sys, threading, time
RAW = os.environ.get("RAW")

s = socket.create_connection(("127.0.0.1", 29000), timeout=5)
buf = bytearray()


def read():
    try:
        while d := s.recv(1 << 20):
            buf.extend(d)
    except OSError:
        pass


threading.Thread(target=read, daemon=True).start()
time.sleep(2)
start = len(buf)
for c in sys.argv[1:]:
    p = c.encode() + b"\0"
    s.sendall(b"CMND" + b"\x00\xd3\x00\x00" + struct.pack(">H", len(p) + 12) + b"\x00\x00" + p)
    time.sleep(1)
time.sleep(1)
b, i = bytes(buf[start:]), 0
while i + 12 <= len(b):
    kind, n = b[i:i + 4], struct.unpack(">H", b[i + 8:i + 10])[0]
    if n < 12:
        break
    if kind == b"PRNT":
        t = b[i + 12:i + n].rstrip(b"\0").split(b"\0")[-1].decode(errors="replace").rstrip(); t = repr(b[i + 12:i + n]) if RAW else t
        if "Unknown controller type" not in t:
            print(t)
    i += n
s.close()
