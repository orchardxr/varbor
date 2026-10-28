#!/usr/bin/env bash
# Run a Windows OpenXR program through the M2 bridge (docs/bridge-plan.md) against our arm64 monado-service:
# NotProton's CrossOver runner (Rosetta, x86_64-unix; FEX=1: aarch64-unix), scratch prefix build/bridge/pfx, CrossOver's DXVK.
#   scripts/run-bridge.sh [seconds] <exe> [args...]
#   scripts/run-bridge.sh 10 build/bridge/openxr-sdk-win/src/tests/hello_xr/hello_xr.exe -g D3D11
#
# Environment:
#   RUNNER=27.0.0.41073-fex   NotProton runner build
#   RUNNER_DIR=<dir>          runner copy to use instead (e.g. app/Tests/scratch.sh's clone with MacVR's runner files)
#   RUNNER_MODE=1             MacVR's runner mode: no BRIDGE_ROOT in WINEDLLPATH and no system32 copy; the runner (see
#                             RUNNER_DIR) must have the dll/.so and BRIDGE_ROOT holds wineopenxr.json + x86_64-windows/
#   FEX=1                     arm64 Wine with FEX (notproton-fex): aarch64-unix wineopenxr.so + arm64 client, the
#                             runner's aarch64-unix template; the PE side stays x86_64
#   BACKEND=dxvk              CX_GRAPHICS_BACKEND (dxvk|dxmt|wined3d)
#   DUMP_FRAME=N              committed frame the null compositor writes to build/logs/bridge-frame.png (default 60)
#   SYNC=cpu                  MONADO_MACOS_SYNC=cpu on both sides
#   PREFIX=<dir>              Wine prefix (default build/bridge/pfx, an APFS clone of NotProton's template)
#   COPY_DLLS=1               also copy the *.dll next to <exe> (e.g. openvr_api.dll) into C:\
#   WIVRN=1                   no service: connect to a running WiVRn server (scripts/run-wivrn.sh) with the bridge's
#                             own client (build/bridge/root, from scripts/build-wivrn.sh --client-x86_64), with
#                             XDG_RUNTIME_DIR unset (as a game under NotProton). Otherwise the client is the
#                             standalone build/bridge/monado-{x86_64,arm64} one (MACVR_OPENXR_RUNTIME), matching
#                             monado-service.
#   SERVICE=monado            monado: our monado-service (default); none: nothing on the socket (no server);
#                             listen: a socket that listens but never accepts and no Mach service (WiVRn without a
#                             headset: its Monado IPC server only runs during a headset session)
#   KILL_SERVICE=N            SIGKILL the service N seconds after the client starts (lost runtime mid-session)
#   RT_DIR=<dir>              XDG_RUNTIME_DIR for the service and client (default build/bridge/rt)
#   BRIDGE_ROOT=<dir>         wineopenxr.dll/.so (+ client dylib) dir (default build/bridge/root). Wine must not
#                             touch ~/Documents (TCC prompt): stage the root, prefix and runtime dir elsewhere
#
# Never touches the runner, NotProton's template or any game prefix. The service runs with its own
# XDG_RUNTIME_DIR (build/bridge/rt), so it doesn't collide with another monado-service or WiVRn.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/env-macos.sh"

secs="${1:-10}"
shift
exe="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
shift

B="$ROOT/build/bridge"
LOGS="$ROOT/build/logs"
mkdir -p "$LOGS"
slog="$LOGS/bridge-service.log"
clog="$LOGS/bridge-$(basename "$exe" .exe).log"
png="$LOGS/bridge-frame.png"
rm -f "$png"

runner="${RUNNER:-27.0.0.41073-fex}"
np="$HOME/Library/Application Support/notproton"
CX_ROOT="${RUNNER_DIR:-$np/runners/crossover-$runner}/CrossOver"
unix_arch=x86_64
[[ "${FEX:-0}" == 1 ]] && unix_arch=aarch64
template="$HOME/Library/Application Support/Steam/steamapps/compatdata/notproton-template/crossover-$runner-$unix_arch-unix/pfx"
prefix="${PREFIX:-$B/pfx}"
[[ -d "$CX_ROOT" ]] || { echo "no runner $CX_ROOT" >&2; exit 1; }
if [[ ! -d "$prefix" ]]; then
	mkdir -p "$(dirname "$prefix")"
	cp -cR "$template" "$prefix"
fi

wine_unix="$CX_ROOT/lib/wine/$unix_arch-unix"
if [[ $unix_arch == aarch64 ]]; then
	[[ "${RUNNER_MODE:-0}" == 1 ]] || { echo "FEX=1 needs RUNNER_MODE=1: arm64 Wine pairs the PE only with the runner's x86_64-windows/wineopenxr.so" >&2; exit 2; }
	WINESERVER="$CX_ROOT/bin/wineserver-arm64"
	WINELOADER="$wine_unix/wine.app/Contents/MacOS/wine"
	export FEX_X87REDUCEDPRECISION="${FEX_X87REDUCEDPRECISION:-1}"
	client_dir=monado-arm64
else
	WINESERVER="$CX_ROOT/bin/wineserver"
	[[ -x "$WINESERVER" ]] || WINESERVER="$CX_ROOT/bin/wineserver-x86"
	WINELOADER="$wine_unix/wine"
	client_dir=monado-x86_64
fi
export CX_ROOT WINESERVER WINELOADER WINEPREFIX="$prefix"
export CX_HOME="$HOME/Library/Application Support/CrossOver"
root="${BRIDGE_ROOT:-$B/root}"
if [[ "${RUNNER_MODE:-0}" == 1 ]]; then
	export WINEDLLPATH="$CX_ROOT/lib/wine/x86_64-windows:$wine_unix"
