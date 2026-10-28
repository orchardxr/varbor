#!/usr/bin/env bash
# Build MacVR.app (menu-bar app + `macvr` CLI, app/) with its payload, ad-hoc signed (docs/macvr-app.md).
#   scripts/build-app.sh [--test]       --test also runs the unit tests (swift test)
# Payload: build/bridge/root (scripts/build-bridge.sh bridge: universal .so + client), build/m3/oc/bin (scripts/build-opencomposite.sh),
# $WIVRN_BUILD_DIR/server + its libopenxr_wivrn.dylib (default build/wivrn-next, scripts/build-wivrn.sh).
# Helpers: macvr (CLI), macvr-broker + macvr-webhelper (web overlays, docs/web-overlays.md). Output: build/app/MacVR.app.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/build/app"
WIVRN="${WIVRN_BUILD_DIR:-$ROOT/build/wivrn-next}"
BRIDGE="$ROOT/build/bridge/root"
OC="$ROOT/build/m3/oc/bin"
mkdir -p "$OUT" "$ROOT/build/logs"

cmp -s "$BRIDGE/x86_64-unix/ipc-stamp" "$WIVRN/server/ipc-stamp" \
	|| { echo "ipc-stamp of $BRIDGE and $WIVRN/server differ: rebuild the clients (build-wivrn.sh --client-x86_64, --client-arm64)" >&2; exit 1; }
for f in wineopenxr.so libopenxr_monado.dylib; do
	[[ "$(lipo -archs "$BRIDGE/x86_64-unix/$f")" == "x86_64 arm64" ]] \
		|| { echo "$BRIDGE/x86_64-unix/$f is not universal (x86_64 arm64)" >&2; exit 1; }
done

echo "==> swift build"
# SwiftPM's linker call stamps the deployment target as the SDK version; macOS only gives apps built against the
# current SDK its current look (Liquid Glass), so pass the real SDK version.
minos="$(sed -n 's/.*\.macOS(\.v\([0-9]*\)).*/\1.0/p' "$ROOT/app/Package.swift")"
sdk=(-Xlinker -platform_version -Xlinker macos -Xlinker "$minos" -Xlinker "$(xcrun --show-sdk-version)")
(cd "$ROOT/app" && swift build -c release "${sdk[@]}" --product macvr && swift build -c release "${sdk[@]}" --product MacVRApp \
	&& swift build -c release "${sdk[@]}" --product macvr-broker && swift build -c release "${sdk[@]}" --product macvr-webhelper) \
	> "$ROOT/build/logs/app-build.log" 2>&1 || { grep -E "error" "$ROOT/build/logs/app-build.log" | head -20; exit 1; }
[[ "${1:-}" == --test ]] && (cd "$ROOT/app" && swift test 2>&1 | tail -3)
BIN="$(cd "$ROOT/app" && swift build -c release "${sdk[@]}" --show-bin-path)"

app="$OUT/MacVR.app"
rm -rf "$app.new"
c="$app.new/Contents"
p="$c/Resources/payload"
mkdir -p "$c/MacOS" "$c/Helpers" "$p/bridge/x86_64-windows" "$p/bridge/x86_64-unix" "$p/opencomposite/bin" "$p/server"
cp "$BIN/MacVRApp" "$c/MacOS/MacVR"
cp "$BIN/macvr" "$c/Helpers/macvr"
cp "$BIN/macvr-broker" "$BIN/macvr-webhelper" "$c/Helpers/"
cp "$ROOT/app/Resources/Info.plist" "$c/Info.plist"
cp "$ROOT/app/Resources/icon/AppIcon.icns" "$ROOT/app/Resources/icon/MenuBarIconTemplate.png" \
	"$ROOT/app/Resources/icon/MenuBarIconTemplate@2x.png" "$c/Resources/"

cp "$BRIDGE/x86_64-windows/wineopenxr.dll" "$BRIDGE/x86_64-windows/macvrreg.dll" "$p/bridge/x86_64-windows/"
cp "$BRIDGE/x86_64-unix/wineopenxr.so" "$BRIDGE/x86_64-unix/libopenxr_monado.dylib" "$BRIDGE/x86_64-unix/ipc-stamp" \
	"$p/bridge/x86_64-unix/"
# Named by path relative to this file: Wine pairs it with the runner's copy (same name) and its unixlib.
cat > "$p/bridge/wineopenxr.json" <<'JSON'
{
    "file_format_version": "1.0.0",
    "runtime": {
        "name": "MacVR wineopenxr (WiVRn)",
        "library_path": "x86_64-windows\\wineopenxr.dll"
    }
}
JSON
cp "$OC/vrclient_x64.dll" "$OC/version.txt" "$p/opencomposite/bin/"
printf 'initUsingVulkan=false\n' > "$p/opencomposite/bin/opencomposite.ini"
cp "$WIVRN/server/wivrn-server" "$WIVRN/server/ipc-stamp" "$p/server/"
# The web helper's OpenXR client (overlay session): same build as the server, so the same ipc-stamp.
cp "$(find "$WIVRN/_deps/monado-build/src/xrt/targets/openxr" -name libopenxr_wivrn.dylib | head -1)" "$p/server/"
cat > "$p/manifest.json" <<JSON
{
    "built": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "ipc_stamp": "$(head -1 "$WIVRN/server/ipc-stamp")",
    "server": "$WIVRN/server/wivrn-server",
    "opencomposite_patches": "$(cd "$ROOT/patches/opencomposite" && ls *.patch | tr '\n' ' ')"
}
JSON

codesign --force -s - "$p/server/wivrn-server" "$p/server/libopenxr_wivrn.dylib" "$c/Helpers/macvr" \
	"$c/Helpers/macvr-broker" "$c/Helpers/macvr-webhelper"
codesign --force -s - "$app.new"
rm -rf "$app"
mv "$app.new" "$app"
echo "==> done: $app (CLI: $app/Contents/Helpers/macvr)"
