#!/usr/bin/env bash
# Build the M2 Windows OpenXR bridge (docs/bridge-plan.md). Logs go to build/logs/.
#   scripts/build-bridge.sh [monado|monado-x86_64|monado-arm64|bridge|openxr-sdk-win]...   (default: all)
#
# monado          arm64 monado-service (null compositor) in build/bridge/monado
# monado-x86_64   standalone IPC client build/bridge/monado-x86_64/.../libopenxr_monado.dylib (no Vulkan loader) for
#                 the monado-service test rig (run-bridge.sh). The client the bridge ships (build/bridge/root) is the
#                 WiVRn one: scripts/build-wivrn.sh --client-x86_64 first.
# monado-arm64    the same for arm64 (FEX runners): build/bridge/monado-arm64 (WiVRn one: --client-arm64)
# bridge          wineopenxr.dll (llvm-mingw) + wineopenxr.so (x86_64-unix and aarch64-unix, each with its WiVRn
#                 client and ipc-stamp) in build/bridge/root, tests in build/bridge/tests
# vrclient        Proton's vrclient (vrclient/): vrclient_x64.dll (llvm-mingw) + universal vrclient_x64.so in
#                 build/vrclient/root, and the D3D11 OpenVR test (tests/openvr-d3d11) in build/vrclient/tests. Fetches
#                 Wine's headers (WINE_TAG, default wine-11.0, sparse) into build/vrclient/wine on first use.
# openxr-sdk-win  Windows hello_xr.exe with a static OpenXR loader (llvm-mingw) in build/bridge/openxr-sdk-win
#                 (needs the third_party/directxmath submodule)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/ccache.sh"
OUT="$ROOT/build/bridge"
LOGS="$ROOT/build/logs"
mkdir -p "$LOGS" "$OUT"

# Any llvm-mingw with x86_64 ucrt works (scripts/lib/detect.sh).
source "$ROOT/scripts/lib/detect.sh"
LLVM_MINGW=$(llvm_mingw)

cmake_build() {
	local name="$1" src="$2"
	shift 2
	echo "==> configure $name"
	cmake -S "$src" -B "$OUT/$name" -G Ninja "$@" > "$LOGS/bridge-$name-configure.log" 2>&1 \
		|| { tail -30 "$LOGS/bridge-$name-configure.log"; exit 1; }
	echo "==> build $name"
	ninja -C "$OUT/$name" ${NINJA_TARGET:-} > "$LOGS/bridge-$name-build.log" 2>&1 \
		|| { grep -E "error|FAILED" "$LOGS/bridge-$name-build.log" | head -30; exit 1; }
}

