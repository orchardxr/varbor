#!/usr/bin/env bash
# Run hello_xr against a Monado build for N seconds, then press "Enter" for a clean shutdown.
#   scripts/run-hello-xr.sh [inproc|service] [seconds] [hello_xr args...]
# Hard-killed (SIGALRM) after seconds+20. Log goes to build/logs/hello_xr-<mode>.log.
# VALIDATE=1 enables VK_LAYER_KHRONOS_validation, the OpenXR core_validation layer and the
# OpenXR api_dump layer (build/logs/hello_xr-<mode>.xrdump.txt, used to count frames).
# Overrides (used by run-oop.sh for the x86_64 client): HELLO_XR, CLIENT_RUNTIME_JSON, CLIENT_VK_DRIVER_FILES,
# CLIENT_API_LAYER_PATH.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/env-macos.sh"
[[ -z "${CLIENT_VK_DRIVER_FILES:-}" ]] || export VK_DRIVER_FILES="$CLIENT_VK_DRIVER_FILES"

mode="${1:-inproc}"
secs="${2:-10}"
shift $(( $# > 2 ? 2 : $# ))
[[ $# -gt 0 ]] || set -- -g Vulkan2

case "$mode" in
	inproc) export XR_RUNTIME_JSON="$ROOT/build/monado-inproc/openxr_monado-dev.json"
	        export SIMULATED_ENABLE="${SIMULATED_ENABLE:-1}" XRT_COMPOSITOR_NULL="${XRT_COMPOSITOR_NULL:-1}" ;;
	service) export XR_RUNTIME_JSON="${CLIENT_RUNTIME_JSON:-$ROOT/build/monado/openxr_monado-dev.json}" ;;
	*) echo "unknown mode $mode" >&2; exit 2 ;;
esac

log="$ROOT/build/logs/hello_xr-$mode.log"
dump="$ROOT/build/logs/hello_xr-$mode.xrdump.txt"
if [[ "${VALIDATE:-0}" == 1 ]]; then
	export VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation
	export XR_API_LAYER_PATH="${CLIENT_API_LAYER_PATH:-$ROOT/build/openxr-sdk/src/api_layers}"
	export DYLD_LIBRARY_PATH="$XR_API_LAYER_PATH"
	export XR_ENABLE_API_LAYERS=XR_APILAYER_LUNARG_core_validation:XR_APILAYER_LUNARG_api_dump
	export XR_API_DUMP_EXPORT_TYPE=text XR_API_DUMP_FILE_NAME="$dump"
	rm -f "$dump"
fi
mkdir -p "$(dirname "$log")"
set +e
(sleep "$secs"; echo) | perl -e 'alarm shift; exec @ARGV' $((secs + 20)) \
	"${HELLO_XR:-$ROOT/build/openxr-sdk/src/tests/hello_xr/hello_xr}" "$@" > "$log" 2>&1
rc=$?
set -e
echo "hello_xr exit code $rc, log $log"
if [[ -f "$dump" && "${VALIDATE:-0}" == 1 ]]; then
	echo "xrEndFrame calls: $(grep -c '^XrResult xrEndFrame' "$dump" || true)"
fi
echo "validation messages: $(grep -c 'VUID-\|Validation Error\|VALIDATION' "$log" || true)"
exit $rc
