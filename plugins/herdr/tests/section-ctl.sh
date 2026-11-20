#!/usr/bin/env bash
# section-ctl.sh -- sourced by run-tests.sh; do not run standalone.
# herdr_ctl.py against the stub herdr: names, start retry, guarded prompt,
# roster, peek, listen and the worktree pre-creation checks.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr/tests/run-tests.sh" >&2; exit 2; }

CT_TMP="$(mktemp -d)"
CT_CTL="$PLUGIN/scripts/herdr_ctl.py"
ctl() { PATH="$FIX/stub-herdr:$PATH" HERDR_ENV=1 HERDR_PANE_ID=w1:p1 HERDR_STUB_DIR="$CT_TMP" HERDR_CTL_INTERVAL=0.05 HERDR_CONFIG_PATH="$CT_TMP/none.toml" python3 "$CT_CTL" "$@"; }
ct_state() { printf '%s' "$1" >"$CT_TMP/state.json"; : >"$CT_TMP/calls.log"; }
ct_calls() { grep -c -- "$1" "$CT_TMP/calls.log" || true; }
ct_agent() { # name status [extra json fields]
    printf '"%s":{"name":"%s","pane_id":"w1:p%s","tab_id":"w1:t1","workspace_id":"w1","agent":"claude","agent_status":"%s","state_change_seq":1,"cwd":"/w"%s}' "$1" "$1" "$1" "$2" "${3:-}"
}

echo "== herdr_ctl: outside Herdr =="
out="$(HERDR_ENV=0 python3 "$CT_CTL" check 2>&1)"; rc=$?
check_rc "check outside Herdr exits 2" 2 "$rc"
check "check outside Herdr says why" "not running inside a Herdr pane" "$out"
out="$(HERDR_ENV=0 python3 "$CT_CTL" roster 2>&1)"; rc=$?
check_rc "every verb refuses outside Herdr" 2 "$rc"

echo "== herdr_ctl: names =="
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

echo "== herdr_ctl: start =="
ct_state '{"busy":3}'
out="$(ctl start --name dev --kind claude --pane w1:p2 2>&1)"; rc=$?
check_rc "start retries while the pane is busy, then succeeds" 0 "$rc"
check "start reports the agent ready" "AGENT READY name=dev pane=w1:p2" "$out"
check "start needed four attempts" "attempts=4" "$out"
ct_state '{"busy":99}'
out="$(ctl start --name dev --kind claude --pane w1:p2 --timeout 1 2>&1)"; rc=$?
check_rc "start gives up on a pane that never frees" 1 "$rc"
check "start names the herdr error" "agent_pane_busy" "$out"
ct_state '{"start":"not_ready"}'
out="$(ctl start --name dev --kind claude --pane w1:p2 2>&1)"; rc=$?
check_rc "agent blocked at startup exits 3" 3 "$rc"
check "blocked startup shows the dialog" "Do you trust this folder?" "$out"
check "blocked startup reads the visible screen" "SCREEN[visible]" "$out"
check "blocked startup hands the answer to the user" "do not answer it yourself" "$out"
check_rc "blocked startup is not retried" 1 "$(ct_calls 'agent start')"
ct_state "{\"agents\":{$(ct_agent dev idle)}}"
out="$(ctl start --name dev --kind claude --pane w1:p2 2>&1)"; rc=$?
check_rc "start refuses a name already in use" 6 "$rc"
check_rc "a refused name never reaches herdr agent start" 0 "$(ct_calls 'agent start')"
ct_state '{}'
ctl start --name dev --kind codex --pane w1:p2 -- --model x >/dev/null 2>&1
check "native agent arguments go after --" "agent start dev --kind codex --pane w1:p2 -- --model x" "$(cat "$CT_TMP/calls.log")"

