#!/usr/bin/env bash
# Scratch tree for MacVR tests (docs/macvr-app.md "Testing"): APFS clones of real prefixes, a template and a runner
# under ~/Library/Application Support/macvr-test/app, plus a fake Steam library. Prints the env for the CLI.
#   FLAT_APPID=<appid of an installed non-VR game> app/Tests/scratch.sh setup | env | check-reg <prefix dir> | clean
set -euo pipefail
S="$HOME/Library/Application Support/Steam"
T="$HOME/Library/Application Support/macvr-test/app"
RUNNER=crossover-27.0.0.41073-fex
TEMPLATE=crossover-27.0.0.41073-fex-x86_64-unix

case "${1:-}" in
	setup)
		flat="${FLAT_APPID:?set FLAT_APPID to an installed non-VR game}"
		rm -rf "$T"
		mkdir -p "$T/Steam/steamapps/compatdata/notproton-template" "$T/Steam/steamapps/common/Half-Life Alyx/game/bin/win64" \
			"$T/runners"
		cp -cR "$S/steamapps/compatdata/546560" "$T/Steam/steamapps/compatdata/546560"
		cp -cR "$S/steamapps/compatdata/$flat" "$T/Steam/steamapps/compatdata/$flat"
		cp -cR "$S/steamapps/compatdata/notproton-template/$TEMPLATE" "$T/Steam/steamapps/compatdata/notproton-template/"
		cp "$S/steamapps/appmanifest_546560.acf" "$S/steamapps/appmanifest_$flat.acf" "$T/Steam/steamapps/"
		touch "$T/Steam/steamapps/common/Half-Life Alyx/game/bin/win64/openvr_api.dll"
		for u in "$S"/userdata/*/config/localconfig.vdf; do
			d="$T/Steam/userdata/$(basename "$(dirname "$(dirname "$u")")")/config"
			mkdir -p "$d" && cp "$u" "$d/"
		done
		printf '"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"%s"\n\t}\n}\n' "$T/Steam" > "$T/Steam/steamapps/libraryfolders.vdf"
		cp -cR "$HOME/Library/Application Support/notproton/runners/$RUNNER" "$T/runners/"
		echo "scratch tree: $T" ;;
	env)
		echo "export MACVR_SUPPORT='${MACVR_SUPPORT:-$T/macvr}' MACVR_STEAM_ROOT='$T/Steam' MACVR_RUNNERS='$T/runners' MACVR_LOG_DIR='$T/logs' MACVR_NO_SYSTEM=1" ;;
	check-reg)
		# Wine itself must read our values back (validates the file format)
		pfx="$2/pfx"
		cx="$T/runners/$RUNNER/CrossOver"
		export WINEPREFIX="$pfx" WINEDEBUG=-all WINESERVER="$cx/bin/wineserver-x86" WINELOADER="$cx/lib/wine/x86_64-unix/wine" WINEDLLPATH="$cx/lib/wine/x86_64-windows:$cx/lib/wine/x86_64-unix"
		wine="$cx/lib/wine/x86_64-unix/wine"
		"$wine" reg query 'HKLM\SOFTWARE\Khronos\OpenXR\1' /v ActiveRuntime
		"$wine" reg query 'HKLM\System\CurrentControlSet\Control\Session Manager\Environment' /v VR_OVERRIDE
		"$wine" cmd /c 'echo VR_OVERRIDE=%VR_OVERRIDE% & echo VR_CONFIG_PATH=%VR_CONFIG_PATH% & echo VR_LOG_PATH=%VR_LOG_PATH%'
		"$cx/bin/wineserver-x86" -w ;;
	clean) rm -rf "$T" ;;
	*) sed -n '2,5p' "$0" >&2; exit 2 ;;
esac
