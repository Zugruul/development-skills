#!/usr/bin/env bash
# section-board-queue.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
#
# Covers issue #77 (board-queue rate-limit resilience) and #84 (adopt).
# Fake gh understands: issue create / project item-add / project item-list /
# project item-edit / api rate_limit / issue view. All rate-limit failures
# are simulated by writing "API rate limit exceeded for installation ID 123."
# to stderr and exiting 1 -- the real GitHub REST/GraphQL rate-limit message
# always contains "rate limit" (case-insensitive), which is exactly what
# board-queue.sh's _rate_limited() matches on.
echo "== board.sh rate-limit queue (#77) + adopt (#84): fake gh =="

_qsetup() { # -> sets BQ (fixture repo dir) and FGH (fake-gh dir on PATH)
    BQ="$(mktemp -d)"; mkdir -p "$BQ/.claude"
    cp "$FIX/valid.project.yaml" "$BQ/.claude/project.yaml"
    FGH="$(mktemp -d)"
    cat >"$FGH/gh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
echo "$*" >>"$FAKE_GH_LOG"
case "$1 $2" in
    "issue create")
        echo "https://github.com/fixture-owner/fixture-project/issues/${FAKE_GH_ISSUE_NUM:-900}"
        ;;
    "project item-add")
        if [[ "${FAKE_GH_ITEM_ADD_RATE_LIMIT:-0}" == "1" ]]; then
            echo "API rate limit exceeded for installation ID 123." >&2
            exit 1
        fi
        ;;
    "project item-list")
        n=$(( $(cat "$FAKE_GH_LIST_CALLCOUNT" 2>/dev/null || echo 0) + 1 ))
        echo "$n" >"$FAKE_GH_LIST_CALLCOUNT"
        if [[ "${FAKE_GH_ITEM_LIST_RATE_LIMIT:-0}" == "1" ]]; then
            echo "API rate limit exceeded for installation ID 123." >&2
            exit 1
        fi
        if [[ "${FAKE_GH_ITEM_VISIBLE:-1}" == "1" ]]; then
            echo "{\"items\":[{\"id\":\"ITEM_${FAKE_GH_ISSUE_NUM:-900}\",\"content\":{\"number\":${FAKE_GH_ISSUE_NUM:-900}},\"status\":\"${FAKE_GH_ITEM_STATUS:-Backlog}\"}]}"
        else
            echo '{"items":[]}'
        fi
        ;;
    "project item-edit")
        n=$(( $(cat "$FAKE_GH_EDIT_CALLCOUNT" 2>/dev/null || echo 0) + 1 ))
        echo "$n" >"$FAKE_GH_EDIT_CALLCOUNT"
        if [[ "$n" -ge "${FAKE_GH_EDIT_RATE_LIMIT_FROM:-999}" ]]; then
            echo "API rate limit exceeded for installation ID 123." >&2
            exit 1
        fi
        echo "edited"
        ;;
    "api rate_limit")
        echo "{\"rate\":{\"limit\":5000,\"remaining\":0,\"reset\":${FAKE_GH_RESET_EPOCH:-1735689600}}}"
        ;;
    "issue view")
        if [[ "${FAKE_GH_ISSUE_VIEW_RATE_LIMIT:-0}" == "1" ]]; then
            echo "API rate limit exceeded for installation ID 123." >&2
            exit 1
        fi
        printf '#%s [OPEN] fixture issue\n\nbody\n(no comments)' "${FAKE_GH_ISSUE_NUM:-900}"
        ;;
    *) echo "fake gh: unexpected: $*" >&2; exit 1 ;;
esac
FAKE
    chmod +x "$FGH/gh"
}

