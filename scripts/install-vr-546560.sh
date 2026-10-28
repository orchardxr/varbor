#!/usr/bin/env bash
# Install the macvr VR stack into Half-Life: Alyx's NotProton prefix (docs/m3-opencomposite.md, "Half-Life: Alyx").
#   scripts/install-vr-546560.sh            Steam must not be running the game
# Backs up the registry files to build/backup/546560/<time>/ first. Rollback: scripts/uninstall-vr-546560.sh.
# Installs: wineopenxr.dll placeholder + wineopenxr.json in system32, HKLM\SOFTWARE\Khronos\OpenXR\1\ActiveRuntime,
# C:\OpenComposite (bin, config, logs, opencomposite.ini) and %LOCALAPPDATA%\openvr\openvrpaths.vrpath,
# and C:\macvr\x86_64-{windows,unix} (bridge + WiVRn's x86_64 Monado client + its ipc-stamp), found through
# WINEDLLPATH (Steam launch option).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
appid=546560
prefix="$HOME/Library/Application Support/Steam/steamapps/compatdata/$appid/pfx"
[[ -f "$prefix/system.reg" ]] || { echo "no prefix $prefix" >&2; exit 1; }
CX_ROOT="$HOME/Library/Application Support/notproton/runners/crossover-$(head -1 "$prefix/../notproton-build")/CrossOver"
export WINEPREFIX="$prefix" WINELOADER="$CX_ROOT/lib/wine/x86_64-unix/wine" WINEDEBUG=-all
export WINESERVER="$CX_ROOT/bin/wineserver-x86"
pgrep -f "compatdata/$appid" > /dev/null && { echo "something runs in the prefix, quit the game first" >&2; exit 1; }

backup="$ROOT/build/backup/$appid/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$backup"
cp -p "$prefix"/system.reg "$prefix"/user.reg "$prefix"/userdef.reg "$backup/"
[[ -d "$prefix/drive_c/macvr" ]] && cp -pR "$prefix/drive_c/macvr" "$backup/macvr"
echo "backup: $backup"

sys32="$prefix/drive_c/windows/system32"
cp "$ROOT/build/bridge/root/x86_64-windows/wineopenxr.dll" "$ROOT/build/bridge/root/wineopenxr.json" "$sys32/"
# The builtin + unixlib + Monado client live in the prefix (C:\macvr), on WINEDLLPATH via the launch option. Not in
# ~/Documents: the game runs as Steam.app for TCC, which has no Documents access.
mkdir -p "$prefix/drive_c/macvr/x86_64-windows" "$prefix/drive_c/macvr/x86_64-unix"
cp "$ROOT/build/bridge/root/x86_64-windows/wineopenxr.dll" "$prefix/drive_c/macvr/x86_64-windows/"
cp "$ROOT/build/bridge/root/x86_64-unix/wineopenxr.so" "$ROOT/build/bridge/root/x86_64-unix/libopenxr_monado.dylib" \
	"$ROOT/build/bridge/root/x86_64-unix/ipc-stamp" "$prefix/drive_c/macvr/x86_64-unix/"
"$WINELOADER" reg add 'HKLM\SOFTWARE\Khronos\OpenXR\1' /v ActiveRuntime /t REG_SZ \
	/d 'C:\windows\system32\wineopenxr.json' /f > /dev/null 2>&1
"$WINESERVER" -w

chmod u+w "$prefix"/drive_c/users/steamuser/AppData/Local/openvr/openvrpaths.vrpath 2>/dev/null || true
"$ROOT/scripts/install-opencomposite.sh" "$prefix"
printf 'initUsingVulkan=false\n' > "$prefix/drive_c/OpenComposite/bin/opencomposite.ini"
# NotProton's steam.exe (Proton's setup_vrpaths) deletes this file on every launch when there is no host vrpath, and
# replaces it with runtime C:\vrclient when there is one. Wine refuses to delete or overwrite a read-only file.
chmod 444 "$prefix"/drive_c/users/steamuser/AppData/Local/openvr/openvrpaths.vrpath
grep -A2 'Khronos\\\\OpenXR\\\\1\]' "$prefix/system.reg"
