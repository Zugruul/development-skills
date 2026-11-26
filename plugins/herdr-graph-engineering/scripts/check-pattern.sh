#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# check-pattern.sh -- validate a pattern before any lane uses it.
# Usage: check-pattern.sh (FILE | --name NAME) [--repo DIR]
# Prints PATTERN OK <file> (<where>), or one PROBLEM line each and exits 6.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/common.sh
. "$HERE/src/common.sh"
# shellcheck source=src/pattern.sh
. "$HERE/src/pattern.sh"

USAGE="check-pattern.sh (FILE | --name NAME) [--repo DIR]"
file="" name="" repo=""
while [ $# -gt 0 ]; do
    case "$1" in
        --name) need_value "$1" $#; name="$2"; shift 2 ;;
        --repo) need_value "$1" $#; repo="$2"; shift 2 ;;
        -*) usage "$USAGE" ;;
        *) file="$1"; shift ;;
    esac
done
require_tools jq yq git
where="file"
if [ -n "$name" ]; then
    found="$(resolve patterns "$name" "$repo")" || die "NO PATTERN: $name (looked in the repository, ~/.config/herdr-graph and the plugin)" 6
    file="${found%%	*}" where="${found##*	}"
fi
[ -n "$file" ] || usage "$USAGE"
[ -f "$file" ] || die "no such file: $file" 2
json="$(yq -o=json '.' "$file" 2>&1)" || die "PROBLEM: not valid YAML: $json" 6
problems="$(pattern_problems "$json" "$repo")"
if [ -n "$problems" ]; then
    printf '%s\n' "$problems" | sed 's/^/PROBLEM: /'
    exit 6
fi
printf 'PATTERN OK %s (%s)\n' "$file" "$where"
