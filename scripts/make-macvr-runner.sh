#!/usr/bin/env bash
# The MacVR runner: an APFS clone of NotProton's CrossOver 27 FEX runner with our patched DXMT (scripts/build-dxmt.sh)
# in place of lib/dxmt's stock files and our ARM64EC DXVK (scripts/build-dxvk.sh) added as lib/dxvk/aarch64-windows
# (stock x86_64/i386 DXVK stay). CX_GRAPHICS_BACKEND picks the engine (dxmt by default, as stock). Only adds files
# under NotProton's support dir and Steam's compatibilitytools.d; the stock runner, NotProton's code and its tool
# registry stay untouched.
#   scripts/make-macvr-runner.sh [create]    clone (once) and copy build/dxmt/install and build/dxvk/install in
#   scripts/make-macvr-runner.sh remove      delete the clone and the compat tool
#   scripts/make-macvr-runner.sh status
#   scripts/make-macvr-runner.sh compat-tool [DIR]
#       write a Steam compat tool for the runner into DIR (default: Steam's compatibilitytools.d; Steam lists it after
#       a restart and once NotProton's registry has it): an unmodified copy of NotProton's `run` + toolmanifest.vdf
#       from its FEX tool, with build/flavor/compatibilitytool.vdf naming the clone; into Steam's dir also a clone of
#       NotProton's per-build bridge data (bridge/wine/<build>), which its `run` checks for
#   scripts/make-macvr-runner.sh compat-tool-remove [DIR]
#   scripts/make-macvr-runner.sh remove-old  delete the earlier separate clones (-macvrdxmt, -macvrdxvk), the
#       notproton-fex-macvrdxmt-<n> tool dir and its bridge data (each only if it carries our marker)
# Environment: BASE_BUILD (default 27.0.0.41073-fex).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
np="$HOME/Library/Application Support/notproton"
steam_tools="$HOME/Library/Application Support/Steam/compatibilitytools.d"
templates="$HOME/Library/Application Support/Steam/steamapps/compatdata/notproton-template"
base="${BASE_BUILD:-27.0.0.41073-fex}"
build="$base-macvr"
src="$np/runners/crossover-$base"
dst="$np/runners/crossover-$build"
marker="$dst/.macvr"
dxmt_inst="$ROOT/build/dxmt/install/lib/dxmt"
dxvk_inst="$ROOT/build/dxvk/install/lib/dxvk"
num="${base%-fex}"
num="${num##*.}"
tool_name="notproton-fex-macvr-$num"

die() { echo "make-macvr-runner: $*" >&2; exit 1; }

files() { (cd "$1" && find . -type f | sed 's|^\./||' | sort); }

create() {
	[[ -d "$src/CrossOver/lib/dxmt" && -d "$src/CrossOver/lib/dxvk" ]] || die "no stock runner $src"
	[[ -f "$dxmt_inst/aarch64-windows/d3d11.dll" ]] || die "no $dxmt_inst (scripts/build-dxmt.sh first)"
	[[ -f "$dxvk_inst/aarch64-windows/d3d11.dll" ]] || die "no $dxvk_inst (scripts/build-dxvk.sh first)"
	[[ ! -e "$src/CrossOver/lib/dxvk/aarch64-windows" ]] || die "$src already has lib/dxvk/aarch64-windows"
	if [[ ! -d "$dst" ]]; then
		cp -c -R "$src" "$dst.tmp-$$"
		mv "$dst.tmp-$$" "$dst"
		echo "cloned $src -> $dst"
	fi
	[[ -f "$marker" ]] || printf 'base %s\n' "$base" > "$marker"
	local f lib inst
	for lib in dxmt dxvk; do
		inst="$ROOT/build/$lib/install/lib/$lib"
		while IFS= read -r f; do
			mkdir -p "$(dirname "$dst/CrossOver/lib/$lib/$f")"
			cp "$inst/$f" "$dst/CrossOver/lib/$lib/$f"
		done < <(files "$inst")
	done
	{
		printf 'base %s\n' "$base"
		for lib in dxmt dxvk; do
			inst="$ROOT/build/$lib/install/lib/$lib"
			printf '%s %s\n' "$lib" "$(git -C "$ROOT/third_party/$lib" describe --always --tags 2>/dev/null || echo unknown)"
			printf '%s-patches %s\n' "$lib" "$(cat "$ROOT"/patches/"$lib"/*.patch | shasum -a 256 | cut -c1-16)"
			files "$inst" | while read -r f; do
				printf 'file %s/%s %s\n' "$lib" "$f" "$(shasum -a 256 "$inst/$f" | cut -c1-16)"
			done
		done
	} > "$marker"
	echo "installed $(files "$dxmt_inst" | wc -l | tr -d ' ') DXMT files into lib/dxmt and" \
		"$(files "$dxvk_inst" | wc -l | tr -d ' ') DXVK files into lib/dxvk of $dst"
}

