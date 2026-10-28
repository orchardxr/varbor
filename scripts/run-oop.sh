#!/usr/bin/env bash
# Out-of-process test: start monado-service (null compositor, simulated HMD), run hello_xr against it
# for N seconds, stop the service, then summarise the logs.
#   scripts/run-oop.sh [seconds] [hello_xr args...]          (default: 10 -g Vulkan2)
#
# Environment:
#   ARCH=x86_64        run the x86_64 hello_xr + client runtime under Rosetta (scripts/build.sh x86_64)
#   SYNC=cpu           MONADO_MACOS_SYNC=cpu on both sides: no MTLSharedEvent, CPU wait before commit
#   VALIDATE=1         Vulkan validation + OpenXR core_validation/api_dump on the client (see run-hello-xr.sh)
#   SERVICE_VALIDATE=1 Vulkan validation in the service
#   DUMP_FRAME=N       which committed frame the null compositor writes to build/logs/oop-frame.png (default 60)
#
# Logs: build/logs/service-oop.log, build/logs/hello_xr-service.log. Both sides print MONADO_SYNC_STATS lines.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/env-macos.sh"

secs="${1:-10}"
shift $(( $# > 0 ? 1 : 0 ))
[[ $# -gt 0 ]] || set -- -g Vulkan2

LOGS="$ROOT/build/logs"
mkdir -p "$LOGS"
slog="$LOGS/service-oop.log"
png="$LOGS/oop-frame.png"
rm -f "$png"

export MONADO_SYNC_STATS=1
[[ "${SYNC:-auto}" == cpu ]] && export MONADO_MACOS_SYNC=cpu

sock="${XDG_RUNTIME_DIR:-$(getconf DARWIN_USER_TEMP_DIR)}"
sock="${sock%/}/monado_comp_ipc"
if [[ -S "$sock" ]] && pgrep -x monado-service > /dev/null; then
	echo "monado-service is already running" >&2
	exit 1
fi
rm -f "$sock"

(
	[[ "${SERVICE_VALIDATE:-0}" == 1 ]] && export VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation
	export XRT_NO_STDIN=1 XRT_COMPOSITOR_NULL=1 SIMULATED_ENABLE=1
	export XRT_COMPOSITOR_NULL_DUMP="$png" XRT_COMPOSITOR_NULL_DUMP_FRAME="${DUMP_FRAME:-60}"
	exec perl -e 'alarm shift; exec @ARGV' $((secs + 60)) "$ROOT/build/monado/src/xrt/targets/service/monado-service"
) > "$slog" 2>&1 &
spid=$!

for _ in $(seq 50); do
	[[ -S "$sock" ]] && break
	sleep 0.1
done
[[ -S "$sock" ]] || { echo "service did not create $sock"; cat "$slog"; kill "$spid" 2>/dev/null; exit 1; }

set +e
if [[ "${ARCH:-arm64}" == x86_64 ]]; then
	# Rosetta can only load the SDK's universal MoltenVK 1.2.11.
	CLIENT_VK_DRIVER_FILES=/usr/local/share/vulkan/icd.d/MoltenVK_icd.json \
		HELLO_XR="$ROOT/build/openxr-sdk-x86_64/src/tests/hello_xr/hello_xr" \
		CLIENT_RUNTIME_JSON="$ROOT/build/monado-x86_64/openxr_monado-dev.json" \
		CLIENT_API_LAYER_PATH="$ROOT/build/openxr-sdk-x86_64/src/api_layers" \
		"$ROOT/scripts/run-hello-xr.sh" service "$secs" "$@"
else
	"$ROOT/scripts/run-hello-xr.sh" service "$secs" "$@"
fi
rc=$?
set -e

kill -INT "$spid" 2>/dev/null
wait "$spid"
src=$?

echo "service exit code $src, log $slog"
grep -E "Mach IPC: registered|layer commits|Frame dump|sync-stats|MTLSharedEvent Mach port" "$slog" || true
grep -E "sync-stats|shared timeline|Mach IPC" "$LOGS/hello_xr-service.log" || true
echo "errors: service $(grep -c ' ERROR \|ERROR \[' "$slog" || true), client $(grep -c ' ERROR \|ERROR \[' "$LOGS/hello_xr-service.log" || true)"
[[ -f "$png" ]] && echo "frame dump: $png"
exit $(( rc != 0 ? rc : src ))