targets=("$@")
[[ ${#targets[@]} -gt 0 ]] || targets=(monado monado-x86_64 monado-arm64 openxr-sdk-win bridge)

for t in "${targets[@]}"; do
	case "$t" in
		monado)
			NINJA_TARGET=monado-service cmake_build monado "$ROOT/third_party/monado" \
				-C "$ROOT/cmake/monado-macos.cmake" -DXRT_FEATURE_SERVICE=ON ;;
		monado-x86_64)
			# -dead_strip_dylibs drops libvulkan: the bridge takes vkGetInstanceProcAddr from CrossOver's MoltenVK.
			NINJA_TARGET=openxr_monado cmake_build monado-x86_64 "$ROOT/third_party/monado" \
				-C "$ROOT/cmake/monado-macos.cmake" -DXRT_FEATURE_SERVICE=ON \
				-DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew \
				-DEigen3_DIR=/opt/homebrew/share/eigen3/cmake -DCMAKE_SHARED_LINKER_FLAGS=-Wl,-dead_strip_dylibs ;;
		monado-arm64)
			NINJA_TARGET=openxr_monado cmake_build monado-arm64 "$ROOT/third_party/monado" \
				-C "$ROOT/cmake/monado-macos.cmake" -DXRT_FEATURE_SERVICE=ON \
				-DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_SHARED_LINKER_FLAGS=-Wl,-dead_strip_dylibs ;;
		openxr-sdk-win)
			# Import library for Wine's vulkan-1.dll; the linker only keeps the entries hello_xr uses.
			mkdir -p "$OUT/vulkan/include"
			ln -sfn /usr/local/include/vulkan "$OUT/vulkan/include/vulkan"
			ln -sfn /usr/local/include/vk_video "$OUT/vulkan/include/vk_video"
			{ echo "LIBRARY vulkan-1.dll"; echo "EXPORTS"
			  grep -ho 'VKAPI_CALL vk[A-Za-z0-9]*(' /usr/local/include/vulkan/vulkan_core.h /usr/local/include/vulkan/vulkan_win32.h \
				| sed 's/VKAPI_CALL //; s/($//' | sort -u; } > "$OUT/vulkan/vulkan-1.def"
			"$LLVM_MINGW/bin/llvm-dlltool" -m i386:x86-64 -d "$OUT/vulkan/vulkan-1.def" -l "$OUT/vulkan/libvulkan-1.a"
			# hello_xr only builds its D3D11 plugin with MSVC upstream; DirectXMath comes from third_party/directxmath.
			LLVM_MINGW="$LLVM_MINGW" NINJA_TARGET=hello_xr cmake_build openxr-sdk-win "$ROOT/third_party/openxr-sdk" \
				-DCMAKE_TOOLCHAIN_FILE="$ROOT/bridge/cmake/llvm-mingw-x86_64.cmake" -DCMAKE_BUILD_TYPE=RelWithDebInfo \
				-DBUILD_TESTS=ON -DBUILD_CONFORMANCE_TESTS=OFF -DBUILD_API_LAYERS=OFF -DDYNAMIC_LOADER=OFF \
				-DBUILD_WITH_SYSTEM_JSONCPP=OFF -DVulkan_INCLUDE_DIR="$OUT/vulkan/include" \
				-DVulkan_LIBRARY="$OUT/vulkan/libvulkan-1.a" \
				-DCMAKE_CXX_FLAGS="-DXR_USE_GRAPHICS_API_D3D11 -isystem $ROOT/third_party/directxmath/Inc -include $ROOT/bridge/tests/mingw_compat.h" \
				-DCMAKE_DISABLE_FIND_PACKAGE_OpenGL=ON \
				-DCMAKE_CXX_STANDARD_LIBRARIES="-ld3d11 -ldxgi -ld3dcompiler -lole32" \
				-DCMAKE_EXE_LINKER_FLAGS=-static -DCMAKE_SHARED_LINKER_FLAGS=-static ;;
		bridge)
			echo "==> build bridge"
			make -C "$ROOT/bridge" B="$OUT" LLVM_MINGW="$LLVM_MINGW" > "$LOGS/bridge-make.log" 2>&1 \
				|| { grep -E "error|Error" "$LOGS/bridge-make.log" | head -30; exit 1; } ;;
		vrclient)
			wine_src="$OUT/../vrclient/wine"
			wine_tag="${WINE_TAG:-wine-11.0}"
			if [[ ! -f "$wine_src/include/wine/unixlib.h" || "$(cat "$wine_src/.macvr-tag" 2>/dev/null)" != "$wine_tag" ]]; then
				echo "==> fetch Wine headers ($wine_tag)"
				rm -rf "$wine_src"
				git clone -q --depth 1 --branch "$wine_tag" --filter=blob:none --sparse \
					https://gitlab.winehq.org/wine/wine.git "$wine_src"
				git -C "$wine_src" sparse-checkout set include dlls/winecrt0
				echo "$wine_tag" > "$wine_src/.macvr-tag"
			fi
			echo "==> build vrclient"
			make -C "$ROOT/vrclient" -j"$(sysctl -n hw.ncpu)" LLVM_MINGW="$LLVM_MINGW" > "$LOGS/vrclient-make.log" 2>&1 \
				|| { grep -E "error|Error" "$LOGS/vrclient-make.log" | head -30; exit 1; } ;;
		*) echo "unknown target $t" >&2; exit 2 ;;
	esac
done
echo "==> done"
