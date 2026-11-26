#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# drift.sh -- where the lane files and the live agents disagree, and the lane.sh command that fixes it.
# Usage: drift.sh [--repo DIR]... [--quiet] [--max-age S]
# Why a script: a lane file changes only when the orchestrator records a node, and it records only
# what it is listening to; an agent that finished, asked or went away outside that leaves its lane
# stale. This reads the facts and says what to record; it never writes a lane file.
#
# 1. For every node recorded running whose agent Herdr shows idle or done, read the agent's
#    screen (herdr agent read --source recent-unwrapped, so a long line is not wrapped) and take
#    its last line `NODE <node> RESULT: pass|fail|question <ref>`. The reads are cached per
#    repository in <lane folder>/live.json ({"fetched": epoch seconds, "agents": {name: {status,
#    seq, result, ref}}}), which status.sh uses for the NEEDS YOU section without reading screens.
# 2. Print every mismatch status.sh then derives, one line each:
#      DRIFT <lane>/<node> <what>: <detail> | <suggested command>
#    what: question, finished pass|fail (verify before recording; never record pass on the
#    agent's word), blocked, gone, stopped (idle without a RESULT line), and
#      DRIFT <lane> pr-merged: PR #N merged | cleanup.sh check (or run, once confirmed)
#    or NO DRIFT.
#   --quiet      refresh the cache, print nothing (the graph panel, in the background)
#   --max-age S  leave a repository whose cache is younger than S seconds (default 0: always read)
# Without --repo: the repositories status.sh reads. Never fails its caller: without herdr nothing
# is read; while another drift.sh holds a repository's lock its cache stays as it was.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/common.sh
. "$HERE/src/common.sh"

USAGE="drift.sh [--repo DIR]... [--quiet] [--max-age S]"
args=() quiet=0 max_age=0
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) need_value "$1" $#; args+=(--repo "$2"); shift 2 ;;
        --quiet) quiet=1; shift ;;
        --max-age) need_value "$1" $#; max_age="$2"; shift 2 ;;
        *) usage "$USAGE" ;;
    esac
done
require_tools jq yq git

view() { bash "$HERE/status.sh" --json ${args[@]+"${args[@]}"} 2>/dev/null || echo '[]'; }

# The text of `herdr agent read`: plain text, or the text field of a JSON answer.
screen_of() { # agent
    local out
    out="$(herdr agent read "$1" --source recent-unwrapped --lines 120 2>/dev/null)" || return 0
    if jq -e 'type == "object"' >/dev/null 2>&1 <<<"$out"; then
        jq -r '((.result | objects) // {}) as $r | [$r.text, $r.content, $r.output] | map(strings) | .[0] // ""' <<<"$out"
    else
        printf '%s\n' "$out"
    fi
}

# The last RESULT line of a node on a screen, as "result<TAB>ref"; nothing when there is none.
# shellcheck disable=SC2016  # the backtick is a character to strip, not an expansion
result_of() { # node, screen text
    printf '%s\n' "$2" | sed -nE "s/.*NODE $1 RESULT: (pass|fail|question)([[:space:]]+(.*))?\$/\\1	\\3/p" | tail -1 |
        sed -E 's/[`[:space:]]+$//; s/	[`[:space:]]+/	/'
}

refresh() { # repo root, its lanes' running nodes whose agents are idle or done (JSON)
    local d="$2" lock cache now fetched entries name node status seq r ref
    lock="$d/live.lock" cache="$d/live.json"
    now="$(date +%s)"
    if [ "$max_age" -gt 0 ] && [ -f "$cache" ]; then
        fetched="$(jq -r '.fetched // 0' "$cache" 2>/dev/null)" || fetched=0
        [ $((now - ${fetched:-0})) -ge "$max_age" ] || return 0
    fi
    # one reader per repository at a time; a lock left by a reader that died is taken after a minute
    if ! mkdir "$lock" 2>/dev/null; then
        [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ] || return 0
        rm -rf "$lock" && mkdir "$lock" 2>/dev/null || return 0
    fi
    entries="{}"
    while IFS="	" read -r name node status seq; do
        [ -n "$name" ] || continue
        r="$(result_of "$node" "$(screen_of "$name")")" ref=""
        [ "${r#*	}" = "$r" ] || ref="${r#*	}"
        entries="$(jq -c --arg n "$name" --arg s "$status" --argjson q "$seq" --arg r "${r%%	*}" --arg f "$ref" \
            '. + {($n): {status: $s, seq: $q, result: $r, ref: $f}}' <<<"$entries")"
    done < <(jq -r '.[] | [.agent, .node, .live, (.seq | tojson)] | @tsv' <<<"$3")
    jq -cn --argjson t "$now" --argjson a "$entries" '{fetched: $t, agents: $a}' >"$cache.tmp" && mv "$cache.tmp" "$cache"
    rmdir "$lock" 2>/dev/null
    return 0
}

v="$(view)"
if command -v herdr >/dev/null 2>&1; then
    while IFS="	" read -r root; do
        [ -n "$root" ] || continue
        d="$(lane_dir "$root" 2>/dev/null)" || continue
        [ -d "$d" ] || continue
        refresh "$root" "$d" "$(jq -c --arg r "$root" '[.[] | select(.root == $r and .section != "closed") | .nodes[]
            | select(.status == "running" and .agent != "" and (.live == "idle" or .live == "done"))]' <<<"$v")"
    done < <(jq -r '[.[].root] | unique | .[]' <<<"$v")
    v="$(view)"
fi
[ "$quiet" -eq 0 ] || exit 0

# shellcheck disable=SC2016  # $l, $n, $q and $c are jq variables
out="$(jq -r '
    def q: if test("^[A-Za-z0-9_./:@%+=,-]+$") then . else @sh end;
    .[] | select(.section != "closed") | . as $l | ("--repo \(.root | q) --lane \(.lane)") as $at
    | (.nodes[] | select(.drift != null) | . as $n | .drift as $d | "--node \($n.node)" as $at2
       | "DRIFT \($l.lane)/\($n.node) "
         + if $d.kind == "question" then
               "question: \($n.agent) asks: \($d.ref) | lane.sh ask \($at) \($at2) --text \("\($n.node) (\($n.agent)) asks: \($d.ref)" | q)"
           elif $d.kind == "pass" then
               "finished pass \($d.ref): verify it, then | lane.sh node \($at) \($at2) --status done --result pass --ref \($d.ref | q)"
           elif $d.kind == "fail" then
               "finished fail \($d.ref): verify it, then | lane.sh node \($at) \($at2) --status failed --result fail --ref \($d.ref | q)"
           elif $d.kind == "blocked" then
               "blocked: \($n.agent) waits on its screen | herdr agent read \($n.agent) --source visible --lines 80, then lane.sh ask \($at) \($at2) --text QUESTION"
           elif $d.kind == "gone" then
               "gone: agent \($n.agent) is gone | lane.sh node \($at) \($at2) --status waiting (to start it again), or ask the user"
           else
               "stopped: \($n.agent) is idle without a RESULT line | herdr agent read \($n.agent) --source visible --lines 80, then prompt it to finish or record what it did"
           end),
      (select(.pr_merged != null)
       | "DRIFT \(.lane) pr-merged: PR #\(.pr_merged.number) merged | "
         + if .cleanup == "confirmed" then "cleanup.sh run \($at)" else "cleanup.sh check \($at)" end)' <<<"$v")"
if [ -n "$out" ]; then printf '%s\n' "$out"; else echo "NO DRIFT"; fi
exit 0
