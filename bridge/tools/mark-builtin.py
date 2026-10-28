#!/usr/bin/env python3
"""Mark PE files as Wine builtins, like `winebuild --builtin`: the signature goes right after the DOS header."""
import struct
import sys

SIGNATURE = b"Wine builtin DLL".ljust(32, b"\0")

for path in sys.argv[1:]:
    with open(path, "r+b") as f:
        dos = f.read(0x40)
        if dos[:2] != b"MZ":
            sys.exit(f"{path}: not a PE file")
        (lfanew,) = struct.unpack_from("<I", dos, 0x3C)
        if lfanew < 0x40 + len(SIGNATURE):
            sys.exit(f"{path}: no room for the Wine signature (e_lfanew {lfanew:#x})")
        f.seek(0x40)
        f.write(SIGNATURE)
