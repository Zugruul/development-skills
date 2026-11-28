#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# drift.sh -- where the lane files and the live agents disagree, and the lane.sh command that fixes it.
# Usage: drift.sh [--repo DIR]... [--quiet] [--max-age S] [--gate-stall M]
# Why a script: a lane file changes only when the orchestrator records a node, and it records only
# what it is listening to; an agent that finished, asked or went away outside that leaves its lane
# stale. This reads the facts and says what to record; it never writes a lane file.
#
# 1. For every node recorded running whose agent Herdr shows idle or done, read the agent's
#    claim, in this order (src/result.sh): its hook's claim (scripts/hook.sh; the screen is then
#    not read), its result file <output>.result.json of this run, then its screen (herdr agent
#    read --source recent-unwrapped, so a long line is not wrapped), where only a line that is
#    `NODE <node> RESULT: pass|fail|question <ref>` or `NODE <node> STEP: <name> <result> <ref>`
#    counts, never a quote or an example. The reads are cached per repository in
#    <lane folder>/live.json ({"fetched": epoch seconds, "agents": {name: {status, seq, run,
#    kind, result, ref, line, source, seen_at}}}), which status.sh uses for the NEEDS YOU section
#    without reading screens. A question line with a newer prompt under it counts no more. An
#    agent with no claim whose status line shows background work (shells, background terminals;
#    its visible screen is read for this, also with a hook claim) is kind busy: not stopped. Each line ends with "# source: ..." naming where the claim is from.
# 2. Print every mismatch status.sh then derives, one line each:
#      DRIFT <lane>/<node> <what>: <detail> | <suggested command>
#    what: question, finished pass|fail (verify before recording; never record pass on the
#    agent's word; a claim that does not hold: lane.sh reject), step-fail, step-question,
#    agent-failed (the agent's own error), blocked, gone, stopped (idle without a RESULT line);
#    for a gate node, from
#    its heartbeat (src/gatefile.sh): gate-unrecorded (EXIT printed, never recorded: gate.sh
#    --collect), gate-lost (its process is gone without an EXIT line), gate-stalled (no output
#    for --gate-stall M minutes, default HERDR_GRAPH_GATE_STALL or 10, while its process tree
#    uses no CPU: a pager, a prompt?); and
#      DRIFT <lane> pr-merged: PR #N merged | cleanup.sh check (or run, once confirmed)
#    or NO DRIFT.
#   --quiet      refresh the cache, print nothing (the graph panel, in the background)
#   --max-age S  leave a repository whose cache is younger than S seconds (default 0: always read)
# Without --repo: the repositories status.sh reads (lane_repos in src/common.sh). Never fails its caller: without herdr nothing
# is read; while another drift.sh holds a repository's lock its cache stays as it was.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/common.sh
. "$HERE/src/common.sh"
# shellcheck source=src/result.sh
. "$HERE/src/result.sh"

USAGE="drift.sh [--repo DIR]... [--quiet] [--max-age S] [--gate-stall M]"
args=() quiet=0 max_age=0
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) need_value "$1" $#; args+=(--repo "$2"); shift 2 ;;
        --quiet) quiet=1; shift ;;
        --max-age) need_value "$1" $#; max_age="$2"; shift 2 ;;
        --gate-stall) need_value "$1" $#; export HERDR_GRAPH_GATE_STALL="$2"; shift 2 ;;
        *) usage "$USAGE" ;;
    esac
done
require_tools jq yq git

view() { bash "$HERE/status.sh" --json ${args[@]+"${args[@]}"} 2>/dev/null || echo '[]'; }

# The text of `herdr agent read`: plain text, or the text field of a JSON answer.
screen_of() { # agent [source] [lines]
    local out
    out="$(herdr agent read "$1" --source "${2:-recent-unwrapped}" --lines "${3:-120}" 2>/dev/null)" || return 0
    if jq -e 'type == "object"' >/dev/null 2>&1 <<<"$out"; then
        jq -r '((.result | objects) // {}) as $r | [$r.text, $r.content, $r.output] | map(strings) | .[0] // ""' <<<"$out"
    else
        printf '%s\n' "$out"
    fi
}

