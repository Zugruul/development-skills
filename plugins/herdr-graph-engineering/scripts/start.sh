#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# start.sh -- the orchestrator's first command: its session file, before anything else.
# Usage: start.sh [--scratch DIR] [--session NAME]
# Why a script: the hooks find the orchestrator by its pane, and the resume block after a
# compaction needs the session file; written by prose, it was skipped and the block never came.
# Names this pane's agent graph (graph-2, ... when another agent has the name), then creates or
# rebinds the session of that name: pane, agent name, scratch folder.
# Exit codes: 0 ok, 1 error, 2 usage, 6 not in a Herdr pane with an agent.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/common.sh
. "$HERE/src/common.sh"
# shellcheck source=src/afk.sh
. "$HERE/src/afk.sh"

scratch="" session=""
while [ $# -gt 0 ]; do
    case "$1" in
        --scratch) need_value "$1" $#; scratch="$2"; shift 2 ;;
        --session) need_value "$1" $#; session="$2"; shift 2 ;;
        *) usage "start.sh [--scratch DIR] [--session NAME]" ;;
    esac
done
require_tools jq yq git herdr
[ -n "${HERDR_PANE_ID:-}" ] || die "NOT STARTED: not inside a Herdr pane" 6
list="$(herdr agent list 2>/dev/null)" || die "NOT STARTED: herdr agent list failed" 6
me="$(jq -c --arg p "$HERDR_PANE_ID" '[.result.agents[]? | select(.pane_id == $p)][0] // empty' <<<"$list")"
[ -n "$me" ] || die "NOT STARTED: Herdr shows no agent in pane $HERDR_PANE_ID" 6
name="$(jq -r '.name // ""' <<<"$me")"
if ! [[ "$name" =~ ^graph(-[0-9]+)?$ ]]; then
    name=graph n=2
    while jq -e --arg n "$name" 'any(.result.agents[]?; .name == $n)' >/dev/null <<<"$list"; do
        name="graph-$n" n=$((n + 1))
    done
    herdr agent rename "$HERDR_PANE_ID" "$name" >/dev/null 2>&1 || die "NOT STARTED: could not name this agent $name" 1
fi
session="${session:-$name}"
set_key() { bash "$HERE/session.sh" set --session "$session" --key "$1" --value "$2" >/dev/null || die "could not write the session" 1; }
set_key pane "$HERDR_PANE_ID"
set_key orchestrator "$name"
[ -z "$scratch" ] || set_key scratch "$scratch"
printf 'STARTED %s (agent %s, pane %s)\n' "$session" "$name" "$HERDR_PANE_ID"
afk_line "$session"
bash "$HERE/session.sh" automerge status --session "$session"
echo "Next: resume.sh --session $session for every lane."
