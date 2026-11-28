#!/usr/bin/env bash
# section-orchneeds.sh -- sourced by run-tests.sh; do not run standalone.
# The orchestrator's own NEEDS YOU entry: session.sh's needs list, how the panel draws it,
# and a click on one of its prompt lines (notify.sh prompt) against the stub herdr.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr-graph-engineering/tests/run-tests.sh" >&2; exit 2; }

N_TMP="$(mktemp -d)"
NSC="$PLUGIN/scripts"
ng() { local s="$1"; shift; (cd "$N_TMP" && env -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_PLUGIN_ID PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$N_TMP" HERDR_ENV=1 NO_COLOR=1 HERDR_GRAPH_KEY_WAIT=0 XDG_CONFIG_HOME="$N_TMP/config" bash "$NSC/$s.sh" "$@"); }
nclick() { printf '\033[<0;%s;%sM\033[<0;%s;%sm' "$1" "$2" "$1" "$2"; }
nrow() { grep -nF -- "$1" <<<"$2" | head -1 | cut -d: -f1; }
RULE='────────────'
EMPTY_BOX="$RULE"$'\n''❯ '$'\n'"$RULE"
DRAFT_BOX="$RULE"$'\n''❯ half a draft'$'\n'"$RULE"
# agent_state status [kind] [pane] [screen] [screen after the clear keys]
nstate() {
    jq -cn --arg s "$1" --arg k "${2:-claude}" --arg p "${3:-w1:p1}" --arg scr "${4:-$DRAFT_BOX}" --arg after "${5-$EMPTY_BOX}" \
        '{agents: {graph: ({name: "graph", pane_id: $p, agent: $k, agent_status: $s, screen: $scr}
            + (if $after != "" then {cleared: $after} else {} end))}}' >"$N_TMP/state.json"
    : >"$N_TMP/calls.log"
}
nsent() { jq -r '.sent // [] | .[] | "\(.pane) \(if .keys then "keys \(.keys)" else "text \(.text)" end)"' "$N_TMP/state.json"; }

echo "== orchestrator needs: the session list =="
nstate idle
ng session set --key pane --value w1:p1 >/dev/null
out="$(ng session add --list needs --text "Reload the plugins" --prompt "/reload-plugins" --prompt "go on with the lanes")"
check "an entry is added" "ADDED needs 1" "$out"
check "with its prompts, in order" '["/reload-plugins","go on with the lanes"]' "$(ng session show --json | jq -c '.needs[0].prompts')"
ng session add --list needs --text x --prompt $'two\nlines' >/dev/null 2>&1
check_rc "a prompt with a newline is refused (it would submit itself)" 2 $?
ng session add --list needs --text x --prompt "-flag" >/dev/null 2>&1
check_rc "a prompt starting with - is refused (herdr would read a flag)" 2 $?
ng session add --list notes --text x --prompt y >/dev/null 2>&1
check_rc "--prompt is only for the needs list" 2 $?

echo "== orchestrator needs: the panel =="
out="$(ng panel --frame --width 60)"
check "the entry is under NEEDS YOU, counted" " NEEDS YOU (1)" "$(sed -n 1p <<<"$out")"
check "it is named orchestrator, with [done]" "1" "$(sed -n 2p <<<"$out" | grep -cE '^ ● orchestrator +\[done\]$')"
check "with its description" "Reload the plugins" "$out"
check "one line per prompt" "▶ /reload-plugins" "$out"
check "the second prompt too" "▶ go on with the lanes" "$out"
NREPO="$N_TMP/repo"
git init -q -b main "$NREPO" && git -C "$NREPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
ng lane new --repo "$NREPO" --lane why-slow --pattern investigate --idea y >/dev/null
ng lane ask --repo "$NREPO" --lane why-slow --node investigate --text "Staging or production?" >/dev/null
out="$(cd "$NREPO" && PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$N_TMP" NO_COLOR=1 XDG_CONFIG_HOME="$N_TMP/config" bash "$NSC/panel.sh" --frame --width 60)"
check "with a lane that needs you: one header, counting both" "NEEDS YOU (2)" "$out"
check "only one NEEDS YOU header" "1" "$(grep -c 'NEEDS YOU' <<<"$out")"
check "the orchestrator comes first" "1" "$([ "$(nrow '● orchestrator' "$out")" -lt "$(nrow '▾ why-slow' "$out")" ] && echo 1)"

