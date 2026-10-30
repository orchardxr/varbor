#!/usr/bin/env bash
# Set a Wine prefix up for the vrclient bridge (vrclient/), the way Proton's setup_openvr_paths does it:
#   C:\vrclient\bin\vrclient_x64.dll       placeholder for openvr_api.dll to load (Wine then runs the builtin)
#   <user>\AppData\Local\openvr\openvrpaths.vrpath   runtime -> C:\vrclient, for every Wine user in the prefix
#   HKCU\Software\Wine\VR                  ready, no Vulkan extensions (for DXVK; see vr_key below)
# Optionally installs the builtin into a CrossOver runner tree and points the macOS openvrpaths.vrpath at the native
# runtime (OpenComposite's vrclient.dylib), which the unix side reads when VARBOR_VRCLIENT_RUNTIME is unset.
#
#   scripts/setup-vrclient-prefix.sh [options] <prefix>      (<prefix> holds drive_c)
#     --root DIR           vrclient build root with x86_64-windows/ and x86_64-unix/ (default build/vrclient/root)
#     --runner DIR         also install vrclient_x64.dll/.so into this CrossOver dir's lib/wine (a runner copy; the
#                          .so goes next to the dll too, which is where arm64 Wine under FEX looks)
#     --macos-vrpath DIR   write ~/Library/Application Support/OpenVR/.openvr/openvrpaths.vrpath with runtime DIR
#                          (a dir with bin/osx64/vrclient.dylib), keeping its other keys
#     --remove             undo the prefix part (C:\vrclient and the prefix's openvrpaths.vrpath)
#
# Like Proton, a runtime the prefix's openvrpaths.vrpath named before (not C:\vrclient) is kept in a "varbor_previous"
# key; --remove restores it. Never touches anything but the given prefix, runner dir and (with --macos-vrpath) the
# macOS openvrpaths.vrpath.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

vrroot="$ROOT/build/vrclient/root"
runner=""
macos_rt=""
remove=0
while [[ $# -gt 1 ]]; do
	case "$1" in
		--root) vrroot="$2"; shift 2 ;;
		--runner) runner="$2"; shift 2 ;;
		--macos-vrpath) macos_rt="$2"; shift 2 ;;
		--remove) remove=1; shift ;;
		*) echo "unknown option $1" >&2; exit 2 ;;
	esac
