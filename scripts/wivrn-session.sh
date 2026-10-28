#!/usr/bin/env bash
# One fresh WiVRn session with the Quest and out-of-process hello_xr, for measurements.
#   scripts/wivrn-session.sh <tag> [hello_xr seconds, default 40]
# Env: MONITOR=1 (server / VTEncoderXPCService / app CPU+RSS every 10 s), plus any server env
# (WIVRN_VT_LOG_TIMING=1, MONADO_SYNC_STATS=1, WIVRN_VT_IDR_RATE_SCALE=..., WIVRN_VT_READBACK=1, WIVRN_DUMP_VIDEO=prefix).
# Another app: HELLO_XR=<binary> APP_ARGS="<args>" (default hello_xr -g Vulkan2), e.g.
# HELLO_XR=build/tests/xr_pattern APP_ARGS="--detail".
# Logs in build/logs/s7/<tag>.{server.log,logcat,hello.log,monitor.txt}; server lines are prefixed with epoch
# seconds (same clock as `adb logcat -v epoch`). Summary: scripts/wivrn-session-summary.py <tag>.server.log
# Needs: adb connected to the Quest (MAC_IP overrides the detected address), the Quest paired, run from the GUI login session (not ssh).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tag=${1:?tag}
secs=${2:-40}
out="$ROOT/build/logs/s7"
source "$ROOT/scripts/lib/detect.sh"
mac_ip=$(mac_ip) || exit 1
mkdir -p "$out"
source "$ROOT/scripts/env-macos.sh"

if [[ -n "$(ls -A "$HOME/Library/Application Support/Steam/steamapps/downloading" 2>/dev/null)" ]]; then
	echo "Steam is downloading, not starting a headset session" >&2
	exit 3
fi
pkill -f build/wivrn/server/wivrn-server && sleep 1
adb shell am force-stop org.meumeu.wivrn
adb logcat -c
caffeinate -i -t $((secs + 90)) &

export XRT_LOG=${XRT_LOG:-info}
("$ROOT/build/wivrn/server/wivrn-server" --no-manage-active-runtime 2>&1 |
	perl -MTime::HiRes=time -ne '$|=1; printf "%.3f %s", time, $_' > "$out/$tag.server.log") &
sleep 0.5
spid=$(pgrep -f build/wivrn/server/wivrn-server | head -1)
sleep 2
"$ROOT/scripts/ipc-stamp.sh" publish "$ROOT/build/wivrn" || true
adb logcat -v epoch > "$out/$tag.logcat" 2>&1 &
lpid=$!
adb shell am start -a android.intent.action.VIEW -d "wivrn://$mac_ip:9757" -n org.meumeu.wivrn/.MainActivity > /dev/null
for _ in $(seq 60); do
	grep -q "Client connected" "$out/$tag.server.log" && break
	sleep 1
done
if ! grep -q "Client connected" "$out/$tag.server.log"; then
	echo "headset did not connect" >&2
	kill "$spid" "$lpid"
	exit 4
fi
sleep 3
app_name=$(basename "${HELLO_XR:-hello_xr}")
if [[ -n "${MONITOR:-}" ]]; then
	(while kill -0 "$spid" 2> /dev/null; do
		echo "$(date +%s) server $(ps -o %cpu=,rss= -p "$spid") vt $(ps -o %cpu=,rss= -p "$(pgrep -n VTEncoderXPCService)") app $(ps -o %cpu=,rss= -p "$(pgrep -n "$app_name")" 2> /dev/null)"
		sleep 10
	done > "$out/$tag.monitor.txt") &
fi
CLIENT_RUNTIME_JSON="$ROOT/build/wivrn/openxr_wivrn-dev.json" "$ROOT/scripts/run-hello-xr.sh" service "$secs" ${APP_ARGS:--g Vulkan2}
cp "$ROOT/build/logs/hello_xr-service.log" "$out/$tag.hello.log"
sleep 1
kill -TERM "$spid"
sleep 2
pkill -f build/wivrn/server/wivrn-server
kill "$lpid" 2> /dev/null
echo "logs: $out/$tag.*"
