#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# roster.sh -- every live agent, where it runs and its state.
# Usage: roster.sh [--workspace ID] [--repo DIR] [--json]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/herdr.sh
. "$HERE/src/herdr.sh"
# shellcheck source=src/require.sh
. "$HERE/src/require.sh"

USAGE="roster.sh [--workspace ID] [--repo DIR] [--json]"
workspace="" repo="" as_json=0
while [ $# -gt 0 ]; do
    case "$1" in
        --workspace) need_value "$1" $#; workspace="$2"; shift 2 ;;
        --repo) need_value "$1" $#; repo="$(real_dir "$2")"; shift 2 ;;
        --json) as_json=1; shift ;;
        *) usage "$USAGE" ;;
    esac
done
require_herdr
workspaces_load
agents_load
rows="$(jq -cn --argjson a "$AGENTS_JSON" --argjson w "$WS_JSON" --arg ws "$workspace" --arg repo "$repo" --arg me "${HERDR_PANE_ID:-}" '
    ($w | map({(.workspace_id): .}) | add // {}) as $wm
    | [$a[] | ($wm[.workspace_id // ""] // {}) as $wk
        | select($ws == "" or .workspace_id == $ws)
        | select($repo == "" or (($wk.worktree | objects | .repo_root) // "") == $repo)
        | {name: (.name // ""), pane: (.pane_id // ""), tab: (.tab_id // ""), kind: (.agent // ""),
           status: (.agent_status // "unknown"), workspace: (.workspace_id // ""), label: ($wk.label // ""),
           cwd: (.cwd // ""), self: (.pane_id == $me)}]')"
if [ "$as_json" -eq 1 ]; then
    printf '%s' "$rows" | jq --indent 1 '.'
    exit 0
fi
if [ "$(printf '%s' "$rows" | jq 'length')" -eq 0 ]; then
    msg="no live agents"
    [ -n "$workspace$repo" ] && msg="$msg match the filter"
    printf '%s\n' "$msg"
    exit 0
fi
printf '%s' "$rows" | jq -r '
    {"blocked": 0, "done": 1, "idle": 2, "working": 3} as $order
    | sort_by([($order[.status] // 4), .workspace, .pane])
    | ([24, (.[] | "\(.workspace) \(.label)" | length)] | max) as $w
    | def pad($s; $n): $s + (" " * ($n - ($s | length)) // "");
      (pad("STATUS"; 8) + " " + pad("NAME"; 20) + " " + pad("PANE"; 9) + " " + pad("KIND"; 9) + " " + pad("WORKSPACE"; $w) + " CWD"),
      (.[] | pad(.status; 8) + " " + pad(((if .name == "" then "(unnamed)" else .name end) + (if .self then " *" else "" end)); 20)
             + " " + pad(.pane; 9) + " " + pad(.kind; 9) + " " + pad("\(.workspace) \(.label)"; $w) + " " + .cwd),
      ([.[] | select(.status == "blocked") | (if .name == "" then .pane else .name end)] | select(length > 0)
       | "BLOCKED, waiting on a human: " + join(", ")),
      "(* = this agent. Target unnamed agents by pane id.)"'
