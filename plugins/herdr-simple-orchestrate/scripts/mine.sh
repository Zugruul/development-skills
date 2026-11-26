#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# mine.sh -- the two lists after an orchestrator report: the live agents that are not
# yours and not you, then this repository's worktrees that are open in Herdr.
# Usage: mine.sh [--cwd DIR] [AGENT ...]     AGENT = a name or pane id you follow
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/herdr.sh
. "$HERE/src/herdr.sh"
# shellcheck source=src/require.sh
. "$HERE/src/require.sh"
# shellcheck source=src/git.sh
. "$HERE/src/git.sh"

cwd="" mine="[]"
while [ $# -gt 0 ]; do
    case "$1" in
        --cwd) need_value "$1" $#; cwd="$2"; shift 2 ;;
        -*) usage "mine.sh [--cwd DIR] [AGENT ...]" ;;
        *) mine="$(jq -cn --argjson m "$mine" --arg a "$1" '$m + [$a]')"; shift ;;
    esac
done
cwd="$(abs_path "${cwd:-$(pwd)}")"
require_herdr
agents_load
workspaces_load
herdr_call worktree list --cwd "$cwd"
trees="null"
[ "$HC_RC" -eq 0 ] && [ "$HC_JSON" -eq 1 ] && trees="$(hj -c '[.result | objects | .worktrees | arrays | .[] | objects]')"

jq -rn --argjson a "$AGENTS_JSON" --argjson w "$WS_JSON" --argjson t "$trees" --argjson mine "$mine" \
    --arg me "${HERDR_PANE_ID:-}" --arg cwd "$cwd" '
    ($w | map({(.workspace_id): .label}) | add // {}) as $label
    | def lab($id): ($label[$id] // $id // "?");
      def cols($rows): if ($rows | length) == 0 then empty else
          ([range(0; $rows[0] | length) as $i | [$rows[][$i] | length] | max]) as $wd
          | $rows[] | [range(0; length) as $i | .[$i] + (" " * ($wd[$i] - (.[$i] | length)) // "")]
          | "  " + join("  ") | sub(" +$"; "") end;
    ([$a[] | select((.pane_id == $me and $me != "") or (.name | IN($mine[])) or (.pane_id | IN($mine[])) | not)]
     | sort_by([(if .agent_status == "blocked" then 0 else 1 end), (.workspace_id // ""), (.pane_id // "")])
     | map([(.workspace_id // "?"), lab(.workspace_id), (.agent // "?"), (.agent_status // "unknown"), (.name // "")])) as $rows
    | (if ($rows | length) > 0 then ("Other agents (\($rows | length))", cols($rows), "") else empty end),
      (if $t == null then "Worktrees: \($cwd) is not in a repository Herdr can list"
       else ([$a[].workspace_id]) as $busy
       | ([$t[] | select(.open_workspace_id)] | sort_by(.open_workspace_id)) as $open
       | "Worktrees (\($open | length) open of \($t | length))",
         cols([$open[] | [lab(.open_workspace_id), (.branch // "(no branch)"),
                          (if (.open_workspace_id | IN($busy[])) then "" else "(no agent)" end)]])
       end)'
