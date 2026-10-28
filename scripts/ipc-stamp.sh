#!/usr/bin/env bash
# IPC stamp: identifies the Monado IPC protocol a WiVRn build speaks, so server and x86_64 client can be compared.
#   scripts/ipc-stamp.sh write <cmake-build-dir> <stamp-file>
#   scripts/ipc-stamp.sh publish <server-build-dir>    after starting wivrn-server: copies <dir>/server/ipc-stamp to
#                                                      $(getconf DARWIN_USER_TEMP_DIR)wivrn/ipc-stamp
#   scripts/ipc-stamp.sh check [server-stamp] [client-stamp]
# A stamp is the git tree of the Monado source the build used (FETCHCONTENT_SOURCE_DIR_MONADO): for
# build/monado-snapshot its .snapshot-tree (`git -C third_party/monado write-tree` of the snapshotted index), else a
# hash of the files. Plus the socket name and the git tag. `check` defaults: the running wivrn-server's
# <dir>/ipc-stamp and MacVR's current bridge client (macvr/current/bridge/x86_64-unix/ipc-stamp). Exit 1 on a mismatch.
# wineopenxr.so does the same check at load (its log) against the published copy: game processes must not read
# anything under ~/Documents (TCC prompt), where the build dirs are.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cache_var() { sed -n "s/^$2:[A-Z]*=//p" "$1/CMakeCache.txt" | head -1; }

tree_of() {
	local src="$1" idx
	[[ -f "$src/.snapshot-tree" ]] && { cat "$src/.snapshot-tree"; return; }
	local gd
	gd="$(git -C "$ROOT/third_party/monado" rev-parse --absolute-git-dir)"
	idx="$(mktemp)"
	rm -f "$idx"
	GIT_INDEX_FILE="$idx" git --git-dir="$gd" --work-tree="$src" add -A -f -- . ':!.snapshot-*' 2>/dev/null
	GIT_INDEX_FILE="$idx" git --git-dir="$gd" write-tree
	rm -f "$idx"
}

case "${1:-}" in
	write)
		build="$2" out="$3"
		src="$(cache_var "$build" FETCHCONTENT_SOURCE_DIR_MONADO)"
		sock="$(cache_var "$build" XRT_IPC_MSG_SOCK_FILENAME)"
		tag="$(cache_var "$build" GIT_TAG)"
		[[ -d "$src" && -n "$sock" && -n "$tag" ]] || { echo "ipc-stamp: $build has no Monado source/socket/tag" >&2; exit 1; }
		printf 'monado-tree=%s\nsocket=%s\ngit-tag=%s\n' "$(tree_of "$src")" "$sock" "$tag" > "$out"
		echo "ipc-stamp: $out"; cat "$out" ;;
	publish)
		dir="$(getconf DARWIN_USER_TEMP_DIR)wivrn"
		mkdir -p "$dir"
		cp "$2/server/ipc-stamp" "$dir/ipc-stamp.new" && mv "$dir/ipc-stamp.new" "$dir/ipc-stamp" ;;
	check)
		server="${2:-}"
		if [[ -z "$server" ]]; then
			pid="$(pgrep -x wivrn-server | head -1 || true)"
			[[ -n "$pid" ]] || { echo "ipc-stamp: no wivrn-server running" >&2; exit 2; }
			exe="$(lsof -a -p "$pid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | grep '/wivrn-server$' | head -1 || true)"
			[[ -n "$exe" ]] || { echo "ipc-stamp: can't find the binary of wivrn-server $pid" >&2; exit 2; }
			server="$(dirname "$exe")/ipc-stamp"
		fi
		client="${3:-$HOME/Library/Application Support/macvr/current/bridge/x86_64-unix/ipc-stamp}"
		for f in "$server" "$client"; do [[ -f "$f" ]] || { echo "ipc-stamp: MISSING $f" >&2; exit 1; }; done
		if cmp -s "$server" "$client"; then
			echo "ipc-stamp: match ($(head -1 "$server"))"
		else
			echo "ipc-stamp: MISMATCH" >&2
			diff <(sed 's/^/server /' "$server") <(sed 's/^/client /' "$client") >&2 || true
			echo "server: $server" >&2; echo "client: $client" >&2
			exit 1
		fi ;;
	*) sed -n '2,8p' "$0" >&2; exit 2 ;;
esac