# What a settled agent finished with, in this order: its hook's claim (status.sh reads that
# itself, so the screen is not touched), its result file, then a strict screen line.
refresh() { # repo root, lane folder, its running nodes whose agents are idle or done (JSON)
    local d="$2" lock cache now fetched entries name node status seq run output hook found source
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
    # a unit separator, not a tab: read would merge the tabs around an empty field
    while IFS=$'\x1f' read -r name node status seq run output hook; do
        [ -n "$name" ] || continue
        case "$hook" in '' | none | permission) ;; *) continue ;; esac
        found="$(file_claim "$node" "$run" "$output")" source=result-file
        if [ -z "$found" ]; then
            if [ "$hook" = none ]; then
                found='{"kind":"none","result":"","ref":"","name":"","line":""}' source=stop-hook
            else
                found="$(screen_claim "$node" "$(screen_of "$name")")" source=screen
            fi
        fi
        # idle while its own background work runs is not stopped (src/result.sh)
        if [ "$(jq -r .kind <<<"$found")" = none ] &&
            background_work "$(jq -r --arg n "$name" '[.result.agents[]? | select(.name == $n) | .agent][0] // ""' <<<"$AGENT_LIST")" "$(screen_of "$name" visible 40)"; then
            found="$(jq -c '.kind = "busy"' <<<"$found")"
        fi
        entries="$(jq -c --arg n "$name" --arg s "$status" --argjson q "$seq" --argjson f "$found" --arg src "$source" --arg run "$run" --arg at "$(now)" \
            '. + {($n): ($f + {status: $s, seq: $q, run: $run, source: $src, seen_at: $at})}' <<<"$entries")"
    done < <(jq -r '.[] | [.agent, .node, .live, (.seq | tojson), .run, .output, (.claim.kind // "")] | map(gsub("[\u001f\n]"; " ")) | join("\u001f")' <<<"$3")
    jq -cn --argjson t "$now" --argjson a "$entries" '{fetched: $t, agents: $a}' >"$cache.tmp" && mv "$cache.tmp" "$cache"
    rmdir "$lock" 2>/dev/null
    return 0
}

v="$(view)"
if command -v herdr >/dev/null 2>&1; then
    AGENT_LIST="$(herdr agent list 2>/dev/null)" || AGENT_LIST='{}'
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
    def src: if (.source // "") != "" then "  # source: \(.source)" + (if (.rejected // 0) > 0 then ", after \(.rejected) rejected" else "" end) else "" end;
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
               "blocked: \($n.agent) " + (if ($d.ref // "") != "" then "waits for approval (\($d.ref))" else "waits on its screen" end)
               + " | herdr agent read \($n.agent) --source visible --lines 80, then lane.sh ask \($at) \($at2) --text QUESTION"
           elif $d.kind == "agent-failed" then
               "agent-failed: \($n.agent): \($d.ref) | herdr agent read \($n.agent) --source visible --lines 80, then tell the user"
           elif ($d.kind | startswith("step-")) then
               "\($d.kind): \($n.agent): \($d.ref) | verify it, then lane.sh step \($at) \($at2) --name \($d.name) --result \(if $d.result == "pass" then "pass" else "fail" end)"
               + (if $d.stepref != "" then " --ref \($d.stepref | q)" else "" end)
           elif $d.kind == "gate-unrecorded" then
               "gate-unrecorded: finished \($d.ref), never recorded | gate.sh --collect \($at) \($at2)"
           elif $d.kind == "gate-lost" then
               "gate-lost: gate process \($d.ref) is gone without an EXIT line | herdr pane read \($n.gate.pane) --source recent --lines 80, then gate.sh --collect \($at) \($at2) (reads its EXIT line), else lane.sh node \($at) \($at2) --status waiting (to run it again)"
           elif $d.kind == "gate-stalled" then
               "gate-stalled: no output for \($d.ref) | herdr pane read \($n.gate.pane) --source recent --lines 80 (a pager or a prompt?), then gate.sh --wait \($at) \($at2), or stop it"
           elif $d.kind == "gone" then
               "gone: agent \($n.agent) is gone | lane.sh node \($at) \($at2) --status waiting (to start it again), or ask the user"
           else
               "stopped: \($n.agent) is idle without a RESULT line | herdr agent read \($n.agent) --source visible --lines 80, then prompt it to finish or record what it did"
           end + ($d | src)),
      (select(.pr_merged != null)
       | "DRIFT \(.lane) pr-merged: PR #\(.pr_merged.number) merged | "
         + if .cleanup == "confirmed" then "cleanup.sh run \($at)" else "cleanup.sh check \($at)" end)' <<<"$v")"
if [ -n "$out" ]; then printf '%s\n' "$out"; else echo "NO DRIFT"; fi
exit 0