# --- (a) rate-limited GraphQL mutation (move) -> queued, exit 0, QUEUED message ---
_qsetup
LOG="$(mktemp)"; EDITCC="$(mktemp)"
out="$(cd "$BQ" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG" FAKE_GH_EDIT_CALLCOUNT="$EDITCC" FAKE_GH_LIST_CALLCOUNT="$(mktemp)" \
    FAKE_GH_ISSUE_NUM=801 FAKE_GH_ITEM_VISIBLE=1 \
    FAKE_GH_EDIT_RATE_LIMIT_FROM=1 FAKE_GH_RESET_EPOCH=1735689600 \
    bash "$PLUGIN/scripts/board.sh" move 801 "In progress" 2>&1; echo "rc=$?")"
check "(a) rate-limited move: QUEUED message with reset time" "QUEUED (rate-limited until 2025-01-01T00:00:00Z): move #801 -> In progress" "$out"
check "(a) rate-limited move: exits 0 (loop keeps going)" "rc=0" "$out"
qf="$BQ/.claude/board-queue.jsonl"
if [[ -f "$qf" ]]; then echo "ok   (a) queue file created"; else echo "FAIL (a) queue file not created"; fails=$((fails + 1)); fi
check "(a) queue file: move op recorded" '"op": "move"' "$(cat "$qf" 2>/dev/null)"
check "(a) queue file: issue number recorded" '"issue": "801"' "$(cat "$qf" 2>/dev/null)"
check "(a) queue file: target status recorded" '"status": "In progress"' "$(cat "$qf" 2>/dev/null)"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC"

# --- (b) flush replays queued ops in order against a recovered fake gh ---
_qsetup
mkdir -p "$BQ/.claude"
printf '{"op":"prio","issue":"802","priority":"P1","ts":"2020-01-01T00:00:00Z"}\n' >"$BQ/.claude/board-queue.jsonl"
printf '{"op":"move","issue":"802","status":"In progress","ts":"2020-01-01T00:00:00Z"}\n' >>"$BQ/.claude/board-queue.jsonl"
LOG="$(mktemp)"; LISTCC="$(mktemp)"; EDITCC="$(mktemp)"
out="$(cd "$BQ" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG" FAKE_GH_LIST_CALLCOUNT="$LISTCC" FAKE_GH_EDIT_CALLCOUNT="$EDITCC" \
    FAKE_GH_ISSUE_NUM=802 FAKE_GH_ITEM_VISIBLE=1 FAKE_GH_ITEM_STATUS="Backlog" \
    bash "$PLUGIN/scripts/board.sh" flush 2>&1; echo "rc=$?")"
check "(b) flush: prio applied" "prio #802 -> P1" "$out"
check "(b) flush: move applied" "moved #802 -> In progress" "$out"
check "(b) flush: exits 0" "rc=0" "$out"
prio_line="$(grep -n "fixturePrio00" "$LOG" | head -1 | cut -d: -f1)"
status_line="$(grep -n "fixtureStatus0" "$LOG" | head -1 | cut -d: -f1)"
if [[ -n "$prio_line" && -n "$status_line" && "$prio_line" -lt "$status_line" ]]; then
    echo "ok   (b) flush: prio replayed before move (queue order preserved)"
else
    echo "FAIL (b) flush: expected prio (line $prio_line) before move (line $status_line)"
    fails=$((fails + 1))
fi
if [[ -s "$BQ/.claude/board-queue.jsonl" ]]; then
    echo "FAIL (b) flush: queue file should be empty after a full successful replay"
    fails=$((fails + 1))
else
    echo "ok   (b) flush: queue file emptied after full replay"
fi
rm -rf "$BQ" "$FGH" "$LOG" "$LISTCC" "$EDITCC"

# --- (c) flush idempotence: move whose target status already holds is skipped ---
_qsetup
mkdir -p "$BQ/.claude"
printf '{"op":"move","issue":"803","status":"In progress","ts":"2020-01-01T00:00:00Z"}\n' >"$BQ/.claude/board-queue.jsonl"
LOG="$(mktemp)"; LISTCC="$(mktemp)"; EDITCC="$(mktemp)"
out="$(cd "$BQ" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG" FAKE_GH_LIST_CALLCOUNT="$LISTCC" FAKE_GH_EDIT_CALLCOUNT="$EDITCC" \
    FAKE_GH_ISSUE_NUM=803 FAKE_GH_ITEM_VISIBLE=1 FAKE_GH_ITEM_STATUS="In progress" \
    bash "$PLUGIN/scripts/board.sh" flush 2>&1; echo "rc=$?")"
