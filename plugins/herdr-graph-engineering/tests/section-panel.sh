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
pg lane new --repo "$PREPO" --lane task-y --pattern solo --idea z --gate "npm test" >/dev/null
pg lane new --repo "$PREPO" --lane why-slow --pattern investigate --idea y >/dev/null
pg lane ask --repo "$PREPO" --lane why-slow --node investigate --text "Staging or production?" >/dev/null
# the codepoint width of the widest line, independent of the locale
widest() { jq -Rn '[inputs | length] | max' <<<"$1"; }
out="$(pg panel --frame --width 40 --interval 5)"
check_absent "the panel draws no title of its own (Herdr's border has it)" " Graph" "$out"
check_absent "no dashed separator" "-----" "$out"
check "the lanes start on the first line, NEEDS YOU first, one column of padding" "1" "$(sed -n 1p <<<"$out" | grep -cx " NEEDS YOU (1)")"
check "a lane starts with its fold chevron, name and pattern, no tree guide" "1" "$(sed -n 2p <<<"$out" | grep -cE "^ ▾ why-slow  investigate ◂ +\[answer\]$")"
check "a lane that asks something ends with [answer], one column short of the right edge" "39" "$(sed -n 2p <<<"$out" | jq -Rr 'length')"
check "an unselected lane with no question has no buttons" "1" "$(grep -cx " ▾ task-x  solo" <<<"$out")"
wide="$(pg panel --frame --width 60 --interval 5)"
check "the selected lane also shows [detail], left of the others" "1" "$(grep -cE "^ ▾ why-slow  investigate ◂ +\[detail\] \[answer\]$" <<<"$wide")"
check "in a pane too narrow for even one button, none show" "1" "$(pg panel --frame --width 28 | grep -cx " ▾ why-slow  investigate ◂")"
check "its lines hang off ├ under it" "1" "$(sed -n 3p <<<"$out" | grep -cx "   ├ investigate ?")"
check "the open question is one of them" "1" "$(grep -cx "   ├ ? Staging or production?" <<<"$out")"
check "each lane's last line hangs off └" "3" "$(grep -c "^   └ last: " <<<"$out")"
check "every lane starts with its chevron" "1" "$(grep -cx " ▾ task-x  solo" <<<"$out")"
check "each lane's lines hang under it" "2" "$(grep -cx "   ├ impl · → tests ·" <<<"$out")"
check "the section's last lane too" "1" "$(grep -cx " ▾ task-y  solo" <<<"$out")"
check "every line keeps one column of padding on the left" "0" "$(grep -c "^[^ ]" <<<"$out")"
check "no line reaches the right edge (one column of padding)" "1" "$([ "$(widest "$out")" -le 39 ] && echo 1 || echo 0)"
wrapped="$(grep -A1 "^   └ last: " <<<"$out" | sed -n 2p)"
check "a long line wraps inside the tree, under its text" "1" "$(grep -c "^     [^ ]" <<<"$wrapped")"
check "a blank line between sections" "1" "$(grep -B1 "WORKING (2)" <<<"$out" | head -1 | grep -cx "")"
check "a thin divider above the footer, inside the padding" " $(printf '─%.0s' $(seq 1 38))" "$(grep "─" <<<"$out")"
check "the divider is exactly as wide as the pane minus padding" "39" "$(widest "$(grep "─" <<<"$out")")"
check "the footer says when it read" " updated " "$out"
check "the footer shows the interval" "every 5s" "$out"
check "the footer is only when it read, the interval and the buttons" "1" "$(pg panel --frame --width 120 | grep -cE "^ updated [0-9:]+ · every 5s +\[◷ 5s\] \[↻\]$")"
check_absent "the footer names no keys" "? keys" "$(pg panel --frame --width 120)"
last="$(tail -1 <<<"$out")"
check "the buttons end the bottom line" "[◷ 5s] [↻]" "$last"
check "the buttons are on the bottom line only" "1" "$(grep -c "\[↻\]" <<<"$out")"
check "the footer is the bottom block, the divider right above it" "─" "$(tail -n +"$(($(grep -n '^ updated ' <<<"$out" | cut -d: -f1) - 1))" <<<"$out" | head -1)"
check "the button columns match the drawn bottom line" "IV 30-35 RF 37-39" "$(pg panel --buttons --width 40 --interval 5)"
check "the interval button starts where the click column says" "30" "$(col_of "[◷" "$last")"
check "the refresh button starts where the click column says" "37" "$(col_of "[↻" "$last")"
check "a wide pane keeps the footer on one line" "1" "$(pg panel --frame --width 120 | grep -c 'updated .*\[↻\]')"
check "the buttons are clicked on the last row of the pane" "ROW 24" "$(pg panel --buttons --width 40 --interval 5 --rows 24)"
check "selection moves" " ▾ task-x  solo ◂" "$(pg panel --frame --width 40 --selected 1)"
check "the interval cycles and wraps" "10 15 30 60 300 5" "$(for i in 5 10 15 30 60 300; do pg panel --next-interval "$i"; done | tr '\n' ' ' | sed 's/ $//')"
check "a minute shows as 1m" "[◷ 1m]" "$(pg panel --frame --width 40 --interval 60)"
check "no lanes: the hint starts on the first line" "1" "$(cd "$P_TMP" && NO_COLOR=1 PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$P_TMP" XDG_CONFIG_HOME="$P_TMP/empty" bash "$SC/panel.sh" --frame --width 40 | sed -n 1p | grep -cx " No lanes yet.")"
# --rowmap prints "row kind" per screen row, as the live panel maps clicks.
map="$(pg panel --frame --width 30 --rowmap)"
narrow="$(pg panel --frame --width 30)"
check "a narrow pane still keeps every line inside the padding" "1" "$([ "$(widest "$narrow")" -le 29 ] && echo 1 || echo 0)"
qrow="$(grep -n "? Staging" <<<"$narrow" | head -1 | cut -d: -f1)"
check "every row of a wrapped line belongs to its lane" "0" "$(awk -v r="$qrow" '$1 >= r && $1 <= r + 1 {print $2}' <<<"$map" | sort -u | tr '\n' ' ' | sed 's/ $//')"
check "the rows stop above the footer when the pane is short" "1" "$(m="$(pg panel --frame --width 30 --rowmap --height 8)"; f="$(grep -c '─\|updated\|\[↻\]' <<<"$narrow")"; [ "$(wc -l <<<"$m")" -le $((8 - f)) ] && echo 1 || echo 0)"
check "since last look lists the lanes that moved" " Since last look: why-slow → needs you" "$(pg panel --frame --width 60 --seen '{"why-slow":"working","task-x":"working","task-y":"working"}')"
check_absent "nothing moved, no since-last-look line" "Since last look" "$(pg panel --frame --width 40 --seen '{"why-slow":"needs","task-x":"working","task-y":"working"}')"

echo "== panel: colour =="
# The mockup's colours, as 24-bit SGR: red f85149, amber d29922, green 3fb950, grey 8b949e,
# the selected row's background 21262d; for pull requests also blue 58a6ff and purple a371f7.
RED="${E}[38;2;248;81;73m" AMB="${E}[38;2;210;153;34m" GRN="${E}[38;2;63;185;80m" GRY="${E}[38;2;139;148;158m"
BLU="${E}[38;2;88;166;255m" PUR="${E}[38;2;163;113;247m" SEL="${E}[48;2;33;38;45m"
out="$(pgc panel --frame --width 40 --interval 5)"
check "NEEDS YOU is a bold red header" " ${E}[1m${RED}NEEDS YOU (1)" "$out"
check "WORKING is a bold amber header" " ${E}[1m${AMB}WORKING (2)" "$out"
check "the selected lane's first line: background from the edge, chevron, bold name, grey pattern" "${SEL} ▾ ${E}[1mwhy-slow${E}[22m  ${GRY}investigate${E}[39m" "$out"
check "its buttons are grey, the line ends with the background" "${GRY}[answer]${E}[39m${E}[K${E}[0m" "$out"
check "only the selected lane's first line has the background" "1" "$(grep -cF "$SEL" <<<"$out")"
check "an unselected lane: chevron, bold name, grey pattern" " ▾ ${E}[1mtask-x${E}[22m  ${GRY}solo${E}[39m" "$out"
check "the tree guides are grey" " ${GRY}  ├ ${E}[39minvestigate ${RED}?${E}[39m" "$out"
check "its question is red" "${RED}? Staging or production?${E}[39m" "$out"
check "a pending node is grey" "impl ${GRY}·${E}[39m" "$out"
check "the footer is grey" " ${GRY}updated " "$out"
check "the divider is grey" " ${GRY}────" "$out"
check_absent "no zebra" "${E}[48;2;22;27;34m" "$out"
check_absent "no 256-colour or dim codes, only the mockup's colours" "${E}[2;" "$out"
check_absent "NO_COLOR: no escape codes at all" "$E" "$(pg panel --frame --width 40 --interval 5)"
check_absent "an empty NO_COLOR still means colour" "NOCOLOUR" "$(grep -q "$E" <<<"$(cd "$PREPO" && NO_COLOR='' PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$P_TMP" XDG_CONFIG_HOME="$P_TMP/config" bash "$SC/panel.sh" --frame --width 40)" || echo NOCOLOUR)"

echo "== panel: clicks, through the real input loop; keys do nothing =="
# --feed runs stdin through read_key and act, as the live panel does, then prints the frame.
# The fold chevron sits in column 2 of a lane's first line (" ▾").
click() { printf '\033[<0;%s;%sM\033[<0;%s;%sm' "$1" "$2" "$1" "$2"; }
out="$(click 2 2 | pg panel --frame --width 40 --feed)"
check "a click on the fold icon folds the lane to its first line" " ▸ why-slow  investigate ◂" "$out"
check_absent "the folded lane hides its lines" "Staging or production?" "$out"
out="$( { click 2 2; click 2 2; } | pg panel --frame --width 40 --feed)"
check "a second click on the icon unfolds it" " ▾ why-slow  investigate ◂" "$out"
check "and shows its lines again" "? Staging or production?" "$out"
row="$(pg panel --frame --width 40 | grep -n "task-x  solo" | cut -d: -f1)"
out="$(click 7 "$row" | pg panel --frame --width 40 --feed)"
check "a click on a lane's name selects it" " ▾ task-x  solo ◂" "$out"
check "and does not fold it" "impl · → tests ·" "$out"
out="$(click 13 "$row" | pg panel --frame --width 40 --feed)"
check "a click on a lane's pattern only selects it" " ▾ task-x  solo ◂" "$out"
out="$(click 2 "$row" | pg panel --frame --width 40 --feed)"
check "a click on another lane's icon selects and folds it" " ▸ task-x  solo ◂" "$out"
check "and leaves the other lanes unfolded" "? Staging or production?" "$out"
out="$(click 2 3 | pg panel --frame --width 40 --feed)"
check "a click on a lane's chain line does not fold it" " ▾ why-slow  investigate ◂" "$out"
out="$(click 2 1 | pg panel --frame --width 40 --feed)"
check "a click on a section header changes nothing" "? Staging or production?" "$out"
# click only: no keystroke acts (the old keys, arrows, enter, space, escape, q)
before="$(pg panel --frame --width 40 | grep -v "updated ")"
pst '{"agents":{"a":{"name":"inv-why","pane_id":"w4:p1","workspace_id":"w4","agent":"claude","agent_status":"blocked"}}}'
out="$(printf ' \n\033[B\033[Agadxrtfn?FXRoq\033' | pg panel --frame --width 40 --feed)"
check "keystrokes change nothing (q does not quit, nothing folds, moves or cycles)" "1" "$([ "$before" = "$(grep -v "updated " <<<"$out")" ] && echo 1 || echo 0)"
check_absent "no key opens a popup, jumps or filters" "plugin pane open" "$(cat "$P_TMP/calls.log")"
check_absent "no agent is focused by a key" "agent focus" "$(cat "$P_TMP/calls.log")"
# [answer] and [detail] open their popups on a click
r2="$(pg panel --frame --width 60 --rowmap | sed -n 2p)"
acol="${r2#*answer=}" acol="${acol%%-*}" dcol="${r2#*detail=}" dcol="${dcol%%-*}"
pst '{}'
click "$acol" 2 | pg panel --frame --width 60 --feed >/dev/null
check "a click on [answer] opens the answer popup" "answer" "$(sj '.opened[0].entrypoint')"
check "for that lane" "GRAPH_LANE=why-slow" "$(cat "$P_TMP/calls.log")"
pst '{}'
click "$dcol" 2 | pg panel --frame --width 60 --feed >/dev/null
check "a click on [detail] opens the detail popup" "detail" "$(sj '.opened[0].entrypoint')"
check "the row map says where each button was drawn" "1" "$(pg panel --frame --width 60 --rowmap | sed -n 2p | grep -cE "^2 0h@detail=[0-9]+-[0-9]+;answer=[0-9]+-[0-9]+$")"
rows="$(pg panel --frame --width 40 | wc -l | tr -d ' ')"
out="$(click 31 "$rows" | pg panel --frame --width 40 --interval 5 --feed)"
check "a click on the interval button on the bottom row cycles it" "every 10s" "$out"
out="$(click 31 1 | pg panel --frame --width 40 --interval 5 --feed)"
check "the same column on the top row is not the button" "every 5s" "$out"


echo "== panel: arrows move a clicked selection, wheel scrolls, room below the last element =="
# Up/Down/Left/Right act only once a click selected an element; the selected element's rows
# start with › in the padding column. The wheel (SGR buttons 64 and 65) scrolls 3 lines.
UP=$'\033[A' DN=$'\033[B' RT=$'\033[C' LT=$'\033[D'
wheel() { printf '\033[<%s;5;5M' "$1"; }
out="$( { click 2 3; printf '%s' "$DN"; } | pg panel --frame --width 40 --feed)"
check "Down moves the selection to the next element" "›  ├ ? Staging or production?" "$out"
check "one element is selected" "1" "$(grep -c '^›  ' <<<"$out")"
out="$( { click 2 3; printf '%s' "$UP"; } | pg panel --frame --width 40 --feed)"
check "Up moves it to the previous element, the lane's first line" " ▾ why-slow  investigate ◂" "$out"
check_absent "a selected first line shows ◂, no ›" "›" "$out"
out="$( { click 7 2; printf '%s%s' "$UP" "$UP"; } | pg panel --frame --width 40 --feed)"
check "Up on the first element stays there" " ▾ why-slow  investigate ◂" "$out"
check_absent "still on that first line" "›" "$out"
out="$( { click 2 3; printf '%s%s' "$DN" "$DN"; } | pg panel --frame --width 40 --feed)"
check "a wrapped element is selected on all its rows" "1" "$([ "$(grep -c '^›' <<<"$out")" -ge 2 ] && echo 1 || echo 0)"
check "the last line of a lane is an element" "›  └ last: " "$out"
out="$( { click 2 3; printf '%s%s%s' "$DN" "$DN" "$DN"; } | pg panel --frame --width 40 --feed)"
check "Down skips blank lines and section headers to the next lane" " ▾ task-x  solo ◂" "$out"
check_absent "the selection left the other lane" "›" "$out"
out="$( { click 7 "$row"; printf '%s' "$UP"; } | pg panel --frame --width 40 --feed)"
check "Up from a lane goes to the previous lane's last element" "›  └ last: " "$out"
check "the selected lane follows the selection" " ▾ why-slow  investigate ◂" "$out"
full="$(pg panel --frame --width 40)"
lastrow="$(grep -n '^   └ ' <<<"$full" | tail -1 | cut -d: -f1)"
out="$( { click 6 "$lastrow"; printf '%s%s%s' "$DN" "$DN" "$DN"; } | pg panel --frame --width 40 --feed)"
check "Down on the last element stays there" "$(sed -n "${lastrow}p" <<<"$full" | sed 's/^ /›/')" "$out"
out="$( { click 2 3; printf '%s' "$LT"; } | pg panel --frame --width 40 --feed)"
check "Left folds the selected element's lane" " ▸ why-slow  investigate ◂" "$out"
check_absent "the folded lane hides its lines" "Staging or production?" "$out"
out="$( { click 2 3; printf '%s%s' "$LT" "$RT"; } | pg panel --frame --width 40 --feed)"
check "Right unfolds it again" " ▾ why-slow  investigate ◂" "$out"
check "and shows its lines" "? Staging or production?" "$out"
out="$( { click 2 3; printf '%s' "$RT"; } | pg panel --frame --width 40 --feed)"
check "Right on an unfolded lane changes nothing" "›  ├ investigate ?" "$out"
pst '{}'
out="$(printf '%s%s%s%s' "$DN" "$UP" "$LT" "$RT" | pg panel --frame --width 40 --feed)"
check_absent "with no clicked selection, arrows select nothing" "›" "$out"
check "and fold nothing" "? Staging or production?" "$out"
# a short pane: --height draws the rows the live panel would, scrolled, the footer at the bottom
H=12
top0="$(pg panel --frame --width 40 --height $H)"
check "a short pane starts at the top" " NEEDS YOU (1)" "$(sed -n 1p <<<"$top0")"
check "a short pane draws exactly its height" "$H" "$(wc -l <<<"$top0" | tr -d ' ')"
out="$(wheel 65 | pg panel --frame --width 40 --height $H --feed)"
check "the wheel scrolls the content down three lines" "$(sed -n 4p <<<"$full")" "$(sed -n 1p <<<"$out")"
check "the footer stays at the bottom" "[↻]" "$(tail -1 <<<"$out")"
out="$( { wheel 65; wheel 64; } | pg panel --frame --width 40 --height $H --feed)"
check "the wheel scrolls back up" " NEEDS YOU (1)" "$(sed -n 1p <<<"$out")"
out="$(wheel 64 | pg panel --frame --width 40 --height $H --feed)"
check "the wheel stops at the top" " NEEDS YOU (1)" "$(sed -n 1p <<<"$out")"
out="$(for _ in 1 2 3 4 5 6 7 8 9 10; do wheel 65; done | pg panel --frame --width 40 --height $H --feed)"
nbottom=$(($(wc -l <<<"$full") - $(grep -n '─' <<<"$full" | cut -d: -f1) + 1))
room=$((H - nbottom)) pad=$(((H - nbottom) * 30 / 100))
lastline="$(sed -n "$(($(grep -n '─' <<<"$full" | cut -d: -f1) - 1))p" <<<"$full")"
check "scrolled to the end, the last line shows" "$lastline" "$(sed -n "$((room - pad))p" <<<"$out")"
check "with 30% of the visible height blank below it" "$pad" "$(sed -n "$((room - pad + 1)),${room}p" <<<"$out" | grep -c '^$')"
out="$( { wheel 65; click 7 1; } | pg panel --frame --width 40 --height $H --feed)"
check "a click on a scrolled view selects what is drawn there" "›$(sed -n 4p <<<"$full" | cut -c2-)" "$out"
out="$( { click 2 3; for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do printf '%s' "$DN"; done; } | pg panel --frame --width 40 --height $H --feed)"
check "Down scrolls so the selection stays visible" "$(sed -n "${lastrow}p" <<<"$full" | sed 's/^ /›/')" "$out"
out="$( { click 2 3; for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do printf '%s' "$DN"; done; for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do printf '%s' "$UP"; done; } | pg panel --frame --width 40 --height $H --feed)"
check "Up scrolls back so the selection stays visible, its header too" " ▾ why-slow  investigate ◂" "$(sed -n 2p <<<"$out")"

echo "== panel: pull requests =="
# prs.sh fetch asks gh (GRAPH_GH, here a stub) for each lane's pull requests: those of the
# lane's branch, and every pull request URL the lane mentions. The cache sits next to the
# lane files; the panel only reads it.
GHD="$P_TMP/gh" && mkdir -p "$GHD"
pr() { jq -cn --argjson n "$1" --arg s "$2" --argjson d "$3" --arg r "$4" '{number: $n, url: "https://github.com/o/r/pull/\($n)", state: $s, isDraft: $d, reviewDecision: $r}'; }
printf '[%s,%s,%s,%s,%s]' "$(pr 7 OPEN true "")" "$(pr 5 MERGED false APPROVED)" "$(pr 8 OPEN false APPROVED)" "$(pr 4 CLOSED false "")" "$(pr 6 OPEN false REVIEW_REQUIRED)" >"$GHD/head-feat_x.json"
pr 9 OPEN false CHANGES_REQUESTED >"$GHD/pr-9.json"
pg lane set --repo "$PREPO" --lane task-x --key branch --value feat/x >/dev/null
pg lane node --repo "$PREPO" --lane task-y --node impl --status running --ref "https://github.com/o/r/pull/9#pullrequestreview-1" >/dev/null
fetch() { (cd "$PREPO" && GRAPH_GH="$FIX/stub-gh/gh" GH_STUB_DIR="$GHD" PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$P_TMP" bash "$SC/prs.sh" fetch --repo "$PREPO" "$@"); }
fetch >/dev/null
check "fetch asks for the lane branch's pull requests, every state" "pr list --head feat/x --state all" "$(cat "$GHD/gh.log")"
check "fetch asks for a pull request the lane mentions, without the fragment" "pr view https://github.com/o/r/pull/9 " "$(cat "$GHD/gh.log")"
cache="$(cd "$PREPO" && git rev-parse --path-format=absolute --git-common-dir)/herdr-graph/prs.json"
check "the cache holds each lane's pull requests" "5" "$(jq '.lanes["task-x"] | length' "$cache")"
calls="$(wc -l <"$GHD/gh.log")"
pg panel --frame --width 80 >/dev/null
check "the panel's render never calls gh" "$calls" "$(wc -l <"$GHD/gh.log")"
fetch --max-age 60 >/dev/null
check "a fresh cache is not fetched again" "$calls" "$(wc -l <"$GHD/gh.log")"
touch "$GHD/gh-fail"
fetch --max-age 0 >/dev/null
rm -f "$GHD/gh-fail"
check "a failed fetch keeps the last known pull requests" "5" "$(jq '.lanes["task-x"] | length' "$cache")"
check "no gh: fetch does nothing and fails nothing" "0" "$(cd "$PREPO" && GRAPH_GH="$P_TMP/no-gh" bash "$SC/prs.sh" fetch --repo "$PREPO" --max-age 0 >/dev/null 2>&1; echo $?)"
out="$(pg panel --frame --width 80 --selected 1)"
check "the pull requests hang under their lane, oldest first" "  ├ ● #4 closed " "$out"
check "the newest is the lane's last line" "  └ ● #8 open · approved  https://github.com/o/r/pull/8" "$out"
check "a draft" "● #7 draft " "$out"
check "an open one with no decision" "● #6 open " "$out"
check "an approved one" "● #8 open · approved " "$out"
check "a merged one" "● #5 merged " "$out"
check "a related lane's pull request, with changes requested" "└ ● #9 open · changes requested  https://github.com/o/r/pull/9" "$out"
check "the URLs line up within a lane" "1" "$(grep -F "● #" <<<"$out" | grep -v "#9 " | jq -Rn '[inputs | split("https://")[0] | length] | unique | length')"
out="$(pgc panel --frame --width 80)"
check "draft is grey" "${GRY}● #7 draft" "$out"
check "open is blue" "${BLU}● #6 open" "$out"
check "approved is green" "${GRN}● #8 open · approved" "$out"
check "changes requested is amber" "${AMB}● #9 open · changes requested" "$out"
check "merged is purple" "${PUR}● #5 merged" "$out"
check "closed is red" "${RED}● #4 closed" "$out"
check "the URL is grey" "${GRY}https://github.com/o/r/pull/8${E}[39m" "$out"
row="$(pg panel --frame --width 80 | grep -n "#8 open" | cut -d: -f1)"
# shellcheck disable=SC2016  # $1 belongs to the written script
printf '#!/bin/sh\nprintf "%%s\\n" "$1" >>"%s/opened"\n' "$P_TMP" >"$P_TMP/browser" && chmod +x "$P_TMP/browser"
(cd "$PREPO" && printf '\033[<0;12;%sM' "$row" | GRAPH_BROWSER="$P_TMP/browser" NO_COLOR=1 PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$P_TMP" XDG_CONFIG_HOME="$P_TMP/config" bash "$SC/panel.sh" --frame --width 80 --feed >/dev/null)
check "a click on a pull request opens it in the browser" "https://github.com/o/r/pull/8" "$(cat "$P_TMP/opened" 2>/dev/null)"
row="$(pg panel --frame --width 80 | grep -n "task-x  solo" | cut -d: -f1)"
out="$(click 2 "$row" | pg panel --frame --width 80 --feed)"
check_absent "a folded lane hides its pull requests" "#8 open" "$out"
check "status text lists a lane's pull requests" "pr: #8 open · approved https://github.com/o/r/pull/8" "$(pg status --text --repo "$PREPO")"
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
check "refresh tells every panel to redraw, with the private sequence ESC [ 99 ~ (not a key)" '[{"pane":"w1:p5","text":"\u001b[99~"}]' "$(jq -c .sent "$P_TMP/state.json")"
pst '{}'
pg panel --frame --width 40 </dev/null >/dev/null
reads="$(grep -c "agent list" "$P_TMP/calls.log")"
pst '{}'
printf '\033[99~' | pg panel --frame --width 40 --feed >/dev/null
check "the panel reads the lanes again on that sequence" "$((reads + 1))" "$(grep -c "agent list" "$P_TMP/calls.log")"
pg lane node --repo "$PREPO" --lane why-slow --node investigate --status running --agent claude-why-slow-inv >/dev/null
pst '{"agents":{"a":{"name":"claude-why-slow-inv","pane_id":"w4:p1","workspace_id":"w4","agent":"claude","agent_status":"blocked"}}}'
out="$(pg panel-action next-needs-me)"
check "next-needs-me focuses the blocked lane agent" "FOCUSED claude-why-slow-inv" "$out"
pst '{"agents":{}}'
check "next-needs-me says when nothing needs you" "NOTHING NEEDS YOU" "$(pg panel-action next-needs-me)"

echo "== panel: no sidebar filter; a stuck one is cleared at start =="
NCD="$P_TMP/nc-bin" && mkdir -p "$NCD"
# shellcheck disable=SC2016  # $* belongs to the written script
printf '#!/bin/sh\nprintf "%%s " "$*" >>"%s/nc.log"; cat >>"%s/nc.log"\n' "$P_TMP" "$P_TMP" >"$NCD/nc" && chmod +x "$NCD/nc"
(cd "$PREPO" && PATH="$NCD:$PATH" HERDR_SOCKET_PATH="$P_TMP/sock" bash "$SC/panel.sh" --reset-view)
check "at start the panel sends one agent.view.clear for its source" '-U -w 1 '"$P_TMP"'/sock {"id":"graph-view","method":"agent.view.clear","params":{"source":"graph-panel"}}' "$(cat "$P_TMP/nc.log")"
check "only one" "1" "$(grep -c "agent.view" "$P_TMP/nc.log")"
check_absent "it never sets a filter" "agent.view.set" "$(cat "$P_TMP/nc.log")"
printf '#!/bin/sh\nexit 1\n' >"$NCD/nc"
check_rc "an error from the socket is ignored" 0 "$(cd "$PREPO" && PATH="$NCD:$PATH" HERDR_SOCKET_PATH="$P_TMP/sock" bash "$SC/panel.sh" --reset-view >/dev/null 2>&1; echo $?)"
NONC="$P_TMP/no-nc" && mkdir -p "$NONC"
for t in jq dirname; do ln -s "$(command -v "$t")" "$NONC/$t"; done
out="$(cd "$PREPO" && PATH="$NONC" HERDR_SOCKET_PATH="$P_TMP/sock" "$BASH" "$SC/panel.sh" --reset-view 2>&1; echo "rc=$?")"
check "no nc: skipped silently" "rc=0" "$out"
check "with nothing printed" "rc=0" "$(head -1 <<<"$out")"
check_absent "the panel has no sidebar filter code left" "agent.view.set" "$(cat "$SC/panel.sh")"

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
check "detail: the pattern is grey" "${GRY} · investigate" "$out"
check "detail: a running node is amber, like the panel" "${AMB}⟳${E}[39m" "$out"
check "detail: the history heading is bold" "${E}[1mhistory${E}[22m" "$out"
out="$(GRAPH_LANE=why-slow GRAPH_REPO="$PREPO" PAGER="$P_TMP/pager" pg popup detail 2>&1)"
check "detail without colour still reads" "why-slow · investigate" "$out"
check_absent "detail: NO_COLOR has no escape codes" "$E" "$out"
out="$(printf '\n' | GRAPH_LANE=why-slow GRAPH_REPO="$PREPO" pgc popup answer 2>&1)"
check "answer: the lane name is bold" "${E}[1mwhy-slow${E}[22m" "$out"
check "answer: the question is red" "${RED}? Staging or production?${E}[39m" "$out"
rm -rf "$P_TMP"
