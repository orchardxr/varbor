#!/usr/bin/env bash
# Build MacVR DXMT: third_party/dxmt (pinned to the DXMT CrossOver 27.0.0.41073 ships) + patches/dxmt.
#   scripts/build-dxmt.sh [--no-patches] [arm64ec] [x86_64]       (default: arm64ec)
#
# arm64ec  ARM64EC d3d11/dxgi/d3d10core/winemetal.dll (lib/dxmt/aarch64-windows: what x86_64 games load on the FEX
#          runner) + aarch64-unix winemetal.so
# x86_64   x86_64 DLLs (lib/dxmt/x86_64-windows) + x86_64-unix winemetal.so (Rosetta runners)
# Output: build/dxmt/install/lib/dxmt/<arch>-{windows,unix}; build logs in build/logs/dxmt-*.log.
#
# Toolchains (scripts/local.env or the environment; CI-equivalent defaults are fetched/built into build/dxmt/toolchains):
#   LLVM_MINGW               llvm-mingw (scripts/lib/detect.sh)
#   DXMT_LLVM_ARM64          LLVM 15 (exact major) with headers and static libs, arm64: llvmorg-15.0.7 built from
#   DXMT_LLVM_X86_64         source when unset (~30 min each)
#   DXMT_WINE_ARM64EC        Wine install with lib/wine/aarch64-windows import libs and bin/winebuild (default: the
#   DXMT_WINE_X86_64         wine-11.2 / v8.16-3shain tarballs DXMT's CI uses)
#   DXMT_RUNNER              the runner whose ntdll.so/winemac.so winemetal.so links against
#                            (default: NotProton's crossover-27.0.0.41073-fex)
# Like CrossOver's build, ARM64EC is plain ARM64EC (no -marm64x) and nvapi/nvngx are not built.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/detect.sh"
SRC="$ROOT/third_party/dxmt"
OUT="$ROOT/build/dxmt"
TC="$OUT/toolchains"
LOGS="$ROOT/build/logs"
mkdir -p "$OUT" "$TC" "$LOGS"

patches=1
archs=()
for a in "$@"; do
	case "$a" in
	--no-patches) patches=0 ;;
	arm64ec|x86_64) archs+=("$a") ;;
	*) echo "usage: $0 [--no-patches] [arm64ec] [x86_64]" >&2; exit 2 ;;
	esac
