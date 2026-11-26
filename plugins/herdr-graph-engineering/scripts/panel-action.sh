#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# panel-action.sh -- the Herdr plugin's actions and hooks (see herdr-plugin.toml).
# Usage: panel-action.sh toggle | refresh | next-needs-me | open-link | restore | worktree-removed
#   toggle           close the graph panel in this tab, or open it to the right of the orchestrator
#   refresh          make every open panel redraw now (it sends ESC [ 99 ~, which no key sends:
#                    the panel ignores keystrokes)
#   next-needs-me    focus the next agent that waits on the user
#   open-link        (a link handler) open a clicked report path or pull request in a popup
#   restore          (startup hook) reopen the panel next to the orchestrator, rewrite the sidebar tokens
#   worktree-removed (event hook) close the lanes whose worktree was removed by hand
# The panel's pane is found by its terminal title, so nothing is stored.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/common.sh
. "$HERE/src/common.sh"

PANEL_TITLE="herdr-graph-panel"
PLUGIN_ID="${HERDR_PLUGIN_ID:-herdr-graph-engineering.graph}"
require_tools jq herdr

panels() { # [tab] -> pane ids of open panels, in that tab when given
    herdr pane list 2>/dev/null | jq -r --arg tab "${1:-}" --arg t "$PANEL_TITLE" \
        '.result.panes[]? | select((.terminal_title_stripped // .terminal_title // "") == $t) | select($tab == "" or .tab_id == $tab) | .pane_id'
}

orchestrator_pane() { # the pane of the live graph orchestrator, if any
    herdr agent list 2>/dev/null | jq -r '[.result.agents[]? | select((.name // "") | test("^graph(-[0-9]+)?$"))][0].pane_id // empty'
}

open_panel() { # target pane
    local args=(plugin pane open --plugin "$PLUGIN_ID" --entrypoint panel --placement split --direction right --no-focus)
    [ -n "$1" ] && args+=(--target-pane "$1")
    herdr "${args[@]}" >/dev/null 2>&1 || die "could not open the graph panel (is the plugin linked and enabled?)"
}

case "${1:-}" in
toggle)
    # The tab this is about: the caller's, else the tab of the pane the panel would open next to.
    target="${HERDR_PANE_ID:-}"
    [ -n "$target" ] || target="$(orchestrator_pane)"
    tab="${HERDR_TAB_ID:-}"
    if [ -z "$tab" ] && [ -n "$target" ]; then
        tab="$(herdr pane get "$target" 2>/dev/null | jq -r '.result.pane.tab_id // empty')"
    fi
    [ -n "$tab" ] || die "no tab to toggle the panel in: run this from a Herdr pane, or start the orchestrator first" 2
    open="$(panels "$tab")"
    if [ -n "$open" ]; then
        for p in $open; do herdr plugin pane close "$p" >/dev/null 2>&1; done
        echo "PANEL CLOSED"
    else
        open_panel "$target"
        echo "PANEL OPEN"
    fi ;;
refresh)
    for p in $(panels ""); do herdr pane send-text "$p" "$(printf '\033[99~')" >/dev/null 2>&1; done ;;
next-needs-me)
    agent="$(bash "$HERE/status.sh" --json | jq -r '[.[] | select(.section == "needs") | .nodes[] | select(.live == "blocked") | .agent][0] // empty')"
    if [ -n "$agent" ]; then
        herdr agent focus "$agent" >/dev/null 2>&1 && echo "FOCUSED $agent"
    else
        herdr notification show "Nothing needs you" --body "No lane agent is waiting on you." >/dev/null 2>&1
        echo "NOTHING NEEDS YOU"
    fi ;;
open-link)
    url="${HERDR_PLUGIN_CLICKED_URL:-}"
    [ -n "$url" ] || die "no clicked URL" 2
    herdr plugin pane open --plugin "$PLUGIN_ID" --entrypoint viewer --env "GRAPH_URL=$url" >/dev/null 2>&1 ||
        die "could not open the viewer" ;;
restore)
    target="$(orchestrator_pane)"
    if [ -n "$target" ]; then
        tab="$(herdr pane get "$target" 2>/dev/null | jq -r '.result.pane.tab_id // empty')"
        [ -n "$(panels "$tab")" ] || open_panel "$target"
    fi
    bash "$HERE/status.sh" --tokens ;;
worktree-removed)
    ev="${HERDR_PLUGIN_EVENT_JSON:-}"
    [ -n "$ev" ] || ev='{}'
    ws="$(jq -r '.workspace_id // .data.workspace_id // empty' <<<"$ev" 2>/dev/null)"
    repo="$(jq -r '.worktree.repo_root // .data.worktree.repo_root // empty' <<<"$ev" 2>/dev/null)"
    [ -n "$ws" ] || exit 0
    for r in $repo $(herdr workspace list 2>/dev/null | jq -r '.result.workspaces[]?.worktree.repo_root // empty' | sort -u); do
        [ -d "$r" ] || continue
        bash "$HERE/lane.sh" list --repo "$r" 2>/dev/null | cut -f1 | while IFS= read -r lane; do
            [ -n "$lane" ] || continue
            [ "$(yq -r '.workspace // ""' "$(lane_file "$r" "$lane")")" = "$ws" ] || continue
            bash "$HERE/lane.sh" close --repo "$r" --lane "$lane"
        done
    done ;;
*) usage "panel-action.sh toggle|refresh|next-needs-me|open-link|restore|worktree-removed" ;;
esac
