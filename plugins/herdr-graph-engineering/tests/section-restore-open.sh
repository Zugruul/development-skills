#!/usr/bin/env bash
# section-restore-open.sh -- sourced by run-tests.sh; do not run standalone.
# lane.sh restore and the panel's [restore] on the selected closed lane (green [confirm],
# key o); a click on a file reference opens it (.html and URLs in the browser, other files
# in $VISUAL / $EDITOR / the system opener, a terminal editor in a new Herdr tab); a double
# click on a lane jumps to its agent, like g.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr-graph-engineering/tests/run-tests.sh" >&2; exit 2; }

O_TMP="$(mktemp -d)"
OSC="$PLUGIN/scripts"
OR="$O_TMP/repo"
git init -q -b main "$OR" && git -C "$OR" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
OD="$(git -C "$OR" rev-parse --path-format=absolute --git-common-dir)/herdr-graph"
OBIN="$O_TMP/bin" && mkdir -p "$OBIN"
# fake openers: each logs its arguments, so nothing real ever opens
for b in browser opener gui-ed; do
    printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" %s "$*" >>"%s/opened.log"\n' "$b" "$O_TMP" >"$OBIN/$b"
    chmod +x "$OBIN/$b"
done
# ro [VAR=value...] script args...: the user's VISUAL/EDITOR never leak in; the browser and
# the system opener are the fakes unless a test says otherwise
ro() {
    local vars=()
    while [[ "${1:-}" == *=* ]]; do vars+=("$1"); shift; done
    local s="$1"; shift
    (cd "$OR" && env -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_PLUGIN_ID -u VISUAL -u EDITOR \
        PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$O_TMP" HERDR_ENV=1 NO_COLOR=1 XDG_CONFIG_HOME="$O_TMP/config" \
        GRAPH_BROWSER="$OBIN/browser" GRAPH_OPENER="$OBIN/opener" "${vars[@]}" bash "$OSC/$s.sh" "$@")
}
ost() { printf '%s' "$1" >"$O_TMP/state.json"; : >"$O_TMP/calls.log"; : >"$O_TMP/opened.log"; }
oclick() { printf '\033[<0;%s;%sM\033[<0;%s;%sm' "$1" "$2" "$1" "$2"; }
orow() { grep -n -- "$1" <<<"$(ro panel --frame --width 48 "${@:2}")" | head -1 | cut -d: -f1; }
ohas() { [ -f "$1" ] && echo 1 || echo 0; }
ost '{}'

echo "== restore: lane.sh restore =="
ro lane new --repo "$OR" --lane was-done --pattern investigate --idea a >/dev/null
ro lane set --repo "$OR" --lane was-done --key status --value "done" >/dev/null
ro lane close --repo "$OR" --lane was-done >/dev/null
out="$(ro lane restore --repo "$OR" --lane was-done)"
check "restore moves a closed lane back to the open lanes" "RESTORED was-done done $OD/was-done.yaml" "$out"
check "it is no longer in closed/" "0" "$(ohas "$OD/closed/was-done.yaml")"
check "a done lane comes back done" "done" "$(yq -r .status "$OD/was-done.yaml")"
check "the history records it" "lane restored (done)" "$(yq -r '.history[-1]' "$OD/was-done.yaml")"
ro lane new --repo "$OR" --lane was-open --pattern investigate --idea b >/dev/null
ro lane close --repo "$OR" --lane was-open >/dev/null
ro lane restore --repo "$OR" --lane was-open >/dev/null
check "a lane closed while open comes back open" "open" "$(yq -r .status "$OD/was-open.yaml")"
out="$(ro lane restore --repo "$OR" --lane was-open 2>&1)"; rc=$?
check_rc "restore refuses a lane that is not closed" 6 "$rc"
check "and says so" "NOT CLOSED: was-open" "$out"
ro lane close --repo "$OR" --lane was-open >/dev/null
ro lane new --repo "$OR" --lane was-open --pattern investigate --idea c >/dev/null
out="$(ro lane restore --repo "$OR" --lane was-open 2>&1)"; rc=$?
check_rc "restore refuses when an open lane of that name exists" 6 "$rc"
check "and says so" "LANE EXISTS: was-open" "$out"
check "the closed file stays" "1" "$(ohas "$OD/closed/was-open.yaml")"
check "the open lane is untouched" "c" "$(yq -r .idea "$OD/was-open.yaml")"
check_rc "restore refuses a name that is not a slug" 2 "$(ro lane restore --repo "$OR" --lane ../x >/dev/null 2>&1; echo $?)"
check_absent "restore touches no worktree or branch" "worktree" "$(cat "$O_TMP/calls.log")"

echo "== restore: the panel's [restore] =="
ro lane close --repo "$OR" --lane was-done >/dev/null
ro lane new --repo "$OR" --lane other-gone --pattern investigate --idea d >/dev/null
ro lane close --repo "$OR" --lane other-gone >/dev/null
out="$(ro panel --frame --width 48)"
check_absent "an unselected closed lane has no [restore]" "[restore]" "$out"
sel="$(grep -n "^ ▸ was-done" <<<"$out" | cut -d: -f1)"
# the display index of was-done: its rank among the lane first lines
idx="$(head -n "$sel" <<<"$out" | grep -cE "^ [▸▾] ")"; idx=$((idx - 1))
out="$(ro panel --frame --width 48 --selected "$idx")"
check "the selected closed lane shows [restore] left of its [x]" "1" "$(grep -cE "^ ▸ was-done  investigate ◂ +\[restore\] \[x\]$" <<<"$out")"
check "the line ends one column short of the right edge" "47" "$(grep "was-done" <<<"$out" | jq -Rr 'length')"
out="$(ro panel --frame --width 30 --selected "$idx")"
check "when [restore] does not fit, only [x] shows" "1" "$(grep -cE "^ ▸ was-done  investigate ◂ +\[x\]$" <<<"$out")"
r="$(orow "was-done  investigate")"
# width 48: [x] on columns 45-47, [restore] on 35-43
out="$( { oclick 10 "$r"; oclick 38 "$r"; } | ro panel --frame --width 48 --feed)"
check "the first click on [restore] turns it into [confirm]" "1" "$(grep -cE "^ ▸ was-done  investigate ◂ +\[confirm\] \[x\]$" <<<"$out")"
check "nothing is restored yet" "1" "$(ohas "$OD/closed/was-done.yaml")"
out="$( { oclick 10 "$r"; oclick 38 "$r"; oclick 10 1; } | ro panel --frame --width 48 --feed)"
check "a click elsewhere puts it back" "0" "$(grep -c "\[confirm\]" <<<"$out")"
GRN=$'\033[38;2;63;185;80m'
out="$( { oclick 10 "$r"; oclick 38 "$r"; } | (cd "$OR" && env -u HERDR_PANE_ID -u NO_COLOR PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$O_TMP" HERDR_ENV=1 XDG_CONFIG_HOME="$O_TMP/config" bash "$OSC/panel.sh" --frame --width 48 --feed))"
check "the restore [confirm] is green" "${GRN}[confirm]" "$out"
: >"$O_TMP/calls.log"
out="$( { oclick 10 "$r"; oclick 38 "$r"; oclick 38 "$r"; } | ro panel --frame --width 48 --feed)"
check "a second click restores the lane" "1" "$(ohas "$OD/was-done.yaml")"
check "it comes back in DONE" "1" "$(grep -cE "^ DONE \(1\)" <<<"$out")"
check "the panel says it brings back the record only" "restored was-done (the record only" "$out"
check_absent "no worktree or branch is made" "worktree" "$(cat "$O_TMP/calls.log")"
check_absent "nor a tab" "tab create" "$(cat "$O_TMP/calls.log")"
r="$(orow "other-gone  investigate")"
out="$( { oclick 10 "$r"; printf 'o'; } | ro panel --frame --width 48 --feed)"
check "o arms [restore] on the selected closed lane" "1" "$(grep -cE "^ ▸ other-gone  investigate ◂ +\[confirm\] \[x\]$" <<<"$out")"
out="$( { oclick 10 "$r"; printf 'oo'; } | ro panel --frame --width 48 --feed)"
check "o pressed twice restores it" "1" "$(ohas "$OD/other-gone.yaml")"
out="$(printf 'o' | ro panel --frame --width 48 --feed)"
check "o on a lane that is not closed says so" "only a closed lane can be restored" "$out"
out="$(printf '?' | ro panel --frame --width 48 --feed)"
check "? lists o" "o restore" "$out"

