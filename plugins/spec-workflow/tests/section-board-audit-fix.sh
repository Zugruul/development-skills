#!/usr/bin/env bash
# section-board-audit-fix.sh -- sourced by run-tests.sh; do not run standalone.
# Task #564: `board.sh audit --fix` reconciles the board with live work, `--if-due` rate-limits it,
# and the API budget is exact (one board read per audit, REST PR lists, moves through board.sh move).
# Fake gh: fixtures/fake-gh-audit.py (mutable board + exact call log). Real git worktrees.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
# shellcheck source=plugins/spec-workflow/tests/_audit-fix-lib.sh
source "$HERE/_audit-fix-lib.sh"
echo "== board.sh audit --fix (#564) =="

# --- A. report-only lists what --fix would change and mutates nothing ---
af_setup pr; af_items "10:Backlog"; af_worktree 10 fx/10-widget; af_seen 10
out="$(af_run audit)"
check "A names the change --fix would make" "WOULD FIX #10: Backlog -> In progress (live worktree" "$out"
check "A exits 1 (discrepancy)" "rc=1" "$out"
check_rc "A no mutation in report mode" 0 "$(af_n 'item-edit')"
check_rc "A no GraphQL command (gh pr list) used" 0 "$(af_n 'GRAPHQL-CMD')"
check_rc "A no unexpected gh call" 0 "$(af_n 'UNEXPECTED')"
check_rc "A one REST open-PR list" 1 "$(af_n 'rest:pulls-open')"
check_rc "A one board read (fields + items)" 1 "$(af_n 'graphql:items')"
check_rc "A board read field query" 1 "$(af_n 'graphql:fields')"
af_teardown

# --- B. worktree, Backlog card, at the WIP limit -> In progress with --over-wip, flagged ---
af_setup pr; af_items "10:Backlog" "11:In progress"; af_worktree 10 fx/10-widget; af_worktree 11 fx/11-other; af_seen 10 11
out="$(af_run audit --fix)"
check "B prints the change" "FIX #10: Backlog -> In progress (live worktree .claude/worktrees/10, branch fx/10-widget)" "$out"
check "B exits 0" "rc=0" "$out"
check "B card is In progress" "In progress" "$(af_status 10)"
check "B over-WIP is reported by the move" "OVER WIP" "$out"
check "B summary" "AUDIT --fix: 1 change(s)" "$out"
check_rc "B exactly one status edit" 1 "$(af_n 'item-edit')"
check_rc "B exactly one over-WIP REST comment" 1 "$(af_n 'rest:comment')"
check_rc "B one board read for the whole audit (the move reuses the snapshot under the held mutex)" 1 "$(af_n 'graphql:items')"
check_rc "B REST open list" 1 "$(af_n 'rest:pulls-open')"
check_rc "B REST closed list" 1 "$(af_n 'rest:pulls-closed')"
check_rc "B no GraphQL command" 0 "$(af_n 'GRAPHQL-CMD')"
check_rc "B total calls" 6 "$(af_total)"
check_rc "B the admission mutex is released" 0 "$([[ -d "$AQ/.claude/board-wip.lock" ]] && echo 1 || echo 0)"
: >"$AF_LOG"
out="$(af_run audit --fix)"
check "B second run reports no changes" "AUDIT --fix: 0 change(s)" "$out"
check_rc "B second run: no mutation" 0 "$(( $(af_n 'item-edit') + $(af_n 'rest:comment') ))"
check_rc "B second run: one board read" 1 "$(af_n 'graphql:items')"
af_teardown

# --- C. under the limit: no over-WIP comment ---
af_setup pr; af_cfg methodology.maxInProgress 5; af_items "10:Backlog"; af_worktree 10 fx/10-widget; af_seen 10
out="$(af_run audit --fix)"
check "C moved" "FIX #10: Backlog -> In progress" "$out"
check_rc "C no over-WIP comment under the limit" 0 "$(af_n 'rest:comment')"
af_teardown