echo "== herdr_ctl: prompt =="
ct_state "{\"agents\":{$(ct_agent dev idle)}}"
out="$(ctl prompt dev --text "do the thing" 2>&1)"; rc=$?
check_rc "prompt to an idle agent succeeds" 0 "$rc"
check "prompt reports delivery" "PROMPT DELIVERED" "$out"
check "the text is sent through agent prompt" "agent prompt dev do the thing" "$(cat "$CT_TMP/calls.log")"
ct_state "{\"agents\":{$(ct_agent dev blocked ',"screen":"Allow edit? 1. Yes 2. No"')}}"
out="$(ctl prompt dev --text "x" 2>&1)"; rc=$?
check_rc "prompt to a blocked agent is refused" 4 "$rc"
check "refusal shows the blocked dialog" "Allow edit? 1. Yes 2. No" "$out"
check_rc "refused prompt sends nothing" 0 "$(ct_calls 'agent prompt')"
ct_state "{\"agents\":{$(ct_agent dev working)}}"
out="$(ctl prompt dev --text "x" 2>&1)"; rc=$?
check_rc "prompt to a working agent is refused by default" 4 "$rc"
out="$(ctl prompt dev --text "x" --while-working 2>&1)"; rc=$?
check_rc "--while-working steers a working agent" 0 "$rc"
ct_state "{\"prompt\":\"silent\",\"agents\":{$(ct_agent dev idle)}}"
out="$(ctl prompt dev --text "x" --confirm 1 2>&1)"; rc=$?
check_rc "submitted but no activity exits 5" 5 "$rc"
check "unconfirmed prompt forbids a blind resend" "Do NOT send it again blindly" "$out"
check_rc "unconfirmed prompt was sent exactly once" 1 "$(ct_calls 'agent prompt')"
ct_state "{\"prompt\":\"stalled\",\"agents\":{$(ct_agent dev idle)}}"
out="$(ctl prompt dev --text "x" 2>&1)"; rc=$?
check_rc "herdr stall exits 5" 5 "$rc"
check "herdr stall is reported as unconfirmed" "PROMPT UNCONFIRMED" "$out"
check_rc "stalled prompt was sent exactly once" 1 "$(ct_calls 'agent prompt')"
ct_state '{}'
out="$(ctl prompt ghost --text "x" 2>&1)"; rc=$?
check_rc "prompt to a missing agent is refused" 4 "$rc"
printf 'from a file\n' >"$CT_TMP/p.txt"
ct_state "{\"agents\":{$(ct_agent dev idle)}}"
ctl prompt dev --file "$CT_TMP/p.txt" >/dev/null 2>&1
check "--file sends the file's text" "agent prompt dev from a file" "$(cat "$CT_TMP/calls.log")"

echo "== herdr_ctl: roster and peek =="
ct_state "{\"workspaces\":[{\"workspace_id\":\"w1\",\"label\":\"lane-a\",\"worktree\":{\"repo_root\":\"/repo\"}}],\"agents\":{$(ct_agent dev working),$(ct_agent rev blocked)}}"
out="$(ctl roster 2>&1)"; rc=$?
check_rc "roster succeeds" 0 "$rc"
check "roster lists agents with their workspace label" "w1 lane-a" "$out"
check "roster calls out blocked agents" "BLOCKED, waiting on a human: rev" "$out"
check "roster --json is machine readable" '"status": "blocked"' "$(ctl roster --json 2>&1)"
check "roster --repo filters by repository" "no live agents match" "$(ctl roster --repo /elsewhere 2>&1)"
out="$(ctl peek rev 2>&1)"
PEEK_OUT="$out"

echo "== herdr_ctl: overview =="
ct_state "{\"root\":\"/repo\",\"workspaces\":[{\"workspace_id\":\"w1\",\"label\":\"monorepo\"},{\"workspace_id\":\"w2B\",\"label\":\"a label with spaces well over 24 characters\"},{\"workspace_id\":\"wK\",\"label\":\"fix-converge-deps\"}],\"worktrees\":[{\"branch\":\"feat/long-branch-name\",\"path\":\"/wt/b\",\"open_workspace_id\":\"w2B\"},{\"branch\":\"main\",\"path\":\"/repo\",\"open_workspace_id\":\"w1\"},{\"branch\":\"old\",\"path\":\"/wt/old\"},{\"branch\":\"older\",\"path\":\"/wt/older\",\"open_workspace_id\":null}],\"agents\":{$(ct_agent 1 idle),$(ct_agent lane-a working),$(ct_agent rev blocked),\"x\":{\"pane_id\":\"wK:p1\",\"workspace_id\":\"wK\",\"agent\":\"opencode\",\"agent_status\":\"working\",\"cwd\":\"/somewhere/long\"}}}"
out="$(ctl overview 2>&1)"; rc=$?
check_rc "overview succeeds" 0 "$rc"
check "overview: plain heading counts every live agent" "Agents (4)" "$out"
check "overview: blocked agents come first, with the workspace label" "Agents (4)
  w1  monorepo           claude    blocked  rev" "$out"
