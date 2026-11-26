#!/usr/bin/env bash
# section-clear-reviews.sh -- sourced by run-tests.sh; do not run standalone.
# The panel's [clear all reviews] on the CLOSED header, left of [clear all]: shown only while a
# closed review lane exists (pattern review or review-stack; with no pattern or a custom one,
# a look/pr-<n> branch), the same two-click [confirm], and it clears only closed review lanes
# through lane.sh clear. Key: R.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr-graph-engineering/tests/run-tests.sh" >&2; exit 2; }

R_TMP="$(mktemp -d)"
RSC="$PLUGIN/scripts"
RA="$R_TMP/repo-a" RB="$R_TMP/repo-b"
for r in "$RA" "$RB"; do
    git init -q -b main "$r" && git -C "$r" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
done
rg_() { local s="$1"; shift; (cd "$RA" && env -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_PLUGIN_ID PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$R_TMP" HERDR_ENV=1 NO_COLOR=1 XDG_CONFIG_HOME="$R_TMP/config" bash "$RSC/$s.sh" "$@"); }
rgc() { local s="$1"; shift; (cd "$RA" && env -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_PLUGIN_ID -u NO_COLOR PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$R_TMP" HERDR_ENV=1 XDG_CONFIG_HOME="$R_TMP/config" bash "$RSC/$s.sh" "$@"); }
rdir() { printf '%s/herdr-graph' "$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)"; }
RDA="$(rdir "$RA")" RDB="$(rdir "$RB")"
printf '%s' "{\"workspaces\":[{\"workspace_id\":\"w1\",\"worktree\":{\"repo_root\":\"$RA\"}},{\"workspace_id\":\"w2\",\"worktree\":{\"repo_root\":\"$RB\"}}]}" >"$R_TMP/state.json"
rclick() { printf '\033[<0;%s;%sM\033[<0;%s;%sm' "$1" "$2" "$1" "$2"; }
rrow() { grep -n -- "$1" <<<"$(rg_ panel --frame --width 48)" | head -1 | cut -d: -f1; }
rhas() { [ -f "$1" ] && echo 1 || echo 0; }
PR=https://github.com/o/r/pull

echo "== clear reviews: no closed review lane, no button =="
rg_ lane new --repo "$RA" --lane plain-gone --pattern investigate --idea a >/dev/null
rg_ lane close --repo "$RA" --lane plain-gone >/dev/null
rg_ lane new --repo "$RA" --lane rv-open --pattern review --idea "review 1" --input pr="$PR/1" >/dev/null
out="$(rg_ panel --frame --width 48)"
check "with no closed review lane the header has only [clear all]" "1" "$(grep -cE "^ CLOSED \(1\) +\[clear all\]$" <<<"$out")"
check_absent "and no [clear all reviews]" "[clear all reviews]" "$out"
out="$(printf 'R' | rg_ panel --frame --width 48 --feed)"
check "R with no closed review lane says so" "no closed review lanes" "$out"

echo "== clear reviews: the button =="
# closed review lanes: by pattern (review), by a custom pattern with a look/pr-<n> branch,
# in another repository; closed lanes that are not reviews: a custom pattern on a feature
# branch, and a solo lane on a look/pr-<n> branch (the recorded pattern wins over the branch)
rg_ lane new --repo "$RA" --lane rv-a --pattern review --idea "review 2" --input pr="$PR/2" >/dev/null
rg_ lane close --repo "$RA" --lane rv-a >/dev/null
rg_ lane new --repo "$RB" --lane rv-stack --pattern-file "$PLUGIN/patterns/investigate.yaml" --idea stack --branch look/pr-7 >/dev/null
rg_ lane close --repo "$RB" --lane rv-stack >/dev/null
rg_ lane new --repo "$RA" --lane custom-gone --pattern-file "$PLUGIN/patterns/investigate.yaml" --idea c --branch feat/x >/dev/null
rg_ lane close --repo "$RA" --lane custom-gone >/dev/null
rg_ lane new --repo "$RA" --lane solo-gone --pattern solo --idea s --gate "npm test" --branch look/pr-9 >/dev/null
rg_ lane close --repo "$RA" --lane solo-gone >/dev/null
out="$(rg_ panel --frame --width 48)"
check "the CLOSED header shows [clear all reviews] left of [clear all]" "1" "$(grep -cE "^ CLOSED \(5\) +\[clear all reviews\] \[clear all\]$" <<<"$out")"
check "the header still ends one column short of the right edge" "47" "$(grep "CLOSED" <<<"$out" | jq -Rr 'length')"
out="$(rg_ panel --frame --width 40)"
check "when both do not fit, only [clear all] shows" "1" "$(grep -cE "^ CLOSED \(5\) +\[clear all\]$" <<<"$out")"
check "and the header still fits" "39" "$(grep "CLOSED" <<<"$out" | jq -Rr 'length')"
out="$(printf '?'| rg_ panel --frame --width 48 --feed)"
check "? lists R" "R clear reviews" "$out"

echo "== clear reviews: confirm and cancel =="
r="$(rrow "CLOSED (5)")"
# width 48: [clear all] on columns 37-47, [clear all reviews] on 17-35
out="$(rclick 20 "$r" | rg_ panel --frame --width 48 --feed)"
check "the first click turns it into a [confirm]" "1" "$(grep -cE "^ CLOSED \(5\) +\[confirm\] \[clear all\]$" <<<"$out")"
check "the armed header still ends one column short of the right edge" "47" "$(grep "CLOSED" <<<"$out" | jq -Rr 'length')"
check "nothing is cleared yet" "1" "$(rhas "$RDA/closed/rv-a.yaml")"
out="$( { rclick 20 "$r"; rclick 5 1; } | rg_ panel --frame --width 48 --feed)"
check "a click anywhere else puts it back" "1" "$(grep -cE "^ CLOSED \(5\) +\[clear all reviews\] \[clear all\]$" <<<"$out")"
out="$( { rclick 20 "$r"; printf 'j'; } | rg_ panel --frame --width 48 --feed)"
check "so does any key" "1" "$(grep -cE "^ CLOSED \(5\) +\[clear all reviews\] \[clear all\]$" <<<"$out")"
out="$( { rclick 20 "$r"; rclick 42 "$r"; } | rg_ panel --frame --width 48 --feed)"
check "a click on [clear all] while reviews is armed only arms [clear all]" "1" "$(grep -cE "^ CLOSED \(5\) +\[clear all reviews\] \[confirm\]$" <<<"$out")"
check "and clears nothing" "1" "$(rhas "$RDA/closed/rv-a.yaml")"
out="$(printf 'R' | rgc panel --frame --width 48 --feed)"
check "R arms it, in red" $'\033[38;2;248;81;73m[confirm]' "$out"
check "nothing cleared by arming" "1" "$(rhas "$RDB/closed/rv-stack.yaml")"

echo "== clear reviews: the second click =="
: >"$R_TMP/calls.log"
out="$( { rclick 20 "$r"; rclick 30 "$r"; } | rg_ panel --frame --width 48 --feed)"
check "a second click clears the closed review lane by pattern" "1" "$(rhas "$RDA/closed/cleared/rv-a.yaml")"
check "and by its look/pr- branch, in every repository" "1" "$(rhas "$RDB/closed/cleared/rv-stack.yaml")"
check "closed lanes that are not reviews stay" "111" "$(rhas "$RDA/closed/plain-gone.yaml")$(rhas "$RDA/closed/custom-gone.yaml")$(rhas "$RDA/closed/solo-gone.yaml")"
check "an open review lane stays" "1" "$(rhas "$RDA/rv-open.yaml")"
check "the CLOSED count drops" "CLOSED (3)" "$out"
check "the button goes with the last closed review lane" "1" "$(grep -cE "^ CLOSED \(3\) +\[clear all\]$" <<<"$out")"
check_absent "the panel touches no worktree or branch" "worktree" "$(cat "$R_TMP/calls.log")"
rg_ lane new --repo "$RA" --lane rv-c --pattern review --idea "review 3" --input pr="$PR/3" >/dev/null
rg_ lane close --repo "$RA" --lane rv-c >/dev/null
out="$(printf 'RR' | rg_ panel --frame --width 48 --feed)"
check "R pressed twice clears the closed review lanes" "1" "$(rhas "$RDA/closed/cleared/rv-c.yaml")"
check "and only them" "3" "$(find "$RDA/closed" -maxdepth 1 -name '*.yaml' | wc -l | tr -d ' ')"
rm -rf "$R_TMP"
