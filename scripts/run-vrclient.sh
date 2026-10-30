#!/usr/bin/env bash
# Run a Windows OpenVR program through the vrclient bridge (vrclient/) and the native macOS OpenComposite
# (build/oc-macos/runtime, Metal compositor) against our arm64 monado-service (null compositor, simulated HMD):
#   game -> openvr_api.dll -> vrclient_x64.dll -> vrclient_x64.so -> vrclient.dylib -> XR_KHR_metal_enable -> Monado
#   scripts/run-vrclient.sh [seconds] [exe [args...]]      (default: 30 s of build/vrclient/tests/ovr_d3d11_render.exe)
#
# Environment:
#   OUT=<dir>          scratch dir (default $DARWIN_USER_TEMP_DIR/macvr-vrclient): staged root/runtime/client, prefix,
#                      logs and frame dumps. Wine must not touch ~/Documents (TCC prompt), so everything it loads is
#                      copied there first.
#   RUNNER=<build>     NotProton runner (default 26.3.0.39832: Rosetta; 27.0.0.41073-fex with FEX=1)
#   FEX=1              arm64 Wine with FEX: a clone of the runner gets vrclient_x64.dll/.so (setup-vrclient-prefix.sh
#                      --runner) and the arm64 OpenXR client; the PE side stays x86_64
#   BACKEND=dxmt       CX_GRAPHICS_BACKEND
#   DUMP_FRAME=N       committed frame the null compositor writes to $OUT/frame-<tag>.png (default 300)
#   TAG=<name>         log/dump name suffix (default: runner arch)
#   VRCLIENT_DXMT_SYNC=query   force the event-query sync (DXMT without keyed mutexes)
#   VRCLIENT_DXMT_GPU_SYNC=0   CPU wait before OpenComposite's copy instead of its GPU wait (oc_metal_submit_sync)
# The service gets its own XDG_RUNTIME_DIR ($OUT/rt). Never touches the runners, NotProton's template or game prefixes.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/env-macos.sh"

