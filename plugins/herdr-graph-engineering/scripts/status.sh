#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# status.sh -- the picture of every lane, derived each time from the lane files and Herdr.
# Reads only. Used by the display skill, the tab bar line and the graph panel.
# Usage: status.sh [--text | --line | --json | --tokens] [--repo DIR]...
# Without --repo: every repository that may hold lanes (lane_repos in src/common.sh: Herdr's
# workspaces and panes, lane.sh's registry and the current one). --repo: those, plus the current one.
#   --text   NEEDS YOU / WORKING / DONE, one line per lane with its node chain (default)
#   --line   one short line for Herdr's tab bar
#   --json   the same facts for a program, with each lane's pull requests from prs.sh's cache;
#            closed lanes too (section "closed", with when they closed and the repository read)
#   --tokens write each live node agent's step into Herdr's sidebar (pane tokens $lane, $node,
#            $step), so a sidebar row layout can show it; display only, lost on a Herdr restart
# Live facts, not only the lane file: a node recorded running whose agent is blocked, gone
# (not in `herdr agent list`), or finished (idle or done, with the RESULT line drift.sh read
# from its screen and cached in <lane folder>/live.json) puts its lane under NEEDS YOU with a
# line in "attention" (a question becomes the lane's question, question_live true), and so
# does a lane whose own pull request merged (prs.sh's cache) until its cleanup is confirmed
# or declined. A cached read counts only while the agent is still in the state it was read
# in (same status and state_change_seq). status.sh never reads a screen; drift.sh does.
# A gate node recorded running carries its run's heartbeat (src/gatefile.sh) as "gate" and a
# "progress" line (elapsed, ok/FAIL counts, last output line). It needs the user when the run
# finished but was never recorded, its process is gone without an EXIT line, or its log has not
# grown for HERDR_GRAPH_GATE_STALL minutes (default 10).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/common.sh
. "$HERE/src/common.sh"
# shellcheck source=src/style.sh
. "$HERE/src/style.sh"
# shellcheck source=src/gatefile.sh
. "$HERE/src/gatefile.sh"

mode="text" repos=""
while [ $# -gt 0 ]; do
    case "$1" in
        --text) mode=text; shift ;;
        --line) mode=line; shift ;;
        --json) mode=json; shift ;;
        --tokens) mode=tokens; shift ;;
        --repo) need_value "$1" $#; repos="$repos
$2"; shift 2 ;;
        *) usage "status.sh [--text | --line | --json | --tokens] [--repo DIR]..." ;;
    esac
done
require_tools jq yq git

agents="[]" have_agents=0
if command -v herdr >/dev/null 2>&1; then
    a="$(herdr agent list 2>/dev/null)" &&
        agents="$(printf '%s' "$a" | jq -ce '[.result.agents[] | {name: (.name // ""), status: (.agent_status // "unknown"), pane: (.pane_id // ""), seq: (.state_change_seq // null)}]' 2>/dev/null)" &&
        have_agents=1 || agents="[]"
fi
if [ -z "$repos" ]; then
    repos="$(lane_repos)"
else
    here_root="$(git rev-parse --show-toplevel 2>/dev/null)" && repos="$repos
$here_root"
fi

