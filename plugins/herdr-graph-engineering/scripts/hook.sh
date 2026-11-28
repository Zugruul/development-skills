#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# hook.sh -- the client hooks (hooks/hooks.json): what an agent's own client says, as it happens.
# Usage: hook.sh stop|prompt|ask|ask-done|permission|stop-failure     (the hook's JSON on stdin)
# These hooks load in every chat where the plugin is enabled, so a pane that is neither a lane
# agent's nor the orchestrator's leaves after one file test, with no tool run (src/panes.sh).
#
# In a lane agent's pane they only observe: they keep the agent's claim in
# <lane folder>/claims/<lane>/<node>.json for its current run and signal notify.sh. They print
# nothing, decide nothing, answer nothing and always exit 0.
#   stop          the last non-empty line of the final message, read strictly (src/result.sh);
#                 background tasks or crons with no result mean not finished
#   prompt        a new turn: the old claim goes
#   ask, ask-done the question dialog's exact questions and options; gone once answered. The
#                 tool is AskUserQuestion (Claude Code), request_user_input (Codex) or question
#                 (OpenCode, through opencode/herdr-graph.js)
#   permission    the tool an approval is asked for
#   stop-failure  the client's own error (rate limit, login, ...)
#
# In the orchestrator's pane:
#   stop    asks the client not to end the turn while a lane it owns has an open question never put
#           to the user (lane.sh asked); once only, and never under AFK
#   prompt  under AFK, adds context to a message that is not the watcher's: show the decided list
#           and ask "still away?"
HERE="${BASH_SOURCE[0]%/*}"
[ -n "${HERDR_PANE_ID:-}" ] || exit 0
key="${HERDR_PANE_ID//[^A-Za-z0-9]/_}"
panes="${XDG_STATE_HOME:-$HOME/.local/state}/herdr-graph/panes"
[ -f "$panes/$key.lane" ] || [ -f "$panes/$key.orch" ] || exit 0

HERE="$(cd "$HERE" 2>/dev/null && pwd)" || exit 0
# shellcheck source=src/common.sh
. "$HERE/src/common.sh"
# shellcheck source=src/result.sh
. "$HERE/src/result.sh"
# shellcheck source=src/afk.sh
. "$HERE/src/afk.sh"
event="${1:-}"
input="$(cat 2>/dev/null)"
for t in jq yq git; do command -v "$t" >/dev/null 2>&1 || exit 0; done

field() { jq -r "$1" <<<"$input" 2>/dev/null; }
question_tool() { case "$(field '.tool_name // ""')" in AskUserQuestion | request_user_input | question) return 0 ;; *) return 1 ;; esac; }

signal() { # repo, lane: look again, once herdr has caught up with the agent's state
    [ -z "${HERDR_GRAPH_NO_SIGNAL:-}" ] || return 0
    (nohup bash "$HERE/notify.sh" signal --delay 5 >/dev/null 2>&1 </dev/null &)
}