echo "== open: file references =="
for l in was-done other-gone was-open; do ro lane close --repo "$OR" --lane "$l" >/dev/null; ro lane clear --repo "$OR" --lane "$l" >/dev/null; done
mkdir -p "$O_TMP/reports/a-long-directory-name-so-the-reference-wraps"
MD="$O_TMP/reports/a-long-directory-name-so-the-reference-wraps/report.md"
HT="$O_TMP/reports/page.html"
: >"$MD"; : >"$HT"
ro lane new --repo "$OR" --lane md-lane --pattern investigate --idea m >/dev/null
ro lane node --repo "$OR" --lane md-lane --node investigate --status "done" --ref "$MD" --agent inv-md >/dev/null
ro lane new --repo "$OR" --lane html-lane --pattern investigate --idea h >/dev/null
ro lane node --repo "$OR" --lane html-lane --node investigate --status "done" --ref "$HT" >/dev/null
ro lane new --repo "$OR" --lane url-lane --pattern investigate --idea u >/dev/null
ro lane node --repo "$OR" --lane url-lane --node investigate --status "done" --ref "https://example.com/r/1" >/dev/null
# the rows of a reference, from the row map (the kind of each row names the file)
refrows() { ro panel --frame --width 48 --rowmap | grep -F -- "f$1" | cut -d' ' -f1; }
check "the reference wraps over several rows, each of them clickable" "1" "$([ "$(refrows "$MD" | wc -l)" -ge 2 ] && echo 1 || echo 0)"
r="$(refrows "$MD" | head -1)"
ost '{}'
oclick 30 "$(refrows "$MD" | tail -1)" | ro VISUAL="$OBIN/gui-ed" panel --frame --width 48 --feed >/dev/null
check "a click on any row of the reference opens it in \$VISUAL" "gui-ed $MD" "$(cat "$O_TMP/opened.log")"
ost '{}'
oclick 30 "$r" | ro EDITOR="$OBIN/gui-ed" panel --frame --width 48 --feed >/dev/null
check "else \$EDITOR" "gui-ed $MD" "$(cat "$O_TMP/opened.log")"
ost '{}'
oclick 30 "$r" | ro panel --frame --width 48 --feed >/dev/null
check "else the system opener" "opener $MD" "$(cat "$O_TMP/opened.log")"
ost '{}'
oclick 30 "$r" | ro VISUAL=nvim HERDR_WORKSPACE_ID=w1 panel --frame --width 48 --feed >/dev/null
check "a terminal editor opens in a new Herdr tab" "tab create --workspace w1" "$(cat "$O_TMP/calls.log")"
check "which runs the editor on the file" "nvim $MD" "$(jq -r '.panes["w1:p9"].typed[0]' "$O_TMP/state.json")"
check "nothing else is opened" "" "$(cat "$O_TMP/opened.log")"
ost '{}'
oclick 30 "$(refrows "$HT" | head -1)" | ro VISUAL="$OBIN/gui-ed" panel --frame --width 48 --feed >/dev/null
check "an .html reference opens in the browser" "browser $HT" "$(cat "$O_TMP/opened.log")"
ost '{}'
oclick 30 "$(refrows "https://example.com/r/1" | head -1)" | ro panel --frame --width 48 --feed >/dev/null
check "a URL reference opens in the browser" "browser https://example.com/r/1" "$(cat "$O_TMP/opened.log")"
rm -f "$MD"
out="$(oclick 30 "$r" | ro panel --frame --width 48 --feed)"
check "a missing file is reported" "no such file" "$out"
: >"$MD"

