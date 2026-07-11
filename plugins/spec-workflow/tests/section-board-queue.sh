#!/usr/bin/env bash
# section-board-queue.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
#
# Covers issue #77 (board-queue rate-limit resilience), #84 (adopt), and #90
# (probe-based detection of MASKED rate limits -- gh's real GraphQL-exhausted
# errors don't always contain "rate limit" text; e.g. "unknown owner type").
# Fake gh understands: issue create / project item-add / project item-list /
# project item-edit / api rate_limit / issue view. Plain rate-limit failures
# are simulated by emitting the honest-rate-limit corpus entry (real "rate
# limit" wording) to stderr and exiting 1 (text-matched fast path). MASKED
# rate-limit failures are simulated by emitting the masked-owner-type corpus
# entry (no "rate limit" text anywhere) -- board-queue.sh must fall back to
# probing `gh api rate_limit` and reading .resources.graphql.remaining to
# tell a masked exhaustion from a real error. FAKE_GH_GRAPHQL_REMAINING
# controls what that probe reports (default 0, so pre-#90 tests that never
# probe -- because they hit the text-matched fast path -- are unaffected).
# Both trigger strings are sourced from tests/fixtures/gh-failures/ (issue
# #91) instead of being inlined here -- see that directory's README for the
# provenance of each captured/reconstructed string, so this fixture can't
# silently drift from what real gh actually emits.
echo "== board.sh rate-limit queue (#77) + adopt (#84): fake gh =="

_qsetup() { # -> sets BQ (fixture repo dir) and FGH (fake-gh dir on PATH)
    BQ="$(mktemp -d)"; mkdir -p "$BQ/.claude"
    cp "$FIX/valid.project.yaml" "$BQ/.claude/project.yaml"
    FGH="$(mktemp -d)"
    export GH_FAILURES="$FIX/gh-failures"  # sourced by the fake gh script below (issue #91)
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
            awk 'f{print} /^$/{f=1}' "$GH_FAILURES/rate-limit-honest-user-id.txt" >&2
            exit 1
        fi
        if [[ "${FAKE_GH_ITEM_ADD_MASKED_RATE_LIMIT:-0}" == "1" ]]; then
            awk 'f{print} /^$/{f=1}' "$GH_FAILURES/masked-unknown-owner-type.txt" >&2
            exit 1
        fi
        if [[ -n "${FAKE_GH_ITEM_ADD_MARKER:-}" ]]; then
            : >"$FAKE_GH_ITEM_ADD_MARKER"
        fi
        ;;
    "project item-list")
        n=$(( $(cat "$FAKE_GH_LIST_CALLCOUNT" 2>/dev/null || echo 0) + 1 ))
        echo "$n" >"$FAKE_GH_LIST_CALLCOUNT"
        if [[ "${FAKE_GH_ITEM_LIST_RATE_LIMIT:-0}" == "1" ]]; then
            awk 'f{print} /^$/{f=1}' "$GH_FAILURES/rate-limit-honest-user-id.txt" >&2
            exit 1
        fi
        if [[ "${FAKE_GH_ITEM_LIST_MASKED_RATE_LIMIT:-0}" == "1" ]]; then
            awk 'f{print} /^$/{f=1}' "$GH_FAILURES/masked-unknown-owner-type.txt" >&2
            exit 1
        fi
        # FAKE_GH_ITEM_ADD_MARKER (if set): the item is invisible until
        # project item-add has actually run once -- models eventual-consistency
        # visibility that only kicks in AFTER a real add (#92 adopt test).
        if [[ -n "${FAKE_GH_ITEM_ADD_MARKER:-}" && ! -f "${FAKE_GH_ITEM_ADD_MARKER:-}" ]]; then
            echo '{"items":[]}'
        elif [[ "${FAKE_GH_ITEM_VISIBLE:-1}" == "1" ]]; then
            echo "{\"items\":[{\"id\":\"ITEM_${FAKE_GH_ISSUE_NUM:-900}\",\"content\":{\"number\":${FAKE_GH_ISSUE_NUM:-900}},\"status\":\"${FAKE_GH_ITEM_STATUS:-Backlog}\"}]}"
        else
            echo '{"items":[]}'
        fi
        ;;
    "project item-edit")
        n=$(( $(cat "$FAKE_GH_EDIT_CALLCOUNT" 2>/dev/null || echo 0) + 1 ))
        echo "$n" >"$FAKE_GH_EDIT_CALLCOUNT"
        if [[ "$n" -ge "${FAKE_GH_EDIT_RATE_LIMIT_FROM:-999}" ]]; then
            awk 'f{print} /^$/{f=1}' "$GH_FAILURES/rate-limit-honest-user-id.txt" >&2
            exit 1
        fi
        if [[ "$n" -ge "${FAKE_GH_EDIT_MASKED_RATE_LIMIT_FROM:-999}" ]]; then
            awk 'f{print} /^$/{f=1}' "$GH_FAILURES/masked-unknown-owner-type.txt" >&2
            exit 1
        fi
        # #104: a REAL (non-rate-limit) failure on exactly one call number --
        # -eq (not -ge) so only that specific call fails and later calls in
        # the same replay succeed, letting a durability test assert the rest
        # of a multi-entry flush still completes.
        if [[ "$n" -eq "${FAKE_GH_EDIT_REAL_FAIL_ON:-0}" ]]; then
            echo "GraphQL: field value does not match schema (invalid input)" >&2
            exit 1
        fi
        echo "edited"
        ;;
    "api rate_limit")
        # FAKE_GH_RATE_LIMIT_REAL_SAMPLE (issue #91): when set, replay a REAL
        # `gh api rate_limit` response captured live from tests/fixtures/gh-failures/
        # instead of the synthetic interpolated shape below -- pins the probe
        # (_graphql_remaining_is_zero / _rate_limit_reset_human) against genuine
        # API shapes, not just hand-built JSON.
        if [[ -n "${FAKE_GH_RATE_LIMIT_REAL_SAMPLE:-}" ]]; then
            awk 'f{print} /^$/{f=1}' "$GH_FAILURES/$FAKE_GH_RATE_LIMIT_REAL_SAMPLE"
        else
            echo "{\"resources\":{\"graphql\":{\"limit\":5000,\"remaining\":${FAKE_GH_GRAPHQL_REMAINING:-0},\"reset\":${FAKE_GH_RESET_EPOCH:-1735689600}}},\"rate\":{\"limit\":5000,\"remaining\":${FAKE_GH_GRAPHQL_REMAINING:-0},\"reset\":${FAKE_GH_RESET_EPOCH:-1735689600}}}"
        fi
        ;;
    "issue view")
        if [[ "${FAKE_GH_ISSUE_VIEW_RATE_LIMIT:-0}" == "1" ]]; then
            awk 'f{print} /^$/{f=1}' "$GH_FAILURES/rate-limit-honest-user-id.txt" >&2
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

