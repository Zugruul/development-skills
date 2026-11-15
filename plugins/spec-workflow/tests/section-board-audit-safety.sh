#!/usr/bin/env bash
# section-board-audit-safety.sh -- sourced by run-tests.sh; do not run standalone.
# Regression for the rpg incident (2026-11-14): `board.sh audit --fix --if-due` filed 29 issues in
# 9 minutes (one per worktree-agent-* / batch/* worktree, local branch and unlinked PR, including a
# duplicate of a live task's PR) and moved them all to In progress over the WIP limit (25/5).
# Contract now: --fix never creates an issue (unlinked work is a DISCREPANCY note; ensure-issue is
# the orchestrator's deliberate call), agent and batch worktrees are never adopted, a branch is
# matched to an existing card by the task id in its name before it is called unlinked, the audit
# never moves a card over the WIP limit, and the pass prints progress and stays inside a time budget.
# Also covers `board.sh remove N`.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
# shellcheck source=plugins/spec-workflow/tests/_audit-fix-lib.sh
source "$HERE/_audit-fix-lib.sh"
echo "== board.sh audit --fix safety (rpg incident) =="

# --- A. the incident fixture: agent worktrees, a batch branch, stray branches, unlinked PRs ---
af_setup pr   # maxInProgress 1
af_items "5:In progress:SC-200: running task" "442:Backlog:SC-228: combat log" "443:Backlog:SC-226: inventory"
af_seen 5 442 443
af_worktree 5 fx/5-running
af_worktree worktree-agent-af6c0ab4c77a6e3ba worktree-agent-af6c0ab4c77a6e3ba
af_worktree worktree-agent-0123456789abcdef0 worktree-agent-0123456789abcdef0
af_worktree batch-30 batch/30
af_worktree sc-226 sc/226-inventory
af_worktree stray feature/no-issue
af_branch batch/31
# PR #446 belongs to SC-228 (#442) but its body has no issue reference.
printf '[%s,%s,%s]' "$(af_pr 446 sc/228-combat-log true false 'feat(SC-228): combat log' 'no ref here')" \
    "$(af_pr 447 worktree-agent-af6c0ab4c77a6e3ba true false 'agent scratch' 'nothing')" \
    "$(af_pr 448 batch/30 true false 'batch 30' 'nothing')" >"$AF_PULLS_OPEN"
out="$(af_run audit --fix)"
check_rc "A zero issue creations" 0 "$(af_n 'issue-create')"
check_rc "A zero item-adds" 0 "$(af_n 'item-add')"
check_rc "A no ensure-issue head lookups either" 0 "$(af_n 'rest:pulls-head')"
check "A an unlinked branch is a DISCREPANCY note" "NOTE: DISCREPANCY: worktree .claude/worktrees/stray (branch feature/no-issue) has no issue" "$out"
check "A the note points at ensure-issue as the deliberate call" "board.sh ensure-issue --title" "$out"
check_absent "A no FIX line files an issue" "had no issue ->" "$out"
check_absent "A agent worktrees are never named as unlinked work" "has no issue" "$(grep 'worktree-agent' <<<"$out")"
check_absent "A batch branches are never named as unlinked work" "has no issue" "$(grep 'batch/' <<<"$out")"
check "A one line says how many agent/batch lanes were ignored" "NOTE: ignored 3 agent/batch lane(s)" "$out"
check_absent "A the task-id-matched PR is not unlinked" "open PR #446" "$(grep 'has no issue' <<<"$out")"
check_absent "A the task-id-matched worktree is not unlinked" "sc/226-inventory" "$(grep 'has no issue' <<<"$out")"
check "A WIP full: the matched card is not moved" "Backlog" "$(af_status 442)"
check "A WIP full: neither is the other one" "Backlog" "$(af_status 443)"
check "A WIP full: a note says the audit never moves over the limit" "NOTE #442: not moved Backlog -> In progress" "$out"
check "A WIP note names the limit" "WIP limit" "$out"
check_rc "A no over-WIP comment at all" 0 "$(af_n 'rest:comment')"
check_rc "A no status edit at all" 0 "$(af_n 'item-edit')"
check_absent "A nothing is flagged OVER WIP" "OVER WIP" "$out"
check "A a WIP refusal is not a failure: exit 0" "rc=0" "$out"
check "A progress: the board read is reported" "audit: board read: 3 item(s)" "$out"
check "A progress: the reconcile phase is reported" "audit: reconciling" "$out"
af_teardown