# --- D. open PRs: a draft keeps In progress, a ready PR is In review (PR mode signals) ---
af_setup pr; af_cfg methodology.maxInProgress 5
af_items "14:In progress" "15:Backlog"
af_worktree 14 fx/14-bar; af_gate_pass 14; af_seen 14 15
printf '[%s,%s]' "$(af_pr 7 fx/14-bar false false 'Bar' 'Closes #14')" "$(af_pr 8 fx/15-baz true false 'Baz' 'Closes #15')" >"$AF_PULLS_OPEN"
out="$(af_run audit --fix)"
check "D ready PR -> In review" "FIX #14: In progress -> In review (open PR #7 marked ready, branch fx/14-bar)" "$out"
check "D draft PR, no worktree -> In progress" "FIX #15: Backlog -> In progress (open PR #8, branch fx/15-baz)" "$out"
check "D 14 is In review" "In review" "$(af_status 14)"
check "D 15 is In progress" "In progress" "$(af_status 15)"
check_rc "D still one REST open list" 1 "$(af_n 'rest:pulls-open')"
af_teardown

# --- E. merged PR -> QA only when the two-pass review guard allows it ---
af_setup pr; af_cfg methodology.maxInProgress 5
af_items "12:In review" "13:In review"; af_review_evidence 12
printf '[%s,%s]' "$(af_pr 20 fx/12-foo false true 'Foo' 'Closes #12')" "$(af_pr 21 fx/13-bar false true 'Bar' 'Closes #13')" >"$AF_PULLS_CLOSED"
out="$(af_run audit --fix)"
check "E merged with review evidence -> QA" "FIX #12: In review -> QA (merged PR #20, branch fx/12-foo)" "$out"
check "E merged without evidence prints the note" "NOTE #13: merged but review evidence missing — record it or use --accepted-by-user" "$out"
check "E 12 is QA" "QA" "$(af_status 12)"
check "E 13 stays In review" "In review" "$(af_status 13)"
check_rc "E only one edit (13 was not forced)" 1 "$(af_n 'item-edit')"
check "E exits 0 (a note is not a failure)" "rc=0" "$out"
af_teardown

# --- F. an open PR with no linked issue gets one through ensure-issue, never an invented link ---
af_setup pr; af_cfg methodology.maxInProgress 5
printf '[%s]' "$(af_pr 8 feature/zzz false false 'Add zzz' 'no ticket here')" >"$AF_PULLS_OPEN"
out="$(af_run audit --fix)"
check "F prints the new issue" "FIX: open PR #8 (branch feature/zzz) had no issue -> #900 (board.sh ensure-issue)" "$out"
check_rc "F one issue created, titled from the PR" 1 "$(af_n 'issue-create Add zzz')"
check "F link recorded locally" "feature/zzz" "$(cat "$AQ/.claude/audit-links.json")"
: >"$AF_LOG"
out="$(af_run audit --fix)"
check_rc "F second run creates nothing" 0 "$(af_n 'issue-create')"
check "F second run: no changes" "AUDIT --fix: 0 change(s)" "$out"
af_teardown

# --- G. work.type: local -- no PR calls; review telemetry says In review; merged commit says QA ---
af_setup local; af_cfg methodology.maxInProgress 5
af_items "15:In progress" "16:In review" "17:In progress"
af_worktree 15 fx/15-rev; af_gate_pass 15; af_seen 15
af_review_evidence 16
( cd "$AQ" && git commit -q --allow-empty -m "feat(16): the thing (#16)" )
python3 "$PLUGIN/scripts/telemetry.py" "$AQ" record '{"kind":"review-round","task":"15","round":1,"verdict":"changes","ts":"2026-01-01T00:00:00Z"}' >/dev/null
( cd "$AQ" && git commit -q --allow-empty -m "feat(17): other thing (#17)" )
out="$(af_run audit --fix)"
check "G review telemetry + live worktree -> In review" "FIX #15: In progress -> In review (live worktree .claude/worktrees/15, branch fx/15-rev; review started)" "$out"
check "G squash commit on main + review evidence -> QA" "FIX #16: In review -> QA (merged: commit on main references #16)" "$out"
check "G merged but unreviewed -> note" "NOTE #17: merged but review evidence missing — record it or use --accepted-by-user" "$out"
check_rc "G local mode makes no PR calls" 0 "$(( $(af_n 'rest:pulls') ))"
check_rc "G local mode: edits are 15 and 16" 2 "$(af_n 'item-edit')"
af_teardown

# --- H. everything already right -> nothing changes, exit 0, one board read, no mutation ---
af_setup pr; af_cfg methodology.maxInProgress 5
af_items "10:In progress"; af_worktree 10 fx/10-widget
out="$(af_run audit --fix)"
check "H zero changes" "AUDIT --fix: 0 change(s)" "$out"
check_rc "H no mutation" 0 "$(( $(af_n 'item-edit') + $(af_n 'rest:comment') + $(af_n 'issue-create') ))"
check_rc "H total calls: 2 graphql + 2 REST lists" 4 "$(af_total)"
af_teardown

