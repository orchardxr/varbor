#!/usr/bin/env bash
# Run the native Metal OpenVR test app (tests/openvr-metal) through the macOS OpenComposite
# (scripts/build-opencomposite.sh --macos) against our monado-service (null compositor, simulated HMD).
#   scripts/run-ovr-metal.sh [seconds] [mode]          (default 30 separate; modes: see tests/openvr-metal/ovr_metal.mm)
#
# Environment:
#   OUT=<dir>          logs (OpenComposite logs to the app's stdout) and the frame dump (default build/logs/ovr-metal)
#   DUMP_FRAME=N       which committed frame the null compositor writes to $OUT/frame-<mode>.png (default 300)
#   MTL_DEBUG_LAYER=1  Metal API validation in the app (passed through)
# The service runs with its own XDG_RUNTIME_DIR ($OUT/rt), so it doesn't collide with WiVRn or another monado-service.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/env-macos.sh"

secs="${1:-30}"
mode="${2:-separate}"
OUT="${OUT:-$ROOT/build/logs/ovr-metal}"
mkdir -p "$OUT/rt"
slog="$OUT/service-$mode.log"
alog="$OUT/ovr_metal-$mode.log"
png="$OUT/frame-$mode.png"
rm -f "$png"

export XDG_RUNTIME_DIR="$OUT/rt" MONADO_SYNC_STATS=1
sock="$XDG_RUNTIME_DIR/monado_comp_ipc"
rm -f "$sock"
(
	export XRT_NO_STDIN=1 XRT_COMPOSITOR_NULL=1 SIMULATED_ENABLE=1
	export XRT_COMPOSITOR_NULL_DUMP="$png" XRT_COMPOSITOR_NULL_DUMP_FRAME="${DUMP_FRAME:-300}"
	exec perl -e 'alarm shift; exec @ARGV' $((secs + 60)) "$ROOT/build/monado/src/xrt/targets/service/monado-service"
) > "$slog" 2>&1 &
spid=$!
for _ in $(seq 50); do
	[[ -S "$sock" ]] && break
	sleep 0.1
done
[[ -S "$sock" ]] || { echo "service did not create $sock"; cat "$slog"; kill "$spid" 2>/dev/null; exit 1; }

set +e
(cd "$OUT" && XR_RUNTIME_JSON="$ROOT/build/monado/openxr_monado-dev.json" \
	perl -e 'alarm shift; exec @ARGV' $((secs + 30)) "$ROOT/build/oc-macos/tests/ovr_metal" "$ROOT/build/oc-macos/runtime" "$secs" "$mode") \
	> "$alog" 2>&1
rc=$?
set -e

kill -INT "$spid" 2>/dev/null
wait "$spid"
src=$?

tail -3 "$alog"
echo "app exit code $rc, log $alog; service exit code $src, log $slog"
grep -E "layer commits|Frame dump|sync-stats" "$slog" || true
echo "errors: service $(grep -c ' ERROR \|ERROR \[' "$slog" || true), app $(grep -ciE '^\[OC\].*(error|abort|fail)|failed assertion|failed:' "$alog" || true)"
[[ -f "$png" ]] && echo "frame dump: $png"
exit $(( rc != 0 ? rc : src ))
