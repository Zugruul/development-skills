#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# start.sh -- start an agent in a pane, retrying while a new pane's shell is still starting.
# Usage: start.sh --name NAME --kind KIND --pane PANE [--timeout SECONDS] [-- AGENT ARGS]
# Why a script: `herdr agent start` fails with agent_pane_busy while a pane made by
# `herdr worktree create` still runs its shell startup files, and Herdr does not retry.
# Prints AGENT READY ...; exits 3 when the agent is up but waits at a startup dialog,
# 6 when the name is invalid or taken, 1 on any other failure.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/herdr.sh
. "$HERE/src/herdr.sh"
# shellcheck source=src/require.sh
. "$HERE/src/require.sh"

USAGE="start.sh --name NAME --kind KIND --pane PANE [--timeout SECONDS] [-- AGENT ARGS]"
name="" kind="" pane="" timeout=90
while [ $# -gt 0 ]; do
    case "$1" in
        --name) need_value "$1" $#; name="$2"; shift 2 ;;
        --kind) need_value "$1" $#; kind="$2"; shift 2 ;;
        --pane) need_value "$1" $#; pane="$2"; shift 2 ;;
        --timeout) need_value "$1" $#; timeout="$2"; shift 2 ;;
        --) shift; break ;;
        *) usage "$USAGE" ;;
    esac
done
[ -n "$name" ] && [ -n "$kind" ] && [ -n "$pane" ] || usage "$USAGE"
case "$timeout" in '' | *[!0-9]*) usage "$USAGE" ;; esac
require_herdr

# Name rules: Herdr allows [a-z][a-z0-9_-]{0,31}, unique among live agents.
re='^[a-z][a-z0-9_-]{0,31}$'
LC_ALL=C
[[ "$name" =~ $re ]] || die "NAME INVALID: '$name' must match [a-z][a-z0-9_-]{0,31}." 6
agents_load
if printf '%s' "$AGENTS_JSON" | jq -e --arg n "$name" 'any(.[]; .name == $n)' >/dev/null; then
    die "NAME TAKEN: a live agent is already named '$name'. Pick another name." 6
fi

blocked_at_startup() {
    printf 'AGENT BLOCKED AT STARTUP name=%s pane=%s\n' "$name" "$pane"
    echo "The agent is running but waiting at a startup dialog. Screen:"
    screen "$name" visible 40
    printf '%s\n' "$SCREEN_TEXT"
    echo "Show this to the user and ask how to answer; do not answer it yourself."
    exit 3
}

deadline=$((SECONDS + timeout))
tries=0
while :; do
    tries=$((tries + 1))
    herdr_call agent start "$name" --kind "$kind" --pane "$pane" ${1+--} "$@"
    [ "$HC_RC" -eq 0 ] && break
    code="$(err_code)"
    [ "$code" = "agent_not_ready" ] && blocked_at_startup
    if [ "$code" = "agent_pane_busy" ] && [ "$SECONDS" -lt "$deadline" ]; then
        sleep "$INTERVAL"
        continue
    fi
    die "herdr agent start failed after $tries attempt(s): $(err_text)"
done

while :; do
    status=""
    agent_get "$name" && status="$(af agent_status)"
    case "$status" in
        idle | done)
            printf 'AGENT READY name=%s pane=%s kind=%s status=%s attempts=%d\n' "$name" "$pane" "$kind" "$status" "$tries"
            exit 0 ;;
        blocked) blocked_at_startup ;;
    esac
    [ "$SECONDS" -lt "$deadline" ] || die "agent $name started but is not idle yet (status=${status:-none}). Do not prompt it yet: read its screen first."
    sleep "$INTERVAL"
done
