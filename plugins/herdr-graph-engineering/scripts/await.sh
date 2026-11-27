#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# await.sh -- the waiter: it waits for the session's next event and ends with it, which wakes the
# chat. It types nothing, so a half-typed message is never touched.
# Usage: await.sh [--session S] [--hook]
#   --hook   how hooks/hooks.json arms it after every turn of the orchestrator (a Claude Code Stop
#            hook with asyncRewake: it runs in the background, and exit 2 wakes the idle chat with
#            what it wrote to stderr). It does nothing outside the orchestrator's pane, or when
#            Herdr shows that pane running another client: one that does not know asyncRewake
#            would hold its turn until the waiter ends.
# One waiter per session: a newer one takes over and the older ends quietly. While it waits it
# costs no tokens. Hooks and Herdr events update the events; the waiter looks at them every
# HERDR_GRAPH_TICK seconds (2) and runs the full sweep (notify.sh reconcile --full: pull
# requests, gate heartbeats, lost events) when none ran for HERDR_GRAPH_SWEEP seconds (300).
# It ends quietly (exit 0) after HERDR_GRAPH_WAIT_MAX seconds (85800, under the hook's 86400:
# Claude kills a hook at its timeout without a word); the push fallback then covers.
# Exit codes: 2 an event (message on stderr), 0 nothing to say.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/common.sh
. "$HERE/src/common.sh"
# shellcheck source=src/afk.sh
. "$HERE/src/afk.sh"
# shellcheck source=src/panes.sh
. "$HERE/src/panes.sh"
# shellcheck source=src/events.sh
. "$HERE/src/events.sh"

session="" hook=0
while [ $# -gt 0 ]; do
    case "$1" in
        --session) need_value "$1" $#; session="$2"; shift 2 ;;
        --hook) hook=1; shift ;;
        *) usage "await.sh [--session S] [--hook]" ;;
    esac
done
if [ "$hook" -eq 1 ]; then
    [ -n "${HERDR_PANE_ID:-}" ] || exit 0
    ofile="$(panes_dir)/$(pane_key "$HERDR_PANE_ID").orch"
    [ -f "$ofile" ] || exit 0
    cat >/dev/null 2>&1
    for t in jq yq git herdr; do command -v "$t" >/dev/null 2>&1 || exit 0; done
    session="$(cat "$ofile")"
    agent="$(orchestrator_agent "$session")" || exit 0
    [ "$(jq -r '.agent // ""' <<<"$agent")" = claude ] || exit 0
fi
require_tools jq yq git
session="${session:-$(default_session)}"

mine="$(session_dir)/$session.waiter" beat="$(session_dir)/$session.beat"
mkdir -p "$(session_dir)"
printf '%s' "$$" >"$mine"
touch "$beat"
bye() { [ "$(cat "$mine" 2>/dev/null)" != "$$" ] || rm -f "$mine" "$beat"; }
trap bye EXIT
trap 'exit 0' INT TERM HUP

tick="${HERDR_GRAPH_TICK:-2}" batch="${HERDR_GRAPH_BATCH:-5}" max="${HERDR_GRAPH_WAIT_MAX:-85800}"
start="$(date +%s)"
# a first look, for what changed during the turn
if sweep_due "$session"; then reconcile "$session" 1 >/dev/null 2>&1; else reconcile "$session" 0 >/dev/null 2>&1; fi
checked="$(date +%s)"
while :; do
    [ "$(cat "$mine" 2>/dev/null)" = "$$" ] || exit 0
    touch "$beat"
    if pending "$session"; then
        sleep "$batch" # one message for what happens together
        reconcile "$session" 0 >/dev/null 2>&1
        [ "$(cat "$mine" 2>/dev/null)" = "$$" ] || exit 0
        if msg="$(take "$session")"; then
            printf '%s\n' "$msg" >&2
            exit 2
        fi
    fi
    now="$(date +%s)"
    [ $((now - start)) -lt "$max" ] || exit 0
    if sweep_due "$session"; then
        reconcile "$session" 1 >/dev/null 2>&1
        checked="$now"
    elif [ $((now - checked)) -ge 60 ]; then
        # reminder times and a "stopped" that now has held need no lane read, but a fresh look is cheap once a minute
        reconcile "$session" 0 >/dev/null 2>&1
        checked="$now"
    fi
    sleep "$tick"
done
