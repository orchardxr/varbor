#!/usr/bin/env bash
# Configure and build the WiVRn server (third_party/wivrn, patched) on macOS.
#   scripts/build-wivrn.sh [--snapshot] [ninja args...]     WIVRN_BUILD_DIR=... overrides build/wivrn
#   scripts/build-wivrn.sh --client-x86_64 [ninja args...]  x86_64 OpenXR client (libopenxr_wivrn) for the bridge,
#                                                           WIVRN_CLIENT_BUILD_DIR=... overrides build/wivrn-client-x86_64
#   scripts/build-wivrn.sh --client-arm64 [ninja args...]   the same for arm64 (FEX runners), build/wivrn-client-arm64
#   WIVRN_BUILD_TYPE=... overrides the CMake build type (default RelWithDebInfo; read at configure time)
#
# Monado comes from build/monado-snapshot, a copy of the staged (= patched) third_party/monado
# index, so a concurrent edit of the monado tree can't break this build. --snapshot refreshes it.
# The client is built from the same WiVRn tree and snapshot as the server (same git tag, socket wivrn/comp_ipc), so
# the IPC version check passes. Both write an ipc-stamp (scripts/ipc-stamp.sh): <build>/server/ipc-stamp and
# <client build>/client/ipc-stamp next to libopenxr_monado.dylib, the name the bridge loads.
# Logs: build/logs/wivrn-{configure,build}.log, wivrn-client-<arch>-{configure,build}.log
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/ccache.sh"
LOGS="$ROOT/build/logs"
SNAP="$ROOT/build/monado-snapshot"
mkdir -p "$LOGS"

client=0
if [[ "${1:-}" == --client-x86_64 || "${1:-}" == --client-arm64 ]]; then
	client_arch="${1#--client-}"
	shift
	client=1
	BUILD="${WIVRN_CLIENT_BUILD_DIR:-$ROOT/build/wivrn-client-$client_arch}"
	LOG="wivrn-client-$client_arch"
	[[ -d "$SNAP/src" ]] || { echo "no $SNAP: build the server first" >&2; exit 1; }
else
	BUILD="${WIVRN_BUILD_DIR:-$ROOT/build/wivrn}"
	LOG="wivrn"
fi

if [[ $client == 0 && ( "${1:-}" == "--snapshot" || ! -d "$SNAP/src" ) ]]; then
	[[ "${1:-}" == "--snapshot" ]] && shift
	echo "==> snapshot staged third_party/monado -> build/monado-snapshot"
	rm -rf "$SNAP.new"
	mkdir -p "$SNAP.new"
	git -C "$ROOT/third_party/monado" checkout-index -a --prefix="$SNAP.new/"
	git -C "$ROOT/third_party/monado" rev-parse HEAD > "$SNAP.new/.snapshot-base"
	git -C "$ROOT/third_party/monado" write-tree > "$SNAP.new/.snapshot-tree"
	(cd "$ROOT/patches/monado" && ls *.patch) > "$SNAP.new/.snapshot-patches"
	# keep mtimes of unchanged files so ninja doesn't rebuild everything
	if [[ -d "$SNAP" ]]; then
		rsync -a --checksum --delete "$SNAP.new/" "$SNAP/"
		rm -rf "$SNAP.new"
	else
		mv "$SNAP.new" "$SNAP"
	fi
fi