check "(c) flush idempotence: skip message when target already holds" "flush: skip move #803 (already In progress)" "$out"
check_absent "(c) flush idempotence: no false 'moved' line" "moved #803" "$out"
check_absent "(c) flush idempotence: item-edit never invoked for the status field" "fixtureStatus0" "$(cat "$LOG")"
if [[ -s "$BQ/.claude/board-queue.jsonl" ]]; then
    echo "FAIL (c) flush idempotence: queue should be emptied (the skip still consumes the op)"
    fails=$((fails + 1))
else
    echo "ok   (c) flush idempotence: queue emptied"
fi
rm -rf "$BQ" "$FGH" "$LOG" "$LISTCC" "$EDITCC"

# --- (d) flush re-queues the remainder when the limit re-trips mid-replay ---
_qsetup
mkdir -p "$BQ/.claude"
printf '{"op":"prio","issue":"804","priority":"P1","ts":"2020-01-01T00:00:00Z"}\n' >"$BQ/.claude/board-queue.jsonl"
printf '{"op":"move","issue":"804","status":"In progress","ts":"2020-01-01T00:00:00Z"}\n' >>"$BQ/.claude/board-queue.jsonl"
LOG="$(mktemp)"; LISTCC="$(mktemp)"; EDITCC="$(mktemp)"
out="$(cd "$BQ" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG" FAKE_GH_LIST_CALLCOUNT="$LISTCC" FAKE_GH_EDIT_CALLCOUNT="$EDITCC" \
    FAKE_GH_ISSUE_NUM=804 FAKE_GH_ITEM_VISIBLE=1 FAKE_GH_ITEM_STATUS="Backlog" \
    FAKE_GH_EDIT_RATE_LIMIT_FROM=2 FAKE_GH_RESET_EPOCH=1735689600 \
    bash "$PLUGIN/scripts/board.sh" flush 2>&1; echo "rc=$?")"
check "(d) flush re-queue: first op (prio) still applied" "prio #804 -> P1" "$out"
check "(d) flush re-queue: second op (move) reports QUEUED, not a failure" "QUEUED (rate-limited until 2025-01-01T00:00:00Z): move #804" "$out"
check "(d) flush re-queue: exits 0 (loop keeps going)" "rc=0" "$out"
remainder="$(cat "$BQ/.claude/board-queue.jsonl" 2>/dev/null)"
check "(d) flush re-queue: the move op is written back verbatim" '"op":"move","issue":"804","status":"In progress"' "$remainder"
check_absent "(d) flush re-queue: the already-applied prio op is NOT re-queued" '"op":"prio"' "$remainder"
rm -rf "$BQ" "$FGH" "$LOG" "$LISTCC" "$EDITCC"

# --- (e) read ops (list/show) fail fast on a rate-limited API: reset time, nonzero exit, no traceback ---
_qsetup
LOG="$(mktemp)"; LISTCC="$(mktemp)"
out="$(cd "$BQ" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG" FAKE_GH_LIST_CALLCOUNT="$LISTCC" \
    FAKE_GH_ITEM_LIST_RATE_LIMIT=1 FAKE_GH_RESET_EPOCH=1735689600 \
    bash "$PLUGIN/scripts/board.sh" list 2>&1; echo "rc=$?")"
check "(e) list: RATE-LIMITED fail-fast message with reset time" "RATE-LIMITED until 2025-01-01T00:00:00Z" "$out"
check "(e) list: hint that work continues / mutations queue / retry after reset" "work continues; mutations queue; retry reads after reset" "$out"
check "(e) list: exits nonzero" "rc=1" "$out"
check_absent "(e) list: no raw Python traceback leak" "Traceback" "$out"
check_absent "(e) list: no masked 'bad issue# or status' error" "bad issue# or status" "$out"
rm -f "$LOG" "$LISTCC"

