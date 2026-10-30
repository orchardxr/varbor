#!/usr/bin/env bash
# The MacVR DXMT runner: an APFS clone of NotProton's CrossOver 27 FEX runner with lib/dxmt's patched files
# (scripts/build-dxmt.sh) in place of the stock ones. Only adds files under NotProton's support dir; the stock runner,
# NotProton's code and its other data stay untouched.
#   scripts/make-macvr-dxmt-runner.sh [create]    clone (once) and copy build/dxmt/install over lib/dxmt
#   scripts/make-macvr-dxmt-runner.sh remove      delete the clone (and the compat tool, if installed)
#   scripts/make-macvr-dxmt-runner.sh status
#   scripts/make-macvr-dxmt-runner.sh compat-tool [DIR]
#       write a Steam compat tool for the runner into DIR (default: Steam's compatibilitytools.d; Steam lists it after
#       a restart): an unmodified copy of NotProton's `run` + toolmanifest.vdf from its FEX tool, with build/flavor/
#       compatibilitytool.vdf naming the clone; into Steam's dir also a clone of NotProton's per-build bridge data
#       (bridge/wine/<build>), which its `run` checks for
#   scripts/make-macvr-dxmt-runner.sh compat-tool-remove [DIR]
# Environment: BASE_BUILD (default 27.0.0.41073-fex), SUFFIX (default macvrdxmt).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
np="$HOME/Library/Application Support/notproton"
steam_tools="$HOME/Library/Application Support/Steam/compatibilitytools.d"
base="${BASE_BUILD:-27.0.0.41073-fex}"
build="$base-${SUFFIX:-macvrdxmt}"
src="$np/runners/crossover-$base"
dst="$np/runners/crossover-$build"
marker="$dst/.macvr-dxmt"
inst="$ROOT/build/dxmt/install/lib/dxmt"
num="${base%-fex}"
num="${num##*.}"
tool_name="notproton-fex-macvrdxmt-$num"

die() { echo "make-macvr-dxmt-runner: $*" >&2; exit 1; }

create() {
	[[ -d "$src/CrossOver/lib/dxmt" ]] || die "no stock runner $src"
	[[ -f "$inst/aarch64-windows/d3d11.dll" ]] || die "no $inst (scripts/build-dxmt.sh first)"
	if [[ ! -d "$dst" ]]; then
		cp -c -R "$src" "$dst.tmp-$$"
		mv "$dst.tmp-$$" "$dst"
		echo "cloned $src -> $dst"
	fi
	[[ -f "$marker" ]] || printf 'base %s\n' "$base" > "$marker"
	local f n=0
	while IFS= read -r f; do
		mkdir -p "$(dirname "$dst/CrossOver/lib/dxmt/$f")"
		cp "$inst/$f" "$dst/CrossOver/lib/dxmt/$f"
		n=$((n + 1))
	done < <(cd "$inst" && find . -type f | sed 's|^\./||' | sort)
	{
		printf 'base %s\n' "$base"
		printf 'dxmt %s\n' "$(git -C "$ROOT/third_party/dxmt" describe --always --tags 2>/dev/null || echo unknown)"
		printf 'patches %s\n' "$(cat "$ROOT"/patches/dxmt/*.patch | shasum -a 256 | cut -c1-16)"
		(cd "$inst" && find . -type f | sed 's|^\./||' | sort | while read -r f; do printf 'file %s %s\n' "$f" "$(shasum -a 256 "$f" | cut -c1-16)"; done)
	} > "$marker"
	echo "installed $n files from build/dxmt/install into $dst/CrossOver/lib/dxmt"
}

status() {
	if [[ -f "$marker" ]]; then
		echo "runner $dst"
		cat "$marker"
	else
		echo "no MacVR DXMT runner at $dst"
	fi
	local d
	for d in "$steam_tools/$tool_name" "$np/bridge/wine/$build"; do
		[[ -e "$d" ]] && echo "present: $d"
	done
	return 0
}

compat_tool() {
	local dir="${1:-$steam_tools}" from="$steam_tools/notproton-fex-$num"
	[[ -f "$marker" ]] || die "create the runner first"
	[[ -f "$from/run" ]] || die "no NotProton FEX compat tool at $from"
	mkdir -p "$dir/$tool_name"
	cp "$from/run" "$from/toolmanifest.vdf" "$dir/$tool_name/"
	printf '%s\n' "$build" > "$dir/$tool_name/build"
	printf 'fex\n' > "$dir/$tool_name/flavor"
	# NotProton deletes compatibilitytools.d/notproton-* dirs it doesn't know unless they hold a file it didn't write
	printf 'macvr-dxmt compat tool\n' > "$dir/$tool_name/.macvr-dxmt"
	cat > "$dir/$tool_name/compatibilitytool.vdf" <<-EOF
	"compatibilitytools"
	{
	  "compat_tools"
	  {
	    "$tool_name"
	    {
	      "install_path" "."
	      "display_name" "CrossOver $base - FEX - MacVR DXMT"
	      "from_oslist" "windows"
	      "to_oslist" "macos"
	    }
	  }
	}
	EOF
	if [[ $dir == "$steam_tools" && -d "$np/bridge/wine/$base" && ! -e "$np/bridge/wine/$build" ]]; then
		cp -c -R "$np/bridge/wine/$base" "$np/bridge/wine/$build"
		printf 'macvr-dxmt clone of %s\n' "$base" > "$np/bridge/wine/$build/.macvr-dxmt"
	fi
	echo "compat tool $dir/$tool_name (Steam shows it after a restart)"
}

compat_tool_remove() {
	local dir="${1:-$steam_tools}"
	if [[ -f "$dir/$tool_name/.macvr-dxmt" || ( -f "$dir/$tool_name/build" && "$(cat "$dir/$tool_name/build")" == "$build" ) ]]; then
		rm -rf "$dir/$tool_name"
		echo "removed $dir/$tool_name"
	fi
	if [[ -f "$np/bridge/wine/$build/.macvr-dxmt" ]]; then
		rm -rf "$np/bridge/wine/$build"
		echo "removed $np/bridge/wine/$build"
	fi
}

remove() {
	compat_tool_remove
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
compat-tool) compat_tool "${2:-}" ;;
compat-tool-remove) compat_tool_remove "${2:-}" ;;
*) sed -n '2,15p' "$0"; exit 2 ;;
esac