done
[[ ${#archs[@]} -gt 0 ]] || archs=(arm64ec)

local_env() {
	[[ -f "$ROOT/scripts/local.env" ]] || return 0
	local v
	v=$(sed -n "s/^$1=//p" "$ROOT/scripts/local.env" | tail -1)
	eval "v=\"$v\""
	echo "$v"
}
setting() {
	local v="${!1:-}"
	[[ -n "$v" ]] || v=$(local_env "$1")
	echo "$v"
}

LLVM_MINGW=$(llvm_mingw)
runner="$(setting DXMT_RUNNER)"
runner="${runner:-$HOME/Library/Application Support/notproton/runners/crossover-27.0.0.41073-fex/CrossOver}"

llvm15() {
	local arch="$1" dir="$TC/llvm-15-$1"
	if [[ ! -f "$dir/lib/libLLVMCore.a" ]]; then
		[[ -d "$TC/llvm-project" ]] || git clone -q --depth 1 --branch llvmorg-15.0.7 \
			https://github.com/llvm/llvm-project.git "$TC/llvm-project"
		echo "==> LLVM 15 ($arch), log $LOGS/dxmt-llvm-$arch.log" >&2
		cmake -B "$TC/llvm-build-$arch" -S "$TC/llvm-project/llvm" -G Ninja \
			-DCMAKE_INSTALL_PREFIX="$dir" -DCMAKE_OSX_ARCHITECTURES="$arch" -DLLVM_HOST_TRIPLE="$arch-apple-darwin" \
			-DLLVM_ENABLE_ASSERTIONS=On -DLLVM_ENABLE_ZSTD=Off -DCMAKE_BUILD_TYPE=Release -DLLVM_TARGETS_TO_BUILD="" \
			-DLLVM_BUILD_TOOLS=Off -DLLVM_INCLUDE_BENCHMARKS=Off -DCMAKE_CXX_FLAGS="-D_LIBCPP_KEEP_TRANSITIVE_INCLUDES_LLVM23" \
			-DLLVM_VERSION_PRINTER_SHOW_HOST_TARGET_INFO=Off > "$LOGS/dxmt-llvm-$arch.log" 2>&1
		cmake --build "$TC/llvm-build-$arch" >> "$LOGS/dxmt-llvm-$arch.log" 2>&1
		cmake --install "$TC/llvm-build-$arch" >> "$LOGS/dxmt-llvm-$arch.log" 2>&1
	fi
	echo "$dir"
}

wine_tarball() {
	local name="$1" url="$2" dir="$TC/$1"
	if [[ ! -x "$dir/bin/winebuild" ]]; then
		mkdir -p "$dir"
		curl -fsSL "$url" | tar -xz --strip-components 2 -C "$dir"
	fi
	echo "$dir"
}

# A Wine install for meson: import libs and winebuild from the toolchain Wine, ntdll.so/winemac.so from the runner
wine_prefix() {
	local winearch="$1" unixarch="$2" wine="$3" dir="$OUT/wine-$1"
	mkdir -p "$dir/bin" "$dir/lib/wine/$winearch-windows" "$dir/lib/wine/$unixarch-unix"
	ln -sf "$wine/bin/winebuild" "$dir/bin/winebuild"
	for l in libwinecrt0.a libntdll.a libdbghelp.a; do
		ln -sf "$wine/lib/wine/$winearch-windows/$l" "$dir/lib/wine/$winearch-windows/$l"
	done
	for l in ntdll.so winemac.so; do
		[[ -f "$runner/lib/wine/$unixarch-unix/$l" ]] || { echo "no $runner/lib/wine/$unixarch-unix/$l" >&2; exit 1; }
		ln -sf "$runner/lib/wine/$unixarch-unix/$l" "$dir/lib/wine/$unixarch-unix/$l"
	done
	echo "$dir"
}

if [[ $patches == 1 ]]; then "$ROOT/scripts/patches.sh" apply dxmt; else "$ROOT/scripts/patches.sh" reset dxmt; fi
[[ -f "$SRC/include/native/directx/d3d11.h" ]] || git -C "$SRC" submodule update --init include/native/directx

for arch in "${archs[@]}"; do
	if [[ $arch == arm64ec ]]; then
		triple=arm64ec-w64-mingw32 winearch=aarch64 unixarch=aarch64 llvmarch=arm64
		llvm="$(setting DXMT_LLVM_ARM64)"; llvm="${llvm:-$(llvm15 arm64)}"
		wine="$(setting DXMT_WINE_ARM64EC)"
		wine="${wine:-$(wine_tarball wine-11.2 https://github.com/3Shain/wine/releases/download/wine-11.2/wine-11.2.tar.gz)}"
	else
		triple=x86_64-w64-mingw32 winearch=x86_64 unixarch=x86_64 llvmarch=x86_64
		llvm="$(setting DXMT_LLVM_X86_64)"; llvm="${llvm:-$(llvm15 x86_64)}"
		wine="$(setting DXMT_WINE_X86_64)"
		wine="${wine:-$(wine_tarball wine-8.16-3shain https://github.com/3Shain/wine/releases/download/v8.16-3shain/wine.tar.gz)}"
	fi
	prefix=$(wine_prefix "$winearch" "$unixarch" "$wine")
	cross="$OUT/cross-$arch.txt"
	cat > "$cross" <<-EOF
	[binaries]
	c = '$LLVM_MINGW/bin/$triple-clang'
	cpp = '$LLVM_MINGW/bin/$triple-clang++'
	ar = '$LLVM_MINGW/bin/$triple-ar'
	strip = '$LLVM_MINGW/bin/$triple-strip'
	windres = '$LLVM_MINGW/bin/$triple-windres'

	[properties]
	needs_exe_wrapper = true

	[host_machine]
	system = 'windows'
	cpu_family = '$winearch'
	cpu = '$winearch'
	endian = 'little'
	EOF
	bdir="$OUT/build-$arch"
	log="$LOGS/dxmt-$arch.log"
	echo "==> DXMT $arch ($(git -C "$SRC" describe --always --tags), LLVM $llvm), log $log"
	if [[ ! -f "$bdir/build.ninja" ]]; then
		meson setup --cross-file "$cross" -Dnative_llvm_path="$llvm" -Dwine_install_path="$prefix" \
			--buildtype release -Dstrip=true --prefix "$OUT/stage-$arch" "$bdir" "$SRC" > "$log" 2>&1 \
			|| { tail -30 "$log"; exit 1; }
	fi
	{ meson compile -C "$bdir" && meson install -C "$bdir"; } >> "$log" 2>&1 || { tail -30 "$log"; exit 1; }
	dst="$OUT/install/lib/dxmt"
	mkdir -p "$dst/$winearch-windows" "$dst/$unixarch-unix"
	for d in d3d11 dxgi d3d10core winemetal; do cp "$OUT/stage-$arch/$winearch-windows/$d.dll" "$dst/$winearch-windows/"; done
	cp "$OUT/stage-$arch/$unixarch-unix/winemetal.so" "$dst/$unixarch-unix/"
	file "$dst/$winearch-windows/d3d11.dll" "$dst/$unixarch-unix/winemetal.so" | sed "s|$OUT/||"
done
