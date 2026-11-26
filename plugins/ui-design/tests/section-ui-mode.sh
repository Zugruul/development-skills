#!/usr/bin/env bash
# section-ui-mode.sh -- sourced by run-tests.sh; do not run standalone.
# ui-mode.sh: status/on/off through one local, gitignored flag in the main
# checkout. It reads no other tool's configuration.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/ui-design/tests/run-tests.sh" >&2; exit 2; }
echo "== ui-mode (local flag) =="

UIM="$PLUGIN/scripts/ui-mode.sh"
_umtmp="$(mktemp -d)"
git_repo "$_umtmp/main"
_um_main="$(canon "$_umtmp/main")"

out="$(cd "$_um_main" && bash "$UIM")"
check "status is the default and starts ON" "ON (UI decisions are delegated to the human" "$out"
out="$(cd "$_um_main" && bash "$UIM" off)"
check "off reports the flag" "Iterative UI mode: OFF for this clone (flag: $_um_main/.claude/ITERATIVE_UI_OFF)" "$out"
r=MISSING; [[ -f "$_um_main/.claude/ITERATIVE_UI_OFF" ]] && r=PRESENT
check "off creates .claude/ITERATIVE_UI_OFF" PRESENT "$r"
out="$(cd "$_um_main" && bash "$UIM" status)"
check "status after off names the local flag" "OFF (local flag $_um_main/.claude/ITERATIVE_UI_OFF" "$out"
out="$(cd "$_um_main" && bash "$UIM" on)"
check "on reports ON" "Iterative UI mode: ON" "$out"
r=GONE; [[ -f "$_um_main/.claude/ITERATIVE_UI_OFF" ]] && r=PRESENT
check "on removes the flag" GONE "$r"
out="$(cd "$_um_main" && bash "$UIM" sideways 2>&1)"; rc=$?
check_rc "an unknown action exits 1" 1 "$rc"
check "an unknown action prints the usage" "usage: ui-mode.sh [status|on|off]" "$out"

# A project config elsewhere never changes the answer: ui-design reads only its flag.
mkdir -p "$_um_main/.neural-network"
printf 'methodology:\n  iterativeUI: false\n' >"$_um_main/.neural-network/project.yaml"
out="$(cd "$_um_main" && bash "$UIM" status)"
check "another tool's project config is not read" "ON (UI decisions" "$out"

# From a linked worktree the flag lives in the main checkout.
(cd "$_um_main" && git worktree add -q "$_umtmp/wt" -b wt) >/dev/null 2>&1
(cd "$_umtmp/wt" && bash "$UIM" off >/dev/null)
r=MISSING; [[ -f "$_um_main/.claude/ITERATIVE_UI_OFF" ]] && r=MAIN
check "off from a worktree sets the main checkout's flag" MAIN "$r"
r=CLEAN; [[ -e "$_umtmp/wt/.claude/ITERATIVE_UI_OFF" ]] && r=SILOED
check "off from a worktree leaves the worktree clean" CLEAN "$r"
out="$(cd "$_um_main" && bash "$UIM" status)"
check "the main checkout sees the worktree's off" "OFF (local flag" "$out"

rm -rf "$_umtmp"