status() {
	if [[ -f "$marker" ]]; then
		echo "runner $dst"
		cat "$marker"
	else
		echo "no MacVR runner at $dst"
	fi
	local d
	for d in "$steam_tools/$tool_name" "$np/bridge/wine/$build" \
		"$np/runners/crossover-$base-macvrdxmt" "$np/runners/crossover-$base-macvrdxvk" \
		"$steam_tools/notproton-fex-macvrdxmt-$num" "$np/bridge/wine/$base-macvrdxmt"; do
		[[ -e "$d" ]] && echo "present: $d"
	done
	return 0
}

compat_tool() {
	local dir="${1:-$steam_tools}" from="$steam_tools/notproton-fex-$num" name
	[[ -f "$marker" ]] || die "create the runner first"
	[[ -f "$from/run" ]] || die "no NotProton FEX compat tool at $from"
	name="$(sed -n 's/.*"display_name"[[:space:]]*"\(.*\)".*/\1/p' "$from/compatibilitytool.vdf")"
	[[ -n $name ]] || die "no display_name in $from/compatibilitytool.vdf"
	mkdir -p "$dir/$tool_name"
	cp "$from/run" "$from/toolmanifest.vdf" "$dir/$tool_name/"
	printf '%s\n' "$build" > "$dir/$tool_name/build"
	printf 'fex\n' > "$dir/$tool_name/flavor"
	# NotProton deletes compatibilitytools.d/notproton-* dirs it doesn't know unless they hold a file it didn't write
	printf 'macvr compat tool\n' > "$dir/$tool_name/.macvr"
	cat > "$dir/$tool_name/compatibilitytool.vdf" <<-EOF
	"compatibilitytools"
	{
	  "compat_tools"
	  {
	    "$tool_name"
	    {
	      "install_path" "."
	      "display_name" "$name - MacVR"
	      "from_oslist" "windows"
	      "to_oslist" "macos"
	    }
	  }
	}
	EOF
	if [[ $dir == "$steam_tools" && -d "$np/bridge/wine/$base" && ! -e "$np/bridge/wine/$build" ]]; then
		cp -c -R "$np/bridge/wine/$base" "$np/bridge/wine/$build"
		printf 'macvr clone of %s\n' "$base" > "$np/bridge/wine/$build/.macvr"
	fi
	echo "compat tool $dir/$tool_name \"$name - MacVR\"; registry line:"
	printf '%s\t%s\tfex\t%s - MacVR\n' "$tool_name" "$build" "$name"
}

# rm_marked DIR MARKER...: delete DIR if it holds one of the marker files
rm_marked() {
	local d="$1" m
	shift
	[[ -e "$d" ]] || return 0
	for m in "$@"; do
		if [[ -f "$d/$m" ]]; then
			rm -rf "$d"
			echo "removed $d"
			return 0
		fi
	done
	echo "$d has none of $*: not ours, left alone" >&2
}

note_templates() {
	local t
	for t in "$templates/crossover-$1-"*; do
		[[ -d "$t" ]] && echo "note: NotProton made a template for the runner: $t"
	done
	return 0
}

compat_tool_remove() {
	local dir="${1:-$steam_tools}"
	rm_marked "$dir/$tool_name" .macvr
	rm_marked "$np/bridge/wine/$build" .macvr
}

remove() {
	compat_tool_remove
	rm_marked "$dst" .macvr
	note_templates "$build"
}

remove_old() {
	rm_marked "$steam_tools/notproton-fex-macvrdxmt-$num" .macvr-dxmt
	rm_marked "$np/bridge/wine/$base-macvrdxmt" .macvr-dxmt
	rm_marked "$np/runners/crossover-$base-macvrdxmt" .macvr-dxmt
	rm_marked "$np/runners/crossover-$base-macvrdxvk" .macvr-dxvk
	note_templates "$base-macvrdxmt"
	note_templates "$base-macvrdxvk"
}

case "${1:-create}" in
create) create ;;
remove) remove ;;
remove-old) remove_old ;;
status) status ;;
compat-tool) compat_tool "${2:-}" ;;
compat-tool-remove) compat_tool_remove "${2:-}" ;;
*) sed -n '2,18p' "$0"; exit 2 ;;
esac
