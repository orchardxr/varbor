#!/usr/bin/env bash
# Configure and build the step-1 trees. Logs go to build/logs/.
#   scripts/build.sh [monado|monado-inproc|openxr-sdk|x86_64]...   (default: the first three)
#
# monado         service build: monado-service + IPC-client libopenxr_monado.dylib
# monado-inproc  XRT_FEATURE_SERVICE=OFF: libopenxr_monado.dylib with the compositor in-process
# openxr-sdk     loader, API layers and hello_xr
# x86_64         Rosetta client for out-of-process tests: build/monado-x86_64 (IPC-client
#                libopenxr_monado.dylib only) and build/openxr-sdk-x86_64 (loader, layers, hello_xr)
#
# Run scripts/patches.sh apply first.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGS="$ROOT/build/logs"
mkdir -p "$LOGS"

# NINJA_TARGET limits the ninja build to one target.
build() {
	local name="$1" src="$2"
	shift 2
	echo "==> configure $name"
	cmake -S "$src" -B "$ROOT/build/$name" -G Ninja "$@" > "$LOGS/$name-configure.log" 2>&1 \
		|| { tail -30 "$LOGS/$name-configure.log"; exit 1; }
	echo "==> build $name"
	ninja -C "$ROOT/build/$name" ${NINJA_TARGET:-} > "$LOGS/$name-build.log" 2>&1 \
		|| { grep -E "error|FAILED" "$LOGS/$name-build.log" | head -30; exit 1; }
}

# Homebrew libraries are arm64 only; only Eigen's headers are taken from there.
X86=(-DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew)

targets=("$@")
[[ ${#targets[@]} -gt 0 ]] || targets=(monado monado-inproc openxr-sdk)

for t in "${targets[@]}"; do
	case "$t" in
		monado)
			build monado "$ROOT/third_party/monado" -C "$ROOT/cmake/monado-macos.cmake" -DXRT_FEATURE_SERVICE=ON ;;
		monado-inproc)
			build monado-inproc "$ROOT/third_party/monado" -C "$ROOT/cmake/monado-macos.cmake" -DXRT_FEATURE_SERVICE=OFF ;;
		openxr-sdk)
			build openxr-sdk "$ROOT/third_party/openxr-sdk" -DCMAKE_BUILD_TYPE=RelWithDebInfo \
				-DBUILD_TESTS=ON -DBUILD_CONFORMANCE_TESTS=OFF -DDYNAMIC_LOADER=ON -DBUILD_WITH_SYSTEM_JSONCPP=OFF ;;
		x86_64)
			NINJA_TARGET=openxr_monado build monado-x86_64 "$ROOT/third_party/monado" \
				-C "$ROOT/cmake/monado-macos.cmake" -DXRT_FEATURE_SERVICE=ON "${X86[@]}" \
				-DEigen3_DIR=/opt/homebrew/share/eigen3/cmake
			build openxr-sdk-x86_64 "$ROOT/third_party/openxr-sdk" -DCMAKE_BUILD_TYPE=RelWithDebInfo "${X86[@]}" \
				-DBUILD_TESTS=ON -DBUILD_CONFORMANCE_TESTS=OFF -DDYNAMIC_LOADER=ON -DBUILD_WITH_SYSTEM_JSONCPP=OFF ;;
		*) echo "unknown target $t" >&2; exit 2 ;;
	esac
done
echo "==> done"
