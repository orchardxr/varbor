#!/bin/zsh
# pacingrun.sh <label> [settle s] : like asyncrun.sh (sync bridge), plus a 5-s gpustress kick at the end of the settle
# and the WiVRn app-pacer trace slice (diag server with WIVRN_PACER_TRACE=build/ab/pacer.trace, if present).
set -u
D=${0:A:h}; ROOT=${D:h:h}; L=$1
C="$HOME/Library/Application Support/Steam/steamapps/compatdata/546560/pfx/drive_c/macvr"
LOG=$C/wineopenxr.log; T=$ROOT/build/ab/pacer.trace
printf 'WINEOPENXR_LOG=C:\\macvr\\wineopenxr.log\r\nWINEOPENXR_STATS=2\r\n' > $C/wineopenxr.env
$ROOT/scripts/alyx-save.sh || exit 1
python3 $D/vcq.py 'vr_fidelity_level_auto 0' 'vr_fidelity_level 3' > /dev/null
osascript -e 'tell application "System Events" to set frontmost of process "hlvr.exe" to true'
sleep $(( ${2:-20} - 9 ))
$ROOT/build/ab/gpustress 5 > /dev/null 2>&1; sleep 4
n0=$(wc -l < $LOG); t0=$(wc -l < $T 2>/dev/null || echo 0)
$ROOT/build/ab/gpufreq 30 > $ROOT/build/ab/$L.gpufreq &
$D/abrecord.sh $L 30 > /dev/null 2>&1
wait
tail -n +$((n0 + 1)) $LOG > $ROOT/build/ab/$L.bridge
[[ -f $T ]] && tail -n +$((t0 + 1)) $T > $ROOT/build/ab/$L.pacer
lsappinfo info -only name $(lsappinfo front) | head -1
python3 $D/abstats.py $ROOT/build/ab/$L | head -2
python3 $D/bridgestats.py $ROOT/build/ab/$L.bridge
cat $ROOT/build/ab/$L.gpufreq
[[ -s $ROOT/build/ab/$L.pacer ]] && python3 $D/pacertrace.py $ROOT/build/ab/$L.pacer
