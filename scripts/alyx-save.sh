#!/bin/zsh
# alyx-save.sh [save] : (re)start Half-Life: Alyx through Steam, load a save (default s6/steamvr_quit) and unpause.
# Needs `-condebug -vconsole` in Alyx's Steam launch options and a running WiVRn server.
set -u
SAVE=${1:-s6/steamvr_quit}
G="$HOME/Library/Application Support/Steam/steamapps/common/Half-Life Alyx/game/hlvr"
VC=${0:A:h}/../tools/vconsole.py

if pgrep -qf 'hlvr.exe'; then
	osascript -e 'quit app "Half-Life Alyx"' >/dev/null 2>&1
	while pgrep -qf 'hlvr.exe'; do sleep 1; done
	sleep 3
fi
[[ -f "$G/console.log" ]] && mv "$G/console.log" "$G/console.prev.log"
open "steam://rungameid/546560"
for i in {1..120}; do
	grep -q 'Map: "startup"' "$G/console.log" 2>/dev/null && break
	sleep 2
done
grep -q 'Map: "startup"' "$G/console.log" 2>/dev/null || { echo "startup map not reached"; exit 1; }
sleep 5
python3 $VC "load $SAVE" >/dev/null
for i in {1..90}; do
	grep -q "paused the game" "$G/console.log" 2>/dev/null && break
	sleep 2
done
for i in {1..3}; do
	sleep 3
	python3 $VC unpause | grep -i pause
done
echo "loaded $SAVE"
