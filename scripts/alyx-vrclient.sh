#!/usr/bin/env bash
# Switch Half-Life: Alyx (Steam app 546560) between MacVR's path (Windows OpenComposite via VR_OVERRIDE) and the
# vrclient bridge path (vrclient_x64 -> native OpenComposite -> Monado/WiVRn OpenXR client -> server), and run a server:
#   scripts/alyx-vrclient.sh on [monado|wivrn]  back up, then set the prefix, its runner and the Mac up. The OpenXR
#                                               client is monado-service's (default) or build/wivrn's (WiVRn server)
#   scripts/alyx-vrclient.sh service            monado-service (null compositor, simulated HMD) in the foreground
#   scripts/alyx-vrclient.sh wivrn [args]       build/wivrn's wivrn-server in the foreground (scripts/run-wivrn.sh),
#                                               with MacVR.app's pacer environment
#   scripts/alyx-vrclient.sh off                restore every backed-up file, remove what `on` added, verify, check
#   scripts/alyx-vrclient.sh check              MacVR's deployed payload and runner files match its own records
# Launch with `open steam://rungameid/546560` while a server runs. Steam launch options are not touched: the
# bridge reads VRCLIENT_LOG/VRCLIENT_STATS from the prefix's machine environment, the unix side finds OpenComposite
# through the macOS openvrpaths.vrpath. The macOS OpenXR loader reads only XR_RUNTIME_JSON or the root-owned
# /usr/local/share/openxr, and Wine keeps the registry environment out of the unix one, so XR_RUNTIME_JSON (a
# universal x86_64 + arm64 client, for Rosetta and FEX runners) is set with `launchctl setenv` for apps launched from
# then on, NotProton's included.
# RUNNER_BUILD=<build> runner for `on` when the game is mapped to another compat tool than the one that last ran the
# prefix (default: the prefix's notproton-build).
# OUT=<dir> staging, logs and frame dumps (default $DARWIN_USER_TEMP_DIR/macvr-alyx-vrclient).
# DUMP_FRAME=N committed frame the null compositor dumps to $OUT/frame.png (default 2400).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP=546560
S="$HOME/Library/Application Support/Steam"
CD="$S/steamapps/compatdata/$APP"
PFX="$CD/pfx"
OUT="${OUT:-$(getconf DARWIN_USER_TEMP_DIR)macvr-alyx-vrclient}"
BK="$OUT/backup"
MAC_VRPATH="$HOME/Library/Application Support/OpenVR/.openvr/openvrpaths.vrpath"
NP_RUNNERS="$HOME/Library/Application Support/notproton/runners"
WIVRN="$ROOT/build/wivrn"
MACVR="$HOME/Library/Application Support/macvr"
cmd="${1:?on|service|wivrn|off|check}"

prefix_idle() {
	! pgrep -qf 'hlvr.exe' || { echo "Alyx is running" >&2; exit 1; }
	! pgrep -qf "wineserver.*" || { pgrep -fl wineserver; echo "a wineserver is running; make sure it is not this prefix's" >&2; }
}

