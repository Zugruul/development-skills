#!/usr/bin/env bash
# section-board-truth-sim.sh -- sourced by run-tests.sh; do not run standalone.
# Task #564 acceptance simulation (the "board truth" set): a session with six lanes at WIP 5, one task
# merged on the user's acceptance (no reviewer APPROVE), and one worktree branch with no issue ends with
# the board matching reality after ONE `board.sh audit --fix`, and a second one changes nothing.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
# shellcheck source=plugins/spec-workflow/tests/_audit-fix-lib.sh
source "$HERE/_audit-fix-lib.sh"
echo "== board truth simulation (#564) =="

af_setup local; af_cfg methodology.maxInProgress 5
af_items "21:Backlog" "22:Backlog" "23:Backlog" "24:Backlog" "25:Backlog" "26:Backlog" "27:Backlog" "28:In review"
for n in 21 22 23 24 25 26 27; do af_worktree "$n" "fx/$n-lane"; done
af_worktree no-issue feature/no-issue
af_seen 21 22 23 24 25 26 27 28
# Lanes 21-25 registered through the board (WIP 5/5); lane 26 is the human's sixth and registers itself
# with its own --over-wip, which really fires. Lane 27 started working and the board was never told.
for n in 21 22 23 24 25; do af_run move "$n" "In progress" >/dev/null; done
out="$(af_run move 26 "In progress" --over-wip "human asked for a sixth lane")"
check "sim start: the self-registering 6th lane is flagged over WIP" "OVER WIP" "$out"
# Task 28 merged to main after the human accepted it without a reviewer APPROVE.
( cd "$AQ" && git commit -q --allow-empty -m "feat(28): the accepted thing (#28)" )
bash "$PLUGIN/scripts/user-acceptance.sh" --root "$AQ" --repo "$AF_REPO" --task 28 --status QA --quote "ship it" >/dev/null 2>&1 || true
check "sim start: 21-26 In progress" "In progress" "$(af_status 21)$(af_status 22)$(af_status 23)$(af_status 24)$(af_status 25)$(af_status 26)"
check "sim start: 27 still invisible" "Backlog" "$(af_status 27)"

: >"$AF_LOG"
out="$(af_run audit --fix)"
for n in 21 22 23 24 25 26 27; do
    check "sim: lane $n is In progress or later" "In progress" "$(af_status "$n")"
done
check "sim: lane 27 FIX line" "FIX #27: Backlog -> In progress (live worktree .claude/worktrees/27, branch fx/27-lane)" "$out"
check_absent "sim: registered lanes need no fix" "FIX #26" "$out"
check "sim: the unregistered lane is over WIP and flagged" "OVER WIP" "$out"
check "sim: the accepted task is in QA" "QA" "$(af_status 28)"
check "sim: QA FIX line" "FIX #28: In review -> QA (merged: commit on main references #28)" "$out"
check "sim: unlinked branch got an issue" "FIX: worktree .claude/worktrees/no-issue (branch feature/no-issue) had no issue -> #900 (board.sh ensure-issue)" "$out"
check "sim: that issue is on the board and In progress" "In progress" "$(af_status 900)"
check "sim: summary" "AUDIT --fix: 4 change(s)" "$out"
check "sim: exit 0" "rc=0" "$out"
# Exact API budget of that audit run: the audit's own read, reused for every move's admission under one held mutex,
# plus the one read ensure-issue's item-add visibility poll makes for the card it creates.
check_rc "sim calls: board reads (fields) = audit + the add poll" 2 "$(af_n 'graphql:fields')"
check_rc "sim calls: board reads (items)" 2 "$(af_n 'graphql:items')"
check_rc "sim calls: status/priority edits (27, 28, new issue: backlog, prio, in progress)" 5 "$(af_n 'item-edit')"
check_rc "sim calls: over-WIP comments (lane 27, new issue)" 2 "$(af_n 'rest:comment')"
check_rc "sim calls: one issue created" 1 "$(af_n 'issue-create')"
check_rc "sim calls: one item-add" 1 "$(af_n 'item-add')"
check_rc "sim calls: one body PATCH" 1 "$(af_n 'rest:patch')"
check_rc "sim calls: one REST head lookup (ensure-issue)" 1 "$(af_n 'rest:pulls-head')"
check_rc "sim calls: no PR list (local mode has no PRs)" 0 "$(( $(af_n 'rest:pulls-open') + $(af_n 'rest:pulls-closed') ))"
check_rc "sim calls: no GraphQL command" 0 "$(af_n 'GRAPHQL-CMD')"
check_rc "sim calls: no child of a trusted move inherited the trust variables" 0 "$(af_leaks)"
check_rc "sim calls: nothing unexpected" 0 "$(af_n 'UNEXPECTED')"
check_rc "sim calls: total" 15 "$(af_total)"
check_rc "sim: the admission mutex is released" 0 "$([[ -d "$AQ/.claude/board-wip.lock" ]] && echo 1 || echo 0)"

: >"$AF_LOG"
out="$(af_run audit --fix)"
check "sim second audit: no changes" "AUDIT --fix: 0 change(s)" "$out"
check_rc "sim second audit: no mutation" 0 "$(( $(af_n 'item-edit') + $(af_n 'rest:comment') + $(af_n 'issue-create') + $(af_n 'item-add') ))"
check_rc "sim second audit: exactly one board read" 1 "$(af_n 'graphql:items')"
check_rc "sim second audit: total calls (2 graphql)" 2 "$(af_total)"
af_teardown