# --- (g) add: visibility-retry cap (2, not 3 (#77) or 10) + queue fallback instead of erroring ---
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
if [[ "$n" -eq 2 ]]; then
    echo "ok   (g) add: visibility poll capped at exactly 2 attempts (issue #78, down from 3 (#77) / 10 pre-#77)"
else
    echo "FAIL (g) add: expected exactly 2 item-list polls, got $n"
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

# --- (i) #90: masked rate-limit on a mutation (item-edit) + probe remaining==0 -> QUEUED, exit 0 ---
_qsetup
LOG="$(mktemp)"; EDITCC="$(mktemp)"
out="$(cd "$BQ" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG" FAKE_GH_EDIT_CALLCOUNT="$EDITCC" FAKE_GH_LIST_CALLCOUNT="$(mktemp)" \
    FAKE_GH_ISSUE_NUM=810 FAKE_GH_ITEM_VISIBLE=1 \
    FAKE_GH_EDIT_MASKED_RATE_LIMIT_FROM=1 FAKE_GH_GRAPHQL_REMAINING=0 FAKE_GH_RESET_EPOCH=1735689600 \
    bash "$PLUGIN/scripts/board.sh" move 810 "In progress" 2>&1; echo "rc=$?")"
check "(i) masked rate-limit mutation: QUEUED message with reset time" "QUEUED (rate-limited until 2025-01-01T00:00:00Z): move #810 -> In progress" "$out"
check "(i) masked rate-limit mutation: exits 0 (loop keeps going)" "rc=0" "$out"
check_absent "(i) masked rate-limit mutation: original masked text never surfaces raw" "unknown owner type" "$out"
qf="$BQ/.claude/board-queue.jsonl"
check "(i) masked rate-limit mutation: queued for replay" '"op": "move"' "$(cat "$qf" 2>/dev/null)"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC"

# --- (j) #90: same masked error but probe remaining>0 -> a REAL error, surfaced verbatim, not queued ---
_qsetup
LOG="$(mktemp)"; EDITCC="$(mktemp)"
out="$(cd "$BQ" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG" FAKE_GH_EDIT_CALLCOUNT="$EDITCC" FAKE_GH_LIST_CALLCOUNT="$(mktemp)" \
    FAKE_GH_ISSUE_NUM=811 FAKE_GH_ITEM_VISIBLE=1 \
    FAKE_GH_EDIT_MASKED_RATE_LIMIT_FROM=1 FAKE_GH_GRAPHQL_REMAINING=5000 FAKE_GH_RESET_EPOCH=1735689600 \
    bash "$PLUGIN/scripts/board.sh" move 811 "In progress" 2>&1; echo "rc=$?")"
check "(j) masked-but-real error: original error surfaced verbatim" "unknown owner type" "$out"
check "(j) masked-but-real error: exits non-zero" "rc=1" "$out"
check_absent "(j) masked-but-real error: not treated as QUEUED" "QUEUED" "$out"
qf="$BQ/.claude/board-queue.jsonl"
if [[ -s "$qf" ]]; then
    echo "FAIL (j) masked-but-real error: must NOT be queued"
    fails=$((fails + 1))
else
    echo "ok   (j) masked-but-real error: nothing queued"
fi
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC"

# --- (k) #90: move's item-id LOOKUP (item-list) fails masked-rate-limited -> QUEUED, not "bad issue# or status" ---
_qsetup
LOG="$(mktemp)"; LISTCC="$(mktemp)"
out="$(cd "$BQ" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG" FAKE_GH_LIST_CALLCOUNT="$LISTCC" \
    FAKE_GH_ISSUE_NUM=812 FAKE_GH_ITEM_LIST_MASKED_RATE_LIMIT=1 FAKE_GH_GRAPHQL_REMAINING=0 FAKE_GH_RESET_EPOCH=1735689600 \
    bash "$PLUGIN/scripts/board.sh" move 812 "In progress" 2>&1; echo "rc=$?")"
check "(k) lookup masked-rate-limited: QUEUED, not a bad-issue error" "QUEUED (rate-limited until 2025-01-01T00:00:00Z): move #812 -> In progress" "$out"
check "(k) lookup masked-rate-limited: exits 0" "rc=0" "$out"
check_absent "(k) lookup masked-rate-limited: never prints the masked bad-issue error" "bad issue# or status" "$out"
qf="$BQ/.claude/board-queue.jsonl"
check "(k) lookup masked-rate-limited: queued for replay" '"op": "move"' "$(cat "$qf" 2>/dev/null)"
rm -rf "$BQ" "$FGH" "$LOG" "$LISTCC"

# --- (l) #90: read op (list) fails fast with reset time when the masked error is a REAL rate limit ---
_qsetup
LOG="$(mktemp)"; LISTCC="$(mktemp)"
out="$(cd "$BQ" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG" FAKE_GH_LIST_CALLCOUNT="$LISTCC" \
    FAKE_GH_ITEM_LIST_MASKED_RATE_LIMIT=1 FAKE_GH_GRAPHQL_REMAINING=0 FAKE_GH_RESET_EPOCH=1735689600 \
    bash "$PLUGIN/scripts/board.sh" list 2>&1; echo "rc=$?")"
check "(l) list under masked rate limit: RATE-LIMITED fail-fast message with reset time" "RATE-LIMITED until 2025-01-01T00:00:00Z" "$out"
check "(l) list under masked rate limit: exits nonzero" "rc=1" "$out"
check_absent "(l) list under masked rate limit: no raw masked text leak" "unknown owner type" "$out"
rm -rf "$BQ" "$FGH" "$LOG" "$LISTCC"

# --- (t)/(u) #91: the probe (_graphql_remaining_is_zero / _rate_limit_reset_human)
# against REAL captured `gh api rate_limit` shapes, not just synthetic JSON --
# both real samples in the corpus have remaining>0 (41, and a near-exhausted
# 1 -- capturing an actual remaining=0 live would have required deliberately
# exhausting this session's real quota, which this task chose not to do; see
# tests/fixtures/gh-failures/README.md), so both must be treated as a REAL
# error, not queued: exercises the exact boundary the classifier depends on
# against genuine API responses instead of hand-built stand-ins.
_qsetup
LOG="$(mktemp)"; EDITCC="$(mktemp)"
out="$(cd "$BQ" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG" FAKE_GH_EDIT_CALLCOUNT="$EDITCC" FAKE_GH_LIST_CALLCOUNT="$(mktemp)" \
    FAKE_GH_ISSUE_NUM=813 FAKE_GH_ITEM_VISIBLE=1 \
    FAKE_GH_EDIT_MASKED_RATE_LIMIT_FROM=1 FAKE_GH_RATE_LIMIT_REAL_SAMPLE=rate-limit-endpoint-sample.json \
    bash "$PLUGIN/scripts/board.sh" move 813 "In progress" 2>&1; echo "rc=$?")"