LOG="$(mktemp)"
out="$(cd "$BQ" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG" FAKE_GH_ISSUE_VIEW_RATE_LIMIT=1 FAKE_GH_RESET_EPOCH=1735689600 \
    bash "$PLUGIN/scripts/board.sh" show 805 2>&1; echo "rc=$?")"
check "(e) show: RATE-LIMITED fail-fast message with reset time" "RATE-LIMITED until 2025-01-01T00:00:00Z" "$out"
check "(e) show: exits nonzero" "rc=1" "$out"
check_absent "(e) show: no raw Python traceback leak" "Traceback" "$out"
rm -rf "$BQ" "$FGH" "$LOG"

# --- (f) auto-flush: every board-READING command flushes a non-empty queue first ---
_qsetup
mkdir -p "$BQ/.claude"
printf '{"op":"prio","issue":"806","priority":"P2","ts":"2020-01-01T00:00:00Z"}\n' >"$BQ/.claude/board-queue.jsonl"
LOG="$(mktemp)"; LISTCC="$(mktemp)"; EDITCC="$(mktemp)"
out="$(cd "$BQ" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG" FAKE_GH_LIST_CALLCOUNT="$LISTCC" FAKE_GH_EDIT_CALLCOUNT="$EDITCC" \
    FAKE_GH_ISSUE_NUM=806 FAKE_GH_ITEM_VISIBLE=1 FAKE_GH_ITEM_STATUS="Backlog" \
    bash "$PLUGIN/scripts/board.sh" list 2>&1; echo "rc=$?")"
check "(f) list auto-flushes a non-empty queue first" "prio #806 -> P2" "$out"
check "(f) list still prints the normal list output after flushing" "Backlog" "$out"
check "(f) list: exits 0" "rc=0" "$out"
if [[ -s "$BQ/.claude/board-queue.jsonl" ]]; then
    echo "FAIL (f) auto-flush: queue should be empty after list ran"
    fails=$((fails + 1))
else
    echo "ok   (f) auto-flush: queue emptied by list"
fi
rm -rf "$BQ" "$FGH" "$LOG" "$LISTCC" "$EDITCC"

# --- (g) add: visibility-retry cap (3, not 10) + queue fallback instead of erroring ---
_qsetup
LOG="$(mktemp)"; LISTCC="$(mktemp)"
out="$(cd "$BQ" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG" FAKE_GH_LIST_CALLCOUNT="$LISTCC" \
    FAKE_GH_ISSUE_NUM=807 FAKE_GH_ITEM_VISIBLE=0 \
    bash "$PLUGIN/scripts/board.sh" add --type feature "never becomes visible" P1 2>&1; echo "rc=$?")"
check "(g) add: never-visible item queues instead of erroring" "QUEUED" "$out"
check "(g) add: QUEUED message names the issue" "item-add #807" "$out"
check "(g) add: exits 0 (no more false ERROR after a bounded retry)" "rc=0" "$out"
check_absent "(g) add: no false 'filed' success line" "filed feature" "$out"
n="$(cat "$LISTCC")"
if [[ "$n" -eq 3 ]]; then
    echo "ok   (g) add: visibility poll capped at exactly 3 attempts (was 10 pre-#77)"
else
    echo "FAIL (g) add: expected exactly 3 item-list polls, got $n"
    fails=$((fails + 1))
fi
qf="$BQ/.claude/board-queue.jsonl"
check "(g) add: queued op is add-finish for the created issue" '"op": "add-finish", "issue": "807"' "$(cat "$qf" 2>/dev/null)"
rm -rf "$BQ" "$FGH" "$LOG" "$LISTCC"