# one JSON object per lane, open or closed, each repository's lane folder read once
lanes="[]" seen=""
while IFS= read -r r; do
    [ -n "$r" ] || continue
    d="$(lane_dir "$r" 2>/dev/null)" || continue
    case "$seen" in *"|$d|"*) continue ;; esac
    seen="$seen|$d|"
    # each lane's pull requests, from prs.sh's cache (read only; never asks gh)
    prs="$(jq -c '.lanes // {}' "$d/prs.json" 2>/dev/null)" || prs="{}"
    [ -n "$prs" ] || prs="{}"
    # what drift.sh last read from each finished agent's screen
    live="$(jq -c '.agents // {}' "$d/live.json" 2>/dev/null)" || live="{}"
    [ -n "$live" ] || live="{}"
    # each gate run's heartbeat with its live facts (src/gatefile.sh), by lane and node
    gates="{}"
    for g in "$d"/gates/*/*.json; do
        [ -f "$g" ] || continue
        gf="$(gate_facts "$g")" || continue
        gates="$(jq -c --arg l "$(basename "$(dirname "$g")")" --arg n "$(basename "$g" .json)" --argjson f "$gf" '.[$l][$n] = $f' <<<"$gates")"
    done
    for f in "$d"/*.yaml "$d"/closed/*.yaml; do
        [ -f "$f" ] || continue
        lanes="$(jq -c --argjson l "$(read_json "$f")" --argjson p "$prs" --argjson v "$live" --argjson gt "$gates" --arg r "$r" '. + [$l + {prs: ($p[$l.lane] // []), livecache: $v, gates: ($gt[$l.lane] // {}), root: $r}]' <<<"$lanes")"
    done
done <<EOF2
$repos
EOF2

stall="${HERDR_GRAPH_GATE_STALL:-10}"
case "$stall" in '' | *[!0-9]*) stall=10 ;; esac
view="$(jq -c --argjson agents "$agents" --argjson have "$have_agents" --argjson stall "$((stall * 60))" '
    def pad2: tostring | if length < 2 then "0" + . else . end;
    def dur: floor | if . < 60 then "\(.)s" elif . < 3600 then "\(. / 60 | floor)m \(. % 60 | pad2)s"
             else "\(. / 3600 | floor)h \(. % 3600 / 60 | floor | pad2)m" end;
    ($agents | map({(.name): .}) | add // {}) as $live
    | map(. as $l
      | ($l.graph | keys_unsorted) as $order
      | [ $order[] as $n | $l.nodes[$n] as $s | $l.graph[$n] as $g
          | ($s.agent // "") as $ag | $live[$ag] as $a | ($l.livecache[$ag] // null) as $c
          # a gate run started by gate.sh: its heartbeat, while the node is recorded running
          | (if ($g.gate // "") != "" and $s.status == "running" then ($l.gates[$n] // null) else null end) as $gt
          | (if $s.agent and ($a.status // "") == "blocked" then "blocked" else $s.status end) as $st
          # a running node whose agent is out of step with the lane file
          | (if $gt != null then
                 (if $gt.finished then (if ($gt.recorded // false) then null else {kind: "gate-unrecorded", ref: "EXIT=\($gt.exit)"} end)
                  elif $gt.alive == false then {kind: "gate-lost", ref: "\($gt.pid)"}
                  elif ($gt.quiet // 0) >= $stall then {kind: "gate-stalled", ref: "\($gt.quiet | dur) (last: \($gt.last))"}
                  else null end)
             elif $s.status != "running" or $ag == "" or $have != 1 then null
             elif $a == null then {kind: "gone"}
             elif $a.status == "blocked" then {kind: "blocked"}
             elif ($a.status == "idle" or $a.status == "done") and $c != null
                  and $c.status == $a.status and $c.seq == $a.seq then
                 (if ($c.result // "") != "" then {kind: $c.result, ref: ($c.ref // "")} else {kind: "stopped"} end)
             else null end) as $drift
          | {node: $n, status: $st, result: ($s.result // ""), retries: ($s.retries // 0),
             agent: $ag, live: ($a.status // ""), seq: ($a.seq // null), drift: $drift,
             max: ([$l.graph[] | select(.retry.to == $n) | .retry.max] | max // 0),
             human: ($g.human // null), ref: ($s.ref // ""), gate: $gt,
             progress: (if $gt != null and ($gt.finished | not) then
                            "running \($gt.elapsed | dur) · \($gt.ok) ok · \($gt.fail) FAIL"
                            + (if ($gt.last // "") != "" then " · last: \($gt.last)" else "" end)
                        else "" end)} ] as $nodes
      | ($l.question // "") as $q
      | [$nodes[] | select(.drift.kind == "question") | "\(.node) (\(.agent)) asks: \(.drift.ref)"] as $asks
      # the lane'"'"'s own pull request: the recorded one, one a node points to, or its branch'"'"'s
      | ([$l.pr // empty] + [$l.nodes[]?.ref // empty | select(test("^https?://"))]) as $own
      | (if $l.status == "closed" or ($l.cleanup // "") == "declined" then null
         else [($l.prs // [])[] | select(.state == "MERGED")
               | select((.url as $u | $own | index($u)) or ((.headRefName // "") != "" and .headRefName == ($l.branch // "")))][0]
         end) as $merged
      | ([$nodes[] | .node as $n | .agent as $ag | .drift | select(. != null) |
           if .kind == "question" then (if $q != "" then "\($n) (\($ag)) asks: \(.ref)" else empty end)
           elif .kind == "pass" or .kind == "fail" then "\($n) finished: \(.kind) \(.ref) (\($ag)); check and record"
           elif .kind == "blocked" then "\($n): \($ag) is blocked, waiting for an answer on its screen"
           elif .kind == "gone" then "\($n): agent \($ag) is gone"
           elif .kind == "gate-unrecorded" then "\($n) finished \(.ref) but was never recorded: gate.sh --collect"
           elif .kind == "gate-lost" then "\($n): gate process \(.ref) is gone without an EXIT line"
           elif .kind == "gate-stalled" then "\($n): no gate output for \(.ref)"
           else "\($n): \($ag) stopped without a RESULT line" end]
         + (if $merged == null then []
            elif ($l.cleanup // "") == "confirmed" then ["PR #\($merged.number) merged, cleanup confirmed: cleanup.sh run"]
            else ["PR #\($merged.number) merged, waiting for cleanup confirmation"] end)) as $att
      | {lane: $l.lane, pattern: $l.pattern, repo: $l.repo,
         question: (if $q != "" then $q else ($asks | join("; ")) end),
         question_live: ($q == "" and ($asks | length) > 0), attention: $att,
         pr_merged: (if $merged then {number: $merged.number, url: $merged.url} else null end),
         workspace: ($l.workspace // ""), owner: ($l.owner // ""), idea: ($l.idea // ""), cleanup: ($l.cleanup // ""),
         branch: ($l.branch // ""), prs: ($l.prs // []),
         root: $l.root, closed: ([($l.history // [])[] | select(endswith(" lane closed"))][-1] // "" | split(" ")[0]),
         nodes: $nodes, last: ($l.history[-1] // ""),
         section: (if $l.status == "closed" then "closed"
                   elif $q != "" or ($asks | length) > 0 or ($att | length) > 0 or any($nodes[]; .status == "blocked") then "needs"
                   elif $l.status == "done" then "done" else "working" end)})' <<<"$lanes")"
# --text, --line and --tokens are about the open lanes only
open_view="$(jq -c 'map(select(.section != "closed"))' <<<"$view")"

case "$mode" in
json) printf '%s\n' "$view" ;;
tokens)
    command -v herdr >/dev/null 2>&1 || exit 0
    jq -r --argjson agents "$agents" '
        ($agents | map({(.name): .pane}) | add // {}) as $pane
        | .[] | .lane as $lane | (.nodes | map("\(.node) \(.status)") | join(" > ")) as $chain
        | .nodes[] | select(.agent != "" and ($pane[.agent] // "") != "")
        | [$pane[.agent], $lane, .node, (if .max > 0 and .retries > 0 then "\(.status) \(.retries)/\(.max)" else .status end)] | @tsv' <<<"$open_view" |
        while IFS="$(printf '\t')" read -r pane lane node step; do
            herdr pane report-metadata "$pane" --source herdr-graph --token "lane=$lane" --token "node=$node" --token "step=$step" >/dev/null 2>&1 || true
        done ;;
line)
    jq -r '
        (map(select(.section == "needs"))) as $n | (map(select(.section == "working")) | length) as $w
        | (map(select(.section == "done")) | length) as $d
        | if length == 0 then "graph: no lanes"
          else [ (if ($n | length) > 0 then "🔴 \($n | length) \($n[0].lane)" else empty end),
                 (if $w > 0 then "🟡 \($w)" else empty end), (if $d > 0 then "🟢 \($d)" else empty end) ] | join("  ") end' <<<"$open_view" ;;
text)
    jq -r "$STYLE_JQ_PR"'
        def mark: if .status == "done" and .result == "changes" then "✗" elif .status == "done" then "✓"
                  elif .status == "running" then "⟳" elif .status == "failed" then "✗"
                  elif .status == "blocked" then "?" elif .status == "skipped" then "–" else "·" end;
        def chain: [.nodes[] | "\(.node) \(mark)" + (if .max > 0 and .retries > 0 then " retry \(.retries)/\(.max)" else "" end)] | join(" → ");
        def row: "  \(.lane)  \(.pattern)  \(chain)"
                 + (if .question != "" then "\n    ? \(.question)" else "" end)
                 + (.attention | map("\n    ! \(.)") | join(""))
                 + (if .cleanup != "" and .cleanup != "declined" then "\n    cleanup: \(.cleanup)" else "" end)
                 + ([.nodes[] | select(.progress != "")] | map("\n    \(.node): \(.progress)") | join(""))
                 + ([.nodes[] | select(.ref != "" and (.ref | test("/")))] | map("\n    \(.node): \(.ref)") | join(""))
                 + "\n    last: \(.last)"
                 + (.prs | map("\n    pr: #\(.number) \(prword) \(.url)") | join(""));
        if length == 0 then "No lanes. Give the orchestrator an idea to start one." else
        ([["needs", "NEEDS YOU"], ["working", "WORKING"], ["done", "DONE"]][] as [$k, $t]
         | [.[] | select(.section == $k)] | select(length > 0)
         | "\($t) (\(length))", (.[] | row))
        end' <<<"$open_view" ;;
esac
