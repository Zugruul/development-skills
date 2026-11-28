#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# close-done.sh -- close the Herdr tabs of a lane's finished agent and gate nodes, at the right moment.
# Usage: close-done.sh --lane L [--repo DIR] [--dry-run]
# Why a script: when a tab may close depends on the lane's graph (retry edges, pending approvals),
# so the rule is decided here, from the lane file, and tested, not left to judgement.
#
# Only a tab recorded for a node (lane.sh node --tab) is ever closed. Per agent or gate node:
#   never closed: no tab recorded; the tab is gone (GONE, recorded as closed); the first tab of
#     its workspace; a tab outside the lane's workspace; a node that is running or blocked; a tab
#     whose agent Herdr shows working or blocked.
#   lane done or closed: every other tab closes.
#   gate: closes once its result is recorded as passed; a failed gate stays until the retry runs.
#   agent: closes once it is done with a passing result, unless a retry edge whose source has not
#     passed can still reset it (the target or anything downstream of it), or a human node that
#     follows it is not decided yet (the orchestrator may still ask it about its output).
# Prints one line per agent or gate node: CLOSE <node> <tab> (<why>), KEEP <node> (<why>),
# GONE <node> <tab> (<why>) or CLOSED <node> <tab> (closed earlier). Closes with `herdr tab close`
# and records each close with lane.sh tab-closed, unless --dry-run.
# shellcheck disable=SC2016
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/common.sh
. "$HERE/src/common.sh"

USAGE="close-done.sh --lane L [--repo DIR] [--dry-run]"
repo="$(pwd)" lane="" dry=0
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) need_value "$1" $#; repo="$2"; shift 2 ;;
        --lane) need_value "$1" $#; lane="$2"; shift 2 ;;
        --dry-run) dry=1; shift ;;
        *) usage "$USAGE" ;;
    esac
done
[ -n "$lane" ] || usage "$USAGE"
require_tools jq yq git herdr
repo="$(cd "$repo" 2>/dev/null && pwd)" || die "no such directory: $repo" 2
file="$(lane_file "$repo" "$lane")" closed=0
if [ ! -f "$file" ]; then
    file="$(lane_dir "$repo")/closed/$lane.yaml" closed=1
    [ -f "$file" ] || die "NO LANE: $lane" 6
fi
lj="$(read_json "$file")" || die "could not read $file"

# What Herdr shows for every recorded, not yet closed tab: {tab id: tab or null when gone}.
tabs="{}"
for t in $(printf '%s' "$lj" | jq -r '[.nodes[] | select((.tab // "") != "" and (.tab_closed // false) != true) | .tab] | unique | .[]'); do
    info="$(herdr tab get "$t" 2>/dev/null | jq -c '.result.tab // null' 2>/dev/null)"
    [ -n "$info" ] || info=null
    tabs="$(jq -cn --argjson m "$tabs" --arg t "$t" --argjson i "$info" '$m + {($t): $i}')"
done

decisions="$(printf '%s' "$lj" | jq -r --argjson tabs "$tabs" --argjson closed "$closed" '
    . as $l | $l.graph as $g
    | def down($s): [$s] + ([$g | to_entries[] | select((.value.needs // []) | index($s)) | .key] | map(down(.)) | add // []);
      def up($n): [($g[$n].needs // [])[] as $m | $m, up($m)[]];
      def st($n): $l.nodes[$n].status // "waiting";
      def passed($n): st($n) == "skipped" or (st($n) == "done" and ($l.nodes[$n].result // "pass") == "pass");
      def decided($n): st($n) == "done" or st($n) == "skipped";
      (if $closed == 1 then "closed" elif $l.status != "open" then $l.status else "" end) as $over
    | $g | to_entries[] | select(.value.agent or .value.gate) | .key as $n | .value as $spec
    | ($l.nodes[$n] // {}) as $s | ($s.tab // "") as $t
    | if $t == "" then "KEEP\t\($n)\t-\t(no tab recorded)"
      elif ($s.tab_closed // false) then "CLOSED\t\($n)\t\($t)\t(closed earlier)"
      elif $tabs[$t] == null then "GONE\t\($n)\t\($t)\t(the tab no longer exists)"
      elif ($tabs[$t].number // 0) == 1 then "KEEP\t\($n)\t-\t(first tab of its workspace)"
      elif ($l.workspace // "") != "" and ($tabs[$t].workspace_id // "") != $l.workspace then
          "KEEP\t\($n)\t-\t(tab \($t) is not in the lane'"'"'s workspace \($l.workspace))"
      elif (st($n) == "running" or st($n) == "blocked") then "KEEP\t\($n)\t-\t(\(st($n)))"
      elif (($tabs[$t].agent_status // "") | IN("working", "blocked")) then "KEEP\t\($n)\t-\t(agent is \($tabs[$t].agent_status))"
      elif $over != "" then "CLOSE\t\($n)\t\($t)\t(lane is \($over))"
      elif $spec.gate then
          if st($n) == "done" then "CLOSE\t\($n)\t\($t)\t(gate result recorded: \($s.result // "pass"))"
          elif st($n) == "failed" then "KEEP\t\($n)\t-\t(gate failed: its output stays until the retry runs)"
          else "KEEP\t\($n)\t-\t(\(st($n)))" end
      elif st($n) != "done" then "KEEP\t\($n)\t-\t(\(st($n)))"
      elif ($s.result // "pass") != "pass" then "KEEP\t\($n)\t-\t(result \($s.result): waiting for the retry or the user)"
      else
          ([$g | to_entries[] | select(.value.retry) | select(passed(.key) | not)
            | select(.value.retry.to as $to | down($to) | index($n)) | "\(.key) can still retry \(.value.retry.to)"]) as $retry
          | ([$g | to_entries[] | select(.value.human) | select(decided(.key) | not)
            | select(up(.key) | index($n)) | "\(.key) is not decided"]) as $human
          | if ($retry | length) > 0 then "KEEP\t\($n)\t-\t(\($retry | join(", ")))"
            elif ($human | length) > 0 then "KEEP\t\($n)\t-\t(\($human | join(", ")): it may be asked about its output)"
            else "CLOSE\t\($n)\t\($t)\t(done, nothing can send work back)" end
      end')" || die "could not read the graph of lane $lane"

while IFS="	" read -r verdict n t why; do
    [ -n "$verdict" ] || continue
    case "$verdict" in
        CLOSE)
            if [ "$dry" -eq 0 ]; then
                if ! herdr tab close "$t" >/dev/null 2>&1; then
                    printf 'KEEP %s (herdr tab close %s failed)\n' "$n" "$t"
                    continue
                fi
                [ "$closed" -eq 1 ] || bash "$HERE/lane.sh" tab-closed --repo "$repo" --lane "$lane" --node "$n" >/dev/null || exit 1
            fi
            printf 'CLOSE %s %s %s\n' "$n" "$t" "$why" ;;
        GONE)
            [ "$dry" -eq 1 ] || [ "$closed" -eq 1 ] || bash "$HERE/lane.sh" tab-closed --repo "$repo" --lane "$lane" --node "$n" >/dev/null || exit 1
            printf 'GONE %s %s %s\n' "$n" "$t" "$why" ;;
        CLOSED) printf 'CLOSED %s %s %s\n' "$n" "$t" "$why" ;;
        *) printf 'KEEP %s %s\n' "$n" "$why" ;;
    esac
done <<EOF
$decisions
EOF