# --- M. (#564 review) a merge never overrides live work, and must be newer than the card's last move into work ---
af_setup local; af_cfg methodology.maxInProgress 5
af_items "30:In progress" "33:In progress" "34:In review" "35:In review" "37:In progress"
af_worktree 30 fx/30-again; af_seen 30
af_worktree 37 fx/37-gated; af_gate_pass 37
python3 "$PLUGIN/scripts/telemetry.py" "$AQ" record '{"kind":"gate","task":"37","ok":true,"ts":"2026-01-01T00:00:00Z"}' >/dev/null
af_accept 30; af_accept 33; af_accept 34; af_accept 35
( cd "$AQ" && git commit -q --allow-empty -m "feat(30): first round (#30)" && git commit -q --allow-empty -m "feat(33): old merge (#33)" \
    && git commit -q --allow-empty -m "test(34): follow-up tests (#34)" && git commit -q --allow-empty -m "docs(35): follow-up docs (#35)" \
    && git commit -q --allow-empty -m "chore(34): tidy (#34)" )
python3 "$PLUGIN/scripts/telemetry.py" "$AQ" record '{"kind":"transition","task":"33","from":"Backlog","to":"In progress","ts":"2999-01-01T00:00:00Z"}' >/dev/null
out="$(af_run audit --fix)"
check "M rework after QA: old merge + live worktree stays In progress" "In progress" "$(af_status 30)"
check_absent "M no QA move for the task with a live worktree" "FIX #30" "$out"
check "M a merge older than the last move into work is ignored" "In progress" "$(af_status 33)"
check "M test( follow-up commit does not move to QA" "In review" "$(af_status 34)"
check "M docs( follow-up commit does not move to QA" "In review" "$(af_status 35)"
check "M a green gate event alone does not pull a card to In review" "In progress" "$(af_status 37)"
check_rc "M no edits at all" 0 "$(af_n 'item-edit')"
af_teardown

af_setup pr; af_cfg methodology.maxInProgress 5
af_items "32:In progress" "36:QA"; af_worktree 36 fx/36-redo; af_seen 36
af_accept 32
printf '[%s]' "$(af_pr 40 fx/32-a true false 'Part A' 'Closes #32')" >"$AF_PULLS_OPEN"
printf '[%s,%s]' "$(af_pr 41 fx/32-b false true 'Part B' 'Closes #32')" "$(af_pr 42 fx/36-old false true 'Old' 'Closes #36')" >"$AF_PULLS_CLOSED"
out="$(af_run audit --fix)"
check "M split across two PRs, one open: stays In progress" "In progress" "$(af_status 32)"
check_absent "M no QA move for 32" "FIX #32" "$out"
check "M QA card with new work and an old merged PR is left alone" "QA" "$(af_status 36)"
af_teardown

# --- N. links record is pruned of branches that no longer exist; --if-due needs --fix ---
af_setup pr
printf '{"gone/branch": 901, "main": 902}' >"$AQ/.claude/audit-links.json"
out="$(af_run audit --fix)"
check_absent "N pruned: the deleted branch is forgotten" "gone/branch" "$(cat "$AQ/.claude/audit-links.json")"
out="$(af_run audit --if-due)"
check "N --if-due without --fix is a usage error" "usage: board.sh audit" "$out"
check "N exit 2" "rc=2" "$out"
af_teardown

# --- O. a status flow shorter than 4 entries skips the position rules with a note ---
af_setup pr
python3 - "$AQ/.neural-network/project.yaml" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
open(p, "w").write(s.replace("statusFlow: [Backlog, In progress, In review, QA, Ready, Deployed]", "statusFlow: [Backlog, In progress, In review]"))
PY
af_items "10:Backlog"; af_worktree 10 fx/10-widget
out="$(af_run audit --fix)"
check "O short flow: a note, no crash" "NOTE: statusFlow has fewer than 4 statuses" "$out"
check_rc "O short flow: no edits" 0 "$(af_n 'item-edit')"
af_teardown