macvr_check() {
	python3 -I - "$MACVR" <<'EOF'
import hashlib, json, os, sys
root = sys.argv[1]
def sha(p):
    with open(p, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()
bad = n = 0
gone = set()
cur = os.path.join(root, "current")
for rel, want in json.load(open(os.path.join(cur, "manifest.json")))["files"].items():
    p, n = os.path.join(cur, rel), n + 1
    if not os.path.isfile(p) or sha(p) != want:
        print("macvr payload differs:", p); bad = 1
for line in open(os.path.join(root, "state", "runner-files")):
    p, _, want = line.rstrip("\n").rpartition("=")
    if not p:
        continue
    runner = p.split("/lib/wine/")[0]
    if not os.path.isdir(runner):
        gone.add(runner)
        continue
    n += 1
    if not os.path.isfile(p) or sha(p) != want:
        print("macvr runner file differs:", p); bad = 1
for r in sorted(gone):
    print("(runner not installed, skipped:", r + ")")
print(f"macvr payload {os.path.realpath(cur)}: {n} files, {'MISMATCH' if bad else 'intact'}")
sys.exit(bad)
EOF
}

case "$cmd" in
on)
	xr="${2:-monado}"
	case "$xr" in
	monado) clients=("$ROOT"/build/bridge/monado-{arm64,x86_64}/src/xrt/targets/openxr/libopenxr_monado.dylib) ;;
	wivrn)
		clients=("$ROOT"/build/wivrn-client-{arm64,x86_64}/client/libopenxr_monado.dylib)
		for s in "$ROOT"/build/wivrn-client-{arm64,x86_64}/client/ipc-stamp; do
			cmp -s "$s" "$WIVRN/server/ipc-stamp" || { echo "$s differs from $WIVRN/server/ipc-stamp: rebuild both" >&2; exit 1; }
		done
		;;
	*) echo "usage: $0 on [monado|wivrn]" >&2; exit 2 ;;
	esac
	# saved: the backup is complete and the prefix may have changed since; an interrupted `on` must not overwrite it
	[[ ! -e "$BK/saved" ]] || { echo "already on, or an interrupted on (backup in $BK); run off first" >&2; exit 1; }
	pgrep -qf 'MacVR.app' && { echo "MacVR.app is running; it may rewrite the prefix" >&2; exit 1; }
	prefix_idle
	runner="$NP_RUNNERS/crossover-${RUNNER_BUILD:-$(sed -n 1p "$CD/notproton-build")}/CrossOver"
	[[ -d "$runner/lib/wine/x86_64-windows" ]] || { echo "no runner $runner" >&2; exit 1; }
	arch=x86_64
	[[ "$(sed -n 2p "$CD/notproton-build")" == *FEX* ]] && arch=aarch64
	mkdir -p "$BK" "$OUT/logs"
	cp -p "$PFX/system.reg" "$PFX/user.reg" "$PFX/userdef.reg" "$BK/"
	cp -p "$MAC_VRPATH" "$BK/openvrpaths.vrpath.mac"
	{
		for f in "$PFX/drive_c/vrclient" "$PFX/drive_c/users/steamuser/AppData/Local/openvr" \
			"$runner/lib/wine/x86_64-windows/vrclient_x64.dll" "$runner/lib/wine/x86_64-windows/vrclient_x64.so" \
			"$runner/lib/wine/x86_64-unix/vrclient_x64.so"; do
			[[ -e "$f" ]] && { echo "$f exists, refusing to touch it" >&2; exit 1; }
			echo "$f"
		done
	} > "$BK/added"
	echo "$runner" > "$BK/runner"
	launchctl getenv XR_RUNTIME_JSON > "$BK/launchd-XR_RUNTIME_JSON" || true
	touch "$BK/saved"

	rsync -a --delete "$ROOT/build/oc-macos/runtime/" "$OUT/runtime/"
	rsync -a --delete "$ROOT/build/vrclient/root/" "$OUT/root/"
	rm -rf "$OUT/xr"
	mkdir -p "$OUT/xr"
	lipo -create "${clients[@]}" -output "$OUT/xr/libopenxr_$xr.dylib"
	printf '{\n  "file_format_version": "1.0.0",\n  "runtime": { "name": "Monado", "library_path": "%s" }\n}\n' \
		"$OUT/xr/libopenxr_$xr.dylib" > "$OUT/xr/openxr_$xr.json"

	"$ROOT/scripts/setup-vrclient-prefix.sh" --root "$OUT/root" --runner "$runner" --macos-vrpath "$OUT/runtime" "$PFX"
	# NotProton's steam.exe deletes a writable prefix vrpath
	chmod a-w "$PFX/drive_c/users/steamuser/AppData/Local/openvr/openvrpaths.vrpath"
	launchctl setenv XR_RUNTIME_JSON "$OUT/xr/openxr_$xr.json"
	python3 -I - "$PFX/system.reg" "$OUT/logs/vrclient.log" <<'EOF'
