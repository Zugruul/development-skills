#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# listen.sh -- wait until one of several agents blocks, finishes or disappears.
# Usage: listen.sh TARGET... [--timeout SECONDS] [--lines N] [--only-blocked]
# Why a script: `herdr agent wait` follows one agent; this returns at the first of many.
# Prints one EVENT line per agent that is blocked, settled (idle/done) or gone, the screen of
# every blocked agent, and STILL WORKING for the rest. A timeout prints LISTEN TIMEOUT, exit 0.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/herdr.sh
. "$HERE/src/herdr.sh"
# shellcheck source=src/require.sh
. "$HERE/src/require.sh"

USAGE="listen.sh TARGET... [--timeout SECONDS] [--lines N] [--only-blocked]"
targets=() timeout=540 lines=40 only_blocked=0
while [ $# -gt 0 ]; do
    case "$1" in
        --timeout) need_value "$1" $#; timeout="$2"; shift 2 ;;
        --lines) need_value "$1" $#; lines="$2"; shift 2 ;;
        --only-blocked) only_blocked=1; shift ;;
        -*) usage "$USAGE" ;;
        *) targets+=("$1"); shift ;;
    esac
done
[ "${#targets[@]}" -gt 0 ] || usage "$USAGE"
case "$timeout" in '' | *[!0-9]*) usage "$USAGE" ;; esac
require_herdr

deadline=$((SECONDS + timeout))
while :; do
    events="" still="" seen=""
    for t in "${targets[@]}"; do
        if ! agent_get "$t"; then
            events="${events}${t}	gone	-	-	-
"
            seen="$seen $t=gone"
            continue
        fi
        status="$(af agent_status)"
        status="${status:-unknown}"
        seen="$seen $t=$status"
        case "$status" in
            blocked) events="${events}${t}	blocked	$(af name)	$(af pane_id)	$(af tab_id)
" ;;
            idle | done)
                if [ "$only_blocked" -eq 0 ]; then
                    events="${events}${t}	${status}	$(af name)	$(af pane_id)	$(af tab_id)
"
                else
                    still="$still, $t=$status"
                fi ;;
            *) still="$still, $t=$status" ;;
        esac
    done
    if [ -n "$events" ]; then
        while IFS="$(printf '\t')" read -r t status n p tab; do
            [ -n "$t" ] || continue
            printf 'EVENT target=%s name=%s pane=%s tab=%s status=%s\n' "$t" "${n:--}" "${p:--}" "${tab:--}" "$status"
            if [ "$status" = "blocked" ]; then
                printf -- '--- %s is waiting on a human. Its screen: ---\n' "$t"
                screen "$t" visible "$lines"
                printf '%s\n' "$SCREEN_TEXT"
                printf -- '--- end of %s ---\n' "$t"
            elif [ "$status" = "gone" ]; then
                printf '    %s no longer hosts an agent (it exited or its pane closed).\n' "$t"
            fi
        done <<EOT
$events
EOT
        [ -n "$still" ] && printf 'STILL WORKING: %s\n' "${still#, }"
        exit 0
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
        printf 'LISTEN TIMEOUT after %ss:%s\n' "$timeout" "$seen"
        echo "Nothing blocked or finished yet. This says nothing about whether an earlier prompt arrived; keep listening or read the screen -- never resend a prompt because of a timeout."
        exit 0
    fi
    sleep "$INTERVAL"
done