# --- I. --if-due: stamp, interval, rate limit ---
af_setup pr; af_items "10:Backlog"; af_worktree 10 fx/10-widget; af_seen 10
out="$(af_run audit --fix --if-due)"
check "I first run is due" "FIX #10:" "$out"
check_rc "I stamp written" 0 "$([[ -s "$AQ/.claude/audit-stamp" ]] && echo 0 || echo 1)"
: >"$AF_LOG"
out="$(af_run audit --fix --if-due)"
check "I fresh stamp -> one skip line" "audit not due" "$out"
check_rc "I not due costs zero gh calls" 0 "$(af_total)"
check_rc "I not due is one line" 1 "$(grep -c . <<<"${out%rc=*}")"
echo $(( $(date +%s) - 700 )) >"$AQ/.claude/audit-stamp"
out="$(af_run audit --fix --if-due)"
check "I 11 minutes old (default 10) -> runs" "AUDIT --fix: 0 change(s)" "$out"
af_cfg methodology.auditIntervalMinutes 60
echo $(( $(date +%s) - 700 )) >"$AQ/.claude/audit-stamp"; : >"$AF_LOG"
out="$(af_run audit --fix --if-due)"
check "I configured interval 60 -> not due at 11 min" "audit not due" "$out"
check_rc "I zero calls again" 0 "$(af_total)"
af_cfg methodology.auditIntervalMinutes 1
echo $(( $(date +%s) - 700 )) >"$AQ/.claude/audit-stamp"
printf '{"op":"move","issue":"10","status":"In progress"}\n' >"$AQ/.claude/board-queue.jsonl"; : >"$AF_LOG"
out="$(af_run audit --fix --if-due)"
check "I queued entries but no persisted rate limit -> still runs" "AUDIT --fix:" "$out"
rm -f "$AQ/.claude/board-queue.jsonl"
echo $(( $(date +%s) - 700 )) >"$AQ/.claude/audit-stamp"
echo $(( $(date +%s) + 600 )) >"$AQ/.claude/rate-limit-reset"; : >"$AF_LOG"
out="$(af_run audit --fix --if-due)"
check "I persisted reset in the future -> skip, one line" "audit skipped: rate-limited until" "$out"
check_rc "I rate-limited costs zero gh calls" 0 "$(af_total)"
echo $(( $(date +%s) - 5 )) >"$AQ/.claude/rate-limit-reset"; : >"$AF_LOG"
out="$(af_run audit --fix --if-due)"
check "I persisted reset in the past -> runs" "AUDIT --fix:" "$out"
af_teardown

# --- P. a rate limit anywhere persists its reset time (.claude/rate-limit-reset) ---
af_setup pr
export AF_GRAPHQL_FAIL=ratelimit
out="$(af_run list)"
check "P a rate-limited read says so" "RATE-LIMITED" "$out"
check_rc "P reset time persisted" 0 "$([[ -s "$AQ/.claude/rate-limit-reset" ]] && echo 0 || echo 1)"
check_rc "P and it is in the future" 0 "$([[ "$(cat "$AQ/.claude/rate-limit-reset")" -gt "$(date +%s)" ]] && echo 0 || echo 1)"
unset AF_GRAPHQL_FAIL
echo $(( $(date +%s) - 700 )) >"$AQ/.claude/audit-stamp"; : >"$AF_LOG"
out="$(af_run audit --fix --if-due)"
check "P the audit tick skips while that reset is ahead" "audit skipped: rate-limited until" "$out"
check_rc "P with zero gh calls" 0 "$(af_total)"
af_teardown

# --- Q. repeated board-wide read failures back off: after 3, no board read for 10 minutes ---
af_setup pr
export AF_GRAPHQL_FAIL=502
for _ in 1 2 3; do af_run list >/dev/null; done
check_rc "Q three failing reads cost three calls" 3 "$(af_n 'graphql:fail')"
t3="$(af_total)"
out="$(af_run list)"; out2="$(af_run audit --fix)"
check_rc "Q the 4th and 5th read are skipped: no further gh call at all" "$t3" "$(af_total)"
check "Q list says it is backing off" "board read skipped" "$out"
check "Q audit says it is backing off" "board read skipped" "$out2"
check_rc "Q the backoff state is persisted" 0 "$([[ -s "$AQ/.claude/board-read-backoff" ]] && echo 0 || echo 1)"
python3 - "$AQ/.claude/board-read-backoff" <<'PY'
import json, sys, time
d = json.load(open(sys.argv[1])); d["until"] = int(time.time()) - 1
json.dump(d, open(sys.argv[1], "w"))
PY
af_run list >/dev/null
check_rc "Q after the window one more attempt is made" 4 "$(af_n 'graphql:fail')"
unset AF_GRAPHQL_FAIL
python3 - "$AQ/.claude/board-read-backoff" <<'PY'
import json, sys, time
d = json.load(open(sys.argv[1])); d["until"] = int(time.time()) - 1
json.dump(d, open(sys.argv[1], "w"))
PY
af_items "10:Backlog"
af_run list >/dev/null
check_rc "Q a successful read clears the state" 0 "$([[ -e "$AQ/.claude/board-read-backoff" ]] && echo 1 || echo 0)"
af_teardown

