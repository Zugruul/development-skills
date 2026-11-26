#!/usr/bin/env bash
# section-closed.sh -- sourced by run-tests.sh; do not run standalone.
# The CLOSED section: lane.sh clear (closed lanes only, moved to closed/cleared/), status.sh
# --json with the closed lanes of every repository, prs.sh keeping a closed lane's pull
# requests until they are final, and the panel's CLOSED (y) section with its [x] and
# [clear all] buttons, each turning into [confirm] on the first click.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr-graph-engineering/tests/run-tests.sh" >&2; exit 2; }

C_TMP="$(mktemp -d)"
SC="$PLUGIN/scripts"
CA="$C_TMP/repo-a" CB="$C_TMP/repo-b"
for r in "$CA" "$CB"; do
    git init -q -b main "$r" && git -C "$r" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
done
cg() { local s="$1"; shift; (cd "$CA" && env -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_PLUGIN_ID PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$C_TMP" HERDR_ENV=1 NO_COLOR=1 XDG_CONFIG_HOME="$C_TMP/config" bash "$SC/$s.sh" "$@"); }
cgc() { local s="$1"; shift; (cd "$CA" && env -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_PLUGIN_ID -u NO_COLOR PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$C_TMP" HERDR_ENV=1 XDG_CONFIG_HOME="$C_TMP/config" bash "$SC/$s.sh" "$@"); }
cst() { printf '%s' "$1" >"$C_TMP/state.json"; : >"$C_TMP/calls.log"; }
dir_of() { printf '%s/herdr-graph' "$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)"; }
DA="$(dir_of "$CA")" DB="$(dir_of "$CB")"
# Both repositories have a workspace open in Herdr, so status.sh reads both.
WS="{\"workspaces\":[{\"workspace_id\":\"w1\",\"worktree\":{\"repo_root\":\"$CA\"}},{\"workspace_id\":\"w2\",\"worktree\":{\"repo_root\":\"$CB\"}}]}"
cst "$WS"
# a closed lane's closing time, set by hand so the order is known
closed_at() { # repo dir, lane, time
    local f
    f="$(dir_of "$1")/closed/$2.yaml"
    yq -i ".history += [\"$3 lane closed\"]" "$f"
}

echo "== closed: lane.sh clear =="
cg lane new --repo "$CA" --lane open-one --pattern investigate --idea a >/dev/null
cg lane new --repo "$CA" --lane gone-one --pattern investigate --idea b >/dev/null
cg lane close --repo "$CA" --lane gone-one >/dev/null
out="$(cg lane clear --repo "$CA" --lane open-one 2>&1)"; rc=$?
check_rc "clear refuses an open lane" 6 "$rc"
check "and says it is not closed" "NOT CLOSED: open-one" "$out"
check "the open lane's file stays" "1" "$([ -f "$DA/open-one.yaml" ] && echo 1 || echo 0)"
out="$(cg lane clear --repo "$CA" --lane ../open-one 2>&1)"; rc=$?
check_rc "clear refuses a lane name that is not a slug" 2 "$rc"
check "the open lane is still there" "1" "$([ -f "$DA/open-one.yaml" ] && echo 1 || echo 0)"
out="$(cg lane clear --repo "$CA" --lane gone-one)"
check "clear moves a closed lane to closed/cleared/" "CLEARED gone-one $DA/closed/cleared/gone-one.yaml" "$out"
check "it is no longer in closed/" "0" "$([ -f "$DA/closed/gone-one.yaml" ] && echo 1 || echo 0)"
check "the file is kept" "gone-one" "$(yq -r .lane "$DA/closed/cleared/gone-one.yaml")"
check_absent "list --all no longer shows a cleared lane" "gone-one" "$(cg lane list --repo "$CA" --all)"
cg lane new --repo "$CA" --lane gone-one --pattern investigate --idea c >/dev/null
cg lane close --repo "$CA" --lane gone-one >/dev/null
out="$(cg lane clear --repo "$CA" --lane gone-one)"
check "a second lane of the same name keeps the first one's file" "$DA/closed/cleared/gone-one.2.yaml" "$out"
check "both are kept" "b c" "$(yq -r .idea "$DA/closed/cleared/gone-one.yaml") $(yq -r .idea "$DA/closed/cleared/gone-one.2.yaml")"
check_rc "clear without --lane is a usage error" 2 "$(cg lane clear --repo "$CA" >/dev/null 2>&1; echo $?)"

echo "== closed: status.sh =="
# repo A: open-one (working), shipped (done, owner graph), old-a (closed); repo B: old-b (closed)
cg lane new --repo "$CA" --lane shipped --pattern investigate --idea d >/dev/null
cg lane set --repo "$CA" --lane shipped --key status --value "done" >/dev/null
cg lane set --repo "$CA" --lane shipped --key owner --value graph >/dev/null
cg lane new --repo "$CA" --lane old-a --pattern investigate --idea e >/dev/null
cg lane set --repo "$CA" --lane old-a --key branch --value feat/old-a >/dev/null
cg lane close --repo "$CA" --lane old-a >/dev/null
closed_at "$CA" old-a 2026-11-20T10:00:00Z
cg lane new --repo "$CB" --lane old-b --pattern solo --idea f --gate "npm test" >/dev/null
cg lane close --repo "$CB" --lane old-b >/dev/null
closed_at "$CB" old-b 2026-11-21T10:00:00Z
js="$(cg status --json)"
check "closed lanes are in --json, section closed" "old-a old-b" "$(jq -r '[.[] | select(.section == "closed") | .lane] | sort | join(" ")' <<<"$js")"
check "from every repository" "$CB" "$(jq -r '.[] | select(.lane == "old-b") | .root' <<<"$js")"
check "each lane says when it closed" "2026-11-21T10:00:00Z" "$(jq -r '.[] | select(.lane == "old-b") | .closed' <<<"$js")"
check "open lanes keep their sections" "done working" "$(jq -r '[.[] | select(.section != "closed") | .section] | sort | join(" ")' <<<"$js")"
check_absent "--text leaves closed lanes out" "old-a" "$(cg status --text)"
check_absent "--line does not count them" "🟢 3" "$(cg status --line)"
check "--line still counts the done lane" "🟢 1" "$(cg status --line)"

echo "== closed: pull requests of closed lanes =="
GHD="$C_TMP/gh" && mkdir -p "$GHD"
cpr() { jq -cn --argjson n "$1" --arg s "$2" '{number: $n, url: "https://github.com/o/r/pull/\($n)", state: $s, isDraft: false, reviewDecision: ""}'; }
printf '[%s]' "$(cpr 31 OPEN)" >"$GHD/head-feat_old-a.json"
cfetch() { (cd "$CA" && GRAPH_GH="$FIX/stub-gh/gh" GH_STUB_DIR="$GHD" PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$C_TMP" bash "$SC/prs.sh" fetch --repo "$CA" --repo "$CB"); }
cfetch
check "a closed lane's pull requests are fetched while not final" "pr list --head feat/old-a" "$(cat "$GHD/gh.log")"
printf '[%s]' "$(cpr 31 MERGED)" >"$GHD/head-feat_old-a.json"
cfetch
check "a closed lane's pull request reaches its final state" "MERGED" "$(jq -r '.lanes["old-a"][0].state' "$DA/prs.json")"
: >"$GHD/gh.log"
cfetch
check_absent "once every pull request is final, it is not asked again" "feat/old-a" "$(cat "$GHD/gh.log")"

echo "== closed: the panel's CLOSED section =="
out="$(cg panel --frame --width 48)"
check "CLOSED (y) comes after DONE" "DONE CLOSED" "$(grep -oE "^ (NEEDS YOU|WORKING|DONE|CLOSED)" <<<"$out" | sed -n '2,3p' | tr -d ' ' | tr '\n' ' ' | sed 's/ $//')"
check "the CLOSED header counts every closed lane and ends with [clear all]" "1" "$(grep -cE "^ CLOSED \(2\) +\[clear all\]$" <<<"$out")"
check "[clear all] ends one column short of the right edge" "47" "$(grep "CLOSED" <<<"$out" | jq -Rr 'length')"
check "closed lanes start folded, each ending with [x]" "1" "$(grep -cE "^ ▸ old-a  investigate +\[x\]$" <<<"$out")"
check "a DONE lane ends with [x] too" "1" "$(grep -cE "^ ▾ shipped  investigate +\[x\]$" <<<"$out")"
check "a WORKING lane has no [x]" "1" "$(grep -cE "^ ▾ open-one  investigate( ◂ +\[detail\])?$" <<<"$out")"
check "the [x] ends one column short of the right edge" "47" "$(grep "old-a" <<<"$out" | jq -Rr 'length')"
check "the newest closed lane first, from every repository" "old-b old-a" "$(grep -oE "^ ▸ old-[ab]" <<<"$out" | sed 's/^ ▸ //' | tr '\n' ' ' | sed 's/ $//')"
check_absent "the footer names no keys" "x close" "$(cg panel --frame --width 120)"
sel="$(cg panel --frame --width 48 --selected 3)"
check "a selected closed lane keeps the [x] inside the edge" "1" "$(grep -cE "^ ▸ old-a  investigate ◂ .*\[x\]$" <<<"$sel")"
check "with its marker before the button, inside the width" "47" "$(grep "old-a" <<<"$sel" | jq -Rr 'length')"
click() { printf '\033[<0;%s;%sM\033[<0;%s;%sm' "$1" "$2" "$1" "$2"; }
row_of() { grep -n -- "$1" <<<"$(cg panel --frame --width 48)" | head -1 | cut -d: -f1; }
r="$(row_of "old-a  investigate")"
out="$(click 2 "$r" | cg panel --frame --width 48 --feed)"
check "a closed lane unfolds like any other" "▾ old-a  investigate" "$out"
check "and shows its pull request in its final state" "└ ● #31 merged  https://github.com/o/r/pull/31" "$out"

echo "== closed: [x] and [clear all] =="
out="$(click 46 "$r" | cg panel --frame --width 48 --feed)"
check "the first click on [x] turns it into [confirm]" "1" "$(grep -cE "^ ▸ old-a  investigate ◂ .*\[confirm\]$" <<<"$out")"
check "nothing is cleared yet" "1" "$([ -f "$DA/closed/old-a.yaml" ] && echo 1 || echo 0)"
out="$( { click 46 "$r"; click 10 1; } | cg panel --frame --width 48 --feed)"
check "a click anywhere else restores [x]" "1" "$(grep -cE "^ ▸ old-a  investigate ◂ .*\[x\]$" <<<"$out")"
check "and clears nothing" "1" "$([ -f "$DA/closed/old-a.yaml" ] && echo 1 || echo 0)"
out="$( { click 46 "$r"; click 40 "$r"; } | cg panel --frame --width 48 --feed)"
check "a second click on [confirm] clears the closed lane" "1" "$([ -f "$DA/closed/cleared/old-a.yaml" ] && echo 1 || echo 0)"
check_absent "and it leaves the panel" "old-a" "$out"
check "the CLOSED count drops" "CLOSED (1)" "$out"
check "the open lanes are untouched" "1" "$([ -f "$DA/open-one.yaml" ] && [ -f "$DA/shipped.yaml" ] && echo 1 || echo 0)"
# the DONE lane: [x] asks its orchestrator to clean it up, which confirms with the user again
cst "$WS"
r="$(row_of "shipped  investigate")"
out="$( { click 46 "$r"; click 40 "$r"; } | cg panel --frame --width 48 --feed)"
check "[confirm] on a DONE lane asks its orchestrator to clean it up" "agent prompt graph Clean up lane shipped" "$(cat "$C_TMP/calls.log")"
check "the panel says so" "asked graph to clean up shipped" "$out"
check "the DONE lane itself is left alone" "1" "$([ -f "$DA/shipped.yaml" ] && echo 1 || echo 0)"
check_absent "no worktree is removed by the panel" "worktree remove" "$(cat "$C_TMP/calls.log")"
cg lane set --repo "$CA" --lane shipped --key owner --value "" >/dev/null 2>&1
out="$( { click 46 "$r"; click 40 "$r"; } | cg panel --frame --width 48 --feed)"
check "a DONE lane with no orchestrator: the panel says where to go" "no orchestrator owns shipped" "$out"
# click only: the old keys (x on the selected lane, X for clear all) do nothing
r="$(row_of "old-b  solo")"
out="$( { click 10 "$r"; printf 'xxXX'; } | cg panel --frame --width 48 --feed)"
check_absent "x and X neither arm nor clear" "[confirm]" "$out"
check "nothing cleared by keys" "1" "$([ -f "$DB/closed/old-b.yaml" ] && echo 1 || echo 0)"
out="$( { click 46 "$r"; printf 'x'; } | cg panel --frame --width 48 --feed)"
check "a key does not put an armed button back either" "1" "$(grep -cE "^ ▸ old-b  solo ◂ .*\[confirm\]$" <<<"$out")"
# more than five closed lanes: five shown, then "… n more"
for i in 1 2 3 4 5 6; do
    cg lane new --repo "$CA" --lane "c-$i" --pattern investigate --idea "c$i" >/dev/null
    cg lane close --repo "$CA" --lane "c-$i" >/dev/null
    closed_at "$CA" "c-$i" "2026-11-2${i}T12:00:00Z"
done
out="$(cg panel --frame --width 48)"
check "five closed lanes show, newest first" "c-6 c-5 c-4 c-3 c-2" "$(grep -oE "^ ▸ (c-[0-9]|old-b)" <<<"$out" | sed 's/^ ▸ //' | tr '\n' ' ' | sed 's/ $//')"
check "then the rest as … n more" "1" "$(grep -cx "   … 2 more" <<<"$out")"
r="$(row_of "… 2 more")"
out="$(click 6 "$r" | cg panel --frame --width 48 --feed)"
check "a click on … n more shows them all" "c-1" "$out"
check_absent "and the line goes" "more" "$out"
r="$(row_of "CLOSED (7)")"
out="$(click 40 "$r" | cg panel --frame --width 48 --feed)"
check "a click on [clear all] turns it into [confirm]" "1" "$(grep -cE "^ CLOSED \(7\) +\[confirm\]$" <<<"$out")"
check "the [confirm] ends one column short of the right edge" "47" "$(grep "CLOSED" <<<"$out" | jq -Rr 'length')"
out="$( { click 40 "$r"; click 44 "$r"; } | cg panel --frame --width 48 --feed)"
check_absent "a second click clears every closed lane" "CLOSED" "$out"
check "in every repository, through lane.sh" "1" "$([ -f "$DB/closed/cleared/old-b.yaml" ] && [ -f "$DA/closed/cleared/c-1.yaml" ] && echo 1 || echo 0)"
check "closed/ holds no lane files any more" "0" "$(find "$DA/closed" "$DB/closed" -maxdepth 1 -name '*.yaml' | wc -l | tr -d ' ')"
check "open and done lanes stay" "1" "$([ -f "$DA/open-one.yaml" ] && [ -f "$DA/shipped.yaml" ] && echo 1 || echo 0)"

echo "== closed: colour =="
cg lane new --repo "$CA" --lane tinted --pattern investigate --idea t >/dev/null
cg lane close --repo "$CA" --lane tinted >/dev/null
GRY=$'\033[38;2;139;148;158m' RED=$'\033[38;2;248;81;73m'
out="$(cgc panel --frame --width 48)"
check "CLOSED is a bold grey header" $' \033[1m'"${GRY}CLOSED (1)" "$out"
check "[x] is grey" "${GRY}[x]" "$out"
r="$(row_of "tinted  investigate")"
out="$(click 46 "$r" | cgc panel --frame --width 48 --feed)"
check "[confirm] is red" "${RED}[confirm]" "$out"
rm -rf "$C_TMP"