check "(t) real rate_limit sample (remaining=41): masked error surfaced verbatim" "unknown owner type" "$out"
check "(t) real rate_limit sample (remaining=41): exits non-zero" "rc=1" "$out"
check_absent "(t) real rate_limit sample (remaining=41): not treated as QUEUED" "QUEUED" "$out"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC"

_qsetup
LOG="$(mktemp)"; EDITCC="$(mktemp)"
out="$(cd "$BQ" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG" FAKE_GH_EDIT_CALLCOUNT="$EDITCC" FAKE_GH_LIST_CALLCOUNT="$(mktemp)" \
    FAKE_GH_ISSUE_NUM=814 FAKE_GH_ITEM_VISIBLE=1 \
    FAKE_GH_EDIT_MASKED_RATE_LIMIT_FROM=1 FAKE_GH_RATE_LIMIT_REAL_SAMPLE=rate-limit-endpoint-near-exhausted.json \
    bash "$PLUGIN/scripts/board.sh" move 814 "In progress" 2>&1; echo "rc=$?")"
check "(u) real rate_limit sample (remaining=1, near-exhausted boundary): masked error surfaced verbatim" "unknown owner type" "$out"
check "(u) real rate_limit sample (remaining=1, near-exhausted boundary): exits non-zero" "rc=1" "$out"
check_absent "(u) real rate_limit sample (remaining=1, near-exhausted boundary): not treated as QUEUED" "QUEUED" "$out"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC"

echo "== board.sh flush concurrency (#92): mutual exclusion, lost-append prevention, stale lock, adopt status =="

# --- (m) two concurrent flushers: mutual exclusion -> zero op loss, exactly-once
# application, the loser skips without ever touching gh. Uses _flush_sync (a
# test-only hook in board-queue.sh) to pin the exact interleaving instead of
# racing wall-clock sleeps: flusher A pauses right after it commits to a batch
# (pre-fix: right after its snapshot copy, before the destructive truncate;
# post-fix: once it holds the lock) so flusher B is guaranteed to start while
# A is still mid-flush.
_qsetup
mkdir -p "$BQ/.claude"
printf '{"op":"prio","issue":"880","priority":"P1","ts":"2020-01-01T00:00:00Z"}\n' >"$BQ/.claude/board-queue.jsonl"
SYNC="$(mktemp -d)"; : >"$SYNC/.board-queue-test-sync"
LOG="$(mktemp)"; LISTCC="$(mktemp)"; EDITCC="$(mktemp)"
OUTA="$(mktemp)"; OUTB="$(mktemp)"

