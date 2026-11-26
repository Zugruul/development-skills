#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# status.sh -- the picture of every lane, derived each time from the lane files and Herdr.
# Reads only. Used by the display skill, the tab bar line and the graph panel.
# Usage: status.sh [--text | --line | --json | --tokens] [--repo DIR]...
# Without --repo: every repository with a workspace open in Herdr, plus the current one.
#   --text   NEEDS YOU / WORKING / DONE, one line per lane with its node chain (default)
#   --line   one short line for Herdr's tab bar
#   --json   the same facts for a program, with each lane's pull requests from prs.sh's cache
#   --tokens write each live node agent's step into Herdr's sidebar (pane tokens $lane, $node,
#            $step), so a sidebar row layout can show it; display only, lost on a Herdr restart
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/common.sh
. "$HERE/src/common.sh"
# shellcheck source=src/style.sh
. "$HERE/src/style.sh"

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

agents="[]"
if command -v herdr >/dev/null 2>&1; then
    a="$(herdr agent list 2>/dev/null)" && agents="$(printf '%s' "$a" | jq -c '[.result.agents[]? | {name: (.name // ""), status: (.agent_status // "unknown"), pane: (.pane_id // "")}]' 2>/dev/null || echo '[]')"
    if [ -z "$repos" ]; then
        repos="$(herdr workspace list 2>/dev/null | jq -r '.result.workspaces[]?.worktree.repo_root // empty' 2>/dev/null)"
    fi
fi
[ -n "$repos" ] || repos="$(pwd)"
here_root="$(git rev-parse --show-toplevel 2>/dev/null)" && repos="$repos
$here_root"

# one JSON object per open lane, each repository's lane folder read once
lanes="[]" seen=""
while IFS= read -r r; do
    [ -n "$r" ] || continue
    d="$(lane_dir "$r" 2>/dev/null)" || continue
    case "$seen" in *"|$d|"*) continue ;; esac
    seen="$seen|$d|"
    # each lane's pull requests, from prs.sh's cache (read only; never asks gh)
    prs="$(jq -c '.lanes // {}' "$d/prs.json" 2>/dev/null)" || prs="{}"
    [ -n "$prs" ] || prs="{}"
    for f in "$d"/*.yaml; do
        [ -f "$f" ] || continue
        lanes="$(jq -c --argjson l "$(read_json "$f")" --argjson p "$prs" '. + [$l + {prs: ($p[$l.lane] // [])}]' <<<"$lanes")"
    done
done <<EOF2
$repos
EOF2

view="$(jq -c --argjson agents "$agents" '
    ($agents | map({(.name): .status}) | add // {}) as $live
    | map(select(.status != "closed")
      | . as $l
      | ($l.graph | keys_unsorted) as $order
      | [ $order[] as $n | $l.nodes[$n] as $s | $l.graph[$n] as $g
          | (if $s.agent and $live[$s.agent] == "blocked" then "blocked" else $s.status end) as $st
          | {node: $n, status: $st, result: ($s.result // ""), retries: ($s.retries // 0),
             agent: ($s.agent // ""), live: ($live[$s.agent // ""] // ""),
             max: ([$l.graph[] | select(.retry.to == $n) | .retry.max] | max // 0),
             human: ($g.human // null), ref: ($s.ref // "")} ] as $nodes
      | {lane: $l.lane, pattern: $l.pattern, repo: $l.repo, question: ($l.question // ""),
         workspace: ($l.workspace // ""), owner: ($l.owner // ""), idea: ($l.idea // ""),
         branch: ($l.branch // ""), prs: ($l.prs // []),
         nodes: $nodes, last: ($l.history[-1] // ""),
         section: (if ($l.question // "") != "" or any($nodes[]; .status == "blocked") then "needs"
                   elif $l.status == "done" then "done" else "working" end)})' <<<"$lanes")"

case "$mode" in
json) printf '%s\n' "$view" ;;
tokens)
    command -v herdr >/dev/null 2>&1 || exit 0
    jq -r --argjson agents "$agents" '
        ($agents | map({(.name): .pane}) | add // {}) as $pane
        | .[] | .lane as $lane | (.nodes | map("\(.node) \(.status)") | join(" > ")) as $chain
        | .nodes[] | select(.agent != "" and ($pane[.agent] // "") != "")
        | [$pane[.agent], $lane, .node, (if .max > 0 and .retries > 0 then "\(.status) \(.retries)/\(.max)" else .status end)] | @tsv' <<<"$view" |
        while IFS="$(printf '\t')" read -r pane lane node step; do
            herdr pane report-metadata "$pane" --source herdr-graph --token "lane=$lane" --token "node=$node" --token "step=$step" >/dev/null 2>&1 || true
        done ;;
line)
    jq -r '
        (map(select(.section == "needs"))) as $n | (map(select(.section == "working")) | length) as $w
        | (map(select(.section == "done")) | length) as $d
        | if length == 0 then "graph: no lanes"
          else [ (if ($n | length) > 0 then "🔴 \($n | length) \($n[0].lane)" else empty end),
                 (if $w > 0 then "🟡 \($w)" else empty end), (if $d > 0 then "🟢 \($d)" else empty end) ] | join("  ") end' <<<"$view" ;;
text)
    jq -r "$STYLE_JQ_PR"'
        def mark: if .status == "done" and .result == "changes" then "✗" elif .status == "done" then "✓"
                  elif .status == "running" then "⟳" elif .status == "failed" then "✗"
                  elif .status == "blocked" then "?" elif .status == "skipped" then "–" else "·" end;
        def chain: [.nodes[] | "\(.node) \(mark)" + (if .max > 0 and .retries > 0 then " retry \(.retries)/\(.max)" else "" end)] | join(" → ");
        def row: "  \(.lane)  \(.pattern)  \(chain)"
                 + (if .question != "" then "\n    ? \(.question)" else "" end)
                 + ([.nodes[] | select(.ref != "" and (.ref | test("/")))] | map("\n    \(.node): \(.ref)") | join(""))
                 + "\n    last: \(.last)"
                 + (.prs | map("\n    pr: #\(.number) \(prword) \(.url)") | join(""));
        if length == 0 then "No lanes. Give the orchestrator an idea to start one." else
        ([["needs", "NEEDS YOU"], ["working", "WORKING"], ["done", "DONE"]][] as [$k, $t]
         | [.[] | select(.section == $k)] | select(length > 0)
         | "\($t) (\(length))", (.[] | row))
        end' <<<"$view" ;;
esac
