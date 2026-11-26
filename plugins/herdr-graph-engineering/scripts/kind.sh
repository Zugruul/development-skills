#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# kind.sh -- which agent kind runs a role on this machine, and the arguments it needs.
# Usage: kind.sh --role R [--repo DIR] [--not KIND] [--access read|write]
# Picks the first kind in the role's `kind:` list whose CLI is installed and that is not
# --not (so a reviewer differs from the implementer). Read-only access is enforced by the
# agent CLI itself, never by the brief alone.
# Prints: KIND <kind>, ARGS <arguments for herdr agent start after -->, ROLE <file> (<where>),
# and SAME-KIND when it had to fall back to the --not kind.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/common.sh
. "$HERE/src/common.sh"

USAGE="kind.sh --role R [--repo DIR] [--not KIND] [--access read|write]"
role="" repo="" not="" access=""
while [ $# -gt 0 ]; do
    case "$1" in
        --role) need_value "$1" $#; role="$2"; shift 2 ;;
        --repo) need_value "$1" $#; repo="$2"; shift 2 ;;
        --not) need_value "$1" $#; not="$2"; shift 2 ;;
        --access) need_value "$1" $#; access="$2"; shift 2 ;;
        *) usage "$USAGE" ;;
    esac
done
[ -n "$role" ] || usage "$USAGE"
require_tools jq yq
found="$(resolve roles "$role" "$repo")" || die "NO ROLE: $role" 6
rfile="${found%%	*}"
front="$(awk 'NR==1 && /^---$/ {f=1; next} f && /^---$/ {exit} f' "$rfile" | yq -o=json '.')" || die "ROLE: $rfile has no valid frontmatter" 6
[ -n "$access" ] || access="$(printf '%s' "$front" | jq -r '.access // "write"')"
case "$access" in read | write) ;; *) die "--access must be read or write" 2 ;; esac
model="$(printf '%s' "$front" | jq -r '.model // empty')"
kinds="$(printf '%s' "$front" | jq -r '(.kind // ["claude"]) | if type == "array" then .[] else . end')"

pick="" same=""
for k in $kinds; do
    command -v "$k" >/dev/null 2>&1 || continue
    if [ -n "$not" ] && [ "$k" = "$not" ]; then
        same="$k"
        continue
    fi
    pick="$k"
    break
done
if [ -z "$pick" ]; then
    [ -n "$same" ] || die "NO KIND: none of the role's kinds ($(printf '%s' "$kinds" | tr '\n' ' ')) is installed" 6
    pick="$same"
    echo "SAME-KIND: only $pick is installed; the report must say this review was same-model"
fi

args=""
if [ "$access" = read ]; then
    case "$pick" in
        claude) args="--disallowedTools Edit Write NotebookEdit" ;;
        opencode) args="--agent plan" ;;
        codex) args="--sandbox read-only" ;;
        *) die "READ-ONLY UNKNOWN: no known read-only mode for kind $pick; do not start it read-only" 6 ;;
    esac
fi
if [ -n "$model" ]; then
    case "$pick" in
        claude) args="$args --model $model" ;;
        opencode | codex) args="$args -m $model" ;;
    esac
fi
printf 'KIND %s\nARGS %s\nROLE %s (%s)\n' "$pick" "${args# }" "$rfile" "${found##*	}"