(cd "$BQ" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG" FAKE_GH_LIST_CALLCOUNT="$LISTCC" FAKE_GH_EDIT_CALLCOUNT="$EDITCC" \
    FAKE_GH_ISSUE_NUM=880 FAKE_GH_ITEM_VISIBLE=1 FAKE_GH_ITEM_STATUS="Backlog" \
    BOARD_QUEUE_TEST_SYNC="$SYNC" BOARD_QUEUE_TEST_TAG=A \
    bash "$PLUGIN/scripts/board.sh" flush >"$OUTA" 2>&1; echo "rc=$?" >>"$OUTA") &
PIDA=$!

_i=0
while [[ ! -f "$SYNC/A.ready" && $_i -lt 150 ]]; do sleep 0.02; _i=$((_i + 1)); done

(cd "$BQ" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG" FAKE_GH_LIST_CALLCOUNT="$LISTCC" FAKE_GH_EDIT_CALLCOUNT="$EDITCC" \
    FAKE_GH_ISSUE_NUM=880 FAKE_GH_ITEM_VISIBLE=1 FAKE_GH_ITEM_STATUS="Backlog" \
    BOARD_QUEUE_TEST_SYNC="$SYNC" BOARD_QUEUE_TEST_TAG=B \
    bash "$PLUGIN/scripts/board.sh" flush >"$OUTB" 2>&1; echo "rc=$?" >>"$OUTB") &
PIDB=$!

# Give B a bounded window to either (fixed code) fail the lock and exit on
# its own, or (unfixed code) reach its own snapshot pause -- if it does, let
# it proceed too so the unfixed race actually plays out instead of hanging.
_i=0
while kill -0 "$PIDB" 2>/dev/null && [[ ! -f "$SYNC/B.ready" ]] && [[ $_i -lt 150 ]]; do sleep 0.02; _i=$((_i + 1)); done
[[ -f "$SYNC/B.ready" ]] && : >"$SYNC/B.go"

: >"$SYNC/A.go"
wait "$PIDA" 2>/dev/null
wait "$PIDB" 2>/dev/null

outA="$(cat "$OUTA")"; outB="$(cat "$OUTB")"
editcalls="$(grep -c "project item-edit" "$LOG" 2>/dev/null || echo 0)"
if [[ "$editcalls" -eq 1 ]]; then
    echo "ok   (m) concurrent flush: exactly-once application (1 item-edit call)"
else
    echo "FAIL (m) concurrent flush: expected exactly 1 item-edit call, got $editcalls"
    fails=$((fails + 1))
fi
if grep -qF "prio #880 -> P1" <<<"$outA$outB"; then
    echo "ok   (m) concurrent flush: the op was actually applied"
else
    echo "FAIL (m) concurrent flush: op #880 was never applied"
    fails=$((fails + 1))
fi
if grep -qi "skip" <<<"$outA$outB"; then
    echo "ok   (m) concurrent flush: one flusher reports a skip"
else
    echo "FAIL (m) concurrent flush: no flusher reported skipping"
    fails=$((fails + 1))
fi
if [[ -s "$BQ/.claude/board-queue.jsonl" ]]; then
    echo "FAIL (m) concurrent flush: queue should be fully drained, nothing lost or stuck"
    fails=$((fails + 1))
else
    echo "ok   (m) concurrent flush: queue drained, nothing lost or stuck"
fi
rm -rf "$BQ" "$FGH" "$LOG" "$LISTCC" "$EDITCC" "$OUTA" "$OUTB" "$SYNC"

# --- (n) queue_append DURING an active flush survives (must not be clobbered
# by the flush's own snapshot/replace of the queue file). Same _flush_sync
# hook: the single flusher pauses right after it has committed to its batch
# (pre-fix: post-cp, pre-truncate -- exactly the unsafe gap; post-fix:
# post-aside-move, which is atomic and safe by construction) while the test
# appends a brand-new op directly to the live queue file.
_qsetup
mkdir -p "$BQ/.claude"
printf '{"op":"prio","issue":"890","priority":"P1","ts":"2020-01-01T00:00:00Z"}\n' >"$BQ/.claude/board-queue.jsonl"
SYNC="$(mktemp -d)"; : >"$SYNC/.board-queue-test-sync"
LOG="$(mktemp)"; LISTCC="$(mktemp)"; EDITCC="$(mktemp)"; OUT="$(mktemp)"

(cd "$BQ" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG" FAKE_GH_LIST_CALLCOUNT="$LISTCC" FAKE_GH_EDIT_CALLCOUNT="$EDITCC" \
    FAKE_GH_ISSUE_NUM=890 FAKE_GH_ITEM_VISIBLE=1 FAKE_GH_ITEM_STATUS="Backlog" \
    BOARD_QUEUE_TEST_SYNC="$SYNC" BOARD_QUEUE_TEST_TAG=solo \
    bash "$PLUGIN/scripts/board.sh" flush >"$OUT" 2>&1; echo "rc=$?" >>"$OUT") &
PID=$!

_i=0
while [[ ! -f "$SYNC/solo.ready" && $_i -lt 150 ]]; do sleep 0.02; _i=$((_i + 1)); done
printf '{"op":"prio","issue":"891","priority":"P2","ts":"2020-01-01T00:00:00Z"}\n' >>"$BQ/.claude/board-queue.jsonl"
: >"$SYNC/solo.go"
wait "$PID" 2>/dev/null

out="$(cat "$OUT")"
check "(n) append-during-flush: the original queued op was applied" "prio #890 -> P1" "$out"
remainder="$(cat "$BQ/.claude/board-queue.jsonl" 2>/dev/null)"
check "(n) append-during-flush: the concurrently-appended op survives" '"issue":"891"' "$remainder"
rm -rf "$BQ" "$FGH" "$LOG" "$LISTCC" "$EDITCC" "$OUT" "$SYNC"

# --- (o) stale lock (older than the TTL) is broken with a warning, not wedged forever ---
_qsetup
mkdir -p "$BQ/.claude" "$BQ/.claude/board-queue.lock"
printf '{"op":"prio","issue":"895","priority":"P1","ts":"2020-01-01T00:00:00Z"}\n' >"$BQ/.claude/board-queue.jsonl"
sleep 1.1
LOG="$(mktemp)"; LISTCC="$(mktemp)"; EDITCC="$(mktemp)"
out="$(cd "$BQ" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG" FAKE_GH_LIST_CALLCOUNT="$LISTCC" FAKE_GH_EDIT_CALLCOUNT="$EDITCC" \
    FAKE_GH_ISSUE_NUM=895 FAKE_GH_ITEM_VISIBLE=1 FAKE_GH_ITEM_STATUS="Backlog" \
    BOARD_QUEUE_LOCK_TTL=1 \
    bash "$PLUGIN/scripts/board.sh" flush 2>&1; echo "rc=$?")"
check "(o) stale lock: broken with a warning" "stale" "$out"
check "(o) stale lock: the op still gets applied after breaking the lock" "prio #895 -> P1" "$out"
check "(o) stale lock: exits 0" "rc=0" "$out"
if [[ -d "$BQ/.claude/board-queue.lock" ]]; then
    echo "FAIL (o) stale lock: lock dir should be released after the flush completes"
    fails=$((fails + 1))
else
    echo "ok   (o) stale lock: lock dir released after flush"
fi
rm -rf "$BQ" "$FGH" "$LOG" "$LISTCC" "$EDITCC"

# --- (p) adopt (#92): a freshly-adopted, now-visible item gets an initial status
# instead of landing with no status ('-' on the board) ---
_qsetup
LOG="$(mktemp)"; LISTCC="$(mktemp)"; EDITCC="$(mktemp)"; MARKER="$(mktemp -u)"
out="$(cd "$BQ" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG" FAKE_GH_LIST_CALLCOUNT="$LISTCC" FAKE_GH_EDIT_CALLCOUNT="$EDITCC" \
    FAKE_GH_ISSUE_NUM=896 FAKE_GH_ITEM_VISIBLE=1 FAKE_GH_ITEM_STATUS="NoStatus" FAKE_GH_ITEM_ADD_MARKER="$MARKER" \
    bash "$PLUGIN/scripts/board.sh" adopt 896 2>&1; echo "rc=$?")"
check "(p) adopt: still reports adopted" "adopted #896" "$out"
check "(p) adopt: exits 0" "rc=0" "$out"
check "(p) adopt: sets the initial status (matches add's FIRST_STATUS behavior)" "fixtureStatus0" "$(cat "$LOG")"
check "(p) adopt: initial status is Backlog (statusFlow[0])" "aaaa0001" "$(cat "$LOG")"
rm -rf "$BQ" "$FGH" "$LOG" "$LISTCC" "$EDITCC" "$MARKER"

echo "== board.sh flush concurrency round 2 (#92 review): dedupe stale requeue, sync-hook safety, queue-empty message =="

# --- (q) explicit `flush` verb on an empty, unlocked queue reports "queue empty"
# (review round 2, finding 3: this went silent when the emptiness check moved
# inside _flush_queue behind the lock) ---
_qsetup
out="$(cd "$BQ" && PATH="$FGH:$PATH" FAKE_GH_LOG="$(mktemp)" bash "$PLUGIN/scripts/board.sh" flush 2>&1; echo "rc=$?")"
check "(q) flush on empty queue: reports queue empty" "queue empty" "$out"
check "(q) flush on empty queue: exits 0" "rc=0" "$out"
rm -rf "$BQ" "$FGH"

# --- (r) _flush_sync's wait is capped, not unbounded (review round 2, finding 2:
# a leaked BOARD_QUEUE_TEST_SYNC would otherwise hang every flush forever).
# Use a tiny cap so the test itself stays fast. ---
_qsetup
mkdir -p "$BQ/.claude"
printf '{"op":"prio","issue":"897","priority":"P1","ts":"2020-01-01T00:00:00Z"}\n' >"$BQ/.claude/board-queue.jsonl"
SYNC="$(mktemp -d)"; : >"$SYNC/.board-queue-test-sync"
LOG="$(mktemp)"; LISTCC="$(mktemp)"; EDITCC="$(mktemp)"
out="$(cd "$BQ" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG" FAKE_GH_LIST_CALLCOUNT="$LISTCC" FAKE_GH_EDIT_CALLCOUNT="$EDITCC" \
    FAKE_GH_ISSUE_NUM=897 FAKE_GH_ITEM_VISIBLE=1 FAKE_GH_ITEM_STATUS="Backlog" \
    BOARD_QUEUE_TEST_SYNC="$SYNC" BOARD_QUEUE_TEST_SYNC_MAX_WAIT_ITERS=3 BOARD_QUEUE_TEST_TAG=cap \
    bash "$PLUGIN/scripts/board.sh" flush 2>&1; echo "rc=$?")"
