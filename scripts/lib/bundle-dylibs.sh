# Copies the Homebrew / /usr/local dylibs that binaries link (recursively) into one directory and points the
# binaries at @rpath, so the app runs without Homebrew or the Vulkan SDK. Source from bash.
#   bundle_dylibs <lib dir> <binary>...    (binaries must also get an LC_RPATH to <lib dir>)

_bundle_resolve() { # <dep> <dir of the file that links it>
	local dep="$1" dir="$2" n="${1##*/}" c
	case "$dep" in
		/opt/homebrew/* | /usr/local/*) echo "$dep" ;;
		@loader_path/* | @rpath/*)
			for c in "$dir/${dep#*/}" "/opt/homebrew/lib/$n" "/usr/local/lib/$n"; do
				[[ -e "$c" ]] && { echo "$c"; return; }
			done ;;
	esac
}

bundle_dylibs() {
	local lib="$1" f origin dep src name entry self
	shift
	mkdir -p "$lib"
	local queue=()
	for f in "$@"; do queue+=("$f|$(dirname "$f")"); done
	while ((${#queue[@]})); do
		entry="${queue[0]}"
		queue=("${queue[@]:1}")
		f="${entry%%|*}" origin="${entry#*|}"
		self="$(otool -D "$f" | sed -n 2p)"
		for dep in $(otool -L "$f" | tail -n +2 | awk '{print $1}'); do
			[[ "$dep" == "$self" ]] && continue
			name="${dep##*/}"
			[[ -e "$(dirname "$f")/$name" && "$(dirname "$f")" != "$lib" ]] && continue
			src="$(_bundle_resolve "$dep" "$origin")"
			[[ -n "$src" ]] || continue
			if [[ ! -e "$lib/$name" ]]; then
				cp -L "$src" "$lib/$name"
				chmod u+w "$lib/$name"
				install_name_tool -id "@rpath/$name" "$lib/$name" 2>/dev/null
				otool -l "$lib/$name" | grep -q "path @loader_path " || install_name_tool -add_rpath @loader_path "$lib/$name" 2>/dev/null
				queue+=("$lib/$name|$(dirname "$(realpath "$src")")")
			fi
			[[ "$dep" == "@rpath/$name" ]] || install_name_tool -change "$dep" "@rpath/$name" "$f" 2>/dev/null
		done
	done
}