check "overview: this agent is marked" "  w1  monorepo           claude    idle     1  (this agent)" "$out"
check "overview: columns are aligned and an unnamed agent has no name column" "  w1  monorepo           claude    working  lane-a
  wK  fix-converge-deps  opencode  working" "$out"
check_absent "overview: no word for an unnamed agent" "unnamed" "$out"
check_absent "overview: no pane ids" "wK:p1" "$out"
check_absent "overview: no paths" "/" "$(printf '%s' "$out" | grep -v 'feat/')"
check "overview: worktree heading counts open of total" "Worktrees (2 open of 4)" "$out"
check "overview: open worktrees by full label, spaces kept, with a note when no agent runs there" "Worktrees (2 open of 4)
  monorepo                                      main
  a label with spaces well over 24 characters  feat/long-branch-name  (no agent)" "$out"
check_absent "overview: git-only worktrees are not listed" "old" "$out"
printf '%s\n' "$out" | grep -q ' $' && rc=1 || rc=0
check_rc "overview: no trailing spaces" 0 "$rc"
out="$(ctl overview --mine lane-a wK:p1 2>&1)"
check "overview --mine: the heading says other agents, without mine or me" "Other agents (1)
  w1  monorepo  claude  blocked  rev

Worktrees" "$out"
check_absent "overview --mine: my agents are left out" "lane-a" "$out"
out="$(ctl overview --mine lane-a wK:p1 rev 2>&1)"
check_absent "overview --mine: no agents list when there are no others" "agents" "$out"
check "overview --mine: the worktrees are still printed" "Worktrees (2 open of 4)" "$out"
ct_state "{\"workspaces\":[{\"workspace_id\":\"w1\",\"label\":\"a label with spaces well over 24 characters\"}],\"agents\":{$(ct_agent dev working),$(ct_agent rev blocked)}}"
check "roster no longer cuts the workspace label" "w1 a label with spaces well over 24 characters /w" "$(ctl roster 2>&1)"
out="$PEEK_OUT"
check "peek shows the state" "status=blocked" "$out"
check "peek reads the visible screen first" "SCREEN[visible]" "$out"
check_absent "peek skips history unless asked" "recent-unwrapped" "$out"
check "peek --history adds the unwrapped history" "SCREEN[recent-unwrapped]" "$(ctl peek rev --history 50 2>&1)"

echo "== herdr_ctl: landed =="
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

echo "== herdr_ctl: listen =="
ct_state "{\"agents\":{$(ct_agent dev working ',"script":["working","working","blocked"],"screen":"Proceed? y/n"'),$(ct_agent rev working)}}"
out="$(ctl listen dev rev --timeout 20 2>&1)"; rc=$?
check_rc "listen returns when an agent blocks" 0 "$rc"
check "listen names the blocked agent, pane and tab" "EVENT target=dev name=dev pane=w1:pdev tab=w1:t1 status=blocked" "$out"
check "listen shows the question" "Proceed? y/n" "$out"
check "listen says who is still working" "STILL WORKING: rev=working" "$out"
ct_state "{\"agents\":{$(ct_agent dev working)}}"
out="$(ctl listen dev --timeout 1 2>&1)"; rc=$?
check_rc "listen timeout is not an error" 0 "$rc"
check "listen timeout forbids resending" "never resend a prompt because of a timeout" "$out"
ct_state "{\"agents\":{$(ct_agent dev "done")}}"
check "listen reports a finished agent" "status=done" "$(ctl listen dev --timeout 1 2>&1)"
check "--only-blocked ignores a finished agent" "LISTEN TIMEOUT" "$(ctl listen dev --only-blocked --timeout 1 2>&1)"
ct_state '{}'
check "listen reports an agent that is gone" "status=gone" "$(ctl listen dev --timeout 1 2>&1)"