check "(r) sync-wait cap: gives up loudly instead of hanging" "gave up after" "$out"
check "(r) sync-wait cap: still completes the flush after giving up" "prio #897 -> P1" "$out"
check "(r) sync-wait cap: exits 0" "rc=0" "$out"
rm -rf "$BQ" "$FGH" "$LOG" "$LISTCC" "$EDITCC" "$SYNC"

# --- (s) stale requeue must not regress a status past a newer move for the
# same issue (review round 2, finding 1, BLOCKING): reproduces the exact
# interleaving -- an old move (#900 -> QA) gets rate-limited and requeued to
# the TAIL of the live file, but a newer move (#900 -> Ready) was appended to
# the live file first (while the first flush was paused mid-flight, via
# _flush_sync). The next flush must not replay the stale QA op over the
# already-newer Ready one: the file-order cur==target skip alone doesn't
# catch this (cur ends up Ready, target is QA -- they never match) so flush
# must dedupe by (op, issue), keeping the most-recently-enqueued entry. ---
_qsetup
mkdir -p "$BQ/.claude"
printf '{"op":"move","issue":"900","status":"QA","ts":"2020-01-01T00:00:00Z"}\n' >"$BQ/.claude/board-queue.jsonl"
SYNC="$(mktemp -d)"; : >"$SYNC/.board-queue-test-sync"
LOG1="$(mktemp)"; LISTCC="$(mktemp)"; EDITCC="$(mktemp)"; OUT1="$(mktemp)"

(cd "$BQ" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG1" FAKE_GH_LIST_CALLCOUNT="$LISTCC" FAKE_GH_EDIT_CALLCOUNT="$EDITCC" \
    FAKE_GH_ISSUE_NUM=900 FAKE_GH_ITEM_VISIBLE=1 FAKE_GH_ITEM_STATUS="Backlog" \
    FAKE_GH_EDIT_RATE_LIMIT_FROM=1 FAKE_GH_RESET_EPOCH=1735689600 \
    BOARD_QUEUE_TEST_SYNC="$SYNC" BOARD_QUEUE_TEST_TAG=first \
    bash "$PLUGIN/scripts/board.sh" flush >"$OUT1" 2>&1; echo "rc=$?" >>"$OUT1") &
PID1=$!

_i=0
while [[ ! -f "$SYNC/first.ready" && $_i -lt 150 ]]; do sleep 0.02; _i=$((_i + 1)); done
printf '{"op":"move","issue":"900","status":"Ready","ts":"2020-01-01T00:00:05Z"}\n' >>"$BQ/.claude/board-queue.jsonl"
: >"$SYNC/first.go"
wait "$PID1" 2>/dev/null

out1="$(cat "$OUT1")"
check "(s) first flush: the old op rate-limits and gets requeued" "QUEUED (rate-limited until 2025-01-01T00:00:00Z): move #900" "$out1"
combined="$(cat "$BQ/.claude/board-queue.jsonl" 2>/dev/null)"
check "(s) after first flush: the newer Ready op landed ahead of the stale requeued QA op" '"status":"Ready"' "$(head -1 <<<"$combined")"
check "(s) after first flush: the stale QA op followed it (verifying the exact interleaving)" '"status":"QA"' "$(tail -1 <<<"$combined")"

LOG2="$(mktemp)"; EDITCC2="$(mktemp)"
out2="$(cd "$BQ" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG2" FAKE_GH_LIST_CALLCOUNT="$(mktemp)" FAKE_GH_EDIT_CALLCOUNT="$EDITCC2" \
    FAKE_GH_ISSUE_NUM=900 FAKE_GH_ITEM_VISIBLE=1 FAKE_GH_ITEM_STATUS="Ready" \
    bash "$PLUGIN/scripts/board.sh" flush 2>&1; echo "rc=$?")"
check "(s) second flush: the current (newer) status is recognized and skipped" "flush: skip move #900 (already Ready)" "$out2"
check_absent "(s) second flush: the stale QA move must NOT regress the status" "moved #900 -> QA" "$out2"
check_absent "(s) second flush: no item-edit call at all (both ops resolved without one)" "project item-edit" "$(cat "$LOG2")"
if [[ -s "$BQ/.claude/board-queue.jsonl" ]]; then
    echo "FAIL (s) second flush: queue should be fully drained"
    fails=$((fails + 1))
else
    echo "ok   (s) second flush: queue drained"
fi
rm -rf "$BQ" "$FGH" "$SYNC" "$LOG1" "$LISTCC" "$EDITCC" "$OUT1" "$LOG2" "$EDITCC2"

echo "== board.sh flush durability + lock liveness (#104) =="
# Live incident 2026-07-08: a flush crashed mid-replay leaving NEITHER the
# queue file NOR an aside file behind -- every queued mutation had to be
# reconstructed by hand from session memory. Two invariants under test here:
# (1) an entry's bytes exist on disk (aside or queue) until its mutation is
# CONFIRMED applied -- never a delete-then-apply window; (2) a lockdir whose
# holder process is verifiably dead is broken immediately, without waiting
# out the full TTL, so the NEXT automatic flush self-heals in seconds.

# --- (v) crash AFTER the aside-move but BEFORE the first mutation applies:
# every originally-queued entry must be recoverable on disk (still in the
# aside file -- _flush_sync's existing pause point is exactly this window)
# so a follow-up flush eventually applies all of them, none lost. Both
# entries target the SAME issue# (with different op kinds, so #92's dedupe
# doesn't collapse them) -- the fixture fake gh's item-list only ever makes
# ONE issue# (FAKE_GH_ISSUE_NUM) visible, so a second distinct issue# would
# never resolve regardless of durability. ---
_qsetup
mkdir -p "$BQ/.claude"
printf '{"op":"prio","issue":"920","priority":"P1","ts":"2020-01-01T00:00:00Z"}\n' >"$BQ/.claude/board-queue.jsonl"
printf '{"op":"est","issue":"920","points":"3","ts":"2020-01-01T00:00:01Z"}\n' >>"$BQ/.claude/board-queue.jsonl"
SYNC="$(mktemp -d)"; : >"$SYNC/.board-queue-test-sync"
LOG="$(mktemp)"; LISTCC="$(mktemp)"; EDITCC="$(mktemp)"; OUT="$(mktemp)"

