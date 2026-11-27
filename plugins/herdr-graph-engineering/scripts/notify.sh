#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# notify.sh -- the one place that decides what wakes the orchestrator, and delivers it once.
# Usage:
#   notify.sh reconcile [--session S] [--full]  look at the facts and update the session's events.
#                                      An event only says "look": the lane files and live state are
#                                      read again. --full (the sweep): also refresh pull requests,
#                                      run cleanup.sh check where a lane may need it, and see what
#                                      auto-merge could merge. Without --session: every session.
#   notify.sh take --session S         print what is pending as one message, mark it delivered
#                                      (exit 1: nothing pending)
#   notify.sh pending --session S       exit 0 when something is pending; updates reminders
#   notify.sh push --session S         the fallback when no waiter (await.sh) is alive: type the message
#                                      into the orchestrator with herdr agent prompt, only when it is
#                                      idle or done, its pane and name still match, and its input box is
#                                      recognisably empty; at most once a minute
#   notify.sh signal [--delay S]       reconcile and push for every session (the lane hooks)
#   notify.sh tick                     the graph panel's turn: reconcile, a full sweep when one is
#                                      due, push
#   notify.sh sweep                    a full reconcile and push for every session (Herdr startup)
#   notify.sh list --session S         the open events
#   notify.sh gate --repo R --lane L --node N     a gate that ran in its tab recorded itself: an event
#                                      until the lane is written again
# State: <state>/herdr-graph/sessions/<session>.events.json {open, sent, swept_at, last_push,
# notifications}. One event per key (repo, lane, node, reason, run, record count, ref). A key is
# sent once; one that clears and comes back within a minute is not sent again. "stopped" must hold
# 30 s. Delivered events stay open until the lane's facts change. A reminder follows after 5 and
# 15 minutes (also as a Herdr notification), then the lane is marked "needs manual intervention"
# (20 minutes). A lane's question waiting for the user reminds the user only. A message carries
# lane and node names and a reason code, never any text of an agent: a pushed message looks like
# typing, so agent text in it could pass as the user's words.
# Times (seconds): HERDR_GRAPH_STOP_HOLD 30, HERDR_GRAPH_REARM 60, HERDR_GRAPH_REMIND_1 300,
# HERDR_GRAPH_REMIND_2 900, HERDR_GRAPH_MANUAL 1200, HERDR_GRAPH_SWEEP 300, HERDR_GRAPH_PUSH_GAP 60.
# Exit codes: 0 ok, 1 nothing, 2 usage.
# shellcheck disable=SC2016
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

USAGE="notify.sh reconcile|take|pending|push|signal|tick|sweep|list|gate [options] (see the header of notify.sh)"
cmd="${1:-}"
case "$cmd" in reconcile | take | pending | push | signal | tick | sweep | list | gate) shift ;; *) usage "$USAGE" ;; esac
session="" full=0 delay=0 repo="" lane="" node=""
while [ $# -gt 0 ]; do
    case "$1" in
        --session) need_value "$1" $#; session="$2"; shift 2 ;;
        --full) full=1; shift ;;
        --delay) need_value "$1" $#; delay="$2"; shift 2 ;;
        --repo) need_value "$1" $#; repo="$2"; shift 2 ;;
        --lane) need_value "$1" $#; lane="$2"; shift 2 ;;
        --node) need_value "$1" $#; node="$2"; shift 2 ;;
        *) usage "$USAGE" ;;
    esac
done
require_tools jq yq git

case "$cmd" in
reconcile)
    if [ -n "$session" ]; then reconcile "$session" "$full"; else for s in $(sessions); do reconcile "$s" "$full"; done; fi ;;
take) [ -n "$session" ] || usage "$USAGE"; take "$session" ;;
pending) [ -n "$session" ] || usage "$USAGE"; pending "$session" ;;
push) [ -n "$session" ] || usage "$USAGE"; push "$session" ;;
signal)
    sleep "$delay"
    for s in $(sessions); do reconcile "$s" 0; push "$s"; done ;;
tick)
    # the panel calls this on every refresh: a screen read is reused for 10 s, never repeated sooner
    DRIFT_AGE=10
    bash "$HERE/drift.sh" --quiet --max-age "$DRIFT_AGE" >/dev/null 2>&1
    for s in $(sessions); do
        # a gone orchestrator's open events are still brought up to date, so none sticks
        orchestrator_agent "$s" >/dev/null || [ "$(state_read "$s" | jq '.open | length')" -gt 0 ] || continue
        if sweep_due "$s"; then reconcile "$s" 1; else reconcile "$s" 0; fi
        push "$s"
    done ;;
sweep) for s in $(sessions); do reconcile "$s" 1; push "$s"; done ;;
list) [ -n "$session" ] || usage "$USAGE"; list_events "$session" ;;
gate)
    if [ -z "$repo" ] || [ -z "$lane" ] || [ -z "$node" ]; then usage "notify.sh gate --repo R --lane L --node N"; fi
    gate_event "$repo" "$lane" "$node" ;;
esac
