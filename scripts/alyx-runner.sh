#!/bin/zsh
# alyx-runner.sh <fex|rosetta|release> : move Half-Life: Alyx between notproton-fex (main), the global
# notproton-fex-rosetta and notproton-26.3 (CrossOver release). Quits Steam once (steam://exit), sets the per-game
# CompatToolMapping, swaps compatdata/546560 with the parked 546560.<flavor> prefix (release: NotProton builds a new
# one if none is parked), restarts Steam and runs `macvr rescan`.
set -u
WANT=${1:?fex|rosetta|release}
typeset -A TOOL=(fex notproton-fex-41073 rosetta '' release notproton-26.3)
(( ${+TOOL[$WANT]} )) || { echo "usage: $0 fex|rosetta|release" >&2; exit 2; }
APP=546560
S="$HOME/Library/Application Support/Steam"
C="$S/steamapps/compatdata"
flavor() {
	local b=("${(@f)$(cat "$1/notproton-build" 2>/dev/null)}")
	if [[ ${b[1]} == 26.* ]]; then echo release; elif [[ ${b[2]} == *FEX ]]; then echo fex; else echo rosetta; fi
}

CUR=$(flavor "$C/$APP")
MAP=$(python3 - "$S/config/config.vdf" $APP <<'EOF'
import re, sys
t = open(sys.argv[1]).read()
m = re.search(r'"CompatToolMapping"\s*\{\s*(?:"\d+"\s*\{[^{}]*\}\s*)*?"%s"\s*\{[^{}]*"name"\s*"([^"]*)"' % sys.argv[2], t)
print({'notproton-fex-41073': 'fex', 'notproton-26.3': 'release'}.get(m.group(1) if m else '', 'rosetta'))
EOF
)
if [[ $CUR == $WANT && $MAP == $WANT ]]; then echo "already $WANT"; exit 0; fi
[[ -d "$C/$APP.$WANT" || $CUR == $WANT || $WANT == release ]] || { echo "no parked prefix $C/$APP.$WANT" >&2; exit 1; }
[[ -e "$C/$APP.$CUR" && $CUR != $WANT ]] && { echo "$C/$APP.$CUR already exists" >&2; exit 1; }
pgrep -qf 'hlvr.exe' && { echo "Alyx is running" >&2; exit 1; }
[[ -n "$(find "$S/steamapps/downloading" -type f -size +0 2>/dev/null | head -1)" ]] && { echo "Steam is downloading" >&2; exit 1; }

if pgrep -xq steam_osx; then
	open steam://exit
	for i in {1..60}; do pgrep -xq steam_osx || break; sleep 1; done
	pgrep -xq steam_osx && { echo "Steam did not quit; quit it by hand and rerun" >&2; exit 1; }
fi

cp "$S/config/config.vdf" "$HOME/Library/Application Support/macvr/state/backup/config-$(date +%s).vdf"
python3 - "$S/config/config.vdf" $APP "${TOOL[$WANT]}" <<'EOF' || exit 1
import re, sys
p, app, tool = sys.argv[1:]
t = open(p).read()
j = t.index('{', t.index('"CompatToolMapping"'))
depth, k = 0, j
while True:
	depth += {'{': 1, '}': -1}.get(t[k], 0)
	if depth == 0: break
	k += 1
block = t[j:k]
block = re.sub(r'\n\t+"%s"\n\t+\{[^{}]*\}' % app, '', block)
if tool:
	ind = re.search(r'\n(\t+)"0"\n', block).group(1)
	block = block[:1] + f'\n{ind}"{app}"\n{ind}{{\n{ind}\t"name"\t\t"{tool}"\n{ind}\t"config"\t\t""\n{ind}\t"priority"\t\t"250"\n{ind}}}' + block[1:]
t = t[:j] + block + t[k:]
assert t.count('{') == t.count('}')
open(p, 'w').write(t)
EOF

if [[ $CUR != $WANT ]]; then
	mv "$C/$APP" "$C/$APP.$CUR" || exit 1
	[[ -d "$C/$APP.$WANT" ]] && { mv "$C/$APP.$WANT" "$C/$APP" || exit 1; }
fi
open -a Steam
for i in {1..60}; do pgrep -xq steam_osx && break; sleep 1; done
/Applications/MacVR.app/Contents/Helpers/macvr rescan
[[ -d "$C/$APP" ]] && echo "$APP: $(flavor "$C/$APP") prefix, mapping $WANT" || echo "$APP: mapping $WANT, NotProton builds the prefix on first launch"
