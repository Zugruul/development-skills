#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# signal.sh -- the Herdr plugin's event hook (herdr-plugin.toml): something changed, go look.
# Usage: signal.sh herdr          (HERDR_PLUGIN_EVENT_JSON: {event, data: {pane_id, agent_status, ...}})
# It runs on every agent change of every workspace, so an event of a pane that is neither a lane
# agent's nor the orchestrator's leaves after one file test. An event is never truth: notify.sh
# reads the lane files and the live state again. tab.closed and workspace.closed name no pane:
# every session is reconciled. A closed pane never closes a lane.
# The orchestrator turning idle delivers what waited, after a few seconds' grace
# (HERDR_GRAPH_PUSH_GRACE, 5) so its own waiter can take it first.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ "${1:-}" = herdr ] || { echo "usage: signal.sh herdr" >&2; exit 2; }
state="${XDG_STATE_HOME:-$HOME/.local/state}/herdr-graph"
compgen -G "$state/sessions/*.yaml" >/dev/null || exit 0
ev="${HERDR_PLUGIN_EVENT_JSON:-}"
re='"pane_id" *: *"([^"]+)"'
pane=""
[[ "$ev" =~ $re ]] && pane="${BASH_REMATCH[1]}"
key="${pane//[^A-Za-z0-9]/_}"
if [ -n "$pane" ]; then
    [ -f "$state/panes/$key.lane" ] || [ -f "$state/panes/$key.orch" ] || exit 0
fi
# a plugin hook's PATH may not hold the herdr binary
[ -z "${HERDR_BIN_PATH:-}" ] || command -v herdr >/dev/null 2>&1 || PATH="$PATH:$(dirname "$HERDR_BIN_PATH")"
command -v jq >/dev/null 2>&1 || exit 0
if [ -n "$pane" ] && [ -f "$state/panes/$key.orch" ]; then
    session="$(cat "$state/panes/$key.orch")"
    case "$ev" in
        *'"agent_status":"idle"'* | *'"agent_status":"done"'*)
            sleep "${HERDR_GRAPH_PUSH_GRACE:-5}"
            bash "$HERE/notify.sh" reconcile --session "$session"
            bash "$HERE/notify.sh" push --session "$session" ;;
        *) bash "$HERE/notify.sh" reconcile --session "$session" ;;
    esac
    exit 0
fi
bash "$HERE/notify.sh" signal
# "stopped" counts only after it held: look once more then
if [ -z "${HERDR_GRAPH_NO_SIGNAL:-}" ] && grep -qs '"reason":"stopped"[^}]*"delivered_at":null' "$state"/sessions/*.events.json; then
    sleep $((${HERDR_GRAPH_STOP_HOLD:-30} + 1))
    bash "$HERE/notify.sh" signal
fi
exit 0