if [[ ! -f "$BUILD/build.ninja" ]]; then
	echo "==> configure $LOG"
	extra=()
	if [[ $client == 1 ]]; then
		# x86_64: deps as for the standalone client (build-bridge.sh monado-x86_64), /usr/local is universal, no
		# arm64-only Homebrew. -dead_strip_dylibs drops libvulkan: the bridge takes vkGetInstanceProcAddr from
		# CrossOver's MoltenVK.
		extra=(-DWIVRN_BUILD_SERVER=OFF -DWIVRN_BUILD_SERVER_LIBRARY=ON -DWIVRN_USE_COREAUDIO=OFF
			-DWIVRN_USE_VIDEOTOOLBOX=OFF -DWIVRN_USE_X264=OFF
			-DCMAKE_OSX_ARCHITECTURES="$client_arch" -DCMAKE_SHARED_LINKER_FLAGS=-Wl,-dead_strip_dylibs)
		[[ $client_arch == x86_64 ]] && extra+=(-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew
			-DEigen3_DIR=/opt/homebrew/share/eigen3/cmake)
	fi
	cmake -S "$ROOT/third_party/wivrn" -B "$BUILD" -G Ninja \
		-C "$ROOT/cmake/monado-macos.cmake" \
		-DCMAKE_BUILD_TYPE="${WIVRN_BUILD_TYPE:-RelWithDebInfo}" \
		-DCMAKE_PREFIX_PATH="/opt/homebrew/opt/libarchive" \
		-DFETCHCONTENT_SOURCE_DIR_MONADO="$SNAP" \
		-DFETCHCONTENT_FULLY_DISCONNECTED=OFF \
		-DGIT_TAG=v26.9 \
		-DWIVRN_BUILD_CLIENT=OFF -DWIVRN_BUILD_DASHBOARD=OFF -DWIVRN_BUILD_WIVRNCTL=OFF \
		-DWIVRN_USE_NVENC=OFF -DWIVRN_USE_VAAPI=OFF -DWIVRN_USE_VULKAN_ENCODE=OFF \
		-DWIVRN_USE_PIPEWIRE=OFF -DWIVRN_FEATURE_SOLARXR=OFF -DWIVRN_FEATURE_STEAMVR_LIGHTHOUSE=OFF \
		-DWIVRN_USE_VIDEOTOOLBOX=ON -DWIVRN_MVT_SOURCE_DIR="$ROOT/encoder" \
		-DWIVRN_USE_X264="${WIVRN_USE_X264:-ON}" \
		-DWIVRN_OPENXR_MANIFEST_TYPE=absolute \
		${extra[@]+"${extra[@]}"} \
		> "$LOGS/$LOG-configure.log" 2>&1 \
		|| { tail -40 "$LOGS/$LOG-configure.log"; exit 1; }
fi

echo "==> build $LOG"
if [[ $client == 1 ]]; then
	ninja -C "$BUILD" openxr_wivrn "$@" > "$LOGS/$LOG-build.log" 2>&1 \
		|| { grep -E -A3 "error|FAILED|Segmentation|PLEASE submit|Stack dump" "$LOGS/$LOG-build.log" | head -80; exit 1; }
	lib="$(find "$BUILD/_deps" -name libopenxr_wivrn.dylib -path '*targets/openxr*' | head -1)"
	mkdir -p "$BUILD/client"
	cp "$lib" "$BUILD/client/libopenxr_monado.dylib"
	"$ROOT/scripts/ipc-stamp.sh" write "$BUILD" "$BUILD/client/ipc-stamp"
	echo "==> done: $BUILD/client/libopenxr_monado.dylib"
	exit 0
fi
ninja -C "$BUILD" "$@" > "$LOGS/$LOG-build.log" 2>&1 \
	|| { grep -E "error|FAILED" "$LOGS/$LOG-build.log" | head -40; exit 1; }
"$ROOT/scripts/ipc-stamp.sh" write "$BUILD" "$BUILD/server/ipc-stamp"
# Test app for driving the compositor without an application swapchain (tests/wivrn/xr_empty_frames.c)
mkdir -p "$ROOT/build/tests"
clang -O1 -Wall -o "$ROOT/build/tests/xr_empty_frames" "$ROOT/tests/wivrn/xr_empty_frames.c" \
	-I"$ROOT/third_party/openxr-sdk/include" -I"$ROOT/build/openxr-sdk/include" -I/usr/local/include \
	-L"$ROOT/build/openxr-sdk/src/loader" -lopenxr_loader -L/usr/local/lib -lvulkan \
	-Wl,-rpath,"$ROOT/build/openxr-sdk/src/loader" -Wl,-rpath,/usr/local/lib
# Native Metal OpenXR app (tests/metal-xr/xr_metal.m, XR_KHR_metal_enable)
clang -fobjc-arc -O1 -Wall -o "$ROOT/build/tests/xr_metal" "$ROOT/tests/metal-xr/xr_metal.m" \
	-I"$ROOT/third_party/openxr-sdk/include" -I"$ROOT/build/openxr-sdk/include" \
	-L"$ROOT/build/openxr-sdk/src/loader" -lopenxr_loader \
	-Wl,-rpath,"$ROOT/build/openxr-sdk/src/loader" -framework Metal -framework Foundation
# Test tone for the CoreAudio backend (tests/wivrn/audio_tone.mm)
clang++ -std=c++20 -fobjc-arc -O1 -o "$ROOT/build/tests/audio_tone" "$ROOT/tests/wivrn/audio_tone.mm" \
	-framework AudioToolbox -framework CoreAudio -framework Foundation
echo "==> done: $BUILD/server/wivrn-server"
