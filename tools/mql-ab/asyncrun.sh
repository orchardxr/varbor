#!/bin/zsh
# asyncrun.sh <label> <WINEOPENXR_ASYNC> [settle s] : restart Alyx with the bridge settings, load the A/B save at
# fidelity 3, settle, then a 30-s abrecord window with the GPU P-states and the bridge's per-frame lines
# (build/ab/<label>.{hud,ps,gpufreq,bridge}). Needs the A/B settings (72 Hz, supersampleRatio) set up by hand.
set -u
D=${0:A:h}; ROOT=${D:h:h}; L=$1
C="$HOME/Library/Application Support/Steam/steamapps/compatdata/546560/pfx/drive_c/macvr"
LOG=$C/wineopenxr.log
printf 'WINEOPENXR_LOG=C:\\macvr\\wineopenxr.log\r\nWINEOPENXR_STATS=2\r\nWINEOPENXR_ASYNC=%s\r\n' $2 > $C/wineopenxr.env
$ROOT/scripts/alyx-save.sh || exit 1
python3 $D/vcq.py 'vr_fidelity_level_auto 0' 'vr_fidelity_level 3' > /dev/null
osascript -e 'tell application "System Events" to set frontmost of process "hlvr.exe" to true'
sleep ${3:-20}
n0=$(wc -l < $LOG)
$ROOT/build/ab/gpufreq 30 > $ROOT/build/ab/$L.gpufreq &
$D/abrecord.sh $L 30 > /dev/null 2>&1
wait
tail -n +$((n0 + 1)) $LOG > $ROOT/build/ab/$L.bridge
lsappinfo info -only name $(lsappinfo front) | head -1
python3 $D/abstats.py $ROOT/build/ab/$L | head -2
python3 $D/bridgestats.py $ROOT/build/ab/$L.bridge
cat $ROOT/build/ab/$L.gpufreq
grep -m3 "spike" $ROOT/build/ab/$L.bridge | cut -c1-400