# --- (h) adopt (#84): adds an existing issue, idempotent, queues when rate-limited ---
_qsetup
LOG="$(mktemp)"; LISTCC="$(mktemp)"
out="$(cd "$BQ" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG" FAKE_GH_LIST_CALLCOUNT="$LISTCC" \
    FAKE_GH_ISSUE_NUM=808 FAKE_GH_ITEM_VISIBLE=0 \
    bash "$PLUGIN/scripts/board.sh" adopt 808 2>&1; echo "rc=$?")"
check "(h) adopt: adds the existing issue to the board" "adopted #808" "$out"
check "(h) adopt: exits 0" "rc=0" "$out"
check "(h) adopt: item-add invoked with the issue's URL" "project item-add 1 --owner fixture-owner --url https://github.com/fixture-owner/fixture-project/issues/808" "$(cat "$LOG")"

LOG2="$(mktemp)"
out="$(cd "$BQ" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG2" FAKE_GH_LIST_CALLCOUNT="$LISTCC" \
    FAKE_GH_ISSUE_NUM=808 FAKE_GH_ITEM_VISIBLE=1 \
    bash "$PLUGIN/scripts/board.sh" adopt 808 2>&1; echo "rc=$?")"
check "(h) adopt: idempotent re-run reports already-on-board, no duplicate add" "adopt #808: already on board" "$out"
check "(h) adopt: idempotent re-run exits 0" "rc=0" "$out"
check_absent "(h) adopt: idempotent re-run never calls item-add again" "project item-add" "$(cat "$LOG2")"
rm -f "$LOG" "$LOG2"

LOG3="$(mktemp)"
out="$(cd "$BQ" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG3" FAKE_GH_LIST_CALLCOUNT="$(mktemp)" \
    FAKE_GH_ISSUE_NUM=809 FAKE_GH_ITEM_VISIBLE=0 FAKE_GH_ITEM_ADD_RATE_LIMIT=1 FAKE_GH_RESET_EPOCH=1735689600 \
    bash "$PLUGIN/scripts/board.sh" adopt 809 2>&1; echo "rc=$?")"
check "(h) adopt: rate-limited item-add queues instead of failing" "QUEUED (rate-limited until 2025-01-01T00:00:00Z): adopt #809" "$out"
check "(h) adopt: rate-limited exits 0" "rc=0" "$out"
check "(h) adopt: queued op recorded" '"op": "adopt", "issue": "809"' "$(cat "$BQ/.claude/board-queue.jsonl" 2>/dev/null)"
rm -rf "$BQ" "$FGH" "$LISTCC" "$LOG3"

echo "== setup-project: .gitignore covers the board-queue feed =="
check "setup-project SKILL.md gitignores .claude/board-queue.jsonl" '.claude/board-queue.jsonl' "$(cat "$PLUGIN/skills/setup-project/SKILL.md")"
check "repo .gitignore covers .claude/board-queue.jsonl" '.claude/board-queue.jsonl' "$(cat "$(dirname "$(dirname "$PLUGIN")")/.gitignore")"

echo "== build-next SKILL.md: rate-limited board is not a stop condition (#77) =="
BNSKILL="$(cat "$PLUGIN/skills/build-next/SKILL.md" 2>/dev/null)"
check "build-next SKILL.md states a rate limit is never a stop condition" "A rate limit is never a stop condition" "$BNSKILL"
check "build-next SKILL.md mentions the queue file" ".claude/board-queue.jsonl" "$BNSKILL"
check "build-next SKILL.md mentions flush" "board.sh flush" "$BNSKILL"
check "build-next SKILL.md report step states still-queued ops" "still queued" "$BNSKILL"

echo "== plugin README documents the queue file + flush + adopt =="
README="$(cat "$PLUGIN/README.md" 2>/dev/null)"
check "README documents the queue file" ".claude/board-queue.jsonl" "$README"
check "README documents flush" "\`flush\`" "$README"
check "README documents adopt" "adopt <issue#>" "$README"
