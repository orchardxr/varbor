#!/usr/bin/env bash
# Obsolete since 2026-10-26: the bridge's client is built from WiVRn's tree (scripts/build-wivrn.sh --client-x86_64)
# and connects to wivrn/comp_ipc itself. Only needed for a standalone-tree client; --remove cleans up an old link.
# Point the bridge's Monado client (socket name monado_comp_ipc, built for the standalone service) at the WiVRn server.
#   scripts/wivrn-ipc-link.sh [runtime-dir]     (default: $(getconf DARWIN_USER_TEMP_DIR), what the client uses
#                                                when XDG_RUNTIME_DIR is unset, e.g. a game started by NotProton)
#   scripts/wivrn-ipc-link.sh --remove [runtime-dir]
# Creates <runtime-dir>/monado_comp_ipc -> $(getconf DARWIN_USER_TEMP_DIR)wivrn/comp_ipc. Both sides derive the
# Mach bootstrap name from the realpath of the socket (Monado patch 0012), so they agree through the symlink.
# A standalone monado-service started with the same runtime dir replaces the link with its own socket.
set -euo pipefail
remove=0
[[ "${1:-}" == --remove ]] && { remove=1; shift; }
tmp="$(getconf DARWIN_USER_TEMP_DIR)"
dir="${1:-$tmp}"
link="${dir%/}/monado_comp_ipc"
if [[ $remove == 1 ]]; then
	[[ -L "$link" ]] && rm -f "$link"
	exit 0
fi
mkdir -p "$dir"
if [[ -e "$link" && ! -L "$link" ]]; then
	echo "$link exists and is not a symlink (a monado-service running?)" >&2
	exit 1
fi
ln -sfn "${tmp}wivrn/comp_ipc" "$link"
echo "$link -> $(readlink "$link")"