# --- R. the fix pass holds the admission mutex; a busy mutex skips the pass with a note, never blocks work ---
af_setup pr; af_items "10:Backlog"; af_worktree 10 fx/10-widget; af_seen 10
mkdir -p "$AQ/.claude/board-wip.lock"; sleep 30 & AF_SLEEPER=$!; echo "$AF_SLEEPER" >"$AQ/.claude/board-wip.lock/pid"
out="$(BOARD_WIP_MUTEX_MAX_WAIT_ITERS=2 af_run audit --fix)"
kill "$AF_SLEEPER" 2>&1 | head -1; wait "$AF_SLEEPER" 2>&1 | head -1
check "R busy mutex: a note" "NOTE: admission mutex busy" "$out"
check "R busy mutex: exit 0" "rc=0" "$out"
check_rc "R busy mutex: no mutation" 0 "$(af_n 'item-edit')"
af_teardown

# --- S. gate fingerprint ignores the audit's runtime files even when the repo does not gitignore them ---
SD="$(mktemp -d)"; ( cd "$SD" && git init -q . && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m i )
s1="$(cd "$SD" && bash "$PLUGIN/scripts/tree-state.sh")"
mkdir -p "$SD/.claude"; for f in audit-stamp audit-links.json rate-limit-reset board-read-backoff; do echo 1 >"$SD/.claude/$f"; done
s2="$(cd "$SD" && bash "$PLUGIN/scripts/tree-state.sh")"
[[ "$s1" == "$s2" ]] && r=SAME || r=DIFFER
check "S tree-state ignores audit/rate-limit/backoff files" "SAME" "$r"
rm -rf "$SD"

