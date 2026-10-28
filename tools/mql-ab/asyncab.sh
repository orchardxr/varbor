#!/bin/zsh
# asyncab.sh <label> <mode>... : one Alyx session (A/B save, fidelity 3), the bridge's WINEOPENXR_ASYNC switched live
# (WINEOPENXR_ASYNC_RELOAD=1) between 30-s windows, so all modes see the same session and similar GPU clocks.
# Window i: build/ab/<label>-<i>m<mode>.{hud,ps,gpufreq,bridge}. Needs the A/B settings (72 Hz, supersampleRatio).
set -u
D=${0:A:h}; ROOT=${D:h:h}; L=$1; shift
C="$HOME/Library/Application Support/Steam/steamapps/compatdata/546560/pfx/drive_c/macvr"
LOG=$C/wineopenxr.log
env_file() { printf 'WINEOPENXR_LOG=C:\\macvr\\wineopenxr.log\r\nWINEOPENXR_STATS=2\r\nWINEOPENXR_ASYNC_RELOAD=1\r\nWINEOPENXR_ASYNC=%s\r\n' $1 > $C/wineopenxr.env; }
env_file $1
$ROOT/scripts/alyx-save.sh || exit 1
python3 $D/vcq.py 'vr_fidelity_level_auto 0' 'vr_fidelity_level 3' > /dev/null
osascript -e 'tell application "System Events" to set frontmost of process "hlvr.exe" to true'
sleep 14
i=0
for m in "$@"; do
	i=$((i + 1)); W=$L-${i}m$m
	env_file $m
	sleep 6
	n0=$(wc -l < $LOG)
	$ROOT/build/ab/gpufreq 30 > $ROOT/build/ab/$W.gpufreq &
	$D/abrecord.sh $W 30 > /dev/null 2>&1
	wait
	tail -n +$((n0 + 1)) $LOG > $ROOT/build/ab/$W.bridge
	echo "== $W ($(grep -h 'async mode' $LOG | tail -1 | cut -c13-)) $(lsappinfo info -only name $(lsappinfo front) | head -1 | cut -c1-20)"
	python3 $D/abstats.py $ROOT/build/ab/$W | head -1
	python3 $D/bridgestats.py $ROOT/build/ab/$W.bridge
	cat $ROOT/build/ab/$W.gpufreq
done