echo "== herdr_ctl: worktree-plan =="
CT_REPO="$CT_TMP/repo"; git init -q -b main "$CT_REPO"
git -C "$CT_REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
ct_state "{\"root\":\"$CT_REPO\",\"worktrees\":[{\"branch\":\"main\",\"path\":\"$CT_REPO\",\"open_workspace_id\":\"w1\"}]}"
out="$(ctl worktree-plan --cwd "$CT_REPO" --branch feat/x --base main --path .worktrees/x --label x 2>&1)"; rc=$?
check_rc "a clean plan passes" 0 "$rc"
check "the plan prints the full explicit command" "herdr worktree create --cwd $CT_REPO --branch feat/x --base main --path $CT_REPO/.worktrees/x --label x --no-focus" "$out"
check "the plan asks for approval first" "only after the user approved" "$out"
check_absent "the plan never grants repository trust" "--trust-repository" "$out"
check_rc "the plan creates nothing" 0 "$(ct_calls 'worktree create')"
out="$(ctl worktree-plan --cwd "$CT_REPO" --branch feat/x --base main 2>&1)"
check "without --path the default is Herdr's worktree directory" "/.herdr/worktrees/repo/feat-x" "$out"
check "without --label the label comes from the branch, hyphenated" "--label feat-x --no-focus" "$out"
out="$(ctl worktree-plan --cwd "$CT_REPO" --branch feat/x --base main --path .worktrees/x --label CU-1k5a5ew4cde-image-input 2>&1)"; rc=$?
check_rc "a tagged hyphenated label passes" 0 "$rc"
check "the label is passed through unchanged, case kept" "--label CU-1k5a5ew4cde-image-input --no-focus" "$out"
out="$(ctl worktree-plan --cwd "$CT_REPO" --branch feat/x --base main --path .worktrees/x --label "1k5a5ew4cde image input" 2>&1)"; rc=$?
check_rc "a label with spaces is refused" 6 "$rc"
check "the refusal names the hyphenated form" "use 1k5a5ew4cde-image-input" "$out"
check_absent "a refused label prints no command" "herdr worktree create" "$out"
out="$(ctl worktree-plan --cwd "$CT_REPO" --branch feat/x --base main --path .worktrees/x --label "a_b/c" 2>&1)"; rc=$?
check_rc "a label with other separators is refused" 6 "$rc"
check "label turns free text into the hyphenated form" "LABEL 1k5a5ew4cde-image-input" "$(ctl label 1k5a5ew4cde image input 2>&1)"
check "label keeps case and collapses separators" "LABEL J-ABC-123-add-parser" "$(ctl label "J-ABC-123  add_parser" 2>&1)"
ctl label "  --  " >/dev/null 2>&1; check_rc "label refuses text with nothing usable" 6 "$?"
out="$(ctl worktree-plan --cwd "$CT_REPO" --branch main --base main --path .worktrees/m 2>&1)"; rc=$?
check_rc "a branch already checked out is refused" 6 "$rc"
check "the refusal points at the existing worktree" "already checked out at $CT_REPO" "$out"
mkdir -p "$CT_REPO/.worktrees/taken"
out="$(ctl worktree-plan --cwd "$CT_REPO" --branch feat/y --base main --path .worktrees/taken 2>&1)"; rc=$?
check_rc "an existing destination is refused" 6 "$rc"
out="$(ctl worktree-plan --cwd "$CT_REPO" --branch feat/y --path .worktrees/y 2>&1)"; rc=$?
check_rc "a new branch without a base is refused" 6 "$rc"
check "the refusal says to ask for the base" "ask which ref to branch from" "$out"
out="$(ctl worktree-plan --cwd "$CT_REPO" --branch feat/y --base nope --path .worktrees/y 2>&1)"; rc=$?
check_rc "an unresolvable base is refused" 6 "$rc"
rm -rf "$CT_TMP"
