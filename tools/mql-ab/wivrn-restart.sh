#!/bin/zsh
# wivrn-restart.sh <server dir> [hz] [VAR=value ...] : stop wivrn-server, start <server dir>/server/wivrn-server with the
# given env (log build/logs/wivrn-server.log), check the bridge client's ipc-stamp, reconnect the Quest, set the refresh rate.
set -u
ROOT=${0:A:h:h:h}; S=$1; HZ=${2:-90}; shift; (( $# )) && shift
cd $ROOT
source scripts/lib/detect.sh
Q=$(quest_serial) || exit 1; IP=$(mac_ip) || exit 1
pkill -f 'server/wivrn-server' && while pgrep -qf 'server/wivrn-server'; do sleep 0.5; done
source scripts/env-macos.sh
env "$@" XRT_LOG=info nohup $S/server/wivrn-server --no-manage-active-runtime > build/logs/wivrn-server.log 2>&1 &
sleep 2
scripts/ipc-stamp.sh publish $S && scripts/ipc-stamp.sh check $S/server/ipc-stamp
adb -s $Q shell am force-stop org.meumeu.wivrn; sleep 2
adb -s $Q shell am start -d "wivrn://$IP:9757" -n org.meumeu.wivrn/.MainActivity > /dev/null
for i in {1..40}; do lsof -nP -c wivrn-ser 2>/dev/null | grep -q ESTABLISHED && break; sleep 1; done
sleep 3
XR_RUNTIME_JSON=$S/openxr_wivrn-dev.json build/ab/xr_refresh $HZ 2>&1 | tail -1