secs="${1:-30}"
shift || true
exe="${1:-$ROOT/build/vrclient/tests/ovr_d3d11_render.exe}"
[[ $# -gt 0 ]] && shift
exe="$(cd "$(dirname "$exe")" && pwd)/$(basename "$exe")"
args=("$@")
[[ $# -gt 0 ]] || args=("$secs")

OUT="${OUT:-$(getconf DARWIN_USER_TEMP_DIR)macvr-vrclient}"
fex="${FEX:-0}"
if [[ $fex == 1 ]]; then runner="${RUNNER:-27.0.0.41073-fex}"; unix_arch=aarch64; xr_arch=arm64
else runner="${RUNNER:-26.3.0.39832}"; unix_arch=x86_64; xr_arch=x86_64; fi
tag="${TAG:-$unix_arch}"
np="$HOME/Library/Application Support/notproton"
src_runner="$np/runners/crossover-$runner/CrossOver"
template="$HOME/Library/Application Support/Steam/steamapps/compatdata/notproton-template/crossover-$runner-$unix_arch-unix/pfx"
[[ -d "$src_runner" ]] || { echo "no runner $src_runner" >&2; exit 1; }
[[ -d "$template" ]] || { echo "no NotProton template $template" >&2; exit 1; }
mkdir -p "$OUT/rt" "$OUT/logs"
slog="$OUT/logs/service-$tag.log"
clog="$OUT/logs/$(basename "$exe" .exe)-$tag.log"
vlog="$OUT/logs/vrclient-$tag.log"
png="$OUT/frame-$tag.png"
rm -f "$png" "$vlog"

# Stage what Wine loads
rsync -a --delete "$ROOT/build/vrclient/root/" "$OUT/root/"
rsync -a --delete "$ROOT/build/oc-macos/runtime/" "$OUT/runtime/"
client="$ROOT/build/bridge/monado-$xr_arch/src/xrt/targets/openxr/libopenxr_monado.dylib"
[[ -f "$client" ]] || { echo "no $client (scripts/build-bridge.sh monado-$xr_arch)" >&2; exit 1; }
mkdir -p "$OUT/xr-$xr_arch"
cp "$client" "$OUT/xr-$xr_arch/"
printf '{\n  "file_format_version": "1.0.0",\n  "runtime": { "name": "Monado", "library_path": "%s" }\n}\n' \
	"$OUT/xr-$xr_arch/libopenxr_monado.dylib" > "$OUT/xr-$xr_arch/openxr_monado.json"

prefix="$OUT/pfx-$runner-$unix_arch"
[[ -d "$prefix" ]] || cp -cR "$template" "$prefix"
setup=("$ROOT/scripts/setup-vrclient-prefix.sh" --root "$OUT/root")
if [[ $fex == 1 ]]; then
	# arm64 Wine pairs the PE only with a .so next to it in the runner's x86_64-windows: use a clone of the runner
	CX_ROOT="$OUT/runner-$runner/CrossOver"
	[[ -d "$CX_ROOT" ]] || { mkdir -p "$OUT/runner-$runner"; cp -cR "$src_runner" "$CX_ROOT"; }
	setup+=(--runner "$CX_ROOT")
else
	CX_ROOT="$src_runner"
fi
"${setup[@]}" "$prefix" > /dev/null

wine_unix="$CX_ROOT/lib/wine/$unix_arch-unix"
if [[ $fex == 1 ]]; then
	WINESERVER="$CX_ROOT/bin/wineserver-arm64"
	WINELOADER="$wine_unix/wine.app/Contents/MacOS/wine"
	export FEX_X87REDUCEDPRECISION="${FEX_X87REDUCEDPRECISION:-1}"
	export WINEDLLPATH="$CX_ROOT/lib/wine/x86_64-windows:$wine_unix"
else
	WINESERVER="$CX_ROOT/bin/wineserver"
	[[ -x "$WINESERVER" ]] || WINESERVER="$CX_ROOT/bin/wineserver-x86"
	WINELOADER="$wine_unix/wine"
	export WINEDLLPATH="$OUT/root:$CX_ROOT/lib/wine/x86_64-windows:$wine_unix"
fi
export CX_ROOT WINESERVER WINELOADER WINEPREFIX="$prefix"
export CX_HOME="$HOME/Library/Application Support/CrossOver"
export CX_GRAPHICS_BACKEND="${BACKEND:-dxmt}"
export WINEDEBUG="${WINEDEBUG:--all,err+vrclient}"
export XDG_RUNTIME_DIR="$OUT/rt"
export MONADO_SYNC_STATS=1
export MACVR_VRCLIENT_RUNTIME="$OUT/runtime"
export XR_RUNTIME_JSON="$OUT/xr-$xr_arch/openxr_monado.json"
export VRCLIENT_LOG="$vlog" VRCLIENT_STATS="${VRCLIENT_STATS:-1}"

sock="$XDG_RUNTIME_DIR/monado_comp_ipc"
rm -f "$sock"
(
	export XRT_NO_STDIN=1 XRT_COMPOSITOR_NULL=1 SIMULATED_ENABLE=1
	export XRT_COMPOSITOR_NULL_DUMP="$png" XRT_COMPOSITOR_NULL_DUMP_FRAME="${DUMP_FRAME:-300}"
	exec perl -e 'alarm shift; exec @ARGV' $((secs + 120)) "$ROOT/build/bridge/monado/src/xrt/targets/service/monado-service"
) > "$slog" 2>&1 &
spid=$!
for _ in $(seq 50); do
	[[ -S "$sock" ]] && break
	sleep 0.1
done
[[ -S "$sock" ]] || { echo "service did not create $sock"; cat "$slog"; kill "$spid" 2>/dev/null; exit 1; }

app="$prefix/drive_c/ovrtest"
mkdir -p "$app"
cp "$exe" "$app/"
for d in "$(dirname "$exe")"/*.dll; do [[ -f "$d" ]] && cp "$d" "$app/"; done
set +e
(cd "$app" && perl -e 'alarm shift; exec @ARGV' $((secs + 90)) "$WINELOADER" "C:\\ovrtest\\$(basename "$exe")" "${args[@]}") \
	> "$clog" 2>&1
rc=$?
"$WINESERVER" -k 2>/dev/null
set -e
kill -INT "$spid" 2>/dev/null || true
wait "$spid" 2>/dev/null && src=0 || src=$?

echo "client exit code $rc, log $clog; service exit code $src, log $slog; bridge log $vlog"
grep -E "^ovr_render: (VR_Init|done|both-eye)|^ovr_test: done" "$clog" || tail -5 "$clog"
grep -E "layer commits|Frame dump: wrote" "$slog" | tail -2 || true
grep -E "DXMT|native runtime|stats" "$vlog" 2>/dev/null | tail -4 || true
echo "errors: service $(grep -c ' ERROR \|ERROR \[' "$slog" || true), client $(grep -ciE '^err:|abort|\[OC\].*error' "$clog" || true)"
[[ -f "$png" ]] && echo "frame dump: $png"
exit $(( rc != 0 ? rc : src ))
