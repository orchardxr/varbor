#!/usr/bin/env bash
# Roll back scripts/install-vr-546560.sh and the Alyx launch setup (docs/m3-opencomposite.md).
#   scripts/uninstall-vr-546560.sh           quit Steam first if the launch options are to be removed too
# - removes wineopenxr.{dll,json} from system32, the Khronos\OpenXR key, C:\OpenComposite, C:\macvr, the openvr
#   vrpath dir and the OpenComposite logs in %LOCALAPPDATA%
# - removes the 546560 LaunchOptions line from localconfig.vdf (only while Steam is not running; the file from
#   before the change is build/backup/546560/localconfig.vdf)
# - cleans up the old workarounds for the standalone client: IPC_IGNORE_VERSION, the monado_comp_ipc -> wivrn link
# The registry files from before the install are in build/backup/546560/<time>/ (full copies, a last resort).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
appid=546560
prefix="$HOME/Library/Application Support/Steam/steamapps/compatdata/$appid/pfx"
CX_ROOT="$HOME/Library/Application Support/notproton/runners/crossover-$(head -1 "$prefix/../notproton-build")/CrossOver"
export WINEPREFIX="$prefix" WINELOADER="$CX_ROOT/lib/wine/x86_64-unix/wine" WINEDEBUG=-all
export WINESERVER="$CX_ROOT/bin/wineserver-x86"
pgrep -f "compatdata/$appid" > /dev/null && { echo "something runs in the prefix, quit the game first" >&2; exit 1; }

rm -f "$prefix/drive_c/windows/system32/wineopenxr.dll" "$prefix/drive_c/windows/system32/wineopenxr.json"
"$WINELOADER" reg delete 'HKLM\SOFTWARE\Khronos\OpenXR' /f > /dev/null 2>&1 || true
"$WINESERVER" -w
rm -rf "$prefix/drive_c/OpenComposite" "$prefix/drive_c/macvr"
for user in "$prefix"/drive_c/users/*; do
	[[ -d "$user" && ! -L "$user" ]] || continue
	rm -rf "$user/AppData/Local/openvr" "$user/AppData/Local/OpenComposite"
done

for cfg in "$HOME/Library/Application Support/Steam/userdata"/*/config/localconfig.vdf; do
	grep -q '"LaunchOptions".*drive_c/macvr' "$cfg" || continue
	if pgrep -x steam_osx > /dev/null; then
		echo "Steam is running: quit it and re-run to remove the 546560 launch options" >&2
	else
		uid=$(basename "$(dirname "$(dirname "$cfg")")")
		cp -p "$cfg" "$ROOT/build/backup/$appid/localconfig-$uid-before-uninstall.vdf"
		grep -v '"LaunchOptions".*drive_c/macvr' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
		echo "launch options removed ($uid)"
	fi
done
launchctl unsetenv IPC_IGNORE_VERSION || true
"$ROOT/scripts/wivrn-ipc-link.sh" --remove
echo "done"
