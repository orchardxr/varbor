#!/bin/sh
# EXTRA_DLLPATH=<dir with x86_64-windows/ and x86_64-unix/> puts our builtins first. Runs a Windows test exe under NotProton's CrossOver runner (Rosetta, x86_64-unix) with DXMT, in a throwaway
# prefix cloned from NotProton's template. Usage: [RUNNER=<build>] run-wine.sh <exe> [args...]
# Never touches the game prefixes or the runner.
set -eu
exe=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
shift
build=${RUNNER:-27.0.0.41073-fex}
here=$(cd "$(dirname "$0")" && pwd)
np="$HOME/Library/Application Support/notproton"
template="$HOME/Library/Application Support/Steam/steamapps/compatdata/notproton-template/crossover-$build-x86_64-unix/pfx"
prefix=${PREFIX:-$here/build/pfx}
if [ ! -d "$prefix" ]; then
  mkdir -p "$(dirname "$prefix")"
  cp -cR "$template" "$prefix"
fi
CX_ROOT="$np/runners/crossover-$build/CrossOver"
wine_unix="$CX_ROOT/lib/wine/x86_64-unix"
WINESERVER="$CX_ROOT/bin/wineserver"
[ -x "$WINESERVER" ] || WINESERVER="$CX_ROOT/bin/wineserver-x86"
export CX_ROOT WINESERVER WINELOADER="$wine_unix/wine" WINEPREFIX="$prefix"
export CX_HOME="$HOME/Library/Application Support/CrossOver"
export WINEDLLPATH="${EXTRA_DLLPATH:+$EXTRA_DLLPATH:}$CX_ROOT/lib/wine/x86_64-windows:$wine_unix"
export CX_GRAPHICS_BACKEND=${CX_GRAPHICS_BACKEND:-dxmt}
export WINEDEBUG=${WINEDEBUG:--all}
export DXMT_LOG_LEVEL=${DXMT_LOG_LEVEL:-info}
cp "$exe" "$prefix/drive_c/"
# Wine only looks for a builtin in WINEDLLPATH once it finds a placeholder in system32 (how Proton installs
# wineopenxr.dll and NotProton installs lsteamclient.dll).
if [ -n "${EXTRA_DLLPATH:-}" ]; then
  for dll in "$EXTRA_DLLPATH"/x86_64-windows/*.dll; do cp "$dll" "$prefix/drive_c/windows/system32/"; done
fi
cd "$prefix/drive_c"
status=0
"$WINELOADER" "C:\\$(basename "$exe")" "$@" || status=$?
"$WINESERVER" -k 2>/dev/null || true
exit $status
