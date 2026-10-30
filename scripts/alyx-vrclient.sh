#!/usr/bin/env bash
# Switch Half-Life: Alyx (Steam app 546560) between MacVR's path (Windows OpenComposite via VR_OVERRIDE) and the
# vrclient bridge test path (vrclient_x64 -> native OpenComposite -> monado-service), and run the service:
#   scripts/alyx-vrclient.sh on                 back up, then set the prefix, its runner and the Mac up
#   scripts/alyx-vrclient.sh service            monado-service (null compositor, simulated HMD) in the foreground
#   scripts/alyx-vrclient.sh off                restore every backed-up file, remove what `on` added, verify
# Launch with `open steam://rungameid/546560` while the service runs. Steam launch options are not touched: the
# bridge reads VRCLIENT_LOG/VRCLIENT_STATS from the prefix's machine environment, the unix side finds OpenComposite
# through the macOS openvrpaths.vrpath. The macOS OpenXR loader reads only XR_RUNTIME_JSON or the root-owned
# /usr/local/share/openxr, and Wine keeps the registry environment out of the unix one, so XR_RUNTIME_JSON (a
# universal Monado client) is set with `launchctl setenv` for apps launched from then on, NotProton's included.
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
cmd="${1:?on|service|off}"

prefix_idle() {
	! pgrep -qf 'hlvr.exe' || { echo "Alyx is running" >&2; exit 1; }
	! pgrep -qf "wineserver.*" || { pgrep -fl wineserver; echo "a wineserver is running; make sure it is not this prefix's" >&2; }
}

case "$cmd" in
on)
	[[ ! -e "$BK/done" ]] || { echo "already on (backup in $BK); run off first" >&2; exit 1; }
	pgrep -qf 'MacVR.app' && { echo "MacVR.app is running; it may rewrite the prefix" >&2; exit 1; }
	prefix_idle
	runner="$NP_RUNNERS/crossover-$(sed -n 1p "$CD/notproton-build")/CrossOver"
	[[ -d "$runner/lib/wine/x86_64-windows" ]] || { echo "no runner $runner" >&2; exit 1; }
	arch=aarch64
	[[ -d "$runner/lib/wine/aarch64-unix" ]] || arch=x86_64
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

	rsync -a --delete "$ROOT/build/oc-macos/runtime/" "$OUT/runtime/"
	rsync -a --delete "$ROOT/build/vrclient/root/" "$OUT/root/"
	mkdir -p "$OUT/xr"
	lipo -create "$ROOT"/build/bridge/monado-{arm64,x86_64}/src/xrt/targets/openxr/libopenxr_monado.dylib \
		-output "$OUT/xr/libopenxr_monado.dylib"
	printf '{\n  "file_format_version": "1.0.0",\n  "runtime": { "name": "Monado", "library_path": "%s" }\n}\n' \
		"$OUT/xr/libopenxr_monado.dylib" > "$OUT/xr/openxr_monado.json"

	"$ROOT/scripts/setup-vrclient-prefix.sh" --root "$OUT/root" --runner "$runner" --macos-vrpath "$OUT/runtime" "$PFX"
	# NotProton's steam.exe deletes a writable prefix vrpath
	chmod a-w "$PFX/drive_c/users/steamuser/AppData/Local/openvr/openvrpaths.vrpath"
	launchctl getenv XR_RUNTIME_JSON > "$BK/launchd-XR_RUNTIME_JSON" || true
	launchctl setenv XR_RUNTIME_JSON "$OUT/xr/openxr_monado.json"
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
	echo "on: runner $runner ($arch), backup $BK"
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
off)
	[[ -e "$BK/done" ]] || { echo "no backup in $BK" >&2; exit 1; }
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
	[[ $bad == 0 ]] || exit 1
	mv "$BK" "$BK.restored-$(date +%s)"
	echo "off: restored and verified"
	;;
*) echo "usage: $0 on|service|off" >&2; exit 2 ;;
esac
