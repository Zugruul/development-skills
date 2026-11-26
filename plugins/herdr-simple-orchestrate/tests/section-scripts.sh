#!/usr/bin/env bash
# section-scripts.sh -- sourced by run-tests.sh; do not run standalone.
# This plugin's scripts against the stub herdr: name, label, roster, mine and landed.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr-simple-orchestrate/tests/run-tests.sh" >&2; exit 2; }

CT_TMP="$(mktemp -d)"
SC="$PLUGIN/scripts"
ctl() { local s="$1"; shift; env -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID PATH="$FIX/stub-herdr:$PATH" HERDR_ENV=1 HERDR_PANE_ID=w1:p1 HERDR_STUB_DIR="$CT_TMP" HERDR_CTL_INTERVAL=0.05 bash "$SC/$s.sh" "$@"; }
ct_state() { printf '%s' "$1" >"$CT_TMP/state.json"; : >"$CT_TMP/calls.log"; }
ct_calls() { grep -c -- "$1" "$CT_TMP/calls.log" || true; }
ct_agent() { # name status [extra json fields]
    printf '"%s":{"name":"%s","pane_id":"w1:p%s","tab_id":"w1:t1","workspace_id":"w1","agent":"claude","agent_status":"%s","state_change_seq":1,"cwd":"/w"%s}' "$1" "$1" "$1" "$2" "${3:-}"
}

echo "== scripts: outside Herdr =="
out="$(HERDR_ENV=0 env -u CODEX_SESSION_ID PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$CT_TMP" bash "$SC/roster.sh" 2>&1)"; rc=$?
check_rc "every script refuses outside Herdr" 2 "$rc"
echo "== scripts: names =="
ct_state "{\"agents\":{$(ct_agent dev idle)}}"
out="$(ctl name reviewer 2>&1)"; rc=$?
check_rc "free valid name passes" 0 "$rc"
out="$(ctl name dev 2>&1)"; rc=$?
check_rc "taken name is refused" 6 "$rc"
check "taken name offers a free alternative" "dev-2" "$out"
for bad in Dev 1dev "dev agent" dev.x "$(printf 'a%.0s' $(seq 33))" ""; do
    out="$(ctl name "$bad" 2>&1)"; rc=$?
    check_rc "invalid name '$bad' is refused" 6 "$rc"
done
out="$(ctl name "$(printf 'a%.0s' $(seq 32))" 2>&1)"; rc=$?
check_rc "32-character name is accepted" 0 "$rc"

echo "== scripts: roster =="
ct_state "{\"workspaces\":[{\"workspace_id\":\"w1\",\"label\":\"lane-a\",\"worktree\":{\"repo_root\":\"/repo\"}}],\"agents\":{$(ct_agent dev working),$(ct_agent rev blocked)}}"
out="$(ctl roster 2>&1)"; rc=$?
check_rc "roster succeeds" 0 "$rc"
check "roster lists agents with their workspace label" "w1 lane-a" "$out"
check "roster calls out blocked agents" "BLOCKED, waiting on a human: rev" "$out"
check "roster --json is machine readable" '"status": "blocked"' "$(ctl roster --json 2>&1)"
check "roster --repo filters by repository" "no live agents match" "$(ctl roster --repo /elsewhere 2>&1)"
echo "== scripts: mine =="
ct_state "{\"root\":\"/repo\",\"workspaces\":[{\"workspace_id\":\"w1\",\"label\":\"monorepo\"},{\"workspace_id\":\"w2B\",\"label\":\"a label with spaces well over 24 characters\"},{\"workspace_id\":\"wK\",\"label\":\"fix-converge-deps\"}],\"worktrees\":[{\"branch\":\"feat/long-branch-name\",\"path\":\"/wt/b\",\"open_workspace_id\":\"w2B\"},{\"branch\":\"main\",\"path\":\"/repo\",\"open_workspace_id\":\"w1\"},{\"branch\":\"old\",\"path\":\"/wt/old\"},{\"branch\":\"older\",\"path\":\"/wt/older\",\"open_workspace_id\":null}],\"agents\":{$(ct_agent 1 idle),$(ct_agent lane-a working),$(ct_agent rev blocked),\"x\":{\"pane_id\":\"wK:p1\",\"workspace_id\":\"wK\",\"agent\":\"opencode\",\"agent_status\":\"working\",\"cwd\":\"/somewhere/long\"}}}"
out="$(ctl mine lane-a wK:p1 2>&1)"
check "mine: the heading says other agents, without mine or me" "Other agents (1)
  w1  monorepo  claude  blocked  rev

