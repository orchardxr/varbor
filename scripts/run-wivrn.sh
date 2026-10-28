#!/usr/bin/env bash
# Run the WiVRn server built by scripts/build-wivrn.sh.
#   scripts/run-wivrn.sh [wivrn-server args...]     e.g. --pairing, --no-encrypt, --no-fork
#
# - Homebrew MoltenVK 1.4.2 (scripts/env-macos.sh).
# - Does not touch ~/.config/openxr/1/active_runtime.json (--no-manage-active-runtime); OpenXR apps
#   use XR_RUNTIME_JSON=build/wivrn/openxr_wivrn-dev.json instead (see docs/wivrn.md).
# - Log: build/logs/wivrn-server.log (also on stdout).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=env-macos.sh
source "$ROOT/scripts/env-macos.sh"
mkdir -p "$ROOT/build/logs"

export XRT_LOG="${XRT_LOG:-info}"
# publish the server's ipc-stamp for the bridge (scripts/ipc-stamp.sh) once the server runs
(sleep 2; "$ROOT/scripts/ipc-stamp.sh" publish "$ROOT/build/wivrn") &
exec "$ROOT/build/wivrn/server/wivrn-server" --no-manage-active-runtime "$@" 2>&1 | tee "$ROOT/build/logs/wivrn-server.log"
