#!/usr/bin/env bash
# Build VarboR.app (window app and the `varbor` CLI, app/) with the bridge payload, ad-hoc signed
# (docs/varbor-app.md).
#   scripts/build-app.sh [--test]       --test also runs the unit tests (swift test)
# Payload: build/bridge/root (scripts/build-bridge.sh bridge) and build/vrclient/root (scripts/build-bridge.sh vrclient).
# Output: build/app/VarboR.app.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/build/app"
BRIDGE="$ROOT/build/bridge/root"
VRCLIENT="$ROOT/build/vrclient/root"
mkdir -p "$OUT" "$ROOT/build/logs"

for f in "$BRIDGE/x86_64-unix/wineopenxr.so" "$VRCLIENT/x86_64-unix/vrclient_x64.so"; do
	[[ "$(lipo -archs "$f")" == "x86_64 arm64" ]] || { echo "$f is not universal (x86_64 arm64)" >&2; exit 1; }
done

echo "==> swift build"
# SwiftPM's linker call stamps the deployment target as the SDK version; macOS only gives apps built against the
# current SDK its current look (Liquid Glass), so pass the real SDK version.
minos="$(sed -n 's/.*\.macOS(\.v\([0-9]*\)).*/\1.0/p' "$ROOT/app/Package.swift")"
sdk=(-Xlinker -platform_version -Xlinker macos -Xlinker "$minos" -Xlinker "$(xcrun --show-sdk-version)")
(cd "$ROOT/app" && swift build -c release "${sdk[@]}" --product varbor && swift build -c release "${sdk[@]}" --product VarborApp) \
	> "$ROOT/build/logs/app-build.log" 2>&1 || { grep -E "error" "$ROOT/build/logs/app-build.log" | head -20; exit 1; }
if [[ "${1:-}" == --test ]]; then
	(cd "$ROOT/app" && swift test > "$ROOT/build/logs/app-test.log" 2>&1) || { grep -E "error|failed" "$ROOT/build/logs/app-test.log" | head -30; exit 1; }
	grep -E "Executed [0-9]+ tests" "$ROOT/build/logs/app-test.log" | tail -1
fi
BIN="$(cd "$ROOT/app" && swift build -c release "${sdk[@]}" --show-bin-path)"

app="$OUT/VarboR.app"
rm -rf "$app.new"
c="$app.new/Contents"
p="$c/Resources/payload"
mkdir -p "$c/MacOS" "$c/Helpers" "$p/bridge/x86_64-windows" "$p/bridge/x86_64-unix"
cp "$BIN/VarborApp" "$c/MacOS/VarboR"
cp "$BIN/varbor" "$c/Helpers/varbor"
cp "$ROOT/app/Resources/Info.plist" "$c/Info.plist"
cp "$ROOT/app/Resources/icon/AppIcon.icns" "$c/Resources/"

cp "$BRIDGE/x86_64-windows/wineopenxr.dll" "$BRIDGE/x86_64-windows/varborreg.dll" \
	"$VRCLIENT/x86_64-windows/vrclient_x64.dll" "$p/bridge/x86_64-windows/"
cp "$BRIDGE/x86_64-unix/wineopenxr.so" "$VRCLIENT/x86_64-unix/vrclient_x64.so" "$p/bridge/x86_64-unix/"
# Named by path relative to this file: Wine pairs it with the runner's copy (same name) and its unixlib.
cat > "$p/bridge/wineopenxr.json" <<'JSON'
{
    "file_format_version": "1.0.0",
    "runtime": {
        "name": "VarboR wineopenxr",
        "library_path": "x86_64-windows\\wineopenxr.dll"
    }
}
JSON
cat > "$p/manifest.json" <<JSON
{
    "built": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "commit": "$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
}
JSON

codesign --force -s - "$c/Helpers/varbor"
codesign --force -s - "$app.new"
rm -rf "$app"
mv "$app.new" "$app"
echo "==> done: $app (CLI: $app/Contents/Helpers/varbor)"
