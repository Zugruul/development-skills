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
# grown for HERDR_GRAPH_GATE_STALL minutes (default 10) while its process tree is idle (a quiet
# log makes this take one HERDR_GRAPH_CPU_SAMPLE, 1 s, per such gate).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/common.sh
. "$HERE/src/common.sh"
# shellcheck source=src/style.sh
. "$HERE/src/style.sh"
# shellcheck source=src/merged.sh
. "$HERE/src/merged.sh"
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

stall="${HERDR_GRAPH_GATE_STALL:-10}"
case "$stall" in '' | *[!0-9]*) stall=10 ;; esac

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
        # a log that went quiet: the CPU says whether the run still works (src/gatefile.sh)
        pid="$(jq -r --argjson s "$((stall * 60))" 'select(.alive == true and (.quiet // 0) >= $s) | .pid' <<<"$gf")"
        if [ -n "$pid" ] && gate_busy "$pid"; then gf="$(jq -c '.busy = true' <<<"$gf")"; fi
        gates="$(jq -c --arg l "$(basename "$(dirname "$g")")" --arg n "$(basename "$g" .json)" --argjson f "$gf" '.[$l][$n] = $f' <<<"$gates")"
    done
    # what each running node's agent claimed through its hooks (scripts/hook.sh), by lane and node
    claims="{}"
    for g in "$d"/claims/*/*.json; do
        [ -f "$g" ] || continue
        cj="$(jq -ce 'objects' "$g" 2>/dev/null)" || continue
        claims="$(jq -c --arg l "$(basename "$(dirname "$g")")" --arg n "$(basename "$g" .json)" --argjson c "$cj" '.[$l][$n] = $c' <<<"$claims")"
    done
    for f in "$d"/*.yaml "$d"/closed/*.yaml; do
        [ -f "$f" ] || continue
        lanes="$(jq -c --argjson l "$(read_json "$f")" --argjson p "$prs" --argjson v "$live" --argjson gt "$gates" --argjson cl "$claims" --arg r "$r" '. + [$l + {prs: ($p[$l.lane] // []), livecache: $v, gates: ($gt[$l.lane] // {}), claims: ($cl[$l.lane] // {}), root: $r}]' <<<"$lanes")"
    done
done <<EOF2
$repos
EOF2

view="$(jq -c --argjson agents "$agents" --argjson have "$have_agents" --argjson stall "$((stall * 60))" "$MERGED_JQ"'
    def pad2: tostring | if length < 2 then "0" + . else . end;
    def dur: floor | if . < 60 then "\(.)s" elif . < 3600 then "\(. / 60 | floor)m \(. % 60 | pad2)s"
             else "\(. / 3600 | floor)h \(. % 3600 / 60 | floor | pad2)m" end;
    # an observation (a hook claim, a result file or a screen line) as the mismatch it means
    def drift_of:
        . as $o | (.kind // (if (.result // "") != "" then "result" else "none" end)) as $k
        | (if $k == "result" then {kind: .result, ref: (.ref // "")}
           elif $k == "question" then {kind: "question", ref: (.ref // "")}
           elif $k == "failure" then {kind: "agent-failed", ref: (.ref // "")}
           elif $k == "busy" then null
           elif $k == "step" and .result != "pass" then
               {kind: "step-\(.result)", ref: ([.name, .result, .ref] | map(select((. // "") != "")) | join(" ")), name: .name, result: .result, stepref: (.ref // "")}
           else {kind: "stopped"} end)
        | if . == null then null else . + {source: ($o.source // "screen"), at: ($o.seen_at // $o.at // "")} end;
    ($agents | map({(.name): .}) | add // {}) as $live
    | map(. as $l
      | ($l.graph | keys_unsorted) as $order
      | [ $order[] as $n | $l.nodes[$n] as $s | $l.graph[$n] as $g
          | ($s.agent // "") as $ag | $live[$ag] as $a | ($l.livecache[$ag] // null) as $c
          # a gate run started by gate.sh: its heartbeat, while the node is recorded running
          | (if ($g.gate // "") != "" and $s.status == "running" then ($l.gates[$n] // null) else null end) as $gt
          | (if $s.agent and ($a.status // "") == "blocked" then "blocked" else $s.status end) as $st
          # a hook claim counts only for the run it was made in
          | (($l.claims[$n] // null) | if . != null and ($s.run // "") != "" and (.run // "") == $s.run then . else null end) as $cl
          # what drift.sh read, while the agent is still in the state it was read in
          | (if $c != null and $c.status == ($a.status // "") and $c.seq == ($a.seq // null) and ($c.run // "") == ($s.run // "") then $c else null end) as $read
          # a running node whose agent is out of step with the lane file
          | (if $gt != null then
                 (if $gt.finished then (if ($gt.recorded // false) then null else {kind: "gate-unrecorded", ref: "EXIT=\($gt.exit)"} end)
                  elif $gt.alive == false then {kind: "gate-lost", ref: "\($gt.pid)"}
                  elif ($gt.quiet // 0) >= $stall and ($gt.busy != true) then {kind: "gate-stalled", ref: "\($gt.quiet | dur) (last: \($gt.last))"}
                  else null end)
             elif $s.status != "running" or $ag == "" or $have != 1 then null
             elif $a == null then (if ($cl.kind // "") == "result" then ($cl | drift_of) else {kind: "gone"} end)
             elif $a.status == "blocked" then
                 (if ($cl.kind // "") == "question" then ($cl | drift_of)
                  elif ($cl.kind // "") == "permission" then {kind: "blocked", ref: ($cl.ref // ""), source: $cl.source}
                  else {kind: "blocked"} end)
             elif ($a.status == "idle" or $a.status == "done") then
                 (if $cl != null and (($cl.kind // "") | IN("none", "permission") | not) then ($cl | drift_of)
                  elif $read != null then ($read | drift_of)
                  elif $cl != null then ($cl + {kind: "none"} | drift_of)
                  else null end)
             else null end) as $found
          # when its evidence was written (a result file, a hook claim) or the gate run: "" for a screen
          | (if $found == null then "" elif $gt != null then ($gt.run // "" | tostring)
             elif $found.source == "result-file" then ($read.stamp // "")
             elif (($found.source // "") | endswith("-hook")) then ($cl.at // "")
             else "" end) as $stamp
          | ([($s.rejected // [])[].ref]) as $rejected
          | (if $found == null then null
             elif ($found.ref // "") != "" and ($rejected | index($found.ref)) != null then null
             else $found + {stamp: $stamp} + (if ($rejected | length) > 0 then {rejected: ($rejected | length)} else {} end) end) as $drift
          | (($s.steps // []) | last) as $step
          | {node: $n, status: $st, result: ($s.result // ""), retries: ($s.retries // 0),
             agent: $ag, live: ($a.status // ""), seq: ($a.seq // null), drift: $drift,
             run: ($s.run // ""), rev: ($s.rev // 0), output: ($s.output // ""), claim: $cl,
             max: ([$l.graph[] | select(.retry.to == $n) | .retry.max] | max // 0),
             human: ($g.human // null), ref: ($s.ref // ""), gate: $gt,
             progress: (if $gt != null and ($gt.finished | not) then
                            "running \($gt.elapsed | dur) · \($gt.ok) ok · \($gt.fail) FAIL"
                            + (if ($gt.last // "") != "" then " · last: \($gt.last)" else "" end)
                            + (if $gt.busy == true then " · quiet \($gt.quiet | dur), using the CPU" else "" end)
                        elif $s.status == "running" and $step != null then
                            "step \($step.name) \($step.result)" + (if ($step.ref // "") != "" then " \($step.ref)" else "" end)
                        else "" end)} ] as $nodes
      | ($l.question // "") as $q
      | [$nodes[] | select(.drift.kind == "question") | "\(.node) (\(.agent)) asks: \(.drift.ref)"] as $asks
      # the lane'"'"'s own merged pull request (src/merged.sh)
      | (if $l.status == "closed" or ($l.cleanup // "") == "declined" then null
         else ($l | own_merged($l.prs // [])) end) as $own
      | ([$nodes[] | select(.status != "done" and .status != "skipped") | .node]) as $unfinished
      # a side pull request of an unfinished lane (none recorded) is only a note (cleanup.sh)
      | (if $l.status == "open" and ($unfinished | length) > 0 and ($l | own_urls | length) == 0 then null else $own end) as $found
      # an early merge the user already answered about stays quiet until the lane is done
      | (if $found != null and $l.status == "open" and ($l.merged_early // "") == $found.url then null else $found end) as $merged
      | ([$nodes[] | .node as $n | .agent as $ag | .drift | select(. != null) |
           if .kind == "question" then (if $q != "" then "\($n) (\($ag)) asks: \(.ref)" else empty end)
           elif .kind == "pass" or .kind == "fail" then "\($n) finished: \(.kind) \(.ref) (\($ag)); check and record"
           elif .kind == "blocked" then "\($n): \($ag) is blocked, " + (if (.ref // "") != "" then "waiting for approval (\(.ref))" else "waiting for an answer on its screen" end)
           elif .kind == "agent-failed" then "\($n): \($ag) failed: \(.ref)"
           elif (.kind | startswith("step-")) then "\($n): step \(.ref) (\($ag))"
           elif .kind == "gone" then "\($n): agent \($ag) is gone"
           elif .kind == "gate-unrecorded" then "\($n) finished \(.ref) but was never recorded: gate.sh --collect"
           elif .kind == "gate-lost" then "\($n): gate process \(.ref) is gone without an EXIT line"
           elif .kind == "gate-stalled" then "\($n): no gate output for \(.ref)"
           else "\($n): \($ag) stopped without a RESULT line" end]
         + (($l.cleanup // "") as $cu
            | if $l.status == "closed" then []
              # waiting to close by itself: only a blocked agent is the user'"'"'s to handle
              elif ($cu | startswith("auto-wait: ")) then
                  (if ($cu | endswith(" is blocked")) then ["finished, not closed: \($cu | ltrimstr("auto-wait: "))"] else [] end)
              elif $cu == "feedback-due" or $merged == null then []
              elif $cu == "confirmed" then ["PR #\($merged.number) merged, cleanup confirmed: cleanup.sh run"]
              elif $cu == "ready" then ["PR #\($merged.number) merged, waiting for cleanup confirmation"]
              elif ($cu | startswith("blocked: ")) then ["PR #\($merged.number) merged, cleanup \($cu)"]
              elif ($cu | startswith("afk-approved")) then ["PR #\($merged.number) merged, removal approved under AFK"]
              elif $l.status == "done" or ($unfinished | length) == 0 then ["PR #\($merged.number) merged, checking cleanup"]
              else ["PR #\($merged.number) merged but the lane is unfinished (\($unfinished | join(", ")))"] end)) as $att
      | {lane: $l.lane, pattern: $l.pattern, repo: $l.repo,
         question: (if $q != "" then $q else ($asks | join("; ")) end),
         question_live: ($q == "" and ($asks | length) > 0), attention: $att,
         pr_merged: (if $merged then {number: $merged.number, url: $merged.url} else null end),
         workspace: ($l.workspace // ""), owner: ($l.owner // ""), idea: ($l.idea // ""), cleanup: ($l.cleanup // ""),
         branch: ($l.branch // ""), prs: ($l.prs // []),
         root: $l.root, status: ($l.status // ""), history: ($l.history // [] | length),
         recorded_pr: ([$l.pr // empty | select(. != "")] + [$l.nodes[]?.ref // empty | select(test("^https?://[^ ]+/pull/[0-9]+$"))] | .[0] // ""),
         questions: [($l.questions // [])[] | select(.answer == null) | {id, node: (.node // ""), kind: (.kind // ""), asked_at: (.asked_at // null)}],
         open_criteria: (if $l.status == "closed" then [($l.done_extra // [])[] | select(.met != true) | .text] else [] end),
         resume: [$l.restore.agents[]? | .command // "" | select(. != "")],
         closed: ([($l.history // [])[] | select(endswith(" lane closed"))][-1] // "" | split(" ")[0]),
         nodes: $nodes, last: ($l.history[-1] // ""),
         section: (if $l.status == "closed" then "closed"
                   elif $q != "" or ($asks | length) > 0 or ($att | length) > 0 or any($nodes[]; .status == "blocked") then "needs"
                   elif $l.status == "done" then "done" else "working" end)})' <<<"$lanes")"
# what was left unhandled after both reminders (notify.sh's events) marks its lane
manual="$(cat "$(session_dir)"/*.events.json 2>/dev/null |
    jq -cs --argjson now "$(date +%s)" '[.[] | .open? // {} | .[] | select(.manual) | {repo, lane, what: "\(if .node != "" then .node + " " else "" end)\(.reason)"}] | unique' 2>/dev/null)" || manual='[]'
[ "${manual:-[]}" = '[]' ] || view="$(jq -c --argjson m "$manual" 'map(. as $l | [$m[] | select(.repo == $l.root and .lane == $l.lane) | .what] as $w
    | if ($w | length) == 0 or $l.section == "closed" then . else .manual = true | .section = "needs" | .attention += ["‼ needs manual intervention: \($w | join(", ")) unhandled after two reminders"] end)' <<<"$view")"

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
