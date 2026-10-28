#!/bin/zsh
# abrecord.sh <label> <seconds> : Metal HUD os_log lines (all processes), ps samples every 2 s and the stack's own
# logs over one window, into build/ab/<label>.*. Summarise with abstats.py.
# Stack A (optional reference: Windows Steam + SteamVR in a CrossOver bottle): AB_DRIVE_C=<bottle drive_c>,
# AB_ENCODER_LOG / AB_SHIM_LOG (its encoder and frame-path logs), AB_ENCODER_PROC (its encoder process name).
set -u
ROOT=${0:A:h:h:h}
OUT=$ROOT/build/ab/$1
SECS=$2
A=${AB_DRIVE_C:-/nonexistent}
EL=${AB_ENCODER_LOG:-/nonexistent}; SL=${AB_SHIM_LOG:-/nonexistent}
L="$A/Program Files (x86)/Steam/logs"
W=$ROOT/build/logs/wivrn-server.log
lines() { wc -l < "$1" 2>/dev/null || echo 0; }
e0=$(lines $EL); s0=$(lines $SL)
v0=$(lines "$L/driver_vrlink.txt"); c0=$(lines "$L/vrcompositor.txt"); w0=$(lines $W)
/usr/bin/log stream --style compact --predicate 'eventMessage CONTAINS "metal-HUD"' > $OUT.hud &
lp=$!
: > $OUT.ps
end=$((SECONDS + SECS))
while (( SECONDS < end )); do
    echo "# $(date +%s)" >> $OUT.ps
    ps -Ao pid=,%cpu=,rss=,command= | grep -E 'hlvr.exe|wineserver|vrserver.exe|vrcompositor.exe|vrwebhelper|vrmonitor|vrdashboard|${AB_ENCODER_PROC:-ab-encoder}|wivrn-server|VTEncoderXPCService|steam.exe|steamwebhelper|WindowServer' | grep -v grep | cut -c1-200 >> $OUT.ps
    sleep 2
done
kill $lp
tail -n +$((e0 + 1)) $EL > $OUT.encoder 2>/dev/null
tail -n +$((s0 + 1)) $SL > $OUT.shim 2>/dev/null
tail -n +$((v0 + 1)) "$L/driver_vrlink.txt" > $OUT.vrlink 2>/dev/null
tail -n +$((c0 + 1)) "$L/vrcompositor.txt" > $OUT.compositor 2>/dev/null
tail -n +$((w0 + 1)) $W > $OUT.wivrn 2>/dev/null
echo "recorded $OUT"
