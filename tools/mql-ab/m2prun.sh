#!/bin/zsh
# m2prun.sh <label> <server dir> [VAR=value ...] : like latrun.sh, for the M2P comparison (docs/linux-comparison.md
# "Where the Mac loses time"). Server built with patches/diag/wivrn-feedback-dump.patch + wivrn-m2p-trace.patch:
# restart it with WIVRN_FEEDBACK_DUMP/WIVRN_M2P_TRACE, reconnect the Quest, 90 Hz, reload Alyx (s6/steamvr_quit,
# fidelity 3), 20 s settle, 30 s window. Alyx is quit afterwards unless KEEP_ALYX=1. Output build/lat/<label>.*;
# summary m2pstats.py.
set -u
D=${0:A:h}; ROOT=${D:h:h}; L=$1; S=${2:A}; shift 2
source $ROOT/scripts/lib/detect.sh
Q=$(quest_serial) || exit 1; IP=$(mac_ip) || exit 1; O=$ROOT/build/lat; mkdir -p $O
mono() { python3 -c 'import time; print(time.clock_gettime_ns(time.CLOCK_MONOTONIC))'; }
power() { echo "$1 $(date +%T) screensharingd=$(pgrep -x screensharingd || echo off) $(pmset -g adapter | grep Wattage | tr -d ' ') $(pmset -g batt | grep -o '[0-9]*%; [a-z ]*')" | tee -a $O/$L.power; }
quit_alyx() {
	pgrep -qf 'hlvr.exe' || return 0
	osascript -e 'quit app "Half-Life Alyx"' > /dev/null 2>&1
	for i in {1..20}; do pgrep -qf 'hlvr.exe' || break; sleep 1; done
	pkill -9 -f 'hlvr.exe'; while pgrep -qf 'hlvr.exe'; do sleep 1; done
	sleep 3
}
cd $ROOT
[[ -n "$(find "$HOME/Library/Application Support/Steam/steamapps/downloading" -type f -size +0 2>/dev/null | head -1)" ]] && { echo "Steam is downloading" >&2; exit 3; }
: > $O/$L.power
power start

quit_alyx
pkill -f 'server/wivrn-server' && while pgrep -qf 'server/wivrn-server'; do sleep 0.5; done
source scripts/env-macos.sh
env "$@" WIVRN_FEEDBACK_DUMP=$O/$L.fb WIVRN_M2P_TRACE=$O/$L.m2p XRT_LOG=info nohup $S/server/wivrn-server --no-manage-active-runtime > build/logs/wivrn-server.log 2>&1 &!
sleep 2
scripts/ipc-stamp.sh publish $S
adb -s $Q shell am force-stop org.meumeu.wivrn
adb -s $Q shell am start -a android.intent.action.VIEW -d "wivrn://$IP:9757" > /dev/null
for i in {1..40}; do lsof -nP -c wivrn-ser 2>/dev/null | grep -q ESTABLISHED && break; sleep 1; done
lsof -nP -c wivrn-ser 2>/dev/null | grep -q ESTABLISHED || { echo "Quest did not connect, not starting Alyx" | tee $O/$L.gate; power end; exit 5; }
sleep 3
XR_RUNTIME_JSON=$S/openxr_wivrn-dev.json build/ab/xr_refresh 90 2>&1 | tail -1

scripts/alyx-save.sh || exit 1
python3 $D/vcq.py 'vr_fidelity_level_auto 0' 'vr_fidelity_level 3' > /dev/null
osascript -e 'tell application "System Events" to set frontmost of process "hlvr.exe" to true'
sleep 15
prof=$(grep -A1 'Updating interaction profiles' build/logs/wivrn-server.log | grep -o 'to XRT_DEVICE_[A-Z_]*' | tail -1)
d0=$(grep -c '^D ' $O/$L.m2p); sleep 5; d1=$(grep -c '^D ' $O/$L.m2p)
fps=$(( (d1 - d0) / 5 ))
sess=$(grep -o 'Session state changed: [A-Z_]*' build/logs/wivrn-server.log | tail -1)
top=$(adb -s $Q shell dumpsys activity activities | grep -m1 topResumedActivity | grep -o -E 'guardian|clearactivity')
echo "gate: profile '$prof', game ${fps} fps, '$sess', quest dialog '${top:-none}'" | tee $O/$L.gate
if [[ $fps -lt 80 || $sess != *FOCUSED || -n $top ]]; then
	echo "gate failed: not recording" | tee -a $O/$L.gate
	power end
	quit_alyx
	exit 4
fi

w0=$(wc -l < build/logs/wivrn-server.log)
adb -s $Q logcat -c
m0=$(mono)
build/ab/gpufreq 30 > $O/$L.gpufreq &
p1=$!
sleep 30
wait $p1
m1=$(mono)
echo "$m0 $m1" > $O/$L.window
# the server re-execs (and truncates these) when the headset session ends
sleep 1; cp $O/$L.m2p $O/$L.m2p.keep; cp $O/$L.fb $O/$L.fb.keep; mv $O/$L.m2p.keep $O/$L.m2p.rec; mv $O/$L.fb.keep $O/$L.fb.rec
adb -s $Q logcat -d -v epoch > $O/$L.logcat
tail -n +$((w0 + 1)) build/logs/wivrn-server.log > $O/$L.wivrn
power end
[[ ${KEEP_ALYX:-0} == 1 ]] || quit_alyx
cp $O/$L.m2p.rec $O/$L.m2p; cp $O/$L.fb.rec $O/$L.fb
python3 $D/m2pstats.py $O/$L
