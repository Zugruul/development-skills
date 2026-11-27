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
#   session.sh set --key feedback --value on|off   the feedback loop for this session (off by default)
#   session.sh afk on [--tiers 1|1,2] [--cleanup] [--lanes A,B] [--no-queued] [--until ISO-TIME]
#   session.sh afk off | status           AFK (off by default; only the afk skill sets it). Default scope:
#                                         tiers 1,2, all lanes, queued ideas (still only under a standing
#                                         worktree approval), no worktree removal, until the user returns
#   session.sh automerge on|off|status [--repo DIR [--lane L]]
#                                         auto-merge (off by default; only the auto-merge skill sets it), for
#                                         the session, one repository or one lane; the narrowest wins. A plain
#                                         "off" turns every one off
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
# shellcheck source=src/afk.sh
. "$HERE/src/afk.sh"

USAGE="session.sh set|add|del|show|path|find|afk|automerge [--session NAME] [options] (see the header of session.sh)"
LISTS="standing queued renames notes files"
args=()
session="graph" key="" value="" list="" text="" lane="" repo="" ref="" id="" pane="" as_json=0 tiers="1,2" cleanup=false lanes="" queued=true until=""
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
        --tiers) need_value "$1" $#; tiers="$2"; shift 2 ;;
        --cleanup) cleanup=true; shift ;;
        --lanes) need_value "$1" $#; lanes="$2"; shift 2 ;;
        --no-queued) queued=false; shift ;;
        --until) need_value "$1" $#; until="$2"; shift 2 ;;
        -*) usage "$USAGE" ;;
        *) args+=("$1"); shift ;;
    esac
done
[ "${#args[@]}" -ge 1 ] || usage "$USAGE"
cmd="${args[0]}" sub="${args[1]:-}"
case "$cmd" in afk | automerge) [ "${#args[@]}" -eq 2 ] || usage "$USAGE" ;; *) [ "${#args[@]}" -eq 1 ] || usage "$USAGE" ;; esac
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
        '{session: $s, orchestrator: "", pane: "", scratch: "", feedback: "off", next_id: 1, standing: [], queued: [], renames: [], notes: [], files: []} + .
         | '"$prog"' | .updated = $now' <<<"$cur")" || die "could not update $file"
    printf '%s' "$out" | write_yaml "$file"
    unlock
}

case "$cmd" in
set)
    case "$key" in orchestrator | pane | scratch) ;; feedback) case "$value" in on | off) ;; *) die "--key feedback takes on or off" 2 ;; esac ;; *) die "--key must be orchestrator, pane, scratch or feedback" 2 ;; esac
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
afk)
    case "$sub" in
        on)
            case "$tiers" in 1 | 1,2) ;; *) die "--tiers must be 1 or 1,2: tier 3 always waits for the user" 2 ;; esac
            case "$until" in '' | [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;; *) die "--until must be a UTC time like 2026-11-27T22:00:00Z" 2 ;; esac
            update '.afk = {state: "on", since: $now, until: $u, tiers: ($t | split(",") | map(tonumber)),
                    lanes: ($ls | split(",") | map(select(. != ""))), queued: $q, cleanup: $c}' \
                --arg t "$tiers" --arg ls "$lanes" --arg u "$until" --argjson q "$queued" --argjson c "$cleanup"
            afk_line "$session"
            echo "AFK cannot answer this chat's own permission prompt: one of those stops everything until you answer it. Permission settings are not changed for AFK." ;;
        off)
            update '.afk = {state: "off", ended: $now}'
            echo "AFK off"
            echo "Show what was decided (decide.sh digest), then ask what waited." ;;
        status) afk_line "$session" ;;
        *) usage "session.sh afk on|off|status" ;;
    esac ;;
automerge)
    root=""
    if [ -n "$repo" ] || [ -n "$lane" ]; then
        entry="$(repo_entry "${repo:-$(pwd)}")" || die "${repo:-$(pwd)} is not in a git repository" 2
        root="${entry#*$'\t'}"
    fi
    case "$sub" in
        on | off)
            if [ -n "$lane" ]; then
                update '.automerge.lanes[$r + "|" + $l] = $v' --arg r "$root" --arg l "$lane" --arg v "$sub"
            elif [ -n "$root" ]; then
                update '.automerge.repos[$r] = $v' --arg r "$root" --arg v "$sub"
            elif [ "$sub" = off ]; then
                update '.automerge = {session: "off", repos: {}, lanes: {}}'
            else
                update '.automerge.session = "on"'
            fi
            printf 'AUTOMERGE %s for %s\n' "$sub" "${lane:+lane $lane of }${root:-this session}" ;;
        status)
            printf 'AUTOMERGE %s\n' "$(automerge_state "$session" "${root:-}" "$lane")"
            if [ -z "$root" ]; then
                session_json "$session" | jq -r '(.automerge // {}) as $a | (($a.repos // {}) | to_entries[] | "  repository \(.key): \(.value)"),
                    (($a.lanes // {}) | to_entries[] | "  lane \(.key | split("|") | "\(.[1]) of \(.[0])"): \(.value)")'
            fi ;;
        *) usage "session.sh automerge on|off|status [--repo DIR [--lane L]]" ;;
    esac ;;
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