echo "== open: double click jumps =="
ost '{"agents":{"a":{"name":"inv-md","pane_id":"w4:p1","workspace_id":"w4","agent":"claude","agent_status":"working"}}}'
r="$(orow "md-lane  investigate")"
oclick 30 "$r" | ro panel --frame --width 48 --feed >/dev/null
check_absent "a single click on a lane does not jump" "agent focus" "$(cat "$O_TMP/calls.log")"
ost '{"agents":{"a":{"name":"inv-md","pane_id":"w4:p1","workspace_id":"w4","agent":"claude","agent_status":"working"}}}'
{ oclick 30 "$r"; oclick 30 "$r"; } | ro panel --frame --width 48 --feed >/dev/null
check "a double click on a lane's first line jumps to its agent" "agent focus inv-md" "$(cat "$O_TMP/calls.log")"
ost '{"agents":{"a":{"name":"inv-md","pane_id":"w4:p1","workspace_id":"w4","agent":"claude","agent_status":"working"}}}'
{ oclick 20 $((r + 1)); oclick 20 $((r + 1)); } | ro panel --frame --width 48 --feed >/dev/null
check "so does a double click on any other line of the lane" "agent focus inv-md" "$(cat "$O_TMP/calls.log")"
ost '{"agents":{"a":{"name":"inv-md","pane_id":"w4:p1","workspace_id":"w4","agent":"claude","agent_status":"working"}}}'
{ oclick 30 "$r"; oclick 30 "$(orow "html-lane  investigate")"; } | ro panel --frame --width 48 --feed >/dev/null
check_absent "two clicks on different lanes do not jump" "agent focus" "$(cat "$O_TMP/calls.log")"
ost '{"agents":{"a":{"name":"inv-md","pane_id":"w4:p1","workspace_id":"w4","agent":"claude","agent_status":"working"}}}'
{ oclick 30 "$r"; sleep 2; oclick 30 "$r"; } | ro panel --frame --width 48 --feed >/dev/null
check_absent "two clicks further apart than the window do not jump" "agent focus" "$(cat "$O_TMP/calls.log")"
ost '{"agents":{"a":{"name":"inv-md","pane_id":"w4:p1","workspace_id":"w4","agent":"claude","agent_status":"working"}}}'
{ oclick 2 "$r"; oclick 2 "$r"; } | ro panel --frame --width 48 --feed >/dev/null
check_absent "two clicks on the chevron fold twice, no jump" "agent focus" "$(cat "$O_TMP/calls.log")"
rm -rf "$O_TMP"
