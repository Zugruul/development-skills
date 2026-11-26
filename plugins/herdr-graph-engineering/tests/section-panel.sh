#!/usr/bin/env bash
# section-panel.sh -- sourced by run-tests.sh; do not run standalone.
# The Herdr panel plugin: its manifest, one rendered frame, the refresh interval cycle and
# button columns, the actions (toggle, refresh, next-needs-me, worktree-removed, restore),
# the sidebar tokens and the answer popup, against the stub herdr.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr-graph-engineering/tests/run-tests.sh" >&2; exit 2; }

P_TMP="$(mktemp -d)"
SC="$PLUGIN/scripts"
PREPO="$P_TMP/repo"
git init -q -b main "$PREPO" && git -C "$PREPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
pg() { local s="$1"; shift; (cd "$PREPO" && env -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_PLUGIN_ID ${P_TAB:+HERDR_TAB_ID=$P_TAB} PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$P_TMP" HERDR_ENV=1 NO_COLOR=1 XDG_CONFIG_HOME="$P_TMP/config" bash "$SC/$s.sh" "$@"); }
# pgc: the same, with colour (NO_COLOR unset).
pgc() { local s="$1"; shift; (cd "$PREPO" && env -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_PLUGIN_ID -u NO_COLOR PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$P_TMP" HERDR_ENV=1 XDG_CONFIG_HOME="$P_TMP/config" bash "$SC/$s.sh" "$@"); }
E=$'\033'
# the codepoint column (1-based) where a text starts in a line, independent of the locale
col_of() { jq -Rr --arg t "$1" 'split($t)[0] | length + 1' <<<"$2"; }
pst() { printf '%s' "$1" >"$P_TMP/state.json"; : >"$P_TMP/calls.log"; }
sj() { jq -r "$1" "$P_TMP/state.json"; }
pst '{}'

echo "== panel: manifest =="
m="$PLUGIN/herdr-plugin.toml"
mj="$(yq -p=toml -o=json '.' "$m" 2>&1)"
check "the Herdr manifest parses" "herdr-graph-engineering.graph" "$(jq -r .id <<<"$mj")"
for k in id name version min_herdr_version; do
    check "manifest has $k" "ok" "$(jq -r --arg k "$k" 'if has($k) then "ok" else "missing" end' <<<"$mj")"
done
check "the panel is a split pane" "split" "$(jq -r '.panes[] | select(.id == "panel") | .placement' <<<"$mj")"
for e in answer detail viewer; do
    check "the $e popup is a popup" "popup" "$(jq -r --arg e "$e" '.panes[] | select(.id == $e) | .placement' <<<"$mj")"
done
check "the actions" "next-needs-me open-link refresh toggle" "$(jq -r '[.actions[].id] | sort | join(" ")' <<<"$mj")"
check "restore runs at startup" "restore" "$(jq -r '.startup[0].command | join(" ")' <<<"$mj")"
check "a removed worktree closes its lane" "worktree.removed" "$(jq -r '.events[0].on' <<<"$mj")"
check "the manifest version matches the plugin" "$(jq -r .version "$PLUGIN/.claude-plugin/plugin.json")" "$(jq -r .version <<<"$mj")"
while IFS= read -r f; do
    ok=0; [[ -f "$PLUGIN/$f" ]] || ok=1
    check_rc "manifest command exists: $f" 0 "$ok"
done < <(jq -r '[.panes[], .actions[], .startup[], .events[]] | .[].command[1]' <<<"$mj" | sort -u)

echo "== panel: frame, interval and buttons =="
pg lane new --repo "$PREPO" --lane task-x --pattern solo --idea x --gate "npm test" >/dev/null
pg lane new --repo "$PREPO" --lane why-slow --pattern investigate --idea y >/dev/null
pg lane ask --repo "$PREPO" --lane why-slow --node investigate --text "Staging or production?" >/dev/null
out="$(pg panel --frame --width 40 --interval 5)"
check_absent "the panel draws no title of its own (Herdr's border has it)" " Graph" "$out"
check_absent "no dashed separator" "-----" "$out"
check "the lanes start on the first line, NEEDS YOU first" " NEEDS YOU (1)" "$(sed -n 1p <<<"$out")"
check "the selected lane has a bar and a marker, name then pattern" " ▎▸ why-slow investigate" "$(sed -n 2p <<<"$out")"
check "the node chain sits under the name, no extra indent" "    investigate ?" "$(sed -n 3p <<<"$out")"
check_absent "the chain is not indented further" "     investigate" "$out"
check "the open question is shown" "    ? Staging or production?" "$out"
check "a blank line between sections" "" "$(sed -n 5p <<<"$out")"
check "an unselected lane, name then pattern" "    task-x solo" "$out"
check "a thin divider above the footer" "────────" "$out"
check "the footer says when it read" "updated " "$out"
check "the footer shows the interval" "every 5s" "$out"
check "the footer names the keys" "↵ fold · g go · a answer · d detail · ? keys" "$(pg panel --frame --width 120)"
last="$(tail -1 <<<"$out")"
check "the buttons end the bottom line" "[◷ 5s] [↻]" "$last"
check "the buttons are on the bottom line only" "1" "$(grep -c "\[↻\]" <<<"$out")"
check "the footer is the bottom block, the divider right above it" "─" "$(tail -n +"$(($(grep -n '^ *updated ' <<<"$out" | cut -d: -f1) - 1))" <<<"$out" | head -1)"
check "the button columns match the drawn bottom line" "IV 30-35 RF 37-39" "$(pg panel --buttons --width 40 --interval 5)"
check "the interval button starts where the click column says" "30" "$(col_of "[◷" "$last")"
check "the refresh button starts where the click column says" "37" "$(col_of "[↻" "$last")"
check "a wide pane keeps the footer on one line" "1" "$(pg panel --frame --width 120 | grep -c 'updated .*\[↻\]')"
check "the buttons are clicked on the last row of the pane" "ROW 24" "$(pg panel --buttons --width 40 --interval 5 --rows 24)"
check "selection moves" "▎▸ task-x solo" "$(pg panel --frame --width 40 --selected 1)"
check "the interval cycles and wraps" "10 15 30 60 300 5" "$(for i in 5 10 15 30 60 300; do pg panel --next-interval "$i"; done | tr '\n' ' ' | sed 's/ $//')"
check "a minute shows as 1m" "[◷ 1m]" "$(pg panel --frame --width 40 --interval 60)"
check "no lanes: the hint starts on the first line" " No lanes yet." "$(cd "$P_TMP" && NO_COLOR=1 PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$P_TMP" XDG_CONFIG_HOME="$P_TMP/empty" bash "$SC/panel.sh" --frame --width 40 | sed -n 1p)"
check "since last look lists the lanes that moved" " Since last look: why-slow → needs you" "$(pg panel --frame --width 40 --seen '{"why-slow":"working","task-x":"working"}')"
check_absent "nothing moved, no since-last-look line" "Since last look" "$(pg panel --frame --width 40 --seen '{"why-slow":"needs","task-x":"working"}')"

echo "== panel: colour =="
out="$(pgc panel --frame --width 40 --interval 5)"
check "NEEDS YOU is a bold red header" "${E}[1;31m NEEDS YOU (1)" "$out"
check "WORKING is a bold yellow header" "${E}[1;33m WORKING (1)" "$out"
check "the selected row: coloured bar, background, bold name, grey pattern" "${E}[48;5;236m ${E}[36m▎▸${E}[39m ${E}[1mwhy-slow${E}[22m ${E}[90minvestigate${E}[39m${E}[K${E}[0m" "$out"
check "an unselected lane: bold name, grey pattern" "    ${E}[1mtask-x${E}[22m ${E}[90msolo${E}[39m" "$out"
check "a node waiting on a person is red" "investigate ${E}[31m?${E}[39m" "$out"
check "its question is red" "${E}[31m? Staging or production?${E}[39m" "$out"
check "a pending node is grey" "impl ${E}[90m·${E}[39m" "$out"
check "the footer is dim grey" "${E}[2;90m updated " "$out"
check "the divider is grey" "${E}[90m────" "$out"
check_absent "NO_COLOR: no escape codes at all" "$E" "$(pg panel --frame --width 40 --interval 5)"
check_absent "an empty NO_COLOR still means colour" "NOCOLOUR" "$(grep -q "$E" <<<"$(cd "$PREPO" && NO_COLOR='' PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$P_TMP" XDG_CONFIG_HOME="$P_TMP/config" bash "$SC/panel.sh" --frame --width 40)" || echo NOCOLOUR)"

echo "== panel: clicks and keys, through the real input loop =="
# --feed runs stdin through read_key and act, as the live panel does, then prints the frame.
click() { printf '\033[<0;%s;%sM\033[<0;%s;%sm' "$1" "$2" "$1" "$2"; }
out="$(click 5 2 | pg panel --frame --width 40 --feed)"
check "a click on a lane row folds it to its header line" " ▎▸ why-slow investigate" "$out"
check_absent "the folded lane hides its chain and question" "Staging or production?" "$out"
check "a folded lane is marked" "▎▸ why-slow investigate …" "$out"
out="$( { click 5 2; click 5 2; } | pg panel --frame --width 40 --feed)"
check "a second click unfolds it" "? Staging or production?" "$out"
row="$(pg panel --frame --width 40 | grep -n "task-x solo" | cut -d: -f1)"
out="$(click 6 "$row" | pg panel --frame --width 40 --feed)"
check "a click on another lane selects it" "▎▸ task-x solo …" "$out"
check "and folds only that lane" "? Staging or production?" "$out"
out="$(click 6 3 | pg panel --frame --width 40 --feed)"
check "a click on a lane's chain line folds that lane too" "▎▸ why-slow investigate …" "$out"
out="$(click 3 1 | pg panel --frame --width 40 --feed)"
check "a click on a section header changes nothing" "? Staging or production?" "$out"
out="$(printf ' ' | pg panel --frame --width 40 --feed)"
check "space folds the selected lane" "▎▸ why-slow investigate …" "$out"
out="$(printf '\n' | pg panel --frame --width 40 --feed)"
check "enter folds the selected lane" "▎▸ why-slow investigate …" "$out"
out="$(printf '\033[B ' | pg panel --frame --width 40 --feed)"
check "down then space folds the next lane" "▎▸ task-x solo …" "$out"
rows="$(pg panel --frame --width 40 | wc -l | tr -d ' ')"
out="$(click 31 "$rows" | pg panel --frame --width 40 --interval 5 --feed)"
check "a click on the interval button on the bottom row cycles it" "every 10s" "$out"
out="$(click 31 1 | pg panel --frame --width 40 --interval 5 --feed)"
check "the same column on the top row is not the button" "every 5s" "$out"
mkdir -p "$P_TMP/cfg" && printf 'refresh=30s\n' >"$P_TMP/cfg/config"
check "the starting interval comes from the plugin config" "every 30s" "$(cd "$PREPO" && HERDR_PLUGIN_CONFIG_DIR="$P_TMP/cfg" PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$P_TMP" XDG_CONFIG_HOME="$P_TMP/config" bash "$SC/panel.sh" --frame --width 40)"

echo "== panel: actions =="
pst '{"agents":{"g":{"name":"graph","pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1","agent":"claude","agent_status":"working"}}}'
out="$(P_TAB=w1:t1 pg panel-action toggle)"
check "toggle opens the panel when none is open" "PANEL OPEN" "$out"
check "it opens the panel entrypoint as a split" "panel" "$(sj '.opened[0].entrypoint')"
check "it opens next to the orchestrator when called from elsewhere" "w1:p1" "$(sj '.opened[0].target')"
pst '{"pane_list":[{"pane_id":"w1:p5","tab_id":"w1:t1","terminal_title_stripped":"herdr-graph-panel"},{"pane_id":"w2:p1","tab_id":"w2:t1","terminal_title_stripped":"herdr-graph-panel"}]}'
out="$(P_TAB=w1:t1 pg panel-action toggle)"
check "toggle closes the panel in this tab" "PANEL CLOSED" "$out"
check "only this tab's panel is closed" '["w1:p5"]' "$(jq -c .closed "$P_TMP/state.json")"
pst '{"pane_list":[{"pane_id":"w1:p5","tab_id":"w1:t1","terminal_title_stripped":"herdr-graph-panel"},{"pane_id":"w1:p2","tab_id":"w1:t1","terminal_title_stripped":"zsh"}]}'
pg panel-action refresh >/dev/null
check "refresh tells every panel to redraw" '[{"pane":"w1:p5","text":"r"}]' "$(jq -c .sent "$P_TMP/state.json")"
pg lane node --repo "$PREPO" --lane why-slow --node investigate --status running --agent claude-why-slow-inv >/dev/null
pst '{"agents":{"a":{"name":"claude-why-slow-inv","pane_id":"w4:p1","workspace_id":"w4","agent":"claude","agent_status":"blocked"}}}'
out="$(pg panel-action next-needs-me)"
check "next-needs-me focuses the blocked lane agent" "FOCUSED claude-why-slow-inv" "$out"
pst '{"agents":{}}'
check "next-needs-me says when nothing needs you" "NOTHING NEEDS YOU" "$(pg panel-action next-needs-me)"

echo "== panel: sidebar tokens and restore =="
pst '{"agents":{"a":{"name":"claude-why-slow-inv","pane_id":"w4:p1","workspace_id":"w4","agent":"claude","agent_status":"working"}}}'
pg status --tokens --repo "$PREPO" >/dev/null
check "tokens go to the lane agent's pane" "w4:p1" "$(sj '.tokens[0].pane')"
check "the tokens name lane, node and step" "--token lane=why-slow --token node=investigate --token step=running" "$(sj '.tokens[0].args')"
pst '{"agents":{"g":{"name":"graph","pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1","agent":"claude","agent_status":"idle"}},"pane_list":[{"pane_id":"w1:p1","tab_id":"w1:t1"}]}'
pg panel-action restore >/dev/null
check "restore reopens the panel next to the orchestrator" "panel w1:p1" "$(sj '"\(.opened[0].entrypoint) \(.opened[0].target)"')"

echo "== panel: a worktree removed by hand =="
pg lane set --repo "$PREPO" --lane task-x --key workspace --value w7 >/dev/null
pst "{\"workspaces\":[{\"workspace_id\":\"w1\",\"worktree\":{\"repo_root\":\"$PREPO\"}}]}"
out="$(HERDR_PLUGIN_EVENT_JSON='{"workspace_id":"w7"}' pg panel-action worktree-removed)"
check "the lane of the removed workspace is closed" "CLOSED task-x" "$out"
check_absent "other lanes stay open" "CLOSED why-slow" "$out"

echo "== panel: answer popup =="
pg lane set --repo "$PREPO" --lane why-slow --key owner --value graph >/dev/null
pst '{"agents":{"g":{"name":"graph","pane_id":"w1:p1","workspace_id":"w1","agent":"claude","agent_status":"idle"}}}'
out="$(printf 'staging\n' | GRAPH_LANE=why-slow GRAPH_REPO="$PREPO" pg popup answer 2>&1)"
check "the popup shows the question" "Staging or production?" "$out"
check "the answer goes to the orchestrator" "Sent to graph" "$out"
check "the orchestrator gets lane, question and answer" 'agent prompt graph Answer for lane why-slow, to: "Staging or production?" -- staging' "$(cat "$P_TMP/calls.log")"
echo "== panel: popup styling =="
printf '#!/bin/sh\ncat\n' >"$P_TMP/pager" && chmod +x "$P_TMP/pager"
out="$(GRAPH_LANE=why-slow GRAPH_REPO="$PREPO" PAGER="$P_TMP/pager" pgc popup detail 2>&1)"
check "detail: the lane name is bold" "${E}[1mwhy-slow${E}[22m" "$out"
check "detail: the pattern is grey" "${E}[90m · investigate" "$out"
check "detail: a running node is yellow, like the panel" "${E}[33m⟳${E}[39m" "$out"
check "detail: the history heading is bold" "${E}[1mhistory${E}[22m" "$out"
out="$(GRAPH_LANE=why-slow GRAPH_REPO="$PREPO" PAGER="$P_TMP/pager" pg popup detail 2>&1)"
check "detail without colour still reads" "why-slow · investigate" "$out"
check_absent "detail: NO_COLOR has no escape codes" "$E" "$out"
out="$(printf '\n' | GRAPH_LANE=why-slow GRAPH_REPO="$PREPO" pgc popup answer 2>&1)"
check "answer: the lane name is bold" "${E}[1mwhy-slow${E}[22m" "$out"
check "answer: the question is red" "${E}[31m? Staging or production?${E}[39m" "$out"
rm -rf "$P_TMP"
