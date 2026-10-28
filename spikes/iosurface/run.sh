#!/bin/bash
# Builds and runs the IOSurface / MoltenVK / Mach-port spike non-interactively.
# Prints PASS/FAIL/XFAIL per case (INFO/BENCH lines are measurements) and exits non-zero on any FAIL.
set -u
cd "$(dirname "$0")"

HB_ICD=${HB_ICD:-/opt/homebrew/etc/vulkan/icd.d/MoltenVK_icd.json}     # MoltenVK 1.4.2, arm64 only
SDK_ICD=${SDK_ICD:-/usr/local/share/vulkan/icd.d/MoltenVK_icd.json}    # MoltenVK 1.2.11 (LunarG SDK), universal
export MVK_CONFIG_LOG_LEVEL=${MVK_CONFIG_LOG_LEVEL:-1}

LOGS=build/logs
make -s all || { echo "FAIL  build"; exit 1; }
rm -rf "$LOGS" && mkdir -p "$LOGS"

show() { grep -E '^(PASS|FAIL|XFAIL|INFO|BENCH|#)' "$1"; }

run() { # name, env..., cmd...
	local name=$1; shift
	echo "=== $name"
	env "$@" >"$LOGS/$name.log" 2>&1
	local st=$?
	show "$LOGS/$name.log"
	[ $st -eq 0 ] || echo "FAIL  $name exited with status $st (see $LOGS/$name.log)"
}

xproc() { # name, client-icd, client-cmd...
	local name=$1 cicd=$2; shift 2
	echo "=== $name"
	VK_DRIVER_FILES=$HB_ICD ./build/xproc_server --timeout 20000 >"$LOGS/$name-server.log" 2>&1 &
	local spid=$!
	for _ in $(seq 100); do grep -q READY "$LOGS/$name-server.log" 2>/dev/null && break; sleep 0.1; done
	VK_DRIVER_FILES=$cicd "$@" >"$LOGS/$name-client.log" 2>&1
	local cst=$?
	wait $spid
	local sst=$?
	show "$LOGS/$name-client.log"
	show "$LOGS/$name-server.log"
	[ $cst -eq 0 ] || echo "FAIL  $name client exited with status $cst"
	[ $sst -eq 0 ] || echo "FAIL  $name server exited with status $sst"
}

{
	run bootstrap ./build/bs_probe
	run formats-arm64-mvk1.4.2 VK_DRIVER_FILES="$HB_ICD" ./build/fmt_test
	run formats-x86_64-rosetta-mvk1.2.11 VK_DRIVER_FILES="$SDK_ICD" arch -x86_64 ./build/fmt_test_x86_64
	xproc xproc-arm64 "$HB_ICD" ./build/xproc_client --frames 600
	xproc xproc-x86_64-rosetta "$SDK_ICD" arch -x86_64 ./build/xproc_client_x86_64 --frames 600
} | tee "$LOGS/all.log"

pass=$(grep -c '^PASS' "$LOGS/all.log")
fail=$(grep -c '^FAIL' "$LOGS/all.log")
xfail=$(grep -c '^XFAIL' "$LOGS/all.log")
echo "=== summary: $pass PASS, $fail FAIL, $xfail XFAIL (expected failures, see RESULTS.md)"
[ "$fail" -eq 0 ]
