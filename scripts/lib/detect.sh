# Machine-specific values, detected at run time. Source from bash or zsh.
#   quest_serial      QUEST_SERIAL, else the only device in `adb devices`
#   mac_ip            MAC_IP, else the IPv4 address of the default-route interface

quest_serial() {
	if [[ -n "${QUEST_SERIAL:-}" ]]; then echo "$QUEST_SERIAL"; return; fi
	local devs n
	devs=$(adb devices | awk 'NR > 1 && $2 == "device" { print $1 }')
	n=$(printf '%s' "$devs" | grep -c .)
	if [[ $n -ne 1 ]]; then
		echo "quest_serial: $n adb devices connected; connect exactly one or set QUEST_SERIAL" >&2
		return 1
	fi
	echo "$devs"
}

mac_ip() {
	if [[ -n "${MAC_IP:-}" ]]; then echo "$MAC_IP"; return; fi
	local ifc ip
	ifc=$(route -n get default 2>/dev/null | awk '/interface:/ { print $2 }')
	ip=$([[ -n "$ifc" ]] && ipconfig getifaddr "$ifc")
	if [[ -z "$ip" ]]; then
		echo "mac_ip: no IPv4 address on the default-route interface; set MAC_IP" >&2
		return 1
	fi
	echo "$ip"
}

# llvm-mingw root (x86_64 ucrt): LLVM_MINGW, else scripts/local.env, else x86_64-w64-mingw32-clang on PATH, else the
# newest ~/toolchains/llvm-mingw-*
llvm_mingw() {
	local d
	if [[ -z "${LLVM_MINGW:-}" && -f "$ROOT/scripts/local.env" ]]; then
		d=$(sed -n 's/^LLVM_MINGW=//p' "$ROOT/scripts/local.env" | tail -1)
		eval "d=\"$d\""
		[[ -z "$d" ]] || LLVM_MINGW=$d
	fi
	if [[ -n "${LLVM_MINGW:-}" ]]; then echo "$LLVM_MINGW"; return; fi
	if d=$(command -v x86_64-w64-mingw32-clang 2>/dev/null); then echo "${d%/bin/*}"; return; fi
	d=$(ls -d "$HOME"/toolchains/llvm-mingw-* 2>/dev/null | sort | tail -1)
	if [[ -z "$d" ]]; then
		echo "llvm_mingw: llvm-mingw not found; set LLVM_MINGW (or put LLVM_MINGW=<path> in scripts/local.env)" >&2
		return 1
	fi
	echo "$d"
}

# Vulkan headers dir (holds vulkan/vulkan_core.h): VULKAN_INCLUDE, else /usr/local/include (LunarG SDK), else Homebrew's
# vulkan-headers
vulkan_include() {
	local d
	for d in "${VULKAN_INCLUDE:-}" /usr/local/include "$(brew --prefix vulkan-headers 2>/dev/null)/include"; do
		[[ -n "$d" && -f "$d/vulkan/vulkan_core.h" ]] && { echo "$d"; return; }
	done
	echo "vulkan_include: no Vulkan headers; brew install vulkan-headers or set VULKAN_INCLUDE" >&2
	return 1
}