Worktrees" "$out"
check_absent "mine: my agents are left out" "lane-a" "$out"
out="$(ctl mine lane-a wK:p1 rev 2>&1)"
check_absent "mine: no agents list when there are no others" "agents" "$out"
check "mine: the worktrees are still printed" "Worktrees (2 open of 4)" "$out"
ct_state "{\"workspaces\":[{\"workspace_id\":\"w1\",\"label\":\"a label with spaces well over 24 characters\"}],\"agents\":{$(ct_agent dev working),$(ct_agent rev blocked)}}"
check "roster no longer cuts the workspace label" "w1 a label with spaces well over 24 characters /w" "$(ctl roster 2>&1)"
echo "== scripts: landed =="
LD="$CT_TMP/landed"; mkdir -p "$LD"
lg() { git -C "$LD/work" -c user.name=t -c user.email=t@t "$@"; }
git init -q --bare -b main "$LD/remote.git"
git init -q -b main "$LD/work"
lg remote add origin "$LD/remote.git"
printf 'a\n' >"$LD/work/a.txt"; lg add -A; lg commit -q -m init; lg push -q origin main
lg checkout -q -b feat/x
printf 'x1\n' >"$LD/work/x.txt"; lg add -A; lg commit -q -m x1
printf 'x2\n' >>"$LD/work/x.txt"; lg add -A; lg commit -q -m x2
out="$(ctl landed --cwd "$LD/work" 2>&1)"; rc=$?
check_rc "landed succeeds on unmerged work" 0 "$rc"
check "landed: unmerged work gets no row" "NOT MERGED" "$out"
check_absent "landed: unmerged work prints no ROW" "ROW" "$out"
printf 'wip\n' >"$LD/work/wip.txt"
check "landed: uncommitted changes are noted" "has uncommitted changes" "$(ctl landed --cwd "$LD/work" 2>&1)"
rm "$LD/work/wip.txt"
# squash onto local main, with an unrelated later commit on main
lg checkout -q main; lg merge -q --squash feat/x; lg commit -q -m "squash x"
LD_SQ="$(lg rev-parse --short HEAD)"
out="$(ctl landed --cwd "$LD/work" --branch feat/x 2>&1)"
check "landed: a squash on the local main only is local, not merged" "ROW  ⚪ direct  local   main @ $LD_SQ" "$out"
check_absent "landed: local-only work is never purple" "🟣" "$out"
printf 'b\n' >"$LD/work/b.txt"; lg add -A; lg commit -q -m "later, unrelated"
lg push -q origin main
out="$(ctl landed --cwd "$LD/work" --branch feat/x 2>&1)"
check "landed: a pushed squash is merged, by content" "MERGED origin/main @ $LD_SQ (same content)" "$out"
check "landed: the row names the commit where the work landed" "ROW  🟣 direct  merged  main @ $LD_SQ" "$out"
check "landed: says it did not fetch" "nothing was fetched now" "$out"
# a branch whose own commits are on the remote main
lg checkout -q -b feat/y; printf 'y\n' >"$LD/work/y.txt"; lg add -A; lg commit -q -m y
LD_Y="$(lg rev-parse --short HEAD)"
lg push -q origin feat/y:main
out="$(ctl landed --cwd "$LD/work" 2>&1)"
check "landed: the same commits on the remote main are merged" "ROW  🟣 direct  merged  main @ $LD_Y" "$out"
check "landed: warns that an empty branch reads the same" "Use the row only for an agent that made commits" "$out"
# main changed the same lines afterwards: no claim of a merge
lg checkout -q -b feat/z; printf 'z\n' >"$LD/work/x.txt"; lg add -A; lg commit -q -m z
lg checkout -q main; lg merge -q --ff-only feat/y; printf 'other\n' >"$LD/work/x.txt"; lg add -A; lg commit -q -m other
check "landed: a conflicting main is not called merged" "NOT MERGED" "$(ctl landed --cwd "$LD/work" --branch feat/z 2>&1)"
out="$(ctl landed --cwd "$LD/work" 2>&1)"
check "landed: unpushed commits on main itself are local" "ROW  ⚪ direct  local   main @ $(lg rev-parse --short HEAD)" "$out"
lg push -q origin main
check "landed: on a pushed main it cannot tell whose commits they are" "ON TARGET" "$(ctl landed --cwd "$LD/work" 2>&1)"
out="$(ctl landed --cwd "$CT_TMP" 2>&1)"; rc=$?
check_rc "landed outside a repository fails" 1 "$rc"
check "label turns free text into the hyphenated form" "LABEL 1k5a5ew4cde-image-input" "$(ctl label 1k5a5ew4cde image input 2>&1)"
check "label keeps case and collapses separators" "LABEL J-ABC-123-add-parser" "$(ctl label "J-ABC-123  add_parser" 2>&1)"
ctl label "  --  " >/dev/null 2>&1; check_rc "label refuses text with nothing usable" 6 "$?"
rm -rf "$CT_TMP"
