#!/bin/zsh
# vrab.sh <label> [settle s] : one Alyx A/B window, identical for MacVR's path and the vrclient path. Loads the save
# (scripts/alyx-save.sh), pins fidelity 3, settles with a 5-s gpustress kick 4 s before the window, then records 30 s
# (abrecord.sh + gpufreq) into build/ab/<label>.* and prints abstats.py. The window's vrclient bridge stats lines
# (VRCLIENT_STATS, vrclient path only) go to build/ab/<label>.bridge.
# AB_WIVRN_LOG: the running server's log (default build/logs/wivrn-server.log; MacVR.app: ~/Library/Logs/MacVR/).
set -u
D=${0:A:h}; ROOT=${D:h:h}; L=$1; B=$ROOT/build/ab
VLOG="$(getconf DARWIN_USER_TEMP_DIR)macvr-alyx-vrclient/logs/vrclient.log"
for t in gpustress gpufreq; do [[ -x $B/$t ]] || { echo "no $B/$t (build it, TODO.md)" >&2; exit 1; }; done
pgrep -q screensharingd && { echo "screensharingd is running: end the Screen Sharing session first" >&2; exit 1; }
pgrep -xq caffeinate || { echo "caffeinate is not running (caffeinate -dimsu &)" >&2; exit 1; }
pgrep -xq wivrn-server || { echo "no wivrn-server running" >&2; exit 1; }
$ROOT/scripts/alyx-save.sh || exit 1
python3 $D/vcq.py 'vr_fidelity_level_auto 0' 'vr_fidelity_level 3' > /dev/null
# AB_ACTIVATE: command that brings hlvr.exe to the front and prints the frontmost app (System Events can hang
# behind a permission prompt); it runs again right before the window, output in <label>.front
activate() { if [[ -n ${AB_ACTIVATE:-} ]]; then $AB_ACTIVATE; else osascript -e 'tell application "System Events" to set frontmost of process "hlvr.exe" to true'; fi; }
activate
sleep $(( ${2:-20} - 9 ))
$B/gpustress 5 > /dev/null 2>&1; sleep 4
activate > $B/$L.front 2>&1
v0=$(wc -l < $VLOG 2>/dev/null || echo 0)
$B/gpufreq 30 > $B/$L.gpufreq &
$D/abrecord.sh $L 30 > /dev/null 2>&1
wait
[[ -f $VLOG ]] && tail -n +$((v0 + 1)) $VLOG > $B/$L.bridge
lsappinfo info -only name $(lsappinfo front) | head -1
python3 $D/abstats.py $B/$L
cat $B/$L.gpufreq
[[ -s $B/$L.bridge ]] && grep stats $B/$L.bridge | tail -3
