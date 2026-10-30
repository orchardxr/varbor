#!/usr/bin/env bash
# Build CrossOver's DXVK (cxaddon-1.10.3) for ARM64EC: third_party/dxvk (upstream v1.10.3) + patches/dxvk
# (0001 = CrossOver 27's fork from crossover-sources-20261015.tar, sources/dxvk; 0002 = ARM64EC build fixes).
#   scripts/build-dxvk.sh [--no-patches]
# Output: build/dxvk/install/lib/dxvk/aarch64-windows/{d3d9,d3d10,d3d10_1,d3d10core,d3d11}.dll, the set CrossOver ships
# for x86_64 (DXVK's d3d11 runs on Wine's dxgi, so no dxgi.dll). The DLLs are marked as Wine builtins like CrossOver's,
# since lib/dxvk is a builtin search dir. Build log: build/logs/dxvk-arm64ec.log.
# Toolchains (scripts/local.env or the environment): LLVM_MINGW (scripts/lib/detect.sh), DXVK_WINEBUILD (any winebuild;
# default DXMT_WINE_ARM64EC's bin/winebuild); glslangValidator, meson, ninja on PATH.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/detect.sh"
SRC="$ROOT/third_party/dxvk"
OUT="$ROOT/build/dxvk"
LOGS="$ROOT/build/logs"
mkdir -p "$OUT" "$LOGS"

patches=1
case "${1:-}" in
--no-patches) patches=0 ;;
"") ;;
*) echo "usage: $0 [--no-patches]" >&2; exit 2 ;;
esac

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
winebuild="$(setting DXVK_WINEBUILD)"
[[ -n "$winebuild" ]] || { w="$(setting DXMT_WINE_ARM64EC)"; [[ -z "$w" ]] || winebuild="$w/bin/winebuild"; }
[[ -x "$winebuild" ]] || winebuild="$(command -v winebuild || true)"
[[ -x "$winebuild" ]] || { echo "no winebuild (set DXVK_WINEBUILD)" >&2; exit 1; }

if [[ $patches == 1 ]]; then "$ROOT/scripts/patches.sh" apply dxvk; else "$ROOT/scripts/patches.sh" reset dxvk; fi

triple=arm64ec-w64-mingw32
cross="$OUT/cross-arm64ec.txt"
cat > "$cross" <<EOF
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
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF

bdir="$OUT/build-arm64ec"
log="$LOGS/dxvk-arm64ec.log"
mkdir -p "$bdir/implib"
printf 'LIBRARY vulkan-1.dll\nEXPORTS\n  vkGetInstanceProcAddr\n' > "$bdir/implib/vulkan-1.def"
"$LLVM_MINGW/bin/llvm-dlltool" -m arm64ec -d "$bdir/implib/vulkan-1.def" -l "$bdir/implib/libvulkan-1.a"
"$LLVM_MINGW/bin/llvm-dlltool" -m arm64ec -d "$SRC/lib/libd3dcompiler_43.def" -l "$bdir/implib/libd3dcompiler_43.a"

# vcs_tag runs `git describe` in the submodule; the shipped DLLs say cxaddon-1.10.3
echo "==> DXVK arm64ec ($(git -C "$SRC" describe --always --tags)), log $log"
if [[ ! -f "$bdir/build.ninja" ]]; then
	meson setup --cross-file "$cross" --buildtype release -Dstrip=true -Denable_tests=false -Denable_dxgi=false \
		--prefix "$OUT/stage" --bindir aarch64-windows --libdir aarch64-windows "$bdir" "$SRC" > "$log" 2>&1 \
		|| { tail -30 "$log"; exit 1; }
fi
{ meson compile -C "$bdir" && meson install -C "$bdir"; } >> "$log" 2>&1 || { tail -30 "$log"; exit 1; }

dst="$OUT/install/lib/dxvk/aarch64-windows"
mkdir -p "$dst"
for d in d3d9 d3d10 d3d10_1 d3d10core d3d11; do
	cp "$OUT/stage/aarch64-windows/$d.dll" "$dst/"
	"$winebuild" --builtin "$dst/$d.dll"
done
file "$dst"/*.dll | sed "s|$OUT/||"
