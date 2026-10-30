#!/usr/bin/env bash
# The MacVR DXVK runner: an APFS clone of NotProton's CrossOver 27 FEX runner plus lib/dxvk/aarch64-windows, the ARM64EC
# DXVK from scripts/build-dxvk.sh. CX_GRAPHICS_BACKEND=dxvk then loads it on FEX (the stock runner only has
# x86_64/i386 DXVK, which an ARM64EC process doesn't search, so it gets wined3d's d3d11). Only adds files under
# NotProton's support dir; the stock runner, NotProton's code and its tool registry stay untouched.
#   scripts/make-macvr-dxvk-runner.sh [create]    clone (once) and copy build/dxvk/install into lib/dxvk
#   scripts/make-macvr-dxvk-runner.sh remove      delete the clone
#   scripts/make-macvr-dxvk-runner.sh status
# Environment: BASE_BUILD (default 27.0.0.41073-fex), SUFFIX (default macvrdxvk).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
np="$HOME/Library/Application Support/notproton"
base="${BASE_BUILD:-27.0.0.41073-fex}"
build="$base-${SUFFIX:-macvrdxvk}"
src="$np/runners/crossover-$base"
dst="$np/runners/crossover-$build"
marker="$dst/.macvr-dxvk"
inst="$ROOT/build/dxvk/install/lib/dxvk"

die() { echo "make-macvr-dxvk-runner: $*" >&2; exit 1; }

create() {
	[[ -d "$src/CrossOver/lib/dxvk" ]] || die "no stock runner $src"
	[[ -f "$inst/aarch64-windows/d3d11.dll" ]] || die "no $inst (scripts/build-dxvk.sh first)"
	if [[ ! -d "$dst" ]]; then
		cp -c -R "$src" "$dst.tmp-$$"
		mv "$dst.tmp-$$" "$dst"
		echo "cloned $src -> $dst"
	fi
	[[ -f "$marker" ]] || printf 'base %s\n' "$base" > "$marker"
	mkdir -p "$dst/CrossOver/lib/dxvk/aarch64-windows"
	cp "$inst"/aarch64-windows/*.dll "$dst/CrossOver/lib/dxvk/aarch64-windows/"
	{
		printf 'base %s\n' "$base"
		printf 'dxvk %s\n' "$(git -C "$ROOT/third_party/dxvk" describe --always --tags 2>/dev/null || echo unknown)"
		printf 'patches %s\n' "$(cat "$ROOT"/patches/dxvk/*.patch | shasum -a 256 | cut -c1-16)"
		(cd "$inst" && find . -type f | sed 's|^\./||' | sort | while read -r f; do printf 'file %s %s\n' "$f" "$(shasum -a 256 "$f" | cut -c1-16)"; done)
	} > "$marker"
	echo "installed $(ls "$inst/aarch64-windows" | wc -l | tr -d ' ') DLLs into $dst/CrossOver/lib/dxvk/aarch64-windows"
}

status() {
	if [[ -f "$marker" ]]; then
		echo "runner $dst"
		cat "$marker"
	else
		echo "no MacVR DXVK runner at $dst"
	fi
}

remove() {
	if [[ -d "$dst" ]]; then
		[[ -f "$marker" ]] || die "$dst has no $marker: not ours, left alone"
		rm -rf "$dst"
		echo "removed $dst"
	fi
	local t
	for t in "$HOME/Library/Application Support/Steam/steamapps/compatdata/notproton-template/crossover-$build-"*; do
		[[ -d "$t" ]] && echo "note: NotProton made a template for the runner: $t"
	done
	return 0
}

case "${1:-create}" in
create) create ;;
remove) remove ;;
status) status ;;
*) sed -n '2,9p' "$0"; exit 2 ;;
esac
