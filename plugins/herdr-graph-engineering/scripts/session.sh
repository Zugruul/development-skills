#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# session.sh -- the only writer of the orchestrator's session file.
#
# The session file holds what the orchestrator learned in its chat that is not about one lane
# and that a compaction would lose: its pane and scratch folder, the user's standing answers,
# lanes queued at the agent limit, renames, notes and scratch files worth finding again.
# Facts about one lane go in its lane file instead (lane.sh note / done-extra).
# One file per orchestrator, per user (it spans repositories):
#   ${XDG_STATE_HOME:-~/.local/state}/herdr-graph/sessions/<session>.yaml
# Every write takes the folder's lock, writes a temporary file and renames it.
# Text that looks like a token, key or password is refused: never store secrets here.
#
# Usage (every command takes --session NAME, default graph):
#   session.sh set --key orchestrator|pane|scratch --value V
#   session.sh add --list standing|queued|renames|notes|files --text T [--lane L] [--repo DIR] [--ref PATH]
#                                         queued needs --lane; --ref is its prepared brief
#   session.sh del --list LIST (--id N | --lane L)
#   session.sh show [--json]
#   session.sh path                       the session file's path
#   session.sh find --pane P              the session whose pane is P (exit 1 when none)
# Exit codes: 0 ok, 1 error or not found, 2 usage, 6 no session or no such item.
# shellcheck disable=SC2016
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/common.sh
. "$HERE/src/common.sh"

USAGE="session.sh set|add|del|show|path|find [--session NAME] [options] (see the header of session.sh)"
LISTS="standing queued renames notes files"
args=()
session="graph" key="" value="" list="" text="" lane="" repo="" ref="" id="" pane="" as_json=0
while [ $# -gt 0 ]; do
    case "$1" in
        --session) need_value "$1" $#; session="$2"; shift 2 ;;
        --key) need_value "$1" $#; key="$2"; shift 2 ;;
        --value) need_value "$1" $#; value="$2"; shift 2 ;;
        --list) need_value "$1" $#; list="$2"; shift 2 ;;
        --text) need_value "$1" $#; text="$2"; shift 2 ;;
        --lane) need_value "$1" $#; lane="$2"; shift 2 ;;
        --repo) need_value "$1" $#; repo="$2"; shift 2 ;;
        --ref) need_value "$1" $#; ref="$2"; shift 2 ;;
        --id) need_value "$1" $#; id="$2"; shift 2 ;;
        --pane) need_value "$1" $#; pane="$2"; shift 2 ;;
        --json) as_json=1; shift ;;
        -*) usage "$USAGE" ;;
        *) args+=("$1"); shift ;;
    esac
done
[ "${#args[@]}" -eq 1 ] || usage "$USAGE"
cmd="${args[0]}"
require_tools jq yq
[ "$(slug "$session")" = "$session" ] || die "SESSION NAME: '$session' must be a lowercase slug, for example $(slug "$session")" 2
dir="$(session_dir)"
file="$dir/$session.yaml"

need_list() {
    case " $LISTS " in *" $list "*) ;; *) die "--list must be one of: $LISTS" 2 ;; esac
}
no_secret() { # text...
    local t
    for t in "$@"; do
        ! looks_secret "$t" || die "SECRET: that looks like a token, key or password; it is never stored. Keep only where it lives (an env var name, a file path)." 2
    done
}

# Apply a jq program to the session under the lock, stamp it, write it back.
update() { # jq program, extra jq args...
    local prog="$1" out cur='{}'
    shift
    lock_in "$dir"
    [ -f "$file" ] && cur="$(read_json "$file")"
    [ -n "$cur" ] && [ "$cur" != null ] || cur='{}'
    out="$(jq -c --arg now "$(now)" --arg s "$session" "$@" \
        '{session: $s, orchestrator: "", pane: "", scratch: "", next_id: 1, standing: [], queued: [], renames: [], notes: [], files: []} + .
         | '"$prog"' | .updated = $now' <<<"$cur")" || die "could not update $file"
    printf '%s' "$out" | write_yaml "$file"
    unlock
}

case "$cmd" in
set)
    case "$key" in orchestrator | pane | scratch) ;; *) die "--key must be orchestrator, pane or scratch" 2 ;; esac
    [ -n "$value" ] || usage "session.sh set --key K --value V"
    no_secret "$value"
    update '.[$k] = $v' --arg k "$key" --arg v "$value"
    printf 'SET %s %s = %s\n' "$session" "$key" "$value" ;;
add)
    need_list
    [ -n "$text" ] || usage "session.sh add --list $list --text T [--lane L] [--repo DIR] [--ref PATH]"
    [ "$list" != queued ] || [ -n "$lane" ] || die "a queued lane needs --lane L (and --ref to its prepared brief)" 2
    no_secret "$text" "$ref"
    update '.next_id as $id | .next_id += 1
            | .[$l] += [{id: $id, text: $t, at: $now}
                        + (if $lane != "" then {lane: $lane} else {} end)
                        + (if $repo != "" then {repo: $repo} else {} end)
                        + (if $ref != "" then {ref: $ref} else {} end)]' \
        --arg l "$list" --arg t "$text" --arg lane "$lane" --arg repo "$repo" --arg ref "$ref"
    printf 'ADDED %s %s\n' "$list" "$(yq -r ".${list}[-1].id" "$file")" ;;
del)
    need_list
    [ -n "$id" ] || [ -n "$lane" ] || usage "session.sh del --list LIST (--id N | --lane L)"
    [ -f "$file" ] || die "NO SESSION $session ($file)" 6
    case "$id" in '' | *[!0-9]*) [ -z "$id" ] || die "--id must be a number" 2 ;; esac
    hit="$(jq -r --arg l "$list" --arg id "$id" --arg lane "$lane" \
        '[.[$l] // [] | .[] | select(($id != "" and (.id | tostring) == $id) or ($lane != "" and .lane == $lane))] | length' <<<"$(read_json "$file")")"
    [ "${hit:-0}" -gt 0 ] || die "NO ITEM in $list${id:+ with id $id}${lane:+ for lane $lane}" 6
    update '.[$l] |= map(select(($id != "" and (.id | tostring) == $id) or ($lane != "" and .lane == $lane) | not))' \
        --arg l "$list" --arg id "$id" --arg lane "$lane"
    printf 'DELETED %s %s\n' "$list" "$hit" ;;
show)
    [ -f "$file" ] || die "NO SESSION $session ($file)" 6
    if [ "$as_json" -eq 1 ]; then read_json "$file"; else cat "$file"; fi ;;
path) printf '%s\n' "$file" ;;
find)
    [ -n "$pane" ] || usage "session.sh find --pane P"
    for f in "$dir"/*.yaml; do
        [ -f "$f" ] || continue
        if [ "$(yq -r '.pane // ""' "$f" 2>/dev/null)" = "$pane" ]; then
            basename "$f" .yaml
            exit 0
        fi
    done
    exit 1 ;;
*) usage "$USAGE" ;;
esac