import sys
path, log = sys.argv[1:3]
t = open(path, encoding="utf-8").read()
i = t.index("[System\\\\ControlSet001\\\\Control\\\\Session Manager\\\\Environment]")
j = t.index('\n"windir"=', i)
win = ("Z:" + log.replace("/", "\\")).replace("\\", "\\\\")
t = t[:j] + f'\n"VRCLIENT_LOG"="{win}"\n"VRCLIENT_STATS"="1"' + t[j:]
open(path, "w", encoding="utf-8").write(t)
EOF
	grep -n -E '^"(VRCLIENT_LOG|VRCLIENT_STATS|XR_RUNTIME_JSON|VR_OVERRIDE)"' "$PFX/system.reg" || true
	touch "$BK/done"
	echo "on: runner $runner ($arch), OpenXR client $xr ($(launchctl getenv XR_RUNTIME_JSON)), backup $BK"
	;;
service)
	mkdir -p "$OUT/logs"
	sock="$(getconf DARWIN_USER_TEMP_DIR)monado_comp_ipc"
	[[ -S "$sock" ]] && { echo "$sock exists: another service is running?" >&2; exit 1; }
	unset XDG_RUNTIME_DIR
	export XRT_NO_STDIN=1 XRT_COMPOSITOR_NULL=1 SIMULATED_ENABLE=1 MONADO_SYNC_STATS=1
	export XRT_COMPOSITOR_NULL_DUMP="$OUT/frame.png" XRT_COMPOSITOR_NULL_DUMP_FRAME="${DUMP_FRAME:-2400}"
	exec "$ROOT/build/bridge/monado/src/xrt/targets/service/monado-service"
	;;
wivrn)
	pgrep -qf 'MacVR.app' && { echo "MacVR.app is running (it starts its own server)" >&2; exit 1; }
	pgrep -xq wivrn-server && { pgrep -xl wivrn-server; echo "a wivrn-server is already running" >&2; exit 1; }
	# MacVR.app's server environment (docs/macvr-app.md), so both paths get the same pacer
	export WIVRN_PACER_WINDOW="${WIVRN_PACER_WINDOW:-500}" WIVRN_PACER_PERCENTILE="${WIVRN_PACER_PERCENTILE:-99}"
	export WIVRN_CLIENT_MARGIN_MS="${WIVRN_CLIENT_MARGIN_MS:-2.5}"
	unset XDG_RUNTIME_DIR
	exec "$ROOT/scripts/run-wivrn.sh" "${@:2}"
	;;
off)
	[[ -e "$BK/saved" ]] || { echo "no backup in $BK" >&2; exit 1; }
	prefix_idle
	bad=0
	cp -p "$BK/system.reg" "$BK/user.reg" "$BK/userdef.reg" "$PFX/"
	cp -p "$BK/openvrpaths.vrpath.mac" "$MAC_VRPATH"
	while IFS= read -r f; do rm -rf "$f"; done < "$BK/added"
	prev="$(cat "$BK/launchd-XR_RUNTIME_JSON" 2>/dev/null || true)"
	if [[ -n "$prev" ]]; then launchctl setenv XR_RUNTIME_JSON "$prev"; else launchctl unsetenv XR_RUNTIME_JSON; fi
	[[ "$(launchctl getenv XR_RUNTIME_JSON)" == "$prev" ]] || { echo "differs: launchd XR_RUNTIME_JSON"; bad=1; }
	for f in system.reg user.reg userdef.reg; do cmp -s "$BK/$f" "$PFX/$f" || { echo "differs: $f"; bad=1; }; done
	cmp -s "$BK/openvrpaths.vrpath.mac" "$MAC_VRPATH" || { echo "differs: $MAC_VRPATH"; bad=1; }
	while IFS= read -r f; do [[ ! -e "$f" ]] || { echo "still there: $f"; bad=1; }; done < "$BK/added"
	grep -q '^"VR_OVERRIDE"=' "$PFX/system.reg" || { echo "VR_OVERRIDE missing"; bad=1; }
	macvr_check || bad=1
	[[ $bad == 0 ]] || exit 1
	mv "$BK" "$BK.restored-$(date +%s)"
	echo "off: restored and verified"
	;;
check)
	macvr_check
	;;
*) echo "usage: $0 on [monado|wivrn]|service|wivrn|off|check" >&2; exit 2 ;;
esac
