#!/bin/zsh
# latrun.sh <label> <server dir> [VAR=value ...] : restart wivrn-server from <server dir> with the env (plus
# WIVRN_FEEDBACK_DUMP if the diag patch is in), wait for the Quest to reconnect on its own, 90 Hz, reload Alyx
# (s6/steamvr_quit, fidelity 3 pinned, bridge WINEOPENXR_STATS=2), 20 s settle with a 5-s gpustress kick, then 30 s of
# abrecord.sh + feedback dump + logcat + one headset screencap at 15 s. Output build/lat/<label>.*; summary latstats.py.
set -u
D=${0:A:h}; ROOT=${D:h:h}; L=$1; S=${2:A}; shift 2
source $ROOT/scripts/lib/detect.sh
Q=$(quest_serial) || exit 1; IP=$(mac_ip) || exit 1; O=$ROOT/build/lat; mkdir -p $O
C="$HOME/Library/Application Support/Steam/steamapps/compatdata/546560/pfx/drive_c/macvr"
LOG=$C/wineopenxr.log
mono() { python3 -c 'import time; print(time.clock_gettime_ns(time.CLOCK_MONOTONIC))'; }
cd $ROOT

# Alyx can't survive a server restart (OpenComposite shows an INSTANCE_LOST dialog), so quit it first
if pgrep -qf 'hlvr.exe'; then
	osascript -e 'quit app "Half-Life Alyx"' > /dev/null 2>&1
	for i in {1..20}; do pgrep -qf 'hlvr.exe' || break; sleep 1; done
	pkill -9 -f 'hlvr.exe'; while pgrep -qf 'hlvr.exe'; do sleep 1; done
	sleep 3
fi
pkill -f 'server/wivrn-server' && while pgrep -qf 'server/wivrn-server'; do sleep 0.5; done
source scripts/env-macos.sh
env "$@" WIVRN_FEEDBACK_DUMP=$O/$L.fb XRT_LOG=info nohup $S/server/wivrn-server --no-manage-active-runtime > build/logs/wivrn-server.log 2>&1 &!
sleep 2
scripts/ipc-stamp.sh publish $S && scripts/ipc-stamp.sh check $S/server/ipc-stamp
t=0
while (( t < 60 )) && ! lsof -nP -c wivrn-ser 2>/dev/null | grep -q ESTABLISHED; do sleep 1; t=$((t + 1)); done
if (( t < 60 )); then
	echo "client reconnected on its own after ${t} s" | tee $O/$L.reconnect
else
	echo "client did NOT reconnect within 60 s, starting it with adb" | tee $O/$L.reconnect
	adb -s $Q shell am start -d "wivrn://$IP:9757" -n org.meumeu.wivrn/.MainActivity > /dev/null
	for i in {1..40}; do lsof -nP -c wivrn-ser 2>/dev/null | grep -q ESTABLISHED && break; sleep 1; done
fi
sleep 3
XR_RUNTIME_JSON=$S/openxr_wivrn-dev.json build/ab/xr_refresh 90 2>&1 | tail -1

printf 'WINEOPENXR_LOG=C:\\macvr\\wineopenxr.log\r\nWINEOPENXR_STATS=2\r\n' > $C/wineopenxr.env
scripts/alyx-save.sh || exit 1
python3 $D/vcq.py 'vr_fidelity_level_auto 0' 'vr_fidelity_level 3' > /dev/null
osascript -e 'tell application "System Events" to set frontmost of process "hlvr.exe" to true'
sleep 11
build/ab/gpustress 5 > /dev/null 2>&1; sleep 4

n0=$(wc -l < $LOG)
adb -s $Q logcat -c
m0=$(mono)
build/ab/gpufreq 30 > $O/$L.gpufreq &
p1=$!
(sleep 15; adb -s $Q exec-out screencap -p > $O/$L-quest.png) &
p2=$!
$D/abrecord.sh lat-$L 30 > /dev/null 2>&1
wait $p1 $p2
m1=$(mono)
echo "$m0 $m1" > $O/$L.window
adb -s $Q logcat -d -v epoch > $O/$L.logcat
tail -n +$((n0 + 1)) $LOG > $O/$L.bridge
for f in $ROOT/build/ab/lat-$L.*; do mv $f $O/$L.${f##*.}; done
python3 $D/latstats.py $O/$L