# --- T. the shared audit snapshot is trusted only from the live audit that holds the mutex (fail closed) ---
_t_setup() { # board at the WIP limit (11 In progress), 10 in Backlog; forged.json says nobody is In progress
    af_setup pr; af_items "11:In progress" "10:Backlog"; af_seen 10
    echo '{"items":[{"id":"ITEM_10","status":"Backlog","content":{"number":10,"type":"Issue"}}],"totalCount":1}' >"$AQ/forged.json"
}
_t_holder() { # token-in-env [snapshot-file] -> a live shell that owns the lock (token "good") and runs move with that snapshot
    ( cd "$AQ" && PATH="$FGH:$PATH" BOARD_WIP_MUTEX_MAX_WAIT_ITERS=2 BT="$1" SNAPSRC="${2:-forged.json}" PLUGIN="$PLUGIN" bash -c '
        lock="$(pwd -P)/.claude/board-wip.lock"; mkdir -p "$lock"; echo $$ >"$lock/pid"; echo good >"$lock/audit-token"
        cp "$SNAPSRC" "$lock/audit-snap.json"
        BOARD_AUDIT_SNAP_FILE="$lock/audit-snap.json" BOARD_AUDIT_TOKEN="$BT" bash "$PLUGIN/scripts/board.sh" move 10 "In progress" 2>&1
        echo "rc=$?"; rm -rf "$lock"' )
}
_t_setup
out="$(cd "$AQ" && PATH="$FGH:$PATH" BOARD_AUDIT_SNAP_FILE="$AQ/forged.json" BOARD_AUDIT_TOKEN=x bash "$PLUGIN/scripts/board.sh" move 10 "In progress" 2>&1; echo "rc=$?")"
check "T forged snapshot file: warned and ignored" "WARN" "$out"
check_rc "T forged snapshot at the limit: refused, no edit" 0 "$(af_n 'item-edit')"
check_rc "T forged snapshot: the normal path read the board itself" 1 "$(af_n 'graphql:items')"
af_teardown
_t_setup
out="$(cd "$AQ" && PATH="$FGH:$PATH" BOARD_AUDIT_SNAP_FILE=/dev/null BOARD_AUDIT_TOKEN=x bash "$PLUGIN/scripts/board.sh" move 10 "In progress" 2>&1; echo "rc=$?")"
check "T /dev/null: warned and ignored" "WARN" "$out"
check_rc "T /dev/null: no edit at the limit" 0 "$(af_n 'item-edit')"
check_rc "T /dev/null: one fresh strict read" 1 "$(af_n 'graphql:items')"
af_teardown
_t_setup
lock="$AQ/.claude/board-wip.lock"; mkdir -p "$lock"; cp "$AQ/forged.json" "$lock/audit-snap.json"; echo good >"$lock/audit-token"
true & dead=$!; wait "$dead"; echo "$dead" >"$lock/pid"
out="$(cd "$AQ" && PATH="$FGH:$PATH" BOARD_AUDIT_SNAP_FILE="$(cd "$AQ" && pwd -P)/.claude/board-wip.lock/audit-snap.json" BOARD_AUDIT_TOKEN=good bash "$PLUGIN/scripts/board.sh" move 10 "In progress" 2>&1; echo "rc=$?")"
check "T stale snapshot, dead holder: warned and ignored" "WARN" "$out"
check_rc "T stale snapshot, dead holder: no edit at the limit" 0 "$(af_n 'item-edit')"
check_rc "T a SIGKILL leftover (dead pid + snapshot + token) is cleaned away" 0 "$([[ -e "$lock/audit-snap.json" || -e "$lock/audit-token" || -d "$lock" ]] && echo 1 || echo 0)"
af_teardown
_t_setup
out="$(_t_holder bad)"
check "T wrong token: warned and ignored" "WARN" "$out"
check_rc "T wrong token: no edit (normal path found the mutex busy)" 0 "$(af_n 'item-edit')"
af_teardown
_t_setup
out="$(_t_holder good)"
check_rc "T live holder, right token and path: the snapshot is honoured" 1 "$(af_n 'item-edit')"
check_rc "T honoured snapshot costs no board read" 0 "$(af_n 'graphql:items')"
check_rc "T the move's children do not inherit the audit's trust variables" 0 "$(af_leaks)"
af_teardown
_t_setup
printf 'not json' >"$AQ/bad.json"; echo '{"x":1,"totalCount":0}' >"$AQ/noitems.json"
out="$(_t_holder good bad.json)"
check "T right path and token but not JSON: warned and ignored" "WARN" "$out"
check_rc "T not JSON: no edit" 0 "$(af_n 'item-edit')"
: >"$AF_LOG"
out="$(_t_holder good noitems.json)"
check "T right path and token but no items list: warned and ignored" "WARN" "$out"
check_rc "T no items list: no edit" 0 "$(af_n 'item-edit')"
af_teardown
_t_setup
lock="$AQ/.claude/board-wip.lock"; mkdir -p "$lock"; cp "$AQ/forged.json" "$lock/audit-snap.json"; echo good >"$lock/audit-token"
sleep 30 & sl=$!; echo "$sl" >"$lock/pid"
out="$(cd "$AQ" && PATH="$FGH:$PATH" BOARD_WIP_MUTEX_MAX_WAIT_ITERS=2 BOARD_AUDIT_SNAP_FILE="$(cd "$AQ" && pwd -P)/.claude/board-wip.lock/audit-snap.json" BOARD_AUDIT_TOKEN=good bash "$PLUGIN/scripts/board.sh" move 10 "In progress" 2>&1; echo "rc=$?")"
kill "$sl" 2>&1 | head -1; wait "$sl" 2>&1 | head -1
check "T live holder that is not an ancestor: warned and ignored" "WARN" "$out"
check_rc "T live non-ancestor holder: no edit" 0 "$(af_n 'item-edit')"
af_teardown
_t_setup
out="$(cd "$AQ" && PATH="$FGH:$PATH" env _FLUSH_HOLDS_WIP=1 _FLUSH_USE_SNAP=1 _FLUSH_WIP_FAILED=0 _FLUSH_SNAP_FAILED=0 \
    _FLUSH_SNAP='{"items":[{"id":"ITEM_10","status":"Backlog","content":{"number":10,"type":"Issue"}}],"totalCount":1}' \
    bash "$PLUGIN/scripts/board.sh" move 10 "In progress" 2>&1; echo "rc=$?")"
check_rc "T inherited _FLUSH_* variables at the limit: no edit" 0 "$(af_n 'item-edit')"
check_rc "T inherited _FLUSH_* variables: the move read the board itself" 1 "$(af_n 'graphql:items')"
check_absent "T inherited _FLUSH_* variables: not moved" "moved #10" "$out"
af_teardown

# --- V. an incomplete snapshot (rc 3) never counts toward the read-failure backoff ---
af_setup pr; af_items "10:Backlog"; af_worktree 10 fx/10-widget; af_seen 10
export AF_NO_STATUS=1
for _ in 1 2 3 4; do af_run audit --fix >/dev/null; done
check_rc "V rc 3 four times: every attempt still reads (4 field queries)" 4 "$(af_n 'graphql:fields')"
check_rc "V rc 3 leaves no backoff state" 0 "$([[ -s "$AQ/.claude/board-read-backoff" ]] && echo 1 || echo 0)"
unset AF_NO_STATUS
af_teardown

# --- W. an inherited _GUARDS_DONE never skips the move guards ---
af_setup pr; af_cfg methodology.maxInProgress 5; af_items "10:In review" "11:In progress"
out="$(cd "$AQ" && PATH="$FGH:$PATH" _GUARDS_DONE="10:QA" bash "$PLUGIN/scripts/board.sh" move 10 QA 2>&1; echo "rc=$?")"
check "W QA with _GUARDS_DONE set: the review guard still refuses" "BLOCKED" "$out"
check_rc "W QA: no edit" 0 "$(af_n 'item-edit')"
out="$(cd "$AQ" && PATH="$FGH:$PATH" _GUARDS_DONE="11:In review" bash "$PLUGIN/scripts/board.sh" move 11 "In review" 2>&1; echo "rc=$?")"
check "W In review with _GUARDS_DONE set: the gate guard still refuses" "BLOCKED" "$out"
check_rc "W In review: no edit" 0 "$(af_n 'item-edit')"
af_teardown

# --- U. a successful strict read clears the read-failure backoff; rc 3 never counts toward it ---
af_setup pr; af_items "10:Backlog"; af_seen 10
printf '{"fails":2,"until":0}' >"$AQ/.claude/board-read-backoff"
af_run move 10 "In progress" --over-wip "test" >/dev/null
check_rc "U a counted move's strict read clears the backoff" 0 "$([[ -e "$AQ/.claude/board-read-backoff" ]] && echo 1 || echo 0)"
af_teardown

# --- J. usage ---
af_setup pr
out="$(af_run audit --bogus)"
check "J unknown option -> usage" "usage: board.sh audit" "$out"
check "J exit 2" "rc=2" "$out"
af_teardown

# --- K. config key auditIntervalMinutes: schema, validator ---
KD="$(mktemp -d)"; mkdir -p "$KD/.neural-network"; cp "$FIX/valid.project.yaml" "$KD/.neural-network/project.yaml"
check "K schema defines the key" "auditIntervalMinutes" "$(cat "$PLUGIN/schemas/project-config.schema.json")"
python3 "$PLUGIN/scripts/config.py" "$KD" set methodology.auditIntervalMinutes 5 >/dev/null
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$KD/.neural-network/project.yaml" 2>&1; echo "rc=$?")"
check "K 5 is valid" "rc=0" "$out"
for bad in 0 -3 '"x"' true 1.5; do
    python3 "$PLUGIN/scripts/config.py" "$KD" set methodology.auditIntervalMinutes "$bad" >/dev/null
    out="$(python3 "$PLUGIN/scripts/validate-config.py" "$KD/.neural-network/project.yaml" 2>&1; echo "rc=$?")"
    check "K rejects $bad" "methodology.auditIntervalMinutes" "$out"
done
rm -rf "$KD"

# --- L. local state + skills + docs ---
check "L manifest ignores the stamp" ".claude/audit-stamp" "$(cat "$PLUGIN/scripts/local-state.manifest")"
check "L manifest ignores the link record" ".claude/audit-links.json" "$(cat "$PLUGIN/scripts/local-state.manifest")"
check "L build-next runs the audit tick" "board.sh audit --fix --if-due" "$(cat "$PLUGIN/skills/build-next/SKILL.md")"
check "L board skill runs the audit tick" "board.sh audit --fix --if-due" "$(cat "$PLUGIN/skills/board/SKILL.md")"
check "L README documents the key" "auditIntervalMinutes" "$(cat "$PLUGIN/README.md")"
