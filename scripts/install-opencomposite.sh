#!/usr/bin/env bash
# Install OpenComposite as the OpenVR runtime of a Wine prefix (docs/m3-opencomposite.md).
#   scripts/install-opencomposite.sh <prefix>    (default build/m3/pfx)
# Copies build/m3/oc/bin to C:\OpenComposite\bin and writes %LOCALAPPDATA%\openvr\openvrpaths.vrpath for every
# user profile in the prefix. The OpenXR side (wineopenxr + ActiveRuntime) is installed by scripts/run-bridge.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
prefix="${1:-$ROOT/build/m3/pfx}"
[[ -d "$prefix/drive_c" ]] || { echo "not a prefix: $prefix" >&2; exit 1; }
oc="$prefix/drive_c/OpenComposite"
mkdir -p "$oc/bin" "$oc/config" "$oc/logs"
cp "$ROOT/build/m3/oc/bin/vrclient_x64.dll" "$ROOT/build/m3/oc/bin/version.txt" "$oc/bin/"
for user in "$prefix"/drive_c/users/*; do
	[[ -d "$user" && ! -L "$user" && "$(basename "$user")" != Public ]] || continue
	mkdir -p "$user/AppData/Local/openvr"
	cat > "$user/AppData/Local/openvr/openvrpaths.vrpath" <<'JSON'
{
	"config": [ "C:\\OpenComposite\\config" ],
	"external_drivers": null,
	"jsonid": "vrpathreg",
	"log": [ "C:\\OpenComposite\\logs" ],
	"runtime": [ "C:\\OpenComposite" ],
	"version": 1
}
JSON
	echo "wrote ${user#"$prefix"/}/AppData/Local/openvr/openvrpaths.vrpath"
done
