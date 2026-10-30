#!/usr/bin/env bash
# Build OpenComposite's Win64 vrclient_x64.dll with llvm-mingw (docs/m3-opencomposite.md).
#   scripts/patches.sh apply opencomposite && scripts/build-opencomposite.sh
# Output: build/m3/oc/bin/vrclient_x64.dll. Needs build/bridge/vulkan (scripts/build-bridge.sh openxr-sdk-win).
#
#   scripts/build-opencomposite.sh --macos
# Native macOS OpenComposite (Metal compositor, XR_KHR_metal_enable): a universal (arm64 + x86_64)
# build/oc-macos/vrclient.dylib next to a universal libopenxr_loader.1.dylib (openxr-sdk 1.1.65, found through
# @loader_path), build/oc-macos/runtime (the <runtime>/bin/osx64 layout OpenVR loads), and the arm64 test app
# build/oc-macos/tests/ovr_metal (tests/openvr-metal).
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/ccache.sh"
OUT="$ROOT/build/m3/oc"
LOGS="$ROOT/build/logs"
mkdir -p "$LOGS"

build_macos() {
	local out="$ROOT/build/oc-macos" oc_rev arch
	oc_rev="$(git -C "$ROOT/third_party/opencomposite" rev-parse --short HEAD)"
	echo "==> configure openxr-loader (universal)"
	cmake -S "$ROOT/third_party/openxr-sdk" -B "$out/openxr-loader" -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo \
		-DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" -DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew -DDYNAMIC_LOADER=ON \
		-DBUILD_TESTS=OFF -DBUILD_API_LAYERS=OFF -DBUILD_CONFORMANCE_TESTS=OFF -DBUILD_WITH_SYSTEM_JSONCPP=OFF \
		> "$LOGS/oc-macos-loader-configure.log" 2>&1 || { tail -30 "$LOGS/oc-macos-loader-configure.log"; exit 1; }
	echo "==> build openxr-loader"
	ninja -C "$out/openxr-loader" openxr_loader > "$LOGS/oc-macos-loader-build.log" 2>&1 \
		|| { grep -E "error|FAILED" "$LOGS/oc-macos-loader-build.log" | head -30; exit 1; }

	# One build per architecture: CMake's precompiled headers don't do multi-arch builds.
	for arch in arm64 x86_64; do
		echo "==> configure opencomposite ($arch)"
		cmake -S "$ROOT/third_party/opencomposite" -B "$out/$arch" -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo \
			-DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew -DOC_VERSION="$oc_rev macvr-macos" \
			-DOC_OPENXR_INCLUDE_DIRS="$out/openxr-loader/include;$ROOT/third_party/openxr-sdk/include" \
			-DOC_OPENXR_LIBRARY="$out/openxr-loader/src/loader/libopenxr_loader.dylib" \
			-DCMAKE_SHARED_LINKER_FLAGS="-Wl,-rpath,@loader_path" \
			> "$LOGS/oc-macos-$arch-configure.log" 2>&1 || { tail -30 "$LOGS/oc-macos-$arch-configure.log"; exit 1; }
		echo "==> build opencomposite ($arch)"
		ninja -C "$out/$arch" ${NINJA_FLAGS:-} > "$LOGS/oc-macos-$arch-build.log" 2>&1 \
			|| { grep -E "error|FAILED" "$LOGS/oc-macos-$arch-build.log" | head -30; exit 1; }
	done
	lipo -create -output "$out/vrclient.dylib" "$out/arm64/bin/osx64/vrclient.dylib" "$out/x86_64/bin/osx64/vrclient.dylib"
	cp "$out"/openxr-loader/src/loader/libopenxr_loader*.dylib "$out/"
	lipo -info "$out/vrclient.dylib"
	otool -L "$out/vrclient.dylib" | tail -n +2

	mkdir -p "$out/runtime/bin/osx64" "$out/tests"
	cp "$out"/vrclient.dylib "$out"/libopenxr_loader*.dylib "$out/runtime/bin/osx64/"
	echo "==> build ovr_metal"
	clang++ -std=c++17 -fobjc-arc -O1 -g -Wall -arch arm64 -I"$ROOT/third_party/openvr/headers" \
		-o "$out/tests/ovr_metal" "$ROOT/tests/openvr-metal/ovr_metal.mm" -framework Metal -framework Foundation
	echo "==> done: $out/vrclient.dylib"
}