echo "== orchestrator needs: a click on a prompt line =="
frame="$(ng panel --frame --width 60)"
row="$(nrow '▶ /reload-plugins' "$frame")"
nstate idle
out="$(nclick 8 "$row" | ng panel --frame --width 60 --feed)"
check "the clear keys go first" "w1:p1 keys ctrl+e ctrl+u" "$(nsent | head -1)"
check "then the text, in the orchestrator's pane" "w1:p1 text /reload-plugins" "$(nsent | tail -1)"
check "the text is sent once" "1" "$(nsent | grep -c ' text ')"
check_absent "no Enter" "enter" "$(nsent | tr '[:upper:]' '[:lower:]')"
check_absent "nothing is submitted" "agent prompt" "$(cat "$N_TMP/calls.log")"
check_absent "no pane run" "pane run" "$(cat "$N_TMP/calls.log")"
check_absent "never ctrl+c or esc" "ctrl+c" "$(cat "$N_TMP/calls.log")"
check "the panel says it is there" "press Enter there" "$out"
nstate "done" opencode
nclick 8 "$row" | ng panel --frame --width 60 --feed >/dev/null
check "OpenCode: the same keys and text" "w1:p1 text /reload-plugins" "$(nsent | tail -1)"
check "the second line sends the second prompt" "w1:p1 text go on with the lanes" "$(nstate idle codex; nclick 8 "$(nrow '▶ go on' "$frame")" | ng panel --frame --width 60 --feed >/dev/null; nsent | tail -1)"

echo "== orchestrator needs: when nothing may be typed =="
for st in working blocked unknown; do
    nstate "$st"
    out="$(nclick 8 "$row" | ng panel --frame --width 60 --feed)"
    check "$st: nothing is sent" "0" "$(nsent | grep -c .)"
    check "$st: the panel says why" "not typed: the orchestrator is $st" "$out"
done
nstate idle claude w2:p2
out="$(nclick 8 "$row" | ng panel --frame --width 60 --feed)"
check "the agent is in another pane: nothing is sent" "0" "$(nsent | grep -c .)"
check "and the panel says so" "not typed: orchestrator not in its pane" "$out"
nstate idle claude w1:p1 "$DRAFT_BOX" ""
out="$(nclick 8 "$row" | ng panel --frame --width 60 --feed)"
check "a box that does not clear gets no text" "0" "$(nsent | grep -c ' text ')"
check "and the panel says so" "not typed: the input box did not clear" "$out"

nstate idle
check "next-needs-me goes to the orchestrator when only it needs you" "FOCUSED graph" "$(cd "$N_TMP" && PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$N_TMP" XDG_STATE_HOME="$XDG_STATE_HOME" HERDR_PLUGIN_STATE_DIR="$N_TMP/plugin" bash -c 'bash "$1/panel-action.sh" next-needs-me' _ "$NSC")"

echo "== orchestrator needs: it leaves =="
nstate idle
drow="$(nrow '● orchestrator' "$frame")"
dcol="$(jq -Rr 'split("[done]")[0] | length + 2' <<<"$(sed -n "${drow}p" <<<"$frame")")"
out="$(nclick "$dcol" "$drow" | ng panel --frame --width 60 --feed)"
check "[done] asks first" "[confirm]" "$out"
out="$({ nclick "$dcol" "$drow"; nclick "$dcol" "$drow"; } | ng panel --frame --width 60 --feed)"
check_absent "the confirmed [done] removes it" "orchestrator" "$out"
check "from the session too" "0" "$(ng session show --json | jq '.needs | length')"
ng session add --list needs --text "Restart the chat" >/dev/null
check "an entry with no prompt shows" "Restart the chat" "$(ng panel --frame --width 60)"
ng session del --list needs --id 2 >/dev/null
check_absent "session.sh del removes it" "Restart the chat" "$(ng panel --frame --width 60)"
check "the orchestrate skill records such entries" "session.sh add --list needs" "$(cat "$PLUGIN/skills/orchestrate/SKILL.md")"

rm -rf "$N_TMP"