(
    cd "$BQ" || exit 1
    exec env PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG" FAKE_GH_LIST_CALLCOUNT="$LISTCC" FAKE_GH_EDIT_CALLCOUNT="$EDITCC" \
        FAKE_GH_ISSUE_NUM=920 FAKE_GH_ITEM_VISIBLE=1 FAKE_GH_ITEM_STATUS="Backlog" \
        BOARD_QUEUE_TEST_SYNC="$SYNC" BOARD_QUEUE_TEST_TAG=crashpre \
        bash "$PLUGIN/scripts/board.sh" flush
) >"$OUT" 2>&1 &
PID=$!

_i=0
while [[ ! -f "$SYNC/crashpre.ready" && $_i -lt 150 ]]; do sleep 0.02; _i=$((_i + 1)); done
kill -9 "$PID" 2>/dev/null
wait "$PID" 2>/dev/null

if [[ -s "$BQ/.claude/board-queue.jsonl" ]]; then
    echo "FAIL (v) crash-before-first-apply: nothing should have been applied yet, but the live queue file was touched"
    fails=$((fails + 1))
else
    echo "ok   (v) crash-before-first-apply: live queue file untouched pre-crash"
fi
asideglob=("$BQ"/.claude/.flush.*)
if [[ -e "${asideglob[0]}" ]]; then
    asidecontent="$(cat "${asideglob[@]}" 2>/dev/null)"
    check "(v) crash-before-first-apply: entry #920 (prio) survives on disk (aside)" '"op":"prio","issue":"920"' "$asidecontent"
    check "(v) crash-before-first-apply: entry #920 (est) survives on disk (aside)" '"op":"est","issue":"920"' "$asidecontent"
else
    echo "FAIL (v) crash-before-first-apply: no aside file found -- entries lost"
    fails=$((fails + 2))
fi
# Recovery: the crashed process left the lockdir held with a now-dead pid --
# rmdir it by hand here only to isolate this assertion from the liveness-probe
# mechanism under test separately below (test y); here we just confirm the
# ENTRIES themselves are recoverable by re-seeding the live queue from the
# aside content and flushing clean.
rmdir "$BQ/.claude/board-queue.lock" 2>/dev/null
cat "${asideglob[@]}" 2>/dev/null >"$BQ/.claude/board-queue.jsonl"
rm -f "${asideglob[@]}" 2>/dev/null
LOG2="$(mktemp)"; EDITCC2="$(mktemp)"
out2="$(cd "$BQ" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG2" FAKE_GH_LIST_CALLCOUNT="$(mktemp)" FAKE_GH_EDIT_CALLCOUNT="$EDITCC2" \
    FAKE_GH_ISSUE_NUM=920 FAKE_GH_ITEM_VISIBLE=1 FAKE_GH_ITEM_STATUS="Backlog" \
    bash "$PLUGIN/scripts/board.sh" flush 2>&1; echo "rc=$?")"
check "(v) recovery flush: the prio entry applied" "prio #920 -> P1" "$out2"
check "(v) recovery flush: the est entry applied" "est #920 -> 3" "$out2"
rm -rf "$BQ" "$FGH" "$SYNC" "$LOG" "$LISTCC" "$EDITCC" "$OUT" "$LOG2" "$EDITCC2"

# --- (w) crash AFTER the last mutation applies but BEFORE the aside file's
# final cleanup: flush must still have fully applied the entry (no
# delete-then-apply window means the per-entry bookkeeping already dropped it
# from the aside before the crash), and a follow-up flush must complete
# cleanly with no duplicate application. ---
_qsetup
mkdir -p "$BQ/.claude"
printf '{"op":"prio","issue":"922","priority":"P1","ts":"2020-01-01T00:00:00Z"}\n' >"$BQ/.claude/board-queue.jsonl"
SYNC="$(mktemp -d)"; : >"$SYNC/.board-queue-test-sync"
LOG="$(mktemp)"; LISTCC="$(mktemp)"; EDITCC="$(mktemp)"; OUT="$(mktemp)"

(
    cd "$BQ" || exit 1
    exec env PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG" FAKE_GH_LIST_CALLCOUNT="$LISTCC" FAKE_GH_EDIT_CALLCOUNT="$EDITCC" \
        FAKE_GH_ISSUE_NUM=922 FAKE_GH_ITEM_VISIBLE=1 FAKE_GH_ITEM_STATUS="Backlog" \
        BOARD_QUEUE_TEST_SYNC="$SYNC" BOARD_QUEUE_TEST_TAG=crashpost \
        bash "$PLUGIN/scripts/board.sh" flush
) >"$OUT" 2>&1 &
PID=$!

# Release the FIRST sync point (right after the aside-move -- test (v)'s
# window) immediately so the flush proceeds through to the mutation, then
# wait for the SECOND ("<tag>-done", right before the now-cosmetic aside
# cleanup) before crashing, so the crash lands after the mutation is
# confirmed applied.
_i=0
while [[ ! -f "$SYNC/crashpost.ready" && $_i -lt 150 ]]; do sleep 0.02; _i=$((_i + 1)); done
: >"$SYNC/crashpost.go"
_i=0
while [[ ! -f "$SYNC/crashpost-done.ready" && $_i -lt 150 ]]; do sleep 0.02; _i=$((_i + 1)); done
kill -9 "$PID" 2>/dev/null
wait "$PID" 2>/dev/null

editcalls="$(grep -c "project item-edit" "$LOG" 2>/dev/null || echo 0)"
if [[ "$editcalls" -eq 1 ]]; then
    echo "ok   (w) crash-after-last-apply: the mutation was applied exactly once before the crash"
else
    echo "FAIL (w) crash-after-last-apply: expected exactly 1 item-edit call, got $editcalls"
    fails=$((fails + 1))
fi
asideglob=("$BQ"/.claude/.flush.*)
if [[ -e "${asideglob[0]}" ]]; then
    asidecontent="$(cat "${asideglob[@]}" 2>/dev/null)"
    check_absent "(w) crash-after-last-apply: the applied entry is NOT still sitting in the orphaned aside" '"issue":"922"' "$asidecontent"
else
    echo "ok   (w) crash-after-last-apply: aside already empty/gone (entry fully confirmed before crash)"
fi
if [[ -s "$BQ/.claude/board-queue.jsonl" ]]; then
    echo "FAIL (w) crash-after-last-apply: live queue file should still be empty (nothing requeued)"
    fails=$((fails + 1))
else
    echo "ok   (w) crash-after-last-apply: live queue file empty"