else
	export WINEDLLPATH="$root:$CX_ROOT/lib/wine/x86_64-windows:$wine_unix"
fi
export CX_GRAPHICS_BACKEND="${BACKEND:-dxvk}"
export WINEDEBUG="${WINEDEBUG:--all}"
export XDG_RUNTIME_DIR="${RT_DIR:-$B/rt}"
export MONADO_SYNC_STATS=1
[[ "${SYNC:-auto}" == cpu ]] && export MONADO_MACOS_SYNC=cpu

# Install: placeholder in system32 (Wine then loads the builtin from WINEDLLPATH), runtime json, ActiveRuntime.
# RUNNER_MODE=1 as MacVR installs it: the runner has the dll/.so, ActiveRuntime names <root>/wineopenxr.json by Z: path.
sys32="$prefix/drive_c/windows/system32"
if [[ "${RUNNER_MODE:-0}" == 1 ]]; then
	rm -f "$sys32/wineopenxr.dll" "$sys32/wineopenxr.json"
	json="Z:$(echo "$root/wineopenxr.json" | tr / '\\')"
else
	cp "$root/x86_64-windows/wineopenxr.dll" "$sys32/"
	cp "$root/wineopenxr.json" "$sys32/"
	json='C:\windows\system32\wineopenxr.json'
fi
"$WINELOADER" reg add 'HKLM\SOFTWARE\Khronos\OpenXR\1' /v ActiveRuntime /t REG_SZ /d "$json" /f > /dev/null 2>&1

if [[ "${WIVRN:-0}" == 1 ]]; then
	unset XDG_RUNTIME_DIR
	[[ -S "$(getconf DARWIN_USER_TEMP_DIR)wivrn/comp_ipc" ]] || { echo "WiVRn server not running" >&2; exit 1; }
	spid=""
else
export MACVR_OPENXR_RUNTIME="${MACVR_OPENXR_RUNTIME:-$B/$client_dir/src/xrt/targets/openxr/libopenxr_monado.dylib}"
mkdir -p "$XDG_RUNTIME_DIR"
sock="$XDG_RUNTIME_DIR/monado_comp_ipc"
rm -f "$sock"
service="${SERVICE:-monado}"
if [[ "$service" == listen ]]; then
	perl -e 'alarm shift; exec @ARGV' $((secs + 90)) python3 -c \
		'import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(8); print("listening", flush=True); time.sleep(1e6)' \
		"$sock" > "$slog" 2>&1 &
	spid=$!
elif [[ "$service" == monado ]]; then
(
	export XRT_NO_STDIN=1 XRT_COMPOSITOR_NULL=1 SIMULATED_ENABLE=1
	export XRT_COMPOSITOR_NULL_DUMP="$png" XRT_COMPOSITOR_NULL_DUMP_FRAME="${DUMP_FRAME:-60}"
	exec perl -e 'alarm shift; exec @ARGV' $((secs + 90)) "$B/monado/src/xrt/targets/service/monado-service"
) > "$slog" 2>&1 &
spid=$!
else
	spid=""
	: > "$slog"
fi
if [[ -n "$spid" ]]; then
	for _ in $(seq 50); do
		[[ -S "$sock" ]] && break
		sleep 0.1
	done
	[[ -S "$sock" ]] || { echo "service did not create $sock"; cat "$slog"; kill "$spid" 2>/dev/null; exit 1; }
fi
fi

cp "$exe" "$prefix/drive_c/"
[[ "${COPY_DLLS:-0}" == 1 ]] && cp "$(dirname "$exe")"/*.dll "$prefix/drive_c/"
killer=""
if [[ -n "${KILL_SERVICE:-}" && -n "$spid" ]]; then
	(sleep "$KILL_SERVICE"; kill -KILL "$spid" 2>/dev/null || true; echo "killed service at $(date +%T)") >> "$slog" 2>&1 &
	killer=$!
fi
set +e
(cd "$prefix/drive_c" && (trap '' PIPE; sleep "$secs"; echo 2>/dev/null || true) | perl -e 'alarm shift; exec @ARGV' $((secs + 60)) \
	"$WINELOADER" "C:\\$(basename "$exe")" "$@") > "$clog" 2>&1
rc=$?
[[ -n "$killer" ]] && kill "$killer" 2>/dev/null
"$WINESERVER" -k 2>/dev/null
set -e
src=0
if [[ -n "$spid" ]]; then
	[[ "${SERVICE:-monado}" == listen ]] && kill -TERM "$spid" 2>/dev/null || true
	kill -INT "$spid" 2>/dev/null || true
	wait "$spid" 2>/dev/null && src=0 || src=$?
	[[ -n "${KILL_SERVICE:-}" || "${SERVICE:-monado}" == listen ]] && src=0
fi

echo "client exit code $rc, log $clog; service exit code $src, log $slog"
[[ -n "$spid" ]] || slog=/dev/null
grep -E "layer commits|Frame dump: wrote|sync-stats" "$slog" | tail -4 || true
grep -E "sync-stats|shared timeline|CPU wait|wineopenxr" "$clog" | tail -6 || true
echo "errors: service $(grep -c ' ERROR \|ERROR \[' "$slog" || true), client $(grep -c ' ERROR \|ERROR \[\|^err:' "$clog" || true)"
[[ -f "$png" ]] && echo "frame dump: $png"
exit $(( rc != 0 ? rc : src ))
