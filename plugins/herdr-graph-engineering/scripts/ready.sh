#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# ready.sh -- which nodes of a lane can start now. Reads only.
# Usage: ready.sh --lane L [--repo DIR]
# A node is ready when it is waiting, every node it needs is done, and when it has a
# `when`, every needed node's result equals it. Nothing is ready while the lane has an
# open question or a failed node that was not retried.
# Prints one line per ready node: READY <node> <agent|gate|human> <role, command or question>
# or NOTHING READY (<why>), or ALL NODES DONE.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/common.sh
. "$HERE/src/common.sh"

repo="$(pwd)" lane=""
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) need_value "$1" $#; repo="$2"; shift 2 ;;
        --lane) need_value "$1" $#; lane="$2"; shift 2 ;;
        *) usage "ready.sh --lane L [--repo DIR]" ;;
    esac
done
[ -n "$lane" ] || usage "ready.sh --lane L [--repo DIR]"
require_tools jq yq git
file="$(lane_file "$repo" "$lane")"
[ -f "$file" ] || die "NO LANE: $lane" 6

read_json "$file" | jq -r '
    . as $l
    | ($l.nodes | to_entries | map(select(.value.status == "failed")) | map(.key)) as $failed
    | ($l.nodes | to_entries | map(select(.value.status == "running")) | map(.key)) as $running
    | if $l.status != "open" then "NOTHING READY (lane is \($l.status))"
      elif ($l.question // "") != "" then "NOTHING READY (open question: \($l.question))"
      elif ($failed | length) > 0 then "NOTHING READY (failed, not retried: \($failed | join(", ")))"
      elif all($l.nodes[]; .status == "done") then "ALL NODES DONE"
      else
        [ $l.graph | to_entries[] | .key as $n | .value as $g
          | select($l.nodes[$n].status == "waiting")
          | select(all(($g.needs // [])[]; $l.nodes[.].status == "done"))
          | select(($g.when // null) == null or all(($g.needs // [])[]; $l.nodes[.].result == $g.when))
          | if $g.agent then "READY \($n) agent \($g.agent)"
            elif $g.gate then "READY \($n) gate \($g.gate)"
            else "READY \($n) human \($g.human)" end ]
        | if length > 0 then .[]
          elif ($running | length) > 0 then "NOTHING READY (running: \($running | join(", ")))"
          else "NOTHING READY (no waiting node has its needs met)" end
      end'