fi
rmdir "$BQ/.claude/board-queue.lock" 2>/dev/null
rm -f "${asideglob[@]}" 2>/dev/null
LOG2="$(mktemp)"; EDITCC2="$(mktemp)"
out2="$(cd "$BQ" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG2" FAKE_GH_LIST_CALLCOUNT="$(mktemp)" FAKE_GH_EDIT_CALLCOUNT="$EDITCC2" \
    FAKE_GH_ISSUE_NUM=922 FAKE_GH_ITEM_VISIBLE=1 FAKE_GH_ITEM_STATUS="Backlog" \
    bash "$PLUGIN/scripts/board.sh" flush 2>&1; echo "rc=$?")"
check "(w) follow-up flush: reports queue empty (no duplicate application, nothing stuck)" "queue empty" "$out2"
check_absent "(w) follow-up flush: never re-applies the already-confirmed mutation" "prio #922 -> P1" "$out2"
rm -rf "$BQ" "$FGH" "$SYNC" "$LOG" "$LISTCC" "$EDITCC" "$OUT" "$LOG2" "$EDITCC2"

# --- (x) a REAL (non-rate-limit) apply failure must not silently vanish the
# entry: it survives on disk in the live queue file, and the flush still
# processes the OTHER lines in the same batch. Both entries target the SAME
# issue# (different op kinds, so #92's dedupe doesn't collapse them) -- the
# fixture fake gh only ever makes ONE issue# visible (see test (v)). ---
_qsetup
mkdir -p "$BQ/.claude"
printf '{"op":"prio","issue":"930","priority":"P1","ts":"2020-01-01T00:00:00Z"}\n' >"$BQ/.claude/board-queue.jsonl"
printf '{"op":"est","issue":"930","points":"5","ts":"2020-01-01T00:00:01Z"}\n' >>"$BQ/.claude/board-queue.jsonl"
LOG="$(mktemp)"; LISTCC="$(mktemp)"; EDITCC="$(mktemp)"
out="$(cd "$BQ" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG" FAKE_GH_LIST_CALLCOUNT="$LISTCC" FAKE_GH_EDIT_CALLCOUNT="$EDITCC" \
    FAKE_GH_ISSUE_NUM=930 FAKE_GH_ITEM_VISIBLE=1 FAKE_GH_ITEM_STATUS="Backlog" \
    FAKE_GH_EDIT_REAL_FAIL_ON=1 FAKE_GH_GRAPHQL_REMAINING=9999 \
    bash "$PLUGIN/scripts/board.sh" flush 2>&1; echo "rc=$?")"
check "(x) real apply failure: the underlying error is surfaced, not swallowed" "field value does not match schema" "$out"
check "(x) real apply failure: exits 0 (the loop keeps going for other tasks)" "rc=0" "$out"
check_absent "(x) real apply failure: never misreported as QUEUED/rate-limited" "QUEUED" "$out"
check "(x) real apply failure: the OTHER (successful, est) entry still applies" "est #930 -> 5" "$out"
remainder="$(cat "$BQ/.claude/board-queue.jsonl" 2>/dev/null)"
check "(x) real apply failure: the failed (prio) entry survives on disk in the live queue file" '"op":"prio","issue":"930"' "$remainder"
check_absent "(x) real apply failure: the OTHER (successful, est) entry is not left behind too" '"op":"est"' "$remainder"
rm -rf "$BQ" "$FGH" "$LOG" "$LISTCC" "$EDITCC"

# --- (y) liveness probe: a lockdir whose pidfile names a definitively-dead
# PID is broken IMMEDIATELY, even with a long TTL that would not otherwise
# have expired -- this must not depend on waiting out BOARD_QUEUE_LOCK_TTL. ---
_qsetup
mkdir -p "$BQ/.claude" "$BQ/.claude/board-queue.lock"
( : ) & DEADPID=$!
wait "$DEADPID" 2>/dev/null   # DEADPID is now guaranteed not running
printf '%s\n' "$DEADPID" >"$BQ/.claude/board-queue.lock/pid"
printf '{"op":"prio","issue":"940","priority":"P1","ts":"2020-01-01T00:00:00Z"}\n' >"$BQ/.claude/board-queue.jsonl"
LOG="$(mktemp)"; LISTCC="$(mktemp)"; EDITCC="$(mktemp)"
out="$(cd "$BQ" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG" FAKE_GH_LIST_CALLCOUNT="$LISTCC" FAKE_GH_EDIT_CALLCOUNT="$EDITCC" \
    FAKE_GH_ISSUE_NUM=940 FAKE_GH_ITEM_VISIBLE=1 FAKE_GH_ITEM_STATUS="Backlog" \
    BOARD_QUEUE_LOCK_TTL=600 \
    bash "$PLUGIN/scripts/board.sh" flush 2>&1; echo "rc=$?")"
check "(y) dead-holder lock: broken immediately via the liveness probe, not the TTL" "breaking dead-holder lock" "$out"
check "(y) dead-holder lock: names the dead pid in the message" "pid $DEADPID" "$out"
check "(y) dead-holder lock: the op still gets applied after breaking the lock" "prio #940 -> P1" "$out"
check "(y) dead-holder lock: exits 0" "rc=0" "$out"
if [[ -d "$BQ/.claude/board-queue.lock" ]]; then
    echo "FAIL (y) dead-holder lock: lock dir should be released after the flush completes"
    fails=$((fails + 1))
else
    echo "ok   (y) dead-holder lock: lock dir released after flush"
fi
rm -rf "$BQ" "$FGH" "$LOG" "$LISTCC" "$EDITCC"

# --- (z) liveness probe must NOT break a lock whose pidfile names a genuinely
# LIVE process, even though a pidfile is now present -- preserves the
# existing SKIP behavior for a real concurrent holder (tests m/n above). ---
_qsetup
mkdir -p "$BQ/.claude" "$BQ/.claude/board-queue.lock"
printf '%s\n' "$$" >"$BQ/.claude/board-queue.lock/pid"   # this test script's own pid: guaranteed alive
printf '{"op":"prio","issue":"941","priority":"P1","ts":"2020-01-01T00:00:00Z"}\n' >"$BQ/.claude/board-queue.jsonl"
LOG="$(mktemp)"; LISTCC="$(mktemp)"; EDITCC="$(mktemp)"
out="$(cd "$BQ" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG" FAKE_GH_LIST_CALLCOUNT="$LISTCC" FAKE_GH_EDIT_CALLCOUNT="$EDITCC" \
    FAKE_GH_ISSUE_NUM=941 FAKE_GH_ITEM_VISIBLE=1 FAKE_GH_ITEM_STATUS="Backlog" \
    BOARD_QUEUE_LOCK_TTL=600 \
    bash "$PLUGIN/scripts/board.sh" flush 2>&1; echo "rc=$?")"
