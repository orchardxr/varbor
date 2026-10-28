#!/bin/bash
# m2prun-linux.sh <label> [VAR=value ...] : runs ON the Linux PC (bash). The Linux half of the M2P comparison: stock WiVRn
# 26.9 + patches/wivrn 0004 pacer log + 0009 + feedback dump + wivrn-m2p-trace-stock.patch, built in the flatpak's
# devel sandbox (~/m2p/build), run in that sandbox instead of the stock server. Alyx native Vulkan via xrizer,
# s6/steamvr_quit, fidelity 3, 20 s settle, 30 s window. The Mac side connects the Quest (m2p-linux-mac.sh).
# Steps: setup | run <label> | teardown
set -u
M=$HOME/m2p; O=$M/out; mkdir -p $O
ST=$HOME/.local/share/Steam
LC=$(ls $ST/userdata/*/config/localconfig.vdf | grep -v '/0/' | head -1)
G="$ST/steamapps/common/Half-Life Alyx/game/hlvr"
APP=io.github.wivrn.wivrn
mono() { python3 -c 'import time; print(time.clock_gettime_ns(time.CLOCK_MONOTONIC))'; }
launch_opts() {
	python3 - "$LC" "$1" <<'EOF'
import re, sys
p, v = sys.argv[1], sys.argv[2]
s = open(p, encoding='utf-8').read()
i = s.index('"546560"\n', s.index('"apps"'))
j = s.index('"LaunchOptions"', i)
k = s.index('\n', j)
s = s[:j] + '"LaunchOptions"\t\t"' + v + '"' + s[k:]
open(p, 'w', encoding='utf-8').write(s)
EOF
	grep -A3 '"546560"' "$LC" | grep LaunchOptions | head -1
}
stop_server() {
	systemctl --user stop wivrn-m2p.service 2>/dev/null
	pkill -f 'wivrn-server' ; sleep 1
	while pgrep -f wivrn-server > /dev/null; do sleep 0.5; done
}
quit_alyx() {
	pgrep -f hlvr_linux > /dev/null || pgrep -f 'bin/linuxsteamrt64/hlvr' > /dev/null || return 0
	python3 $M/vcq.py quit > /dev/null 2>&1
	for i in $(seq 30); do pgrep -f 'linuxsteamrt64/hlvr' > /dev/null || break; sleep 1; done
	pkill -9 -f "[l]inuxsteamrt64/hlvr"; sleep 2
}
case $1 in
setup)
	pgrep -x steam > /dev/null && { echo "steam is running, stop it first"; exit 1; }
	launch_opts 'PRESSURE_VESSEL_IMPORT_OPENXR_1_RUNTIMES=1 %command% -condebug -vconsole +vr_fidelity_level_auto 0 +vr_fidelity_level 3'
	;;
run)
	L=$2; shift 2
	quit_alyx
	stop_server
	envs=(--env=WIVRN_FEEDBACK_DUMP=$O/$L.fb --env=WIVRN_M2P_TRACE=$O/$L.m2p --env=XRT_LOG=info)
	for e in "$@"; do envs+=(--env=$e); done
	systemd-run --user --unit=wivrn-m2p --collect -p StandardOutput=file:$O/$L.server.log -p StandardError=inherit \
		flatpak run --devel --filesystem=home "${envs[@]}" --command=$M/build/server/wivrn-server $APP
	sleep 3
	echo "server started; connect the Quest, then: $0 game $L"
	;;
game)
	L=$2
	if ! pgrep -x steam > /dev/null; then
		systemd-run --user --unit=steam-m2p --collect steam -silent
		for i in $(seq 60); do [ -S "$HOME/.steam/steam.pipe" ] || [ -e "$HOME/.steam/steam.pipe" ] && break; sleep 2; done
		sleep 15
	fi
	[ -f "$G/console.log" ] && mv "$G/console.log" "$G/console.prev.log"
	steam steam://rungameid/546560 > /dev/null 2>&1 &
	for i in $(seq 120); do grep -q 'Map: "startup"' "$G/console.log" 2>/dev/null && break; sleep 2; done
	grep -q 'Map: "startup"' "$G/console.log" 2>/dev/null || { echo "startup map not reached"; exit 1; }
	sleep 5
	python3 $M/vcq.py 'load s6/steamvr_quit' > /dev/null
	for i in $(seq 90); do grep -q "paused the game" "$G/console.log" 2>/dev/null && break; sleep 2; done
	for i in 1 2 3; do sleep 3; python3 $M/vcq.py unpause | grep -i pause; done
	python3 $M/vcq.py 'vr_fidelity_level_auto 0' 'vr_fidelity_level 3' > /dev/null
	sleep 20
	m0=$(mono)
	nvidia-smi --query-gpu=utilization.gpu,utilization.encoder,clocks.gr --format=csv,noheader -l 2 > $O/$L.gpu 2>&1 &
	np=$!
	sleep 30
	m1=$(mono)
	kill $np
	echo "$m0 $m1" > $O/$L.window
	for f in $O/$L-*.h265; do [ -f "$f" ] && cp "$f" "$f.rec"; done
	for e in m2p fb; do cp $O/$L.$e $O/$L.$e.rec; done
	grep -E "latency|fps|Mbit" $O/$L.server.log | tail -12 > $O/$L.wivrn
	echo "recorded $L"
	;;
quit)
	quit_alyx
	;;
teardown)
	quit_alyx
	stop_server
	steam -shutdown > /dev/null 2>&1; for i in $(seq 30); do pgrep -x steam > /dev/null || break; sleep 2; done
	pkill -x steam; sleep 2
	launch_opts ''
	rm -f $HOME/.config/openxr/1/active_runtime.json $HOME/.config/openvr/openvrpaths.vrpath
	ls $HOME/.var/app/$APP/config/wivrn/config.json 2>/dev/null && echo "WARNING config.json present"
	;;
esac