# --- B. under the limit the task-id match moves the right card, once ---
af_setup pr; af_cfg methodology.maxInProgress 5
af_items "442:Backlog:SC-228: combat log" "443:Backlog:SC-226: inventory" "226:Backlog:unrelated #226"
af_seen 442 443 226
af_worktree sc-226 sc/226-inventory
printf '[%s]' "$(af_pr 446 sc/228-combat-log true false 'feat(SC-228): combat log' 'no ref here')" >"$AF_PULLS_OPEN"
out="$(af_run audit --fix)"
check "B PR on sc/228-... moves SC-228's card (#442)" "FIX #442: Backlog -> In progress (open PR #446, branch sc/228-combat-log)" "$out"
check "B worktree sc/226-... moves SC-226's card (#443), not issue #226" "FIX #443: Backlog -> In progress (live worktree .claude/worktrees/sc-226, branch sc/226-inventory)" "$out"
check "B #226 untouched" "Backlog" "$(af_status 226)"
check_rc "B no issue created" 0 "$(af_n 'issue-create')"
check_rc "B moves under the limit carry no over-WIP comment" 0 "$(af_n 'rest:comment')"
af_teardown

# --- C. a task id that matches two cards is ambiguous: never guessed ---
af_setup pr; af_cfg methodology.maxInProgress 5
af_items "442:Backlog:SC-228: combat log" "450:Backlog:SC-228 follow-up"
af_worktree sc-228 sc/228-x
out="$(af_run audit --fix)"
check_rc "C ambiguous id: no edit" 0 "$(af_n 'item-edit')"
check "C ambiguous id: reported as a discrepancy instead" "branch sc/228-x) has no issue" "$out"
af_teardown

# --- D. the time budget bounds the pass: past it, no more moves, one note ---
af_setup pr; af_cfg methodology.maxInProgress 5
af_items "10:Backlog" "11:Backlog"; af_worktree 10 fx/10-a; af_worktree 11 fx/11-b; af_seen 10 11
out="$(BOARD_AUDIT_BUDGET_SECONDS=0 af_run audit --fix)"
check "D budget spent: a note says the rest waits for the next tick" "NOTE: audit time budget (0s) reached" "$out"
check_rc "D budget spent: no moves" 0 "$(af_n 'item-edit')"
check "D budget spent is not a failure" "rc=0" "$out"
out="$(af_run audit --fix)"
check "D default budget: both moves happen" "FIX #11: Backlog -> In progress" "$out"
af_teardown

# --- E. board.sh remove N deletes the card (issue stays), clears the cache entry ---
af_setup pr; af_items "10:Backlog" "11:In progress"
out="$(af_run remove 10)"
check "E remove: confirmation line" "removed #10 from the board (the issue itself is unchanged)" "$out"
check "E remove: exit 0" "rc=0" "$out"
check "E remove: the card is gone" "MISSING" "$(af_status 10)"
check "E remove: the other card stays" "In progress" "$(af_status 11)"
check_rc "E remove: one item-delete for the right item" 1 "$(af_n 'item-delete ITEM_10')"
check_absent "E remove: the cache no longer lists #10" '"10"' "$(cat "$AQ/.claude/board-cache.json" 2>/dev/null)"
check_rc "E remove: no issue was closed or edited" 0 "$(( $(af_n 'rest:patch') + $(af_n 'item-edit') ))"
out="$(af_run remove 77)"
check "E remove: a number not on the board is an error" "#77 is not on the board" "$out"
check "E remove: exit 1" "rc=1" "$out"
out="$(af_run remove)"
check "E remove: no number is a usage error" "usage: board.sh remove" "$out"
check "E remove: usage exit 2" "rc=2" "$out"
out="$(af_run remove abc)"
check "E remove: a non-number is a usage error" "usage: board.sh remove" "$out"
AF_DELETE_FAIL=1 out="$(AF_DELETE_FAIL=1 af_run remove 11)"
check "E remove: a failed delete says so" "ERROR: could not remove #11" "$out"
check "E remove: failed delete exit 1" "rc=1" "$out"
af_teardown

# --- F. docs ---
BN="$(cat "$PLUGIN/skills/build-next/SKILL.md")"
BS="$(cat "$PLUGIN/skills/board/SKILL.md")"
RD="$(cat "$PLUGIN/README.md")"
check "F build-next: the audit never files issues" "never creates an issue" "$BN"
check "F build-next: the audit never moves over WIP" "never moves a card over the WIP limit" "$BN"
check "F board skill documents remove" "board.sh remove" "$BS"
check "F README documents remove" "board.sh remove" "$RD"
check "F board.sh usage lists remove" "board.sh remove <issue#>" "$(cat "$PLUGIN/scripts/board.sh")"

# --- G. register-first title for scoped commit-msg hooks; review passes for every orchestrator PR ---
IT="$(cat "$PLUGIN/skills/implement-task/SKILL.md")"
check "G implement-task: an empty registration commit title that passes scope-checking hooks" 'git commit --allow-empty -m "chore: register <task-id> (#N)"' "$IT"
check "G implement-task: why the scope is dropped" "an empty commit changes no scope" "$IT"
check "G implement-task: follow the hook's own message when it refuses" "follow the hook's message" "$IT"
check "G implement-task: every orchestrator PR needs both tagged passes before merge" "needs the two tagged review passes (spec-compliance, code-quality) recorded before merge" "$IT"
check "G build-next: same rule up front" "needs the two tagged review passes (spec-compliance, code-quality) recorded before merge" "$BN"