if [[ "${1:-}" == --macos ]]; then
	build_macos
	exit 0
fi
source "$ROOT/scripts/lib/detect.sh"
LLVM_MINGW=$(llvm_mingw)
export LLVM_MINGW
[[ -f "$ROOT/build/bridge/vulkan/libvulkan-1.a" ]] || "$ROOT/scripts/build-bridge.sh" openxr-sdk-win

# OpenComposite's sources test WIN32 (MSVC defines it, mingw in strict -std=c++20 doesn't); atlbase.h is our CComPtr.
mingw="$ROOT/bridge/opencomposite/mingw"
flags="-DWIN32 -D_WIN32_WINNT=0x0A00 -isystem $mingw -include $mingw/oc_mingw_compat.h"
oc_rev="$(git -C "$ROOT/third_party/opencomposite" rev-parse --short HEAD)"
echo "==> configure opencomposite"
cmake -S "$ROOT/third_party/opencomposite" -B "$OUT" -G Ninja \
	-DCMAKE_TOOLCHAIN_FILE="$ROOT/bridge/cmake/llvm-mingw-x86_64.cmake" -DCMAKE_BUILD_TYPE=RelWithDebInfo \
	-DOC_VULKAN_INCLUDE_DIR="$ROOT/build/bridge/vulkan/include" -DOC_VULKAN_LIBRARY="$ROOT/build/bridge/vulkan/libvulkan-1.a" \
	-DOC_VERSION="$oc_rev macvr-mingw" -DCMAKE_C_FLAGS="$flags" -DCMAKE_CXX_FLAGS="$flags" \
	-DCMAKE_CXX_STANDARD_LIBRARIES="-lshlwapi -ld3d11 -ldxgi -ld3dcompiler -lole32" -DCMAKE_SHARED_LINKER_FLAGS=-static \
	> "$LOGS/m3-oc-configure.log" 2>&1 || { tail -30 "$LOGS/m3-oc-configure.log"; exit 1; }
echo "==> build opencomposite"
ninja -C "$OUT" ${NINJA_FLAGS:-} > "$LOGS/m3-oc-build.log" 2>&1 || { grep -E "error|FAILED" "$LOGS/m3-oc-build.log" | head -30; exit 1; }
ls -l "$OUT/bin/vrclient_x64.dll"

# OpenVR test app against Valve's openvr_api.dll (third_party/openvr, v2.15.6: the interface versions current Half-Life: Alyx uses).
OVR="$ROOT/third_party/openvr"
[[ -f "$OVR/headers/openvr.h" ]] || git -C "$ROOT" submodule update --init --depth 1 third_party/openvr
mkdir -p "$ROOT/build/m3/tests"
echo "==> build ovr_d3d11_test.exe"
"$LLVM_MINGW/bin/x86_64-w64-mingw32-clang++" -std=c++17 -O1 -g -Wall -I"$OVR/headers" \
	-o "$ROOT/build/m3/tests/ovr_d3d11_test.exe" "$ROOT/bridge/tests/ovr_d3d11_test.cpp" \
	"$OVR/lib/win64/openvr_api.lib" -ld3d11 -static
cp "$OVR/bin/win64/openvr_api.dll" "$ROOT/build/m3/tests/"
echo "==> build ovr_vulkan_test.exe"
"$LLVM_MINGW/bin/x86_64-w64-mingw32-clang++" -std=c++17 -O1 -g -Wall -I"$ROOT/build/bridge/vulkan/include" -I"$OVR/headers" \
	-o "$ROOT/build/m3/tests/ovr_vulkan_test.exe" "$ROOT/bridge/tests/ovr_vulkan_test.cpp" \
	"$OVR/lib/win64/openvr_api.lib" "$ROOT/build/bridge/vulkan/libvulkan-1.a" -static
