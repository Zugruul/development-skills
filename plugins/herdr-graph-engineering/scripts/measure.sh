#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# measure.sh -- how the lanes went, from their lane files. Reads only.
# Usage: measure.sh [--repo DIR]... [--json]
# For every lane (open and closed): pattern, outcome, minutes from start to its last history
# line, retries, questions to the user, and nodes that failed. Then totals per pattern.
# Use it to judge the setup on real ideas: where you were asked too often, where retries ran
# out, which patterns earn their agents.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/common.sh
. "$HERE/src/common.sh"

repos="" as_json=0
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) need_value "$1" $#; repos="$repos
$2"; shift 2 ;;
        --json) as_json=1; shift ;;
        *) usage "measure.sh [--repo DIR]... [--json]" ;;
    esac
done
require_tools jq yq git
[ -n "$repos" ] || repos="$(pwd)"

all="[]"
while IFS= read -r r; do
    [ -n "$r" ] || continue
    d="$(lane_dir "$r" 2>/dev/null)" || continue
    for f in "$d"/*.yaml "$d"/closed/*.yaml; do
        [ -f "$f" ] || continue
        all="$(jq -c --argjson l "$(read_json "$f")" '. + [$l]' <<<"$all")"
    done
done <<EOF2
$repos
EOF2

rows="$(jq -c "$LANE_TYPE_JQ"'
    def ts: sub("Z$"; "") | strptime("%Y-%m-%dT%H:%M:%S") | mktime;
    map(. as $l
      | ($l.history | map(split(" ")[0])) as $t
      | {lane: $l.lane, pattern: ($l | lane_type),
         outcome: (if $l.status == "closed" and any($l.history[]; test("set status = done|status = done")) then "done"
                   elif $l.status == "done" then "done" elif $l.status == "closed" then "closed early" else "open" end),
         minutes: (if ($t | length) > 1 then ((($t[-1] | ts) - ($t[0] | ts)) / 60 | floor) else 0 end),
         retries: ([$l.nodes[].retries // 0] | add // 0),
         questions: ([$l.history[] | select(test(" question"))] | length),
         failed: ([$l.history[] | select(test(" failed"))] | length)})' <<<"$all")"

if [ "$as_json" -eq 1 ]; then
    printf '%s\n' "$rows"
    exit 0
fi
jq -r '
    if length == 0 then "No lanes yet." else
    (["LANE", "PATTERN", "OUTCOME", "MIN", "RETRIES", "QUESTIONS", "FAILED"] | @tsv),
    (.[] | [.lane, .pattern, .outcome, .minutes, .retries, .questions, .failed] | @tsv),
    "",
    (["PATTERN", "LANES", "DONE", "AVG MIN", "RETRIES", "QUESTIONS"] | @tsv),
    (group_by(.pattern)[] | [.[0].pattern, length, ([.[] | select(.outcome == "done")] | length),
        (([.[].minutes] | add) / length | floor), ([.[].retries] | add), ([.[].questions] | add)] | @tsv)
    end' <<<"$rows" | column -t -s "$(printf '\t')" 2>/dev/null || jq -r '.[] | [.lane, .pattern, .outcome] | @tsv' <<<"$rows"
