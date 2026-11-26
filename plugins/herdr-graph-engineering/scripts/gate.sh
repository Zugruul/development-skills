#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# gate.sh -- run a gate node's command in a visible Herdr pane and record its exit code.
# Usage: gate.sh --lane L --node N --pane PANE [--repo DIR] [--timeout SECONDS] [--resume ID]
# Why a script: `herdr pane run` only queues the text; it does not return the command's
# exit code. The command is followed by a marker line with a run id, and
# `herdr pane wait-output` waits for that exact line.
# Prints GATE PASS|FAIL <node> EXIT=<n>, or GATE TIMEOUT <node> RUN=<id> (exit 5; the node
# stays running; call again with --resume <id> to keep waiting).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/common.sh
. "$HERE/src/common.sh"

USAGE="gate.sh --lane L --node N --pane PANE [--repo DIR] [--timeout SECONDS] [--resume ID]"
repo="$(pwd)" lane="" node="" pane="" timeout=1800 run=""
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) need_value "$1" $#; repo="$2"; shift 2 ;;
        --lane) need_value "$1" $#; lane="$2"; shift 2 ;;
        --node) need_value "$1" $#; node="$2"; shift 2 ;;
        --pane) need_value "$1" $#; pane="$2"; shift 2 ;;
        --timeout) need_value "$1" $#; timeout="$2"; shift 2 ;;
        --resume) need_value "$1" $#; run="$2"; shift 2 ;;
        *) usage "$USAGE" ;;
    esac
done
[ -n "$lane" ] && [ -n "$node" ] && [ -n "$pane" ] || usage "$USAGE"
case "$timeout" in '' | *[!0-9]*) usage "$USAGE" ;; esac
require_tools jq yq git herdr
file="$(lane_file "$repo" "$lane")"
[ -f "$file" ] || die "NO LANE: $lane" 6
cmd="$(yq -r ".graph[\"$node\"].gate // \"\"" "$file")"
[ -n "$cmd" ] || die "NOT A GATE: $node in lane $lane" 6

if [ -z "$run" ]; then
    run="$(date +%s)$$"
    bash "$HERE/lane.sh" node --repo "$repo" --lane "$lane" --node "$node" --status running --note "run $run" >/dev/null || exit 1
    # The marker's $? expands in the pane's shell; the typed line itself never matches EXIT=<digits>.
    herdr pane run "$pane" "$cmd; echo \"GATE $node $run EXIT=\$?\"" >/dev/null 2>&1 || die "herdr pane run failed for pane $pane"
fi
if ! out="$(herdr pane wait-output "$pane" --regex "GATE $node $run EXIT=[0-9]+" --source recent --lines 400 --timeout $((timeout * 1000)) 2>&1)"; then
    printf 'GATE TIMEOUT %s RUN=%s\n' "$node" "$run"
    echo "The command may still be running in pane $pane. Wait again with --resume $run; do not start it a second time."
    exit 5
fi
line="$(printf '%s' "$out" | jq -r '.result.matched_line // empty' 2>/dev/null)"
code="$(printf '%s' "$line" | sed -n 's/.*EXIT=\([0-9][0-9]*\).*/\1/p')"
[ -n "$code" ] || die "could not read the exit code from: $line"
if [ "$code" -eq 0 ]; then
    bash "$HERE/lane.sh" node --repo "$repo" --lane "$lane" --node "$node" --status "done" --result pass --exit 0 >/dev/null || exit 1
    printf 'GATE PASS %s EXIT=0\n' "$node"
else
    bash "$HERE/lane.sh" node --repo "$repo" --lane "$lane" --node "$node" --status failed --result fail --exit "$code" >/dev/null || exit 1
    printf 'GATE FAIL %s EXIT=%s\n' "$node" "$code"
fi