done
[[ $# -eq 1 ]] || { sed -n '2,19p' "$0" >&2; exit 2; }
prefix="$1"
[[ -d "$prefix/drive_c" ]] || { echo "$prefix: no drive_c" >&2; exit 1; }
dll="$vrroot/x86_64-windows/vrclient_x64.dll"
so="$vrroot/x86_64-unix/vrclient_x64.so"

# The prefix's openvrpaths.vrpath for one Wine user: set (runtime C:\vrclient) or restore (--remove).
vrpath() {
	python3 -I - "$1" "$2" <<'EOF'
import json, os, sys
path, mode = sys.argv[1], sys.argv[2]
ours = ["C:\\vrclient\\", "C:\\vrclient"]
try:
    with open(path) as f:
        c = json.load(f)
except (OSError, ValueError):
    c = {}
if mode == "set":
    if c.get("runtime") and c["runtime"] != ours:
        c["varbor_previous"] = c["runtime"]
    c["runtime"] = ours
    c.setdefault("config", ["C:\\vrclient\\config"])
    c.setdefault("log", ["C:\\vrclient\\logs"])
    c.setdefault("external_drivers", None)
    c["jsonid"] = "vrpathreg"
    c["version"] = 1
else:
    if c.get("runtime") != ours:
        sys.exit(0)
    if "varbor_previous" not in c:
        os.remove(path)
        sys.exit(0)
    c["runtime"] = c.pop("varbor_previous")
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as f:
    json.dump(c, f, indent=3)
EOF
}

# HKCU\Software\Wine\VR, what Proton's steam.exe has vrclient_init_registry() write before a game starts: DXVK's
# OpenVR support reads its Vulkan extension lists from there (state 1 = ready) instead of asking the runtime, which
# the Metal-only OpenComposite answers with an abort. The bridge hands Metal textures to the runtime, so nothing is
# needed: the instance list names VK_KHR_surface, which DXVK enables anyway (an empty string becomes an empty
# extension name and vkCreateInstance fails). Edits user.reg directly, like VR_OVERRIDE below: the prefix's
# wineserver must not be running.
vr_key() {
	python3 -I - "$1" "$2" <<'EOF'
import re, sys, time
path, mode = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as f:
        text = f.read()
except OSError:
    sys.exit(0)
section = re.compile(r'\n\[Software\\\\Wine\\\\VR\] [^\n]*\n(?:[^\n\[][^\n]*\n|\n(?!\[))*')
m = section.search(text)
if mode == "set":
    if m and '"varbor"=' not in m.group(0):
        sys.exit(0)
    if m:
        text = text[:m.start()] + text[m.end():]
    text = text.rstrip("\n") + "\n\n[Software\\\\Wine\\\\VR] %d\n" % int(time.time()) + \
        '"varbor"="vrclient"\n"openvr_vulkan_instance_extensions"="VK_KHR_surface"\n"state"=dword:00000001\n'
elif m and '"varbor"=' in m.group(0):
    text = text[:m.start()] + "\n" + text[m.end():].lstrip("\n")
else:
    sys.exit(0)
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
EOF
}

users=()
for u in "$prefix"/drive_c/users/*/; do
	u=$(basename "$u")
	[[ "$u" == Public ]] || users+=("$u")
done
[[ ${#users[@]} -gt 0 ]] || { echo "$prefix: no Wine user dirs" >&2; exit 1; }

if [[ $remove == 1 ]]; then
	rm -rf "$prefix/drive_c/vrclient"
	for u in "${users[@]}"; do vrpath "$prefix/drive_c/users/$u/AppData/Local/openvr/openvrpaths.vrpath" restore; done
	vr_key "$prefix/user.reg" remove
	echo "vrclient removed from $prefix"
	exit 0
fi

[[ -f "$dll" && -f "$so" ]] || { echo "no vrclient build in $vrroot (scripts/build-bridge.sh vrclient)" >&2; exit 1; }
mkdir -p "$prefix/drive_c/vrclient/bin" "$prefix/drive_c/vrclient/config" "$prefix/drive_c/vrclient/logs"
cp "$dll" "$prefix/drive_c/vrclient/bin/vrclient_x64.dll"
for u in "${users[@]}"; do vrpath "$prefix/drive_c/users/$u/AppData/Local/openvr/openvrpaths.vrpath" set; done
vr_key "$prefix/user.reg" set
echo "prefix $prefix: C:\\vrclient\\bin\\vrclient_x64.dll, openvrpaths.vrpath for ${users[*]}"

# openvr_api.dll prefers VR_OVERRIDE (a machine-wide one, e.g. from a Windows OpenComposite setup) over
# openvrpaths.vrpath; Proton drops it too. Edits system.reg directly: the prefix's wineserver must not be running.
if grep -q '^"VR_OVERRIDE"=' "$prefix/system.reg" 2>/dev/null; then
	sed -i '' '/^"VR_OVERRIDE"=/d' "$prefix/system.reg"
	echo "prefix $prefix: removed VR_OVERRIDE from the machine environment"
fi

if [[ -n "$runner" ]]; then
	lib="$runner/lib/wine"
	[[ -d "$lib/x86_64-windows" ]] || { echo "$runner: not a CrossOver dir (no lib/wine/x86_64-windows)" >&2; exit 1; }
	cp "$dll" "$lib/x86_64-windows/vrclient_x64.dll"
	cp "$so" "$lib/x86_64-windows/vrclient_x64.so"
	[[ -d "$lib/x86_64-unix" ]] && cp "$so" "$lib/x86_64-unix/vrclient_x64.so"
	echo "runner $runner: vrclient_x64.dll + .so installed"
fi

if [[ -n "$macos_rt" ]]; then
	[[ -f "$macos_rt/bin/osx64/vrclient.dylib" ]] || echo "warning: $macos_rt/bin/osx64/vrclient.dylib missing" >&2
	f="$HOME/Library/Application Support/OpenVR/.openvr/openvrpaths.vrpath"
	python3 -I - "$f" "$macos_rt" <<'EOF'
import json, os, sys
path, rt = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        c = json.load(f)
except (OSError, ValueError):
    c = {"jsonid": "vrpathreg", "version": 1}
c["runtime"] = [rt] + [r for r in c.get("runtime", []) if r != rt]
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as f:
    json.dump(c, f, indent=3)
EOF
	echo "macOS openvrpaths.vrpath: runtime $macos_rt"
fi
