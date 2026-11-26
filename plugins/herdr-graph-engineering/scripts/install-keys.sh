#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# install-keys.sh -- the keyboard shortcut for the graph panel: PREFIX then Alt+G toggles it.
# Usage: install-keys.sh [--write]
#   (no flag)  print the binding and the config file it belongs in; change nothing
#   --write    append it to Herdr's config.toml (a backup first), check it with
#              `herdr config check`, and put the backup back if the check fails
# Idempotent: when the toggle action is already bound (to any key) it says so and writes
# nothing; when PREFIX then Alt+G is already used by something else it refuses.
# Herdr plugin manifests cannot declare keys, so the binding lives in the user's config.
# The config file is $HERDR_CONFIG_PATH, else ~/.config/herdr/config.toml (as Herdr reads it).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/common.sh
. "$HERE/src/common.sh"

KEY="prefix+alt+g"
ACTION="herdr-graph-engineering.graph.toggle"
CFG="${HERDR_CONFIG_PATH:-$HOME/.config/herdr/config.toml}"
write=0
case "${1:-}" in
"") ;;
--write) write=1 ;;
*) usage "install-keys.sh [--write]" ;;
esac
require_tools yq jq

snippet() {
    printf '[[keys.command]]\nkey = "%s"\ntype = "plugin_action"\ncommand = "%s"\ndescription = "Graph: toggle panel"\n' "$KEY" "$ACTION"
}

bound="" taken=""
if [ -s "$CFG" ]; then
    json="$(yq -p=toml -o=json '.' "$CFG" 2>/dev/null)" ||
        die "cannot read $CFG; fix it first (herdr config check), nothing was changed"
    # The key already bound to the toggle action, if any.
    bound="$(jq -r --arg a "$ACTION" '[.keys.command[]? | select(.command == $a) | .key | if type == "array" then .[] else . end][0] // empty' <<<"$json")"
    # Anything else under [keys] that already uses PREFIX then Alt+G.
    taken="$(jq -r --arg k "$KEY" --arg a "$ACTION" '
        def uses: (if type == "array" then .[] else . end) | strings | ascii_downcase == $k;
        [(.keys // {} | to_entries[] | select(.key != "command" and (.value | uses)) | .key),
         (.keys.command[]? | select(.command != $a and (.key | uses)) | "keys.command " + (.command // "?"))][0] // empty' <<<"$json")"
fi

if [ -n "$bound" ]; then
    echo "ALREADY BOUND $bound -> $ACTION in $CFG"
    exit 0
fi
[ -z "$taken" ] || die "$KEY is already used in $CFG (by $taken); bind $ACTION to another key by hand, nothing was changed"

if [ "$write" -eq 0 ]; then
    echo "Add this to $CFG, then run: herdr server reload-config"
    echo
    snippet
    echo
    echo "Or run: bash $HERE/install-keys.sh --write   (backs the file up and checks it)"
    exit 0
fi

require_tools herdr
mkdir -p "$(dirname "$CFG")" || die "cannot create $(dirname "$CFG")"
bak=""
if [ -e "$CFG" ]; then
    bak="$CFG.bak.$(date +%Y%m%d%H%M%S)"
    cp -p "$CFG" "$bak" || die "cannot back up $CFG, nothing was changed"
fi
# Start on a fresh line, apart from what is there.
sep=""
if [ -s "$CFG" ]; then
    sep=$'\n'
    [ -n "$(tail -c1 "$CFG")" ] && sep=$'\n\n'
fi
{
    printf '%s' "$sep"
    snippet
} >>"$CFG" || die "cannot write $CFG"

if ! check="$(HERDR_CONFIG_PATH="$CFG" herdr config check 2>&1)"; then
    if [ -n "$bak" ]; then
        cp -p "$bak" "$CFG" && rm -f "$bak"
        die "herdr config check failed after the change; restored $CFG from the backup:
$check"
    fi
    rm -f "$CFG"
    die "herdr config check failed after the change; removed the new $CFG (restored to nothing):
$check"
fi
echo "KEYS WRITTEN $KEY -> $ACTION in $CFG${bak:+ (backup: $bak)}"
echo "Load it now: herdr server reload-config"