lane_hook() {
    local ref repo lane node agent file run dir out claim bg
    ref="$(cat "$panes/$key.lane" 2>/dev/null)"
    repo="$(jq -r .repo <<<"$ref")" lane="$(jq -r .lane <<<"$ref")" node="$(jq -r .node <<<"$ref")" agent="$(jq -r .agent <<<"$ref")"
    file="$(lane_file "$repo" "$lane")"
    [ -f "$file" ] || return 0
    # only while the node still runs with this agent; the claim belongs to its current run
    run="$(read_json "$file" | jq -r --arg n "$node" --arg a "$agent" '.nodes[$n] | select((.status == "running" or .status == "blocked") and .agent == $a) | .run // ""')"
    [ -n "$run" ] || return 0
    dir="$(lane_dir "$repo")"
    out="$(claim_file "$dir" "$lane" "$node")"
    jq -e . >/dev/null 2>&1 <<<"$input" || return 0
    case "$event" in
        stop)
            claim="$(last_line_claim "$node" "$(field '.last_assistant_message // ""')")" || return 0
            bg="$(field '((.background_tasks // []) | length) + ((.session_crons // []) | length)')"
            claim="$(jq -c --argjson bg "${bg:-0}" '.background = $bg | if .kind == "none" and $bg > 0 then .kind = "busy" else . end | .source = "stop-hook"' <<<"$claim")" ;;
        prompt) rm -f "$out"; signal; return 0 ;;
        ask)
            question_tool || return 0
            claim="$(field '{kind: "question", source: "ask-hook", ref: ([.tool_input.questions[]? | .question + " [" + ([.options[]?.label] | join(" | ")) + "]"] | join("; ") | gsub("[\r\n\t]+"; " "))} | tojson')" ;;
        ask-done)
            [ "$(jq -r '.source // ""' "$out" 2>/dev/null)" != ask-hook ] || rm -f "$out"
            signal
            return 0 ;;
        permission)
            # the question dialog asks permission too: its question claim says more
            ! question_tool || return 0
            claim="$(field '{kind: "permission", source: "permission-hook", ref: ("\(.tool_name // "a tool"): \(.tool_input | objects | .command // .file_path // .url // "")" | gsub("[\r\n\t]+"; " ") | .[0:200])} | tojson')" ;;
        stop-failure)
            claim="$(field '{kind: "failure", source: "stop-failure-hook", ref: ((.error // .error_type // .reason // "unknown error") | if type == "string" then . else tojson end | gsub("[\r\n\t]+"; " ") | .[0:200])} | tojson')" ;;
        *) return 0 ;;
    esac
    [ -n "$claim" ] || return 0
    mkdir -p "$(dirname "$out")" || return 0
    jq -c --arg run "$run" --arg at "$(now)" --arg sid "$(field '.session_id // ""')" '. + {run: $run, at: $at, session_id: $sid}' <<<"$claim" >"$out.$$" &&
        mv "$out.$$" "$out"
    signal
}

# The open questions of this session's lanes that were never put to the user.
unasked() { # session
    local name
    name="$(session_json "$1" | jq -r --arg s "$1" 'if (.orchestrator // "") != "" then .orchestrator else $s end')"
    bash "$HERE/status.sh" --json 2>/dev/null |
        jq -r --arg o "$name" '[.[] | select(.owner == $o and .section != "closed") | .lane as $l | (.questions // [])[] | select(.asked_at == null) | "\($l) #\(.id)"] | join(", ")'
}

orchestrator_hook() {
    local session list
    session="$(cat "$panes/$key.orch" 2>/dev/null)"
    [ -n "$session" ] || return 0
    case "$event" in
        stop)
            [ "$(field '.stop_hook_active // false')" != true ] || return 0
            [ "$(afk_json "$session" | jq -r .state)" != on ] || return 0
            list="$(unasked "$session")"
            [ -n "$list" ] || return 0
            jq -cn --arg r "herdr-graph: open questions not yet put to the user: $list. Put each to the user now (one question dialog; without a question tool, a numbered block that ends your turn), after recording it with lane.sh asked --lane L --id N." \
                '{decision: "block", reason: $r}' ;;
        prompt)
            [[ ! "$(field '.prompt // ""')" =~ $EVENT_MESSAGE_RE ]] || return 0
            [ "$(afk_json "$session" | jq -r .state)" = on ] || return 0
            jq -cn '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext:
                "herdr-graph: AFK is on. If this message is from the user (not the watcher, an agent or another session): show decide.sh digest first, then ask \"still away?\". Only their answer, or the afk off command, turns AFK off; then run decide.sh seen."}}' ;;
    esac
}

if [ -f "$panes/$key.orch" ]; then
    orchestrator_hook 2>/dev/null
elif [ -f "$panes/$key.lane" ]; then
    lane_hook >/dev/null 2>&1
fi
exit 0
