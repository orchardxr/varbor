#!/usr/bin/env bash
# Manage the pinned third_party trees and our staged (never committed) patch stacks.
#
#   patches.sh apply  [project...]   reset to the pin, then git apply --index every patch
#   patches.sh reset  [project...]   reset to the pin, no patches
#   patches.sh status [project...]   pin, HEAD, patch count, staged/unstaged summary
#   patches.sh new <project> <NNNN-name|name>
#                                    export unstaged changes + untracked files as the
#                                    next patch in patches/<project>/, then stage them
#
# Projects are the directories under patches/ whose third_party/<project> is a submodule.
# The pin is the submodule commit recorded in the superproject's index (bump it with
# `git add third_party/<project>` after checking out the new upstream commit).
# For monado, WiVRn's own third_party/wivrn/patches/monado/* are applied first (in
# glob order, like wivrn's apply.sh), so wivrn must be checked out at its pin.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCHES="$ROOT/patches"
TP="$ROOT/third_party"

die() { echo "patches.sh: $*" >&2; exit 1; }
log() { echo "==> $*"; }

pin_of() { git -C "$ROOT" ls-files -s -- "third_party/$1" | awk '$1 == "160000" { print $2 }'; }

all_projects() {
	local d
	for d in "$PATCHES"/*/; do
		d="$(basename "$d")"
		[[ -n "$(pin_of "$d")" ]] && echo "$d"
	done
}

check_project() {
	[[ -n "$(pin_of "$1")" ]] || die "unknown project '$1' (third_party/$1 is not a submodule)"
	[[ -d "$TP/$1/.git" || -f "$TP/$1/.git" ]] || die "third_party/$1 is not checked out (git submodule update --init third_party/$1)"
}

base_of() { pin_of "$1"; }

git_p() { git -C "$TP/$1" "${@:2}"; }

patch_list() {
	local p="$1" f
	shopt -s nullglob
	if [[ "$p" == monado ]]; then
		local wivrn_base
		wivrn_base="$(base_of wivrn)"
		[[ "$(git_p wivrn rev-parse HEAD)" == "$(git_p wivrn rev-parse "$wivrn_base^{commit}")" ]] \
			|| die "third_party/wivrn is not at its pin; run 'patches.sh apply wivrn' first"
		for f in "$TP"/wivrn/patches/monado/*; do
			[[ -f "$f" ]] && echo "$f"
		done
	fi
	for f in "$PATCHES/$p"/*.patch; do
		echo "$f"
	done
	shopt -u nullglob
}

do_reset() {
	local p="$1" base
	check_project "$p"
	base="$(base_of "$p")"
	git_p "$p" cat-file -e "$base^{commit}" 2>/dev/null || git_p "$p" fetch -q origin "$base"
	log "$p: reset to $base"
	git_p "$p" am --abort >/dev/null 2>&1 || true
	git_p "$p" checkout -q --detach -f "$base"
	git_p "$p" reset -q --hard "$base"
	git_p "$p" clean -q -fdx
}

do_apply() {
	local p="$1" f n=0
	local list
	list="$(patch_list "$p")"
	do_reset "$p"
	while IFS= read -r f; do
		[[ -n "$f" ]] || continue
		echo "    apply ${f#"$ROOT"/}"
		git_p "$p" apply --index --whitespace=nowarn "$f" || die "$p: failed to apply $f"
		n=$((n + 1))
	done <<< "$list"
	log "$p: $n patches staged"
}

do_status() {
	local p="$1" base head nours
	check_project "$p"
	base="$(base_of "$p")"
	head="$(git_p "$p" rev-parse HEAD)"
	nours=$(find "$PATCHES/$p" -maxdepth 1 -name '*.patch' | wc -l | tr -d ' ')
	echo "== $p"
	echo "   pin  $base"
	if [[ "$head" == "$(git_p "$p" rev-parse "$base^{commit}" 2>/dev/null || echo none)" ]]; then
		echo "   HEAD at pin"
	else
		echo "   HEAD $head  (NOT at pin)"
	fi
	echo "   our patches: $nours"
	echo "   staged:   $(git_p "$p" diff --cached --shortstat || true)"
	echo "   unstaged: $(git_p "$p" diff --shortstat || true)"
	local untracked
	untracked="$(git_p "$p" ls-files --others --exclude-standard | wc -l | tr -d ' ')"
	echo "   untracked files: $untracked"
}

do_new() {
	local p="$1" name="$2" last num file
	check_project "$p"
	name="${name%.patch}"
	if [[ ! "$name" =~ ^[0-9]{4}- ]]; then
		last=$(find "$PATCHES/$p" -maxdepth 1 -name '[0-9][0-9][0-9][0-9]-*.patch' -exec basename {} \; | sort | tail -n1)
		num=1
		[[ -z "$last" ]] || num=$(( 10#${last:0:4} + 1 ))
		name="$(printf '%04d' "$num")-$name"
	fi
	file="$PATCHES/$p/$name.patch"
	[[ ! -e "$file" ]] || die "$file already exists"

	git_p "$p" ls-files -z --others --exclude-standard | xargs -0 -r git -C "$TP/$p" add -N --
	if git_p "$p" diff --quiet; then
		die "$p: no unstaged changes to export"
	fi
	{
		echo "From: macvr"
		echo "Subject: [PATCH] ${name#[0-9][0-9][0-9][0-9]-}"
		echo
		echo "---"
		git_p "$p" diff --stat
		echo
		git_p "$p" diff --binary --full-index
	} > "$file"
	git_p "$p" add -A
	log "wrote ${file#"$ROOT"/} and staged it"
}

cmd="${1:-}"
[[ -n "$cmd" ]] || die "usage: patches.sh {apply|reset|status} [project...] | new <project> <name>"
shift

case "$cmd" in
	apply | reset | status)
		if [[ $# -eq 0 ]]; then
			projects=()
			while IFS= read -r p; do projects+=("$p"); done < <(all_projects)
			# wivrn first: monado's patch list depends on it
			ordered=()
			for p in wivrn "${projects[@]}"; do
				[[ " ${ordered[*]-} " == *" $p "* ]] || [[ ! " ${projects[*]} " == *" $p "* ]] || ordered+=("$p")
			done
			set -- "${ordered[@]}"
		fi
		for p in "$@"; do
			case "$cmd" in
				apply) do_apply "$p" ;;
				reset) do_reset "$p" ;;
				status) do_status "$p" ;;
			esac
		done
		;;
	new)
		[[ $# -eq 2 ]] || die "usage: patches.sh new <project> <name>"
		do_new "$1" "$2"
		;;
	*) die "unknown command '$cmd'" ;;
esac