check "(z) live-holder lock: SKIPs, not broken, just because a pidfile is present" "SKIP" "$out"
check_absent "(z) live-holder lock: never claims to break a dead-holder lock" "breaking dead-holder lock" "$out"
check_absent "(z) live-holder lock: never claims to break a stale lock" "breaking stale lock" "$out"
if [[ -d "$BQ/.claude/board-queue.lock" ]]; then
    echo "ok   (z) live-holder lock: left in place (still held)"
else
    echo "FAIL (z) live-holder lock: lock dir should NOT have been removed"
    fails=$((fails + 1))
fi
rm -rf "$BQ" "$FGH" "$LOG" "$LISTCC" "$EDITCC"

# --- (aa) review finding (#104, round 1): _aside_write_remaining's rewrite of
# the aside file must itself be atomic -- a kill -9 landing between an
# in-place truncate and its line-by-line appends would leave the aside file
# empty/partial, i.e. an entry mid-rewrite in NEITHER the aside file nor
# $QUEUE_FILE. Pins the exact window right before the atomic `mv` (via the
# dedicated, separately-gated BOARD_QUEUE_TEST_ASIDE_SYNC hook, so this
# doesn't cost every other sync-using test above an extra wait) and asserts
# the aside path still shows its OLD, untouched, full content at that point
# -- proving the new content lives only in a sibling temp file until the
# single atomic rename lands, never as a partially-written aside file. ---
_qsetup
mkdir -p "$BQ/.claude"
printf '{"op":"prio","issue":"950","priority":"P1","ts":"2020-01-01T00:00:00Z"}\n' >"$BQ/.claude/board-queue.jsonl"
SYNC="$(mktemp -d)"; : >"$SYNC/.board-queue-test-sync"
LOG="$(mktemp)"; LISTCC="$(mktemp)"; EDITCC="$(mktemp)"; OUT="$(mktemp)"

(
    cd "$BQ" || exit 1
    exec env PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG" FAKE_GH_LIST_CALLCOUNT="$LISTCC" FAKE_GH_EDIT_CALLCOUNT="$EDITCC" \
        FAKE_GH_ISSUE_NUM=950 FAKE_GH_ITEM_VISIBLE=1 FAKE_GH_ITEM_STATUS="Backlog" \
        BOARD_QUEUE_TEST_SYNC="$SYNC" BOARD_QUEUE_TEST_TAG=asideatomic BOARD_QUEUE_TEST_ASIDE_SYNC=1 \
        bash "$PLUGIN/scripts/board.sh" flush
) >"$OUT" 2>&1 &
PID=$!

# Release the pre-apply pause (right after the aside-move) immediately so the
# flush proceeds to actually apply the one queued entry, then wait on the
# aside-write-specific pause (right before _aside_write_remaining's atomic
# mv, i.e. AFTER the entry applied but BEFORE the aside file is rewritten to
# reflect that).
_i=0
while [[ ! -f "$SYNC/asideatomic.ready" && $_i -lt 150 ]]; do sleep 0.02; _i=$((_i + 1)); done
: >"$SYNC/asideatomic.go"
_i=0
while [[ ! -f "$SYNC/asideatomic-aside-write.ready" && $_i -lt 150 ]]; do sleep 0.02; _i=$((_i + 1)); done

asideglob=("$BQ"/.claude/.flush.*)
if [[ -e "${asideglob[0]}" ]]; then
    asidecontent="$(cat "${asideglob[@]}" 2>/dev/null)"
    check "(aa) mid-aside-rewrite pause: the aside file still shows its OLD, untruncated content (no partial write visible)" '"op":"prio","issue":"950"' "$asidecontent"
else
    echo "FAIL (aa) mid-aside-rewrite pause: aside file missing entirely at the pause point"
    fails=$((fails + 1))
fi
tmpglob=("$BQ"/.claude/.flush-remaining.*)
if [[ -e "${tmpglob[0]}" ]]; then
    echo "ok   (aa) mid-aside-rewrite pause: the new (empty) content sits in a sibling temp file, not yet mv'd over the aside path"
else
    echo "FAIL (aa) mid-aside-rewrite pause: expected a sibling .flush-remaining.* temp file to exist mid-write"
    fails=$((fails + 1))
fi

kill -9 "$PID" 2>/dev/null
wait "$PID" 2>/dev/null

# Durability check: even crashing exactly inside the aside rewrite must never
# lose the entry -- it's recoverable (either the aside still holds it, or an
# already-applied entry is simply gone because it was durably confirmed,
# never "vanished mid-write").
asideglob=("$BQ"/.claude/.flush.*)
recoverable=0
if [[ -e "${asideglob[0]}" ]] && grep -qF '"issue":"950"' "${asideglob[@]}" 2>/dev/null; then
    recoverable=1
fi
applied=0
grep -qF "prio #950 -> P1" "$OUT" 2>/dev/null && applied=1
if [[ "$recoverable" -eq 1 || "$applied" -eq 1 ]]; then
    echo "ok   (aa) crash mid-aside-rewrite: the entry was either already applied or remains recoverable on disk -- never lost"
else
    echo "FAIL (aa) crash mid-aside-rewrite: entry #950 is neither applied nor recoverable -- lost"
    fails=$((fails + 1))
fi
rmdir "$BQ/.claude/board-queue.lock" 2>/dev/null
if [[ ! -s "$BQ/.claude/board-queue.jsonl" ]]; then
    cat "${asideglob[@]}" 2>/dev/null >"$BQ/.claude/board-queue.jsonl"
fi
rm -f "${asideglob[@]}" "${tmpglob[@]}" 2>/dev/null
LOG2="$(mktemp)"; EDITCC2="$(mktemp)"
out2="$(cd "$BQ" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG2" FAKE_GH_LIST_CALLCOUNT="$(mktemp)" FAKE_GH_EDIT_CALLCOUNT="$EDITCC2" \
    FAKE_GH_ISSUE_NUM=950 FAKE_GH_ITEM_VISIBLE=1 FAKE_GH_ITEM_STATUS="Backlog" \
    bash "$PLUGIN/scripts/board.sh" flush --verbose 2>&1; echo "rc=$?")"
if grep -qF "prio #950 -> P1" <<<"$out2" || grep -qF "queue empty" <<<"$out2"; then
    echo "ok   (aa) recovery flush: the entry ends up applied (either just now, or already was)"
else
    echo "FAIL (aa) recovery flush: entry #950 never applied"
    fails=$((fails + 1))
fi
rm -rf "$BQ" "$FGH" "$SYNC" "$LOG" "$LISTCC" "$EDITCC" "$OUT" "$LOG2" "$EDITCC2"

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
