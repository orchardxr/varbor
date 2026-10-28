#!/bin/zsh
# gpurun.sh <label> [settle s] : settle, then a 30-s abrecord window with a 5-s Metal System Trace (all processes) in
# its middle; prints abstats and gputrace summaries. Files in build/ab/<label>.*
set -u
D=${0:A:h}; ROOT=${D:h:h}; L=$1
osascript -e 'tell application "System Events" to set frontmost of process "hlvr.exe" to true'
sleep ${2:-20}
$D/abrecord.sh $L 30 > /dev/null 2>&1 &
sleep 10
rm -rf $ROOT/build/ab/$L.trace
xcrun xctrace record --template 'Metal System Trace' --all-processes --time-limit 5s --output $ROOT/build/ab/$L.trace > /dev/null 2>&1
wait
lsappinfo info -only name $(lsappinfo front) | head -1
$D/gpuexport.sh $L
python3 $D/abstats.py $ROOT/build/ab/$L | head -6
python3 $D/gputrace.py $ROOT/build/ab/$L | head -8
