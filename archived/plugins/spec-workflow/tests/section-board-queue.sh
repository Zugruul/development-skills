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
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== board.sh rate-limit queue (#77) + adopt (#84): fake gh =="

_qsetup() { # -> sets BQ (fixture repo dir) and FGH (fake-gh dir on PATH)
    BQ="$(mktemp -d)"; mkdir -p "$BQ/.claude" "$BQ/.neural-network"
    cp "$FIX/valid.project.yaml" "$BQ/.neural-network/project.yaml"
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
        if [[ -n "${FAKE_GH_ITEM_ADD_FAIL_TEXT:-}" ]]; then
            echo "$FAKE_GH_ITEM_ADD_FAIL_TEXT" >&2
            exit 1
        fi
        if [[ -n "${FAKE_GH_ITEM_ADD_TRANSIENT:-}" ]]; then
            awk 'f{print} /^$/{f=1}' "$GH_FAILURES/$FAKE_GH_ITEM_ADD_TRANSIENT" >&2
            exit 1
        fi
        if [[ -n "${FAKE_GH_ITEM_ADD_MARKER:-}" ]]; then
            : >"$FAKE_GH_ITEM_ADD_MARKER"
        fi
        ;;
    "api graphql") exec python3 "$GH_GQL_ADAPTER" "$0" "$@" ;;
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
        if [[ -n "${FAKE_GH_ITEM_LIST_LATE_FAIL_TEXT:-}" && "$n" -ge "${FAKE_GH_ITEM_LIST_FAIL_FROM:-999}" ]]; then
            echo "$FAKE_GH_ITEM_LIST_LATE_FAIL_TEXT" >&2
            exit 1
        fi
        if [[ -n "${FAKE_GH_ITEM_LIST_FAIL_TEXT:-}" ]]; then
            echo "$FAKE_GH_ITEM_LIST_FAIL_TEXT" >&2
            exit 1
        fi
        if [[ -n "${FAKE_GH_ITEM_LIST_TRANSIENT:-}" ]]; then
            awk 'f{print} /^$/{f=1}' "$GH_FAILURES/$FAKE_GH_ITEM_LIST_TRANSIENT" >&2
            exit 1
        fi
        # #561: FAKE_GH_ITEMS_JSON replaces the whole snapshot; FAKE_GH_ISSUES
        # ("901 902 ...") makes several issues visible, all at FAKE_GH_ITEM_STATUS.
        if [[ -n "${FAKE_GH_ITEMS_JSON:-}" ]]; then
            echo "$FAKE_GH_ITEMS_JSON"
            exit 0
        fi
        if [[ -n "${FAKE_GH_ISSUES:-}" ]]; then
            body=""
            for i in $FAKE_GH_ISSUES; do
                body="$body${body:+,}{\"id\":\"ITEM_$i\",\"content\":{\"number\":$i},\"status\":\"${FAKE_GH_ITEM_STATUS:-Backlog}\"}"
            done
            echo "{\"items\":[$body]}"
            exit 0
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
        if [[ "$n" -eq "${FAKE_GH_EDIT_RATE_LIMIT_ONLY_ON:-0}" ]]; then
            awk 'f{print} /^$/{f=1}' "$GH_FAILURES/rate-limit-honest-user-id.txt" >&2
            exit 1
        fi
        if [[ -n "${FAKE_GH_EDIT_FAIL_TEXT:-}" ]]; then
            echo "$FAKE_GH_EDIT_FAIL_TEXT" >&2
            exit 1
        fi
        if [[ -n "${FAKE_GH_EDIT_TRANSIENT:-}" && "$n" -ge "${FAKE_GH_EDIT_TRANSIENT_FROM:-1}" ]]; then
            awk 'f{print} /^$/{f=1}' "$GH_FAILURES/$FAKE_GH_EDIT_TRANSIENT" >&2
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

# _seed_seen <issue#> -- pre-seed the #234 comment-steering marker so these
# pre-existing rate-limit/queue/flush mechanics tests (unrelated to #234) can
# still move an issue to "In progress" without each one calling `board.sh
# show` first; mirrors a caller that already ran `show` for real.
_seed_seen() { printf '{"%s": true}' "$1" >"$BQ/.claude/board-comments-seen.json"; }

# --- (a) rate-limited GraphQL mutation (move) -> queued, exit 0, QUEUED message ---
_qsetup
_seed_seen 801
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
mkdir -p "$BQ/.claude" "$BQ/.neural-network"
_seed_seen 802
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
mkdir -p "$BQ/.claude" "$BQ/.neural-network"
_seed_seen 803
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
mkdir -p "$BQ/.claude" "$BQ/.neural-network"
_seed_seen 804
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
mkdir -p "$BQ/.claude" "$BQ/.neural-network"
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
_seed_seen 810
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
_seed_seen 811
LOG="$(mktemp)"; EDITCC="$(mktemp)"
out="$(cd "$BQ" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG" FAKE_GH_EDIT_CALLCOUNT="$EDITCC" FAKE_GH_LIST_CALLCOUNT="$(mktemp)" \
    FAKE_GH_ISSUE_NUM=811 FAKE_GH_ITEM_VISIBLE=1 \
    FAKE_GH_EDIT_MASKED_RATE_LIMIT_FROM=1 FAKE_GH_GRAPHQL_REMAINING=5000 FAKE_GH_RESET_EPOCH=1735689600 \
    bash "$PLUGIN/scripts/board.sh" move 811 "In progress" 2>&1; echo "rc=$?")"
check "(j) masked-but-real error: original error surfaced verbatim" "unknown owner type" "$out"
check "(j) masked-but-real error: queued, exits 0 (round 2: a live unrecognised error never stops work)" "rc=0" "$out"
check "(j) masked-but-real error: QUEUED as a gh error, not as a rate limit" "QUEUED (gh error): move #" "$out"
qf="$BQ/.claude/board-queue.jsonl"
check "(j) masked-but-real error: queued with attempts=1" '"attempts": "1"' "$(cat "$qf" 2>/dev/null)"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC"

# --- (k) #90: move's item-id LOOKUP (item-list) fails masked-rate-limited -> QUEUED, not "bad issue# or status" ---
_qsetup
_seed_seen 812
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
_seed_seen 813
LOG="$(mktemp)"; EDITCC="$(mktemp)"
out="$(cd "$BQ" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG" FAKE_GH_EDIT_CALLCOUNT="$EDITCC" FAKE_GH_LIST_CALLCOUNT="$(mktemp)" \
    FAKE_GH_ISSUE_NUM=813 FAKE_GH_ITEM_VISIBLE=1 \
    FAKE_GH_EDIT_MASKED_RATE_LIMIT_FROM=1 FAKE_GH_RATE_LIMIT_REAL_SAMPLE=rate-limit-endpoint-sample.json \
    bash "$PLUGIN/scripts/board.sh" move 813 "In progress" 2>&1; echo "rc=$?")"
check "(t) real rate_limit sample (remaining=41): masked error surfaced verbatim" "unknown owner type" "$out"
check "(t) real rate_limit sample (remaining=41): queued, exits 0 (round 2: a live unrecognised error never stops work)" "rc=0" "$out"
check "(t) real rate_limit sample (remaining=41): QUEUED as a gh error, not as a rate limit" "QUEUED (gh error): move #" "$out"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC"

_qsetup
_seed_seen 814
LOG="$(mktemp)"; EDITCC="$(mktemp)"
out="$(cd "$BQ" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG" FAKE_GH_EDIT_CALLCOUNT="$EDITCC" FAKE_GH_LIST_CALLCOUNT="$(mktemp)" \
    FAKE_GH_ISSUE_NUM=814 FAKE_GH_ITEM_VISIBLE=1 \
    FAKE_GH_EDIT_MASKED_RATE_LIMIT_FROM=1 FAKE_GH_RATE_LIMIT_REAL_SAMPLE=rate-limit-endpoint-near-exhausted.json \
    bash "$PLUGIN/scripts/board.sh" move 814 "In progress" 2>&1; echo "rc=$?")"
check "(u) real rate_limit sample (remaining=1, near-exhausted boundary): masked error surfaced verbatim" "unknown owner type" "$out"
check "(u) real rate_limit sample (remaining=1, near-exhausted boundary): queued, exits 0 (round 2: a live unrecognised error never stops work)" "rc=0" "$out"
check "(u) real rate_limit sample (remaining=1, near-exhausted boundary): QUEUED as a gh error, not as a rate limit" "QUEUED (gh error): move #" "$out"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC"

# --- (v) #101: _rate_limit_reset_human against a REAL rate_limit payload that
# LACKS resources.graphql -- the only shape that fires its fallback branch.
# rate-limit-endpoint-graphql-absent.json is the live sample with the graphql
# key stripped; in that real sample the top-level `rate` key ALIASES core, whose
# reset (1783513577 -> 2026-07-08T12:26:17Z) is ~12min LATER than the removed
# graphql reset (1783512842 -> 2026-07-08T12:14:02Z). An honest-text rate-limit
# on the move queues it, then _rate_limit_reset_human probes the endpoint for the
# QUEUED message's "until X". The fallback must NOT report core's time as if it
# were graphql's (a wrong-but-confident timestamp is worse than an honest
# unknown), and the helper must not leak a datetime.utcfromtimestamp
# DeprecationWarning (Python 3.13) into that message.
_qsetup
_seed_seen 815
LOG="$(mktemp)"; EDITCC="$(mktemp)"; ERR="$(mktemp)"
out="$(cd "$BQ" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG" FAKE_GH_EDIT_CALLCOUNT="$EDITCC" FAKE_GH_LIST_CALLCOUNT="$(mktemp)" \
    FAKE_GH_ISSUE_NUM=815 FAKE_GH_ITEM_VISIBLE=1 \
    FAKE_GH_EDIT_RATE_LIMIT_FROM=1 FAKE_GH_RATE_LIMIT_REAL_SAMPLE=rate-limit-endpoint-graphql-absent.json \
    bash "$PLUGIN/scripts/board.sh" move 815 "In progress" 2>"$ERR"; echo "rc=$?")"
err="$(cat "$ERR")"
check "(v) graphql-absent reset: QUEUED reports an honest 'unknown', not core's reset" "QUEUED (rate-limited until unknown): move #815 -> In progress" "$out"
check_absent "(v) graphql-absent reset: does NOT report core's reset as if graphql's" "2026-07-08T12:26:17Z" "$out"
check "(v) graphql-absent reset: move still queued (exits 0)" "rc=0" "$out"
check_absent "(v) graphql-absent reset: no utcfromtimestamp DeprecationWarning leaks to stderr" "DeprecationWarning" "$err"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$ERR"

echo "== board.sh flush concurrency (#92): mutual exclusion, lost-append prevention, stale lock, adopt status =="

# --- (m) two concurrent flushers: mutual exclusion -> zero op loss, exactly-once
# application, the loser skips without ever touching gh. Uses _flush_sync (a
# test-only hook in board-queue.sh) to pin the exact interleaving instead of
# racing wall-clock sleeps: flusher A pauses right after it commits to a batch
# (pre-fix: right after its snapshot copy, before the destructive truncate;
# post-fix: once it holds the lock) so flusher B is guaranteed to start while
# A is still mid-flush.
_qsetup
mkdir -p "$BQ/.claude" "$BQ/.neural-network"
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
mkdir -p "$BQ/.claude" "$BQ/.neural-network"
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
mkdir -p "$BQ/.claude" "$BQ/.neural-network" "$BQ/.claude/board-queue.lock"
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
mkdir -p "$BQ/.claude" "$BQ/.neural-network"
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
mkdir -p "$BQ/.claude" "$BQ/.neural-network"
# #236 (CDX-031 gap #4): moving to QA now requires both review passes
# recorded in telemetry (two-pass-review-preflight.sh, wired into _do_move()
# alongside the pre-existing checks) -- seed them here so this scenario
# still exercises the rate-limit/dedupe interleaving it targets, not the
# (separately covered, see section-two-pass-review-preflight.sh) two-pass
# gate itself.
printf '{"kind":"review-round","task":"900","round":1,"verdict":"approved","pass":"spec-compliance","ts":"2020-01-01T00:00:00Z"}\n{"kind":"review-round","task":"900","round":2,"verdict":"approved","pass":"code-quality","ts":"2020-01-01T00:00:01Z"}\n' >"$BQ/.claude/telemetry.jsonl"
# #561: local guards now run before the replay's board read, so the queued Ready move
# meets closure-preflight before the "already Ready" skip. Record closure evidence so
# this scenario keeps exercising the dedupe/skip it targets.
printf '{"kind":"retro-skip","task":"900","reason":"fixture","ts":"2020-01-01T00:00:02Z"}\n' >>"$BQ/.claude/telemetry.jsonl"
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
mkdir -p "$BQ/.claude" "$BQ/.neural-network"
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
mkdir -p "$BQ/.claude" "$BQ/.neural-network"
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
mkdir -p "$BQ/.claude" "$BQ/.neural-network"
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
check "(x) real apply failure: the failed (prio) entry survives on disk in the live queue file (round 3: format-agnostic, the attempts path rewrites the line)" '"op": "prio", "issue": "930"' "$remainder"
check "(x) real apply failure: the failure is counted on the entry" '"attempts": "1"' "$remainder"
check_absent "(x) real apply failure: the OTHER (successful, est) entry is not left behind too" '"op": "est"' "$remainder"
rm -rf "$BQ" "$FGH" "$LOG" "$LISTCC" "$EDITCC"

# --- (y) liveness probe: a lockdir whose pidfile names a definitively-dead
# PID is broken IMMEDIATELY, even with a long TTL that would not otherwise
# have expired -- this must not depend on waiting out BOARD_QUEUE_LOCK_TTL. ---
_qsetup
mkdir -p "$BQ/.claude" "$BQ/.neural-network" "$BQ/.claude/board-queue.lock"
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
mkdir -p "$BQ/.claude" "$BQ/.neural-network" "$BQ/.claude/board-queue.lock"
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
mkdir -p "$BQ/.claude" "$BQ/.neural-network"
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

# =====================================================================
# #561 -- board truth: queue failed moves and replay them ASAP.
# A non-guard failure (transient API/network, 5xx, timeout, incomplete
# snapshot, busy admission mutex) is queued and exits 0; a guard refusal
# is NOT queued. Replay shares ONE board snapshot, and the pending
# display reads the local queue file only.
# =====================================================================
echo "== board.sh queue failed moves (#561): fake gh =="

# _bq <extra env assignments...> -- <board.sh args...>: run board.sh in $BQ, all output + rc.
_bq() {
    local -a envs=()
    while [[ "$1" != "--" ]]; do envs+=("$1"); shift; done
    shift
    (cd "$BQ" && env PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG" FAKE_GH_EDIT_CALLCOUNT="$EDITCC" FAKE_GH_LIST_CALLCOUNT="$LISTCC" \
        FAKE_GH_GRAPHQL_REMAINING=9999 ${envs[@]+"${envs[@]}"} bash "$PLUGIN/scripts/board.sh" "$@" 2>&1; echo "rc=$?")
}
_cnt() { grep -c -- "$1" "$LOG" || true; }  # gh calls whose argv contains $1
_seen_all() { printf '{"%s": true, "%s": true, "%s": true}' "$1" "$2" "$3" >"$BQ/.claude/board-comments-seen.json"; }
_qlogs() { LOG="$(mktemp)"; EDITCC="$(mktemp)"; LISTCC="$(mktemp)"; }

# --- (ab) classifier: real-form gh transient wording is recognised; a schema error is not ---
_qsetup
_lbl() { bash -c 'ROOT=/nonexistent; source "$1"; _gh_failure_label "$2"' _ "$PLUGIN/scripts/board-queue.sh" "$(awk 'f{print} /^$/{f=1}' "$GH_FAILURES/$1")"; }
check "(ab) classifier: HTTP 502 -> 'HTTP 502'" "HTTP 502" "$(_lbl transient-http-502.txt)"
check "(ab) classifier: HTTP 504 gateway timeout -> 'HTTP 504' (status wins over the word timeout)" "HTTP 504" "$(_lbl transient-http-504.txt)"
check "(ab) classifier: context deadline -> 'timeout'" "timeout" "$(_lbl transient-timeout.txt)"
check "(ab) classifier: error connecting -> 'network error'" "network error" "$(_lbl transient-connecting.txt)"
check "(ab) classifier: no such host -> 'network error'" "network error" "$(_lbl transient-no-such-host.txt)"
check "(ab) classifier: gh api graphql wording 'gh: Bad Gateway (HTTP 502)' -> 'HTTP 502'" "HTTP 502" "$(_lbl transient-graphql-502.txt)"
check "(ab) classifier: an unrecognised error is a generic 'gh error'" "gh error" "$(bash -c 'ROOT=/nonexistent; source "$1"; _gh_failure_label "GraphQL: field value does not match schema (invalid input)"' _ "$PLUGIN/scripts/board-queue.sh")"
rm -rf "$BQ" "$FGH"

# --- (ac) transient item-edit failure on an In progress move: QUEUED, exit 0, exact gh call counts ---
_calls() { grep -cE '^(api|project|issue) ' "$LOG" || true; }  # top-level gh invocations (query bodies span lines)
_qsetup; _seed_seen 970; _qlogs
out="$(_bq FAKE_GH_ISSUE_NUM=970 FAKE_GH_ITEM_STATUS=Backlog FAKE_GH_EDIT_TRANSIENT=transient-http-502.txt -- move 970 "In progress")"
check "(ac) transient move: QUEUED with the reason" "QUEUED (HTTP 502): move #970 -> In progress" "$out"
check "(ac) transient move: exits 0 (work never stops)" "rc=0" "$out"
check_absent "(ac) transient move: not claimed as rate-limited" "rate-limited" "$out"
check "(ac) transient move: queued on disk" '"op": "move"' "$(cat "$BQ/.claude/board-queue.jsonl" 2>/dev/null)"
check "(ac) transient move: reason stored for the pending display" 'HTTP 502' "$(cat "$BQ/.claude/board-queue.jsonl" 2>/dev/null)"
check_rc "(ac) gh calls for a queued In progress move: exactly 1 board read (admission)" 1 "$(_cnt 'project item-list')"
check_rc "(ac) gh calls for a queued In progress move: exactly 1 edit attempt (no stale-id re-resolve on a 5xx)" 1 "$(_cnt 'project item-edit')"
check_rc "(ac) gh calls for a queued In progress move: NO rate-limit probe for a recognised 5xx" 0 "$(_cnt 'api rate_limit')"
check_rc "(ac) gh calls for a queued In progress move: total" 4 "$(_calls)"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"

# --- (ad) incomplete board snapshot while admitting to a WIP status: QUEUED ---
_qsetup; _seed_seen 971; _qlogs
out="$(_bq FAKE_GH_ISSUE_NUM=971 FAKE_GH_ITEMS_JSON='{"items":[{"id":"ITEM_971","content":{"number":971},"status":"Backlog"}],"totalCount":2}' -- move 971 "In progress")"
check "(ad) incomplete snapshot data: QUEUED, reason names the snapshot" "QUEUED (board snapshot incomplete" "$out"
check "(ad) snapshot failure: exits 0" "rc=0" "$out"
check "(ad) snapshot failure: queued on disk" '"issue": "971"' "$(cat "$BQ/.claude/board-queue.jsonl" 2>/dev/null)"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"

# --- (ae) busy admission mutex: QUEUED ---
_qsetup; _seed_seen 972; _qlogs
mkdir -p "$BQ/.claude/board-wip.lock"
out="$(_bq FAKE_GH_ISSUE_NUM=972 BOARD_WIP_MUTEX_MAX_WAIT_ITERS=3 -- move 972 "In progress")"
check "(ae) busy mutex: QUEUED with the reason" "QUEUED (admission mutex busy): move #972 -> In progress" "$out"
check "(ae) busy mutex: exits 0" "rc=0" "$out"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"

# --- (af) guard refusals are NOT queued and still fail loudly ---
_qsetup; _qlogs   # no comments-seen marker => the comments guard refuses
out="$(_bq FAKE_GH_ISSUE_NUM=973 -- move 973 "In progress")"
check "(af) comments-not-read guard: still printed" "BLOCKED" "$out"
check_absent "(af) comments-not-read guard: exit is non-zero" "rc=0" "$out"
check_absent "(af) comments-not-read guard: not QUEUED" "QUEUED" "$out"
out="$(_bq FAKE_GH_ISSUE_NUM=973 -- move 973 "No Such Status")"
check "(af) bad status: still printed" "bad issue# or status" "$out"
check_absent "(af) bad status: exit is non-zero" "rc=0" "$out"
check_absent "(af) bad status: not QUEUED" "QUEUED" "$out"
_seed_seen 974
out="$(_bq FAKE_GH_ISSUE_NUM=974 FAKE_GH_ITEMS_JSON='{"items":[{"id":"ITEM_1","content":{"number":1},"status":"In progress"},{"id":"ITEM_974","content":{"number":974},"status":"Backlog"}]}' -- move 974 "In progress")"
check "(af) WIP capacity refusal: still printed" "capacity 1/1 occupied" "$out"
check_absent "(af) WIP capacity refusal: exit is non-zero" "rc=0" "$out"
check_absent "(af) WIP capacity refusal: not QUEUED" "QUEUED" "$out"
if [[ -s "$BQ/.claude/board-queue.jsonl" ]]; then echo "FAIL (af) a guard refusal must leave the queue empty"; fails=$((fails + 1)); else echo "ok   (af) guard refusals left the queue empty"; fi
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"

# --- (ag) replay of N queued moves: oldest first, ONE shared snapshot read ---
_qsetup; _seen_all 981 982 983; _qlogs
printf '{"op":"move","issue":"981","status":"Backlog","reason":"HTTP 502","ts":"2020-01-01T00:00:01Z"}\n{"op":"move","issue":"982","status":"Backlog","reason":"HTTP 502","ts":"2020-01-01T00:00:02Z"}\n{"op":"move","issue":"983","status":"Backlog","reason":"HTTP 502","ts":"2020-01-01T00:00:03Z"}\n' >"$BQ/.claude/board-queue.jsonl"
out="$(_bq FAKE_GH_ISSUES="981 982 983" FAKE_GH_ITEM_STATUS=Ready -- flush)"
check "(ag) replay of 3 queued moves: each applied" "moved #983 -> Backlog" "$out"
check "(ag) replay of 3: exactly 1 snapshot read (not one per op)" "1" "$(_cnt 'project item-list')"
check "(ag) replay of 3: exactly 3 edits" "3" "$(_cnt 'project item-edit')"
o1="$(grep -n ITEM_981 "$LOG" | head -1 | cut -d: -f1)"; o3="$(grep -n ITEM_983 "$LOG" | head -1 | cut -d: -f1)"
if [[ -n "$o1" && -n "$o3" && "$o1" -lt "$o3" ]]; then echo "ok   (ag) replay: oldest first"; else echo "FAIL (ag) replay order (981 at '$o1', 983 at '$o3')"; fails=$((fails + 1)); fi
if [[ -s "$BQ/.claude/board-queue.jsonl" ]]; then echo "FAIL (ag) queue should be empty after replay"; fails=$((fails + 1)); else echo "ok   (ag) queue empty after replay"; fi
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"

# --- (ah) replay also runs on a later MOVE call; a replay that still fails stays queued ---
_qsetup; _seen_all 984 985 986; _qlogs
printf '{"op":"move","issue":"984","status":"Backlog","reason":"HTTP 502","ts":"2020-01-01T00:00:01Z"}\n' >"$BQ/.claude/board-queue.jsonl"
out="$(_bq FAKE_GH_ISSUES="984 985" FAKE_GH_ITEM_STATUS=Ready -- move 985 Backlog)"
check "(ah) a later move call replays the older queued move" "moved #984 -> Backlog" "$out"
check "(ah) and then applies its own move" "moved #985 -> Backlog" "$out"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"
_qsetup; _qlogs
printf '{"op":"move","issue":"987","status":"Backlog","reason":"HTTP 502","ts":"2020-01-01T00:00:01Z"}\n' >"$BQ/.claude/board-queue.jsonl"
out="$(_bq FAKE_GH_ISSUES="987" FAKE_GH_ITEM_STATUS=Ready FAKE_GH_EDIT_TRANSIENT=transient-timeout.txt -- flush)"
check "(ah) replay still failing: stays queued" '"issue":"987"' "$(cat "$BQ/.claude/board-queue.jsonl" 2>/dev/null)"
check "(ah) replay still failing: exits 0" "rc=0" "$out"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"

# --- (ai) replay: a refusal that can never clear DROPS the entry with a printed line ---
_qsetup; _qlogs   # a status that is not in statusFlow can never apply
printf '{"op":"move","issue":"988","status":"No Such Status","reason":"HTTP 502","ts":"2020-01-01T00:00:01Z"}\n' >"$BQ/.claude/board-queue.jsonl"
out="$(_bq FAKE_GH_ISSUES="988" FAKE_GH_ITEM_STATUS="In review" -- flush)"
check "(ai) guard refusal on replay: dropped with a printed line" "flush: DROPPED move #988 -> No Such Status" "$out"
if [[ -s "$BQ/.claude/board-queue.jsonl" ]]; then echo "FAIL (ai) dropped entry still in the queue"; fails=$((fails + 1)); else echo "ok   (ai) dropped entry left the queue"; fi
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"

# --- (aj) add: a non-rate-limit item-add failure queues add-finish ---
_qsetup; _qlogs
out="$(_bq FAKE_GH_ISSUE_NUM=990 FAKE_GH_ITEM_ADD_TRANSIENT=transient-http-502.txt -- add --type feature "found something" P2)"
check "(aj) add + item-add failure: QUEUED" "QUEUED (HTTP 502): item-add #990" "$out"
check "(aj) add + item-add failure: exits 0" "rc=0" "$out"
check_absent "(aj) add + item-add failure: no 'not on the board' claim" "it is not on the board" "$out"
check "(aj) add + item-add failure: add-finish queued" '"op": "add-finish"' "$(cat "$BQ/.claude/board-queue.jsonl" 2>/dev/null)"
check "(aj) gh calls: no board read for the queued add" "0" "$(_cnt 'project item-list')"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"
# the false failure: the item IS on the board; replay must not item-add again and sets status + priority
_qsetup; _qlogs
printf '{"op":"add-finish","issue":"991","url":"https://github.com/fixture-owner/fixture-project/issues/991","first_status":"Backlog","prio":"P2","reason":"HTTP 502","ts":"2020-01-01T00:00:01Z"}\n' >"$BQ/.claude/board-queue.jsonl"
out="$(_bq FAKE_GH_ISSUES="991" FAKE_GH_ITEM_STATUS="Ready" -- flush)"
check "(aj) replay of add-finish on an item already on the board: finished" "flush: finished add #991" "$out"
check "(aj) replay: no second item-add" "0" "$(_cnt 'project item-add')"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"

# --- (ak) adopt: a non-rate-limit item-add failure queues adopt ---
_qsetup; _qlogs
out="$(_bq FAKE_GH_ISSUE_NUM=992 FAKE_GH_ITEM_VISIBLE=0 FAKE_GH_ITEM_ADD_TRANSIENT=transient-connecting.txt -- adopt 992)"
check "(ak) adopt + item-add failure: QUEUED" "QUEUED (network error): adopt #992" "$out"
check "(ak) adopt + item-add failure: exits 0" "rc=0" "$out"
check "(ak) adopt + item-add failure: adopt queued" '"op": "adopt"' "$(cat "$BQ/.claude/board-queue.jsonl" 2>/dev/null)"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"

# --- (al) pending display: local file only (0 gh calls); also shown by list ---
_qsetup; _qlogs
printf '{"op":"move","issue":"993","status":"Backlog","reason":"HTTP 502","ts":"2020-01-01T00:00:01Z"}\n' >"$BQ/.claude/board-queue.jsonl"
out="$(_bq -- pending)"
check "(al) pending: prints the PENDING line" "PENDING: move #993 -> Backlog (queued " "$out"
check "(al) pending: shows the reason" "HTTP 502)" "$out"
check "(al) pending: ZERO gh calls" "0" "$(wc -l <"$LOG" | tr -d ' ')"
rm -f "$LOG"; LOG="$(mktemp)"
out="$(_bq FAKE_GH_ISSUES="993" FAKE_GH_ITEM_STATUS=Ready FAKE_GH_EDIT_TRANSIENT=transient-http-502.txt -- list)"
check "(al) list: prints the still-pending move" "PENDING: move #993 -> Backlog" "$out"
check "(al) list: replay shares one snapshot (flush 1 read + list 1 read)" "2" "$(_cnt 'project item-list')"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"


# --- (am) replay of N WIP-status moves: ONE board read total; capacity honoured within the snapshot ---
_qsetup; _seen_all 981 982 983; _qlogs
sed -i 's/maxInProgress: 1/maxInProgress: 3/' "$BQ/.neural-network/project.yaml"
printf '{"op":"move","issue":"981","status":"In progress","reason":"HTTP 502","seq":"1","ts":"2020-01-01T00:00:01Z"}\n{"op":"move","issue":"982","status":"In progress","reason":"HTTP 502","seq":"2","ts":"2020-01-01T00:00:02Z"}\n{"op":"move","issue":"983","status":"In progress","reason":"HTTP 502","seq":"3","ts":"2020-01-01T00:00:03Z"}\n' >"$BQ/.claude/board-queue.jsonl"
out="$(_bq FAKE_GH_ISSUES="981 982 983" FAKE_GH_ITEM_STATUS=Backlog -- flush)"
check "(am) WIP replay of 3: last one applied" "moved #983 -> In progress" "$out"
check_rc "(am) WIP replay of 3: exactly 1 board read in total" 1 "$(_cnt 'project item-list')"
check_rc "(am) WIP replay of 3: exactly 3 edits" 3 "$(_cnt 'project item-edit')"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"
_qsetup; _seen_all 981 982 983; _qlogs
sed -i 's/maxInProgress: 1/maxInProgress: 2/' "$BQ/.neural-network/project.yaml"
printf '{"op":"move","issue":"981","status":"In progress","reason":"HTTP 502","seq":"1","ts":"2020-01-01T00:00:01Z"}\n{"op":"move","issue":"982","status":"In progress","reason":"HTTP 502","seq":"2","ts":"2020-01-01T00:00:02Z"}\n{"op":"move","issue":"983","status":"In progress","reason":"HTTP 502","seq":"3","ts":"2020-01-01T00:00:03Z"}\n' >"$BQ/.claude/board-queue.jsonl"
out="$(_bq FAKE_GH_ISSUES="981 982 983" FAKE_GH_ITEM_STATUS=Backlog -- flush)"
check "(am) capacity 2: the third start is refused by the patched snapshot" "capacity 2/2 occupied" "$out"
check_rc "(am) capacity 2: exactly 2 edits" 2 "$(_cnt 'project item-edit')"
check_rc "(am) capacity 2: still exactly 1 board read" 1 "$(_cnt 'project item-list')"
check "(am) capacity 2: the refused start stays queued" '"issue":"983"' "$(cat "$BQ/.claude/board-queue.jsonl" 2>/dev/null)"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"

# --- (an) local guards run BEFORE any board read: a guard-refused entry costs 0 gh calls per call ---
_qsetup; _qlogs   # no two-pass review recorded => the QA guard refuses
printf '{"op":"move","issue":"985","status":"QA","reason":"HTTP 502","seq":"1","ts":"2020-01-01T00:00:01Z"}\n' >"$BQ/.claude/board-queue.jsonl"
for _i in 1 2 3; do out="$(_bq FAKE_GH_ISSUES="985" FAKE_GH_ITEM_STATUS="In review" -- flush)"; done
check_rc "(an) QA move refused by the two-pass guard, replayed 3 times: 0 gh calls" 0 "$(wc -l <"$LOG" | tr -d ' ')"
check "(an) the refused entry stays queued" '"issue":"985"' "$(cat "$BQ/.claude/board-queue.jsonl" 2>/dev/null)"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"

# --- (ao) retry policy ---
# network/timeout stops the pass (like a rate limit): the second entry is not even tried
_qsetup; _seen_all 995 996 996; _qlogs
printf '{"op":"move","issue":"995","status":"Backlog","reason":"timeout","seq":"1","ts":"2020-01-01T00:00:01Z"}\n{"op":"move","issue":"996","status":"Backlog","reason":"timeout","seq":"2","ts":"2020-01-01T00:00:02Z"}\n' >"$BQ/.claude/board-queue.jsonl"
out="$(_bq FAKE_GH_ISSUES="995 996" FAKE_GH_ITEM_STATUS=Ready FAKE_GH_EDIT_TRANSIENT=transient-timeout.txt -- flush)"
check_rc "(ao) timeout stops the flush pass: only 1 edit attempted" 1 "$(_cnt 'project item-edit')"
check "(ao) a per-entry item-edit timeout has its own line" "flush: move #995 hit a timeout" "$out"
check_absent "(ao) a per-entry item-edit timeout is not called a board read failure" "board read failed" "$out"
check "(ao) timeout: first entry kept" '"issue":"995"' "$(cat "$BQ/.claude/board-queue.jsonl" 2>/dev/null)"
check "(ao) timeout: second entry kept untouched" '"issue":"996"' "$(cat "$BQ/.claude/board-queue.jsonl" 2>/dev/null)"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"
# a 5xx retries forever: six passes, still queued, never dropped
_qsetup; _qlogs
printf '{"op":"move","issue":"997","status":"Backlog","reason":"HTTP 502","seq":"1","ts":"2020-01-01T00:00:01Z"}\n' >"$BQ/.claude/board-queue.jsonl"
for _i in 1 2 3 4 5 6; do out="$(_bq FAKE_GH_ISSUES="997" FAKE_GH_ITEM_STATUS=Ready FAKE_GH_EDIT_TRANSIENT=transient-http-502.txt -- flush)"; done
check "(ao) HTTP 502 retries without limit: still queued after 6 passes" '"issue":"997"' "$(cat "$BQ/.claude/board-queue.jsonl" 2>/dev/null)"
check_absent "(ao) HTTP 502 is never dropped" "DROPPED" "$out"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"
# an unrecognised error label: counted, dropped on the 5th attempt with a clear line
_qsetup; _qlogs
printf '{"op":"adopt","issue":"998","reason":"gh error","attempts":"4","seq":"1","ts":"2020-01-01T00:00:01Z"}\n' >"$BQ/.claude/board-queue.jsonl"
out="$(_bq FAKE_GH_ISSUE_NUM=998 FAKE_GH_ITEM_VISIBLE=0 FAKE_GH_ITEM_ADD_FAIL_TEXT="boom: something gh never said before" -- flush)"
check "(ao) 5th failed attempt: dropped with the fix hint" "flush: DROPPED adopt #998 after 5 attempts (gh error) — fix and re-run board.sh adopt 998" "$out"
if [[ -s "$BQ/.claude/board-queue.jsonl" ]]; then echo "FAIL (ao) dropped entry still queued"; fails=$((fails + 1)); else echo "ok   (ao) dropped entry left the queue"; fi
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"
_qsetup; _qlogs
printf '{"op":"adopt","issue":"998","reason":"gh error","attempts":"1","seq":"1","ts":"2020-01-01T00:00:01Z"}\n' >"$BQ/.claude/board-queue.jsonl"
out="$(_bq FAKE_GH_ISSUE_NUM=998 FAKE_GH_ITEM_VISIBLE=0 FAKE_GH_ITEM_ADD_FAIL_TEXT="boom: something gh never said before" -- flush)"
check "(ao) 2nd failed attempt: counted in the entry" '"attempts": "2"' "$(cat "$BQ/.claude/board-queue.jsonl" 2>/dev/null)"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"
_qsetup; _qlogs
out="$(_bq FAKE_GH_ISSUE_NUM=999 FAKE_GH_ITEM_ADD_FAIL_TEXT="boom: something gh never said before" -- add --type feature "unrecognised failure" P2)"
check "(ao) live add with an unrecognised item-add error: the first attempt is counted" '"attempts": "1"' "$(cat "$BQ/.claude/board-queue.jsonl" 2>/dev/null)"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"

# --- (ap) snapshot failure on a WIP move: transient label queues; anything else is loud ---
_qsetup; _seed_seen 971; _qlogs
out="$(_bq FAKE_GH_ISSUE_NUM=971 FAKE_GH_ITEM_LIST_FAIL_TEXT="HTTP 401: Bad credentials (https://api.github.com/graphql)" -- move 971 "In progress")"
check "(ap) 401 on the snapshot: queued as a gh error (round 2), never stops work" "QUEUED (board read failed: gh error): move #971 -> In progress" "$out"
check "(ap) 401 on the snapshot: exits 0" "rc=0" "$out"
check "(ap) 401 on the snapshot: attempts=1, same as a non-WIP live move" '"attempts": "1"' "$(cat "$BQ/.claude/board-queue.jsonl" 2>/dev/null)"
check "(ap) 401 on the snapshot: GitHub's error is shown" "Bad credentials" "$out"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"
_qsetup; _seed_seen 971; _qlogs
out="$(_bq FAKE_GH_ISSUE_NUM=971 FAKE_GH_ITEM_LIST_TRANSIENT=transient-timeout.txt -- move 971 "In progress")"
check "(ap) timeout on the snapshot: queued with the label" "QUEUED (board read failed: timeout): move #971 -> In progress" "$out"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"

# --- (aq) supersede: the drop runs under the queue file lock; a concurrent flush honours it ---
_qh() { bash -c 'ROOT="$1"; export BOARD_QUEUE_FILE="$2"; source "$3"; shift 3; "$@"' _ "$QT" "$QT/q.jsonl" "$PLUGIN/scripts/board-queue.sh" "$@"; }
_wait_for() { local f="$1" n=0; while [[ ! -e "$f" && "$n" -lt 200 ]]; do sleep 0.05; n=$((n + 1)); done; [[ -e "$f" ]]; }
QT="$(mktemp -d)"; mkdir -p "$QT"
printf '{"op":"move","issue":"7","status":"Backlog","seq":"1","ts":"2020-01-01T00:00:01Z"}\n{"op":"move","issue":"8","status":"Backlog","seq":"2","ts":"2020-01-01T00:00:02Z"}\n' >"$QT/q.jsonl"
mkdir "$QT/board-queue.file.lock"   # hold the lock by hand
_qh _queue_drop_moves 7 & DPID=$!
_qh queue_append move issue=9 status=Backlog & APID=$!
if _wait_for "$QT/board-queue.superseded/7"; then echo "ok   (aq) drop writes its supersede marker before waiting for the lock"; else echo "FAIL (aq) no supersede marker"; fails=$((fails + 1)); fi
check "(aq) while the lock is held the queue file is untouched (old move still there)" '"issue":"7"' "$(cat "$QT/q.jsonl")"
rmdir "$QT/board-queue.file.lock"
wait "$DPID"; wait "$APID"
qc="$(cat "$QT/q.jsonl")"
check_absent "(aq) after the lock: the superseded move #7 is gone" '"issue": "7"' "$qc"
check_absent "(aq) after the lock: no compact #7 either" '"issue":"7"' "$qc"
check "(aq) the unrelated move #8 survives the rewrite" '"issue":"8"' "$qc"
check "(aq) the racing append (#9) was not lost" '"issue": "9"' "$qc"
check_rc "(aq) exactly 2 entries remain" 2 "$(grep -c . "$QT/q.jsonl")"
rm -rf "$QT"
# a flush replaying an older entry honours the marker (0 gh calls)
_qsetup; _seen_all 7 7 7; _qlogs
printf '{"op":"move","issue":"7","status":"Backlog","reason":"HTTP 502","seq":"1000","ts":"2020-01-01T00:00:01Z"}\n' >"$BQ/.claude/board-queue.jsonl"
mkdir -p "$BQ/.claude/board-queue.superseded"; printf '2000' >"$BQ/.claude/board-queue.superseded/7"
out="$(_bq FAKE_GH_ISSUES="7" FAKE_GH_ITEM_STATUS=Ready -- flush)"
check "(aq) flush skips a superseded move with a printed line" "flush: skip superseded move #7" "$out"
check_rc "(aq) superseded replay: 0 gh calls" 0 "$(wc -l <"$LOG" | tr -d ' ')"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"
# a direct move that applies (another flusher holds the lock, so no replay first) writes the marker and drops older queued moves
_qsetup; _seen_all 7 7 7; _qlogs
printf '{"op":"move","issue":"7","status":"Backlog","reason":"HTTP 502","seq":"1","ts":"2020-01-01T00:00:01Z"}\n{"op":"move","issue":"8","status":"Backlog","reason":"HTTP 502","seq":"2","ts":"2020-01-01T00:00:02Z"}\n' >"$BQ/.claude/board-queue.jsonl"
mkdir "$BQ/.claude/board-queue.lock"; echo "$$" >"$BQ/.claude/board-queue.lock/pid"
out="$(_bq FAKE_GH_ISSUES="7 8" FAKE_GH_ITEM_STATUS=Ready -- move 7 Backlog)"
check "(aq) direct move applied while another flusher held the lock" "moved #7 -> Backlog" "$out"
check_absent "(aq) direct move: the older queued #7 was dropped" '"issue":"7"' "$(cat "$BQ/.claude/board-queue.jsonl")"
check "(aq) direct move: the unrelated queued #8 is kept" '"issue":"8"' "$(cat "$BQ/.claude/board-queue.jsonl")"
if [[ -f "$BQ/.claude/board-queue.superseded/7" ]]; then echo "ok   (aq) direct move: supersede marker written"; else echo "FAIL (aq) direct move: no supersede marker"; fails=$((fails + 1)); fi
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"

# --- (ar) reason plumbing: no predictable /tmp path, nothing of ours left behind
# (paginate.sh's sw-gh-reset file is a separate, pre-existing leak and is ignored here) ---
check_absent "(ar) no pid-derived reason file path in board-queue.sh" 'board-qreason.$$' "$(cat "$PLUGIN/scripts/board-queue.sh")"
_qsetup; _qlogs; TD="$(mktemp -d)"
out="$(_bq TMPDIR="$TD" FAKE_GH_ISSUE_NUM=970 FAKE_GH_ITEM_STATUS=Ready FAKE_GH_EDIT_TRANSIENT=transient-http-502.txt -- move 970 Backlog)"
check "(ar) queued move still reports its reason" "QUEUED (HTTP 502)" "$out"
check_rc "(ar) no temp files left behind after the run" 0 "$(find "$TD" -type f ! -name 'sw-gh-reset.*' | grep -c . || true)"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC" "$TD"


# =====================================================================
# #561 review round 2
# =====================================================================
echo "== board.sh queue failed moves (#561 round 2) =="

# --- (as) WIP over-admission: the flush takes the WIP mutex BEFORE its snapshot and holds it ---
_qsetup; _seen_all 981 982 983; _qlogs
printf '{"op":"move","issue":"981","status":"In progress","reason":"HTTP 502","seq":"1","ts":"2020-01-01T00:00:01Z"}\n' >"$BQ/.claude/board-queue.jsonl"
SYNC="$(mktemp -d)"; : >"$SYNC/.board-queue-test-sync"
: >"$SYNC/wipflush.go"; : >"$SYNC/wipflush-done.go"   # only the -snap pause is wanted
(_bq FAKE_GH_ISSUES="981 982 983" FAKE_GH_ITEM_STATUS=Backlog BOARD_QUEUE_TEST_SYNC="$SYNC" BOARD_QUEUE_TEST_TAG=wipflush -- flush >"$SYNC/flush.out") &
FPID=$!
_wait_for "$SYNC/wipflush-snap.ready" || echo "FAIL (as) flush never reached the snapshot sync point" >&2
# a LIVE start while the flush holds its snapshot: must not be admitted
out="$(_bq FAKE_GH_ISSUES="981 982 983" FAKE_GH_ITEM_STATUS=Backlog BOARD_WIP_MUTEX_MAX_WAIT_ITERS=3 BOARD_QUEUE_FILE_LOCK_ITERS=3 -- move 982 "In progress")"
check "(as) live start during the replay waits for the mutex and queues" "QUEUED (admission mutex busy): move #982 -> In progress" "$out"
check "(as) the live start exits 0" "rc=0" "$out"
: >"$SYNC/wipflush-snap.go"
wait "$FPID"
check_rc "(as) WIP limit 1 is never exceeded: exactly 1 edit in total (the replayed start only)" 1 "$(_cnt 'project item-edit')"
check "(as) the replayed start applied" "moved #981 -> In progress" "$(cat "$SYNC/flush.out")"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC" "$SYNC"

# --- (at) a board-wide read failure never counts attempts and never drops the queue ---
_qsetup; _seen_all 971 972 973; _qlogs
for n in 971 972 973; do printf '{"op":"move","issue":"%s","status":"Backlog","reason":"HTTP 502","attempts":"4","seq":"%s","ts":"2020-01-01T00:00:01Z"}\n' "$n" "$n" >>"$BQ/.claude/board-queue.jsonl"; done
for _i in 1 2 3 4 5 6; do out="$(_bq FAKE_GH_ISSUES="971 972 973" FAKE_GH_ITEM_LIST_FAIL_TEXT="HTTP 401: Bad credentials (https://api.github.com/graphql)" -- flush)"; done
check "(at) auth outage: one loud line, queue kept" "flush: board read failed" "$out"
check_rc "(at) auth outage: exactly one board read per pass (6 passes, 6 reads)" 6 "$(_cnt 'project item-list')"
check_absent "(at) auth outage: nothing is dropped" "DROPPED" "$out"
check_rc "(at) auth outage, 6 passes: all 3 entries still queued" 3 "$(grep -c . "$BQ/.claude/board-queue.jsonl")"
check_rc "(at) auth outage: attempts untouched (still 4 on every entry)" 3 "$(grep -c '"attempts":"4"' "$BQ/.claude/board-queue.jsonl")"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"

# --- (au) per-entry unrecognised item-edit error in replay: attempts path, no stale-id re-read ---
_qsetup; _seen_all 975 975 975; _qlogs
printf '{"op":"move","issue":"975","status":"Backlog","reason":"gh error","attempts":"4","seq":"1","ts":"2020-01-01T00:00:01Z"}\n' >"$BQ/.claude/board-queue.jsonl"
out="$(_bq FAKE_GH_ISSUES="975" FAKE_GH_ITEM_STATUS=Ready FAKE_GH_EDIT_FAIL_TEXT="GraphQL: Could not resolve to a node with the global id of 'x'" -- flush)"
check "(au) 5th failed attempt of a move: dropped, hint carries the status" 'flush: DROPPED move #975 after 5 attempts (gh error) — fix and re-run board.sh move 975 "Backlog"' "$out"
check_rc "(au) replay of one failing move: exactly 1 board read (no stale-id re-read)" 1 "$(_cnt 'project item-list')"
check_rc "(au) replay of one failing move: exactly 1 edit" 1 "$(_cnt 'project item-edit')"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"
_qsetup; _seen_all 976 976 976; _qlogs
sed -i 's/maxInProgress: 1/maxInProgress: 3/' "$BQ/.neural-network/project.yaml"
printf '{"op":"move","issue":"976","status":"In progress","reason":"gh error","attempts":"1","seq":"1","ts":"2020-01-01T00:00:01Z"}\n' >"$BQ/.claude/board-queue.jsonl"
out="$(_bq FAKE_GH_ISSUES="976" FAKE_GH_ITEM_STATUS=Backlog FAKE_GH_EDIT_FAIL_TEXT="GraphQL: Could not resolve to a node with the global id of 'x'" -- flush)"
check "(au) WIP move: failure counted in the entry" '"attempts": "2"' "$(cat "$BQ/.claude/board-queue.jsonl" 2>/dev/null)"
check_rc "(au) WIP move replay: exactly 1 board read" 1 "$(_cnt 'project item-list')"
check_rc "(au) WIP move replay: exactly 1 edit" 1 "$(_cnt 'project item-edit')"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"

# --- (av) a live unrecognised move error is queued with attempts=1 (round 2 decision) ---
_qsetup; _qlogs
out="$(_bq FAKE_GH_ISSUE_NUM=977 FAKE_GH_ITEM_STATUS=Ready FAKE_GH_EDIT_FAIL_TEXT="GraphQL: Could not resolve to a node with the global id of 'x'" -- move 977 Backlog)"
check "(av) live move, unrecognised gh error: QUEUED" "QUEUED (gh error): move #977 -> Backlog" "$out"
check "(av) live move, unrecognised gh error: exit 0" "rc=0" "$out"
check "(av) live move, unrecognised gh error: attempts=1" '"attempts": "1"' "$(cat "$BQ/.claude/board-queue.jsonl" 2>/dev/null)"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"

# --- (av2) a live board READ failure with an unrecognised error is queued with attempts=1 too ---
_qsetup; _qlogs
out="$(_bq FAKE_GH_ISSUE_NUM=978 FAKE_GH_ITEM_LIST_FAIL_TEXT="GraphQL: Your token has not been granted the required scopes" -- move 978 Backlog)"
check "(av2) live move, unreadable board: QUEUED with the read reason" "QUEUED (board read failed: gh error): move #978 -> Backlog" "$out"
check "(av2) live move, unreadable board: attempts=1" '"attempts": "1"' "$(cat "$BQ/.claude/board-queue.jsonl" 2>/dev/null)"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"

# --- (aw) add-finish with the network down: stop the pass after ONE board read, attempts untouched ---
_qsetup; _qlogs
printf '{"op":"add-finish","issue":"991","url":"https://github.com/fixture-owner/fixture-project/issues/991","first_status":"Backlog","prio":"P2","seq":"1","ts":"2020-01-01T00:00:01Z"}\n{"op":"add-finish","issue":"992","url":"https://github.com/fixture-owner/fixture-project/issues/992","first_status":"Backlog","prio":"P2","seq":"2","ts":"2020-01-01T00:00:02Z"}\n' >"$BQ/.claude/board-queue.jsonl"
out="$(_bq FAKE_GH_ITEM_LIST_TRANSIENT=transient-timeout.txt -- flush)"
check_rc "(aw) network down: exactly 1 board read for 2 queued add-finish" 1 "$(_cnt 'project item-list')"
check_rc "(aw) network down: both entries still queued" 2 "$(grep -c . "$BQ/.claude/board-queue.jsonl")"
check_absent "(aw) network down: no attempts counted" "attempts" "$(cat "$BQ/.claude/board-queue.jsonl")"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"

# --- (ax) the supersede marker time is the apply time handed in, not the drop time ---
QT="$(mktemp -d)"
printf '{"op":"move","issue":"7","status":"Backlog","seq":"4999","ts":"2020-01-01T00:00:01Z"}\n{"op":"move","issue":"7","status":"In review","seq":"5001","ts":"2020-01-01T00:00:02Z"}\n' >"$QT/q.jsonl"
_qh _queue_drop_moves 7 5000
qc="$(cat "$QT/q.jsonl")"
check_absent "(ax) a move queued BEFORE the apply is dropped" '"seq":"4999"' "$qc"
check "(ax) a move queued AFTER the apply is kept" '"seq":"5001"' "$qc"
rm -rf "$QT"

# --- (ay) queue file lock: dead holder broken at once; live holder -> spool, never an unlocked write ---
QT="$(mktemp -d)"; mkdir "$QT/board-queue.file.lock"
( : ) & DEADP=$!; wait "$DEADP"; echo "$DEADP" >"$QT/board-queue.file.lock/pid"
BOARD_QUEUE_FILE_LOCK_ITERS=2 _qh queue_append move issue=5 status=Backlog
check_rc "(ay) dead-holder file lock is broken and released" 0 "$([[ -d "$QT/board-queue.file.lock" ]] && echo 1 || echo 0)"
check "(ay) append after breaking the stale lock lands in the queue" '"issue": "5"' "$(cat "$QT/q.jsonl" 2>/dev/null)"
rm -rf "$QT"
QT="$(mktemp -d)"; mkdir "$QT/board-queue.file.lock"; echo "$$" >"$QT/board-queue.file.lock/pid"
BOARD_QUEUE_FILE_LOCK_ITERS=2 _qh queue_append move issue=6 status=Backlog
check_rc "(ay) live-holder lock: queue file not written unlocked" 0 "$([[ -s "$QT/q.jsonl" ]] && echo 1 || echo 0)"
check_rc "(ay) live-holder lock: the entry was spooled (1 file)" 1 "$(find "$QT/board-queue.spool" -type f 2>/dev/null | grep -c . || true)"
rm -rf "$QT"
# a spooled entry is merged and replayed by the next flush
_qsetup; _seen_all 7 7 7; _qlogs
mkdir -p "$BQ/.claude/board-queue.spool"
printf '{"op":"move","issue":"7","status":"Backlog","reason":"HTTP 502","seq":"9","ts":"2020-01-01T00:00:01Z"}\n' >"$BQ/.claude/board-queue.spool/0001.1"
out="$(_bq FAKE_GH_ISSUES="7" FAKE_GH_ITEM_STATUS=Ready -- flush)"
check "(ay) flush merges and replays the spooled entry" "moved #7 -> Backlog" "$out"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"

# --- (az) cleanup registry, not trap parsing ---
check_absent "(az) no trap -p parsing in board-queue.sh" 'trap -p' "$(cat "$PLUGIN/scripts/board-queue.sh")"


# =====================================================================
# #561 review round 3
# =====================================================================
echo "== board.sh queue failed moves (#561 round 3) =="

# --- (ba) a mixed queue [Backlog, In progress] reads the board ONCE ---
_qsetup; _seen_all 5 6 6; _qlogs
sed -i 's/maxInProgress: 1/maxInProgress: 3/' "$BQ/.neural-network/project.yaml"
printf '{"op":"move","issue":"5","status":"Backlog","reason":"HTTP 502","seq":"1","ts":"2020-01-01T00:00:01Z"}\n{"op":"move","issue":"6","status":"In progress","reason":"HTTP 502","seq":"2","ts":"2020-01-01T00:00:02Z"}\n' >"$BQ/.claude/board-queue.jsonl"
out="$(_bq FAKE_GH_ISSUES="5 6" FAKE_GH_ITEM_STATUS=Ready -- flush)"
check "(ba) mixed queue: the WIP start applied" "moved #6 -> In progress" "$out"
check_rc "(ba) mixed queue [Backlog, In progress]: exactly 1 board read" 1 "$(_cnt 'project item-list')"
check_rc "(ba) mixed queue: exactly 2 edits" 2 "$(_cnt 'project item-edit')"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"

# --- (bb) live add / adopt whose read-back fails: queued with a reason, exit 0 ---
_qsetup; _qlogs
out="$(_bq FAKE_GH_ISSUE_NUM=990 FAKE_GH_ITEM_LIST_FAIL_TEXT="GraphQL: Your token has not been granted the required scopes" -- add --type feature "found something" P2)"
check "(bb) add + unreadable board: QUEUED with the read reason" "QUEUED (board read failed: gh error): item-add #990" "$out"
check "(bb) add + unreadable board: exit 0" "rc=0" "$out"
check_absent "(bb) add + unreadable board: no DEFERRED stop" "DEFERRED" "$out"
check "(bb) add + unreadable board: add-finish queued with attempts=1" '"attempts": "1"' "$(cat "$BQ/.claude/board-queue.jsonl" 2>/dev/null)"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"

# --- (bc) queue file lock: the break verifies the pid it probed; unlock only removes our own lock ---
_dead_pid() { ( : ) & local d=$!; wait "$d"; echo "$d"; }
QT="$(mktemp -d)"; mkdir "$QT/board-queue.file.lock"; echo "$$" >"$QT/board-queue.file.lock/pid"
_qh _lock_break_if "$QT/board-queue.file.lock" 999999
check_rc "(bc) break probed for a DIFFERENT pid leaves a live lock alone" 1 "$([[ -d "$QT/board-queue.file.lock" ]] && echo 1 || echo 0)"
check "(bc) and the live holder's pid file is intact" "$$" "$(cat "$QT/board-queue.file.lock/pid" 2>/dev/null)"
DP="$(_dead_pid)"; echo "$DP" >"$QT/board-queue.file.lock/pid"
_qh _lock_break_if "$QT/board-queue.file.lock" "$DP"
check_rc "(bc) break of the probed dead pid removes the lock" 0 "$([[ -d "$QT/board-queue.file.lock" ]] && echo 1 || echo 0)"
mkdir "$QT/board-queue.file.lock"; echo "$$" >"$QT/board-queue.file.lock/pid"
_qh _qfile_unlock
check_rc "(bc) unlock by a process that is not the holder leaves the lock" 1 "$([[ -d "$QT/board-queue.file.lock" ]] && echo 1 || echo 0)"
rm -rf "$QT"

# --- (bd) prio/est replay: attempts path, no stale-id re-read, board-wide failure stops the pass ---
_qsetup; _qlogs
printf '{"op":"prio","issue":"930","priority":"P1","seq":"1","ts":"2020-01-01T00:00:01Z"}\n' >"$BQ/.claude/board-queue.jsonl"
out="$(_bq FAKE_GH_ISSUES="930" FAKE_GH_ITEM_STATUS=Backlog FAKE_GH_EDIT_FAIL_TEXT="GraphQL: Could not resolve to a node with the global id of 'x'" -- flush)"
check "(bd) prio replay failure is counted" '"attempts": "1"' "$(cat "$BQ/.claude/board-queue.jsonl" 2>/dev/null)"
check_rc "(bd) prio replay failure: exactly 1 board read (no stale-id re-read)" 1 "$(_cnt 'project item-list')"
check_rc "(bd) prio replay failure: exactly 1 edit" 1 "$(_cnt 'project item-edit')"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"
_qsetup; _qlogs
printf '{"op":"prio","issue":"930","priority":"P1","attempts":"4","seq":"1","ts":"2020-01-01T00:00:01Z"}\n{"op":"est","issue":"931","points":"5","attempts":"4","seq":"2","ts":"2020-01-01T00:00:02Z"}\n' >"$BQ/.claude/board-queue.jsonl"
out="$(_bq FAKE_GH_ISSUES="930 931" FAKE_GH_ITEM_LIST_FAIL_TEXT="HTTP 401: Bad credentials (https://api.github.com/graphql)" -- flush)"
check "(bd) unreadable board on prio/est: the pass stops with the board line" "flush: board read failed" "$out"
check_rc "(bd) unreadable board on prio/est: exactly 1 board read" 1 "$(_cnt 'project item-list')"
check_rc "(bd) unreadable board on prio/est: both entries kept" 2 "$(grep -c . "$BQ/.claude/board-queue.jsonl")"
check_rc "(bd) unreadable board on prio/est: attempts untouched" 2 "$(grep -c '"attempts":"4"' "$BQ/.claude/board-queue.jsonl")"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"

# --- (be) a WIP mutex whose holder is dead is broken (live move and flush) ---
_qsetup; _seed_seen 984; _qlogs
mkdir -p "$BQ/.claude/board-wip.lock"; _dead_pid >"$BQ/.claude/board-wip.lock/pid"
out="$(_bq FAKE_GH_ISSUES="984" FAKE_GH_ITEM_STATUS=Backlog BOARD_WIP_MUTEX_MAX_WAIT_ITERS=3 -- move 984 "In progress")"
check "(be) live start: a dead holder's WIP mutex is broken, the move applies" "moved #984 -> In progress" "$out"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"
_qsetup; _seen_all 985 985 985; _qlogs
mkdir -p "$BQ/.claude/board-wip.lock"; _dead_pid >"$BQ/.claude/board-wip.lock/pid"
printf '{"op":"move","issue":"985","status":"In progress","reason":"HTTP 502","seq":"1","ts":"2020-01-01T00:00:01Z"}\n' >"$BQ/.claude/board-queue.jsonl"
out="$(_bq FAKE_GH_ISSUES="985" FAKE_GH_ITEM_STATUS=Backlog BOARD_WIP_MUTEX_MAX_WAIT_ITERS=3 -- flush)"
check "(be) flush: a dead holder's WIP mutex is broken, the start applies" "moved #985 -> In progress" "$out"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"
# a live holder is never broken
_qsetup; _seed_seen 986; _qlogs
mkdir -p "$BQ/.claude/board-wip.lock"; echo "$$" >"$BQ/.claude/board-wip.lock/pid"
out="$(_bq FAKE_GH_ISSUES="986" FAKE_GH_ITEM_STATUS=Backlog BOARD_WIP_MUTEX_MAX_WAIT_ITERS=3 -- move 986 "In progress")"
check "(be) a LIVE holder's WIP mutex is never broken" "QUEUED (admission mutex busy): move #986 -> In progress" "$out"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"

# --- (bf) flush skips the pass when the queue file lock stays busy (no unlocked move-aside) ---
_qsetup; _seen_all 987 987 987; _qlogs
printf '{"op":"move","issue":"987","status":"Backlog","seq":"1","ts":"2020-01-01T00:00:01Z"}\n' >"$BQ/.claude/board-queue.jsonl"
mkdir "$BQ/.claude/board-queue.file.lock"; echo "$$" >"$BQ/.claude/board-queue.file.lock/pid"
out="$(_bq FAKE_GH_ISSUES="987" FAKE_GH_ITEM_STATUS=Ready BOARD_QUEUE_FILE_LOCK_ITERS=2 -- flush)"
check "(bf) busy queue file lock: one line, pass skipped" "flush: SKIP -- queue file lock busy" "$out"
check "(bf) busy queue file lock: the queue is untouched" '"issue":"987"' "$(cat "$BQ/.claude/board-queue.jsonl")"
check_rc "(bf) busy queue file lock: 0 gh calls" 0 "$(wc -l <"$LOG" | tr -d ' ')"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"

# --- (bg) dedupe ranks by seq, not the one-second ts ---
_qsetup; _qlogs
printf '{"op":"prio","issue":"930","priority":"P1","seq":"2000","ts":"2020-01-01T00:00:01Z"}\n{"op":"prio","issue":"930","priority":"P2","seq":"1000","ts":"2020-01-01T00:00:01Z"}\n' >"$BQ/.claude/board-queue.jsonl"
out="$(_bq FAKE_GH_ISSUES="930" FAKE_GH_ITEM_STATUS=Backlog -- flush)"
check "(bg) the entry with the higher seq wins inside one second" "prio #930 -> P1" "$out"
check_absent "(bg) the lower seq is dropped, not applied" "prio #930 -> P2" "$out"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"


# =====================================================================
# #561 review round 4
# =====================================================================
echo "== board.sh queue failed moves (#561 round 4) =="

# --- (ca) a queued move for an item that is NOT on the board: 1 read per call, attempts, dropped on the 5th ---
_qsetup; _qlogs
printf '{"op":"move","issue":"998","status":"Backlog","reason":"HTTP 502","seq":"1","ts":"2020-01-01T00:00:01Z"}\n' >"$BQ/.claude/board-queue.jsonl"
for _i in 1 2 3; do out="$(_bq FAKE_GH_ISSUES="1" FAKE_GH_ITEM_STATUS=Backlog -- flush)"; done
check_rc "(ca) absent item, 3 flushes: exactly 3 board reads (1 per call)" 3 "$(_cnt 'project item-list')"
check_rc "(ca) absent item, 3 flushes: 0 edits" 0 "$(_cnt 'project item-edit')"
check "(ca) absent item: counted on the entry" '"attempts": "3"' "$(cat "$BQ/.claude/board-queue.jsonl" 2>/dev/null)"
for _i in 4 5; do out="$(_bq FAKE_GH_ISSUES="1" FAKE_GH_ITEM_STATUS=Backlog -- flush)"; done
check "(ca) absent item: dropped on the 5th attempt with the adopt hint" "flush: DROPPED move #998 after 5 attempts (not on the board) — fix and re-run board.sh adopt 998" "$out"
check_rc "(ca) absent item, 5 flushes: exactly 5 board reads, 0 edits" 5 "$(_cnt 'project item-list')"
check_rc "(ca) absent item: nothing left in the queue" 0 "$(grep -c . "$BQ/.claude/board-queue.jsonl" 2>/dev/null || true)"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"

# --- (cb) adopt read-back failure queues an adopt-style op: membership re-checked, status only if empty ---
_qsetup; _qlogs
printf '{"op":"adopt","issue":"9","reason":"board read failed: gh error","attempts":"1","seq":"1","ts":"2020-01-01T00:00:01Z"}\n' >"$BQ/.claude/board-queue.jsonl"
out="$(_bq FAKE_GH_ITEMS_JSON='{"items":[{"id":"ITEM_9","content":{"number":9},"status":"In progress"}]}' -- flush)"
check "(cb) card moved by a human before the replay: left alone" "adopt #9: already on board" "$out"
check_rc "(cb) human-moved card: 0 edits" 0 "$(_cnt 'project item-edit')"
check_rc "(cb) human-moved card: exactly 1 board read" 1 "$(_cnt 'project item-list')"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"
_qsetup; _qlogs
printf '{"op":"adopt","issue":"9","reason":"board read failed: gh error","attempts":"1","seq":"1","ts":"2020-01-01T00:00:01Z"}\n' >"$BQ/.claude/board-queue.jsonl"
out="$(_bq FAKE_GH_ITEMS_JSON='{"items":[{"id":"ITEM_9","content":{"number":9}}]}' -- flush)"
check "(cb) card on the board with an EMPTY status: first status set" "moved #9 -> Backlog" "$out"
check_rc "(cb) empty status: exactly 1 edit" 1 "$(_cnt 'project item-edit')"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"
_qsetup; _qlogs
printf '{"op":"adopt","issue":"9","reason":"board read failed: gh error","attempts":"1","seq":"1","ts":"2020-01-01T00:00:01Z"}\n' >"$BQ/.claude/board-queue.jsonl"
out="$(_bq FAKE_GH_ISSUE_NUM=9 FAKE_GH_ITEM_ADD_MARKER="$BQ/added" -- flush)"
check_rc "(cb) card absent: item-add runs again" 1 "$(_cnt 'project item-add')"
check_rc "(cb) card absent: at most 2 board reads for the entry (snapshot + one read-back)" 2 "$(_cnt 'project item-list')"
check "(cb) card absent: the entry is done" "adopted #9" "$out"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"

# --- (cc) bug verb: only QUEUED lines for THIS issue's move/prio count; stderr stays on stderr ---
_qsetup; _qlogs
printf '{"op":"move","issue":"999","status":"Backlog","reason":"HTTP 502","seq":"1","ts":"2020-01-01T00:00:01Z"}\n' >"$BQ/.claude/board-queue.jsonl"
out="$(_bq FAKE_GH_ISSUE_NUM=905 FAKE_GH_ISSUES="999 905" FAKE_GH_ITEM_STATUS=Ready FAKE_GH_EDIT_RATE_LIMIT_ONLY_ON=1 FAKE_GH_RESET_EPOCH=1735689600 -- bug "stray queued line" P2)"
check "(cc) a stray QUEUED line for ANOTHER issue does not turn a filed bug into a queued one" "filed bug #905 [P2]" "$out"
check_absent "(cc) and it is not called queued" "board update queued" "$out"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"

# --- (cd) live adopt: attempts only for an unrecognised label ---
_qsetup; _qlogs
out="$(_bq FAKE_GH_ISSUE_NUM=992 FAKE_GH_ITEM_VISIBLE=0 FAKE_GH_ITEM_ADD_TRANSIENT=transient-http-502.txt -- adopt 992)"
check_absent "(cd) live adopt, 5xx item-add: no attempts counted" "attempts" "$(cat "$BQ/.claude/board-queue.jsonl" 2>/dev/null)"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"

# --- (ce) a guard-refused queued start does not hold the WIP mutex ---
_qsetup; _seed_seen 982; _qlogs   # 981 has no comments-seen marker: its start is guard-refused
printf '{"op":"move","issue":"981","status":"In progress","reason":"HTTP 502","seq":"1","ts":"2020-01-01T00:00:01Z"}\n' >"$BQ/.claude/board-queue.jsonl"
SYNC="$(mktemp -d)"; : >"$SYNC/.board-queue-test-sync"
: >"$SYNC/wipflush.go"; : >"$SYNC/wipflush-snap.go"
(_bq FAKE_GH_ISSUES="981 982" FAKE_GH_ITEM_STATUS=Backlog BOARD_QUEUE_TEST_SYNC="$SYNC" BOARD_QUEUE_TEST_TAG=wipflush -- flush >"$SYNC/flush.out") &
FPID=$!
_wait_for "$SYNC/wipflush-done.ready" || echo "FAIL (ce) flush never reached its end" >&2
out="$(_bq FAKE_GH_ISSUES="981 982" FAKE_GH_ITEM_STATUS=Backlog BOARD_WIP_MUTEX_MAX_WAIT_ITERS=3 -- move 982 "In progress")"
check "(ce) a live start while the pass holds only a refused entry applies at once" "moved #982 -> In progress" "$out"
: >"$SYNC/wipflush-done.go"
wait "$FPID"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC" "$SYNC"


# =====================================================================
# #561 round 5
# =====================================================================
echo "== board.sh queue failed moves (#561 round 5) =="

# --- (da) replay adopt trusts the SNAPSHOT status, not the cache (a cache write can fail) ---
_qsetup; _qlogs
mkdir -p "$BQ/.claude/board-cache.json.tmp"      # makes every cache write fail
printf '{"9": {"itemId": "ITEM_9", "status": ""}}' >"$BQ/.claude/board-cache.json"
printf '{"op":"adopt","issue":"9","reason":"board read failed: gh error","attempts":"1","seq":"1","ts":"2020-01-01T00:00:01Z"}\n' >"$BQ/.claude/board-queue.jsonl"
out="$(_bq FAKE_GH_ITEMS_JSON='{"items":[{"id":"ITEM_9","content":{"number":9},"status":"In progress"}]}' -- flush)"
check "(da) stale empty cache status, snapshot says In progress: card left alone" "adopt #9: already on board" "$out"
check_rc "(da) a human-moved card is never moved back: 0 edits" 0 "$(_cnt 'project item-edit')"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"

# --- (db) replay add-finish uses the flush snapshot, not a separate status read ---
_qsetup; _qlogs
printf '{"op":"add-finish","issue":"991","url":"https://github.com/fixture-owner/fixture-project/issues/991","first_status":"Backlog","prio":"P2","seq":"1","ts":"2020-01-01T00:00:01Z"}\n' >"$BQ/.claude/board-queue.jsonl"
out="$(_bq FAKE_GH_ISSUES="991" FAKE_GH_ITEM_STATUS=Ready -- flush)"
check "(db) add-finish replay finished" "flush: finished add #991" "$out"
check_rc "(db) add-finish replay on a present card: exactly 1 board read" 1 "$(_cnt 'project item-list')"
check_rc "(db) add-finish replay on a card that already has a status: 1 edit (priority only, round 6: status only when empty)" 1 "$(_cnt 'project item-edit')"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"
_qsetup; _qlogs
printf '{"op":"add-finish","issue":"9","url":"https://github.com/fixture-owner/fixture-project/issues/9","first_status":"Backlog","prio":"P2","seq":"1","ts":"2020-01-01T00:00:01Z"}\n' >"$BQ/.claude/board-queue.jsonl"
out="$(_bq FAKE_GH_ISSUE_NUM=9 FAKE_GH_ITEM_ADD_MARKER="$BQ/added" -- flush)"
check "(db) add-finish replay on an absent card: finished" "flush: finished add #9" "$out"
check_rc "(db) add-finish replay on an absent card: item-add once" 1 "$(_cnt 'project item-add')"
check_rc "(db) add-finish replay on an absent card: exactly 2 board reads (snapshot + read-back)" 2 "$(_cnt 'project item-list')"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"

# --- (dc) a card added during the flush is visible to a later entry of the same flush ---
_qsetup; _qlogs
printf '{"op":"adopt","issue":"9","seq":"1","ts":"2020-01-01T00:00:01Z"}\n{"op":"prio","issue":"9","priority":"P1","seq":"2","ts":"2020-01-01T00:00:02Z"}\n' >"$BQ/.claude/board-queue.jsonl"
out="$(_bq FAKE_GH_ISSUE_NUM=9 FAKE_GH_ITEM_ADD_MARKER="$BQ/added" -- flush)"
check "(dc) the prio after the adopt finds the new card" "prio #9 -> P1" "$out"
check_absent "(dc) and is not counted as not on the board" "not on the board" "$out"
check_rc "(dc) adopt + prio in one flush: exactly 2 board reads" 2 "$(_cnt 'project item-list')"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"

# --- (dd) replay adopt whose read-back fails stops the pass, keeps the entry, queues nothing new ---
_qsetup; _qlogs
printf '{"op":"adopt","issue":"9","attempts":"1","seq":"1","ts":"2020-01-01T00:00:01Z"}\n' >"$BQ/.claude/board-queue.jsonl"
out="$(_bq FAKE_GH_ISSUE_NUM=9 FAKE_GH_ITEM_ADD_MARKER="$BQ/added" FAKE_GH_ITEM_LIST_LATE_FAIL_TEXT="GraphQL: Your token has not been granted the required scopes" FAKE_GH_ITEM_LIST_FAIL_FROM=2 -- flush)"
check "(dd) read-back failure in replay: the board line, pass stopped" "flush: board read failed" "$out"
check_absent "(dd) read-back failure in replay: no new QUEUED line" "QUEUED (board read failed: gh error): adopt" "$out"
check_rc "(dd) read-back failure in replay: the original entry is the only one" 1 "$(grep -c . "$BQ/.claude/board-queue.jsonl")"
check_rc "(dd) read-back failure in replay: attempts untouched" 1 "$(grep -c '"attempts":"1"' "$BQ/.claude/board-queue.jsonl")"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"


# =====================================================================
# #561 x #560: a queued --over-wip move keeps its flag through the new flush paths
# =====================================================================
echo "== board.sh queue (#561 x #560): over-wip flag survives requeue and attempts =="
_qsetup; _seen_all 981 981 981; _qlogs
BOARD_JSON='{"items":[{"id":"ITEM_1","content":{"number":1},"status":"In progress"},{"id":"ITEM_981","content":{"number":981},"status":"Backlog"}]}'
printf '{"op":"move","issue":"981","status":"In progress","reason":"rate-limited","over_wip":"urgent fix","over_wip_by":"orchestrator","seq":"1","ts":"2020-01-01T00:00:01Z"}\n' >"$BQ/.claude/board-queue.jsonl"
out="$(_bq FAKE_GH_ITEMS_JSON="$BOARD_JSON" FAKE_GH_EDIT_FAIL_TEXT="GraphQL: Could not resolve to a node with the global id of 'x'" -- flush)"
q1="$(cat "$BQ/.claude/board-queue.jsonl" 2>/dev/null)"
check "(ea) a failed replay keeps the over_wip flag on the requeued line" '"over_wip": "urgent fix"' "$q1"
check "(ea) and counts the attempt on the same line" '"attempts": "1"' "$q1"
out="$(_bq FAKE_GH_ITEMS_JSON="$BOARD_JSON" -- flush)"
check "(ea) the next flush applies the flagged move above the limit" "OVER WIP" "$out"
check "(ea) the move itself is reported" "moved #981 -> In progress" "$out"
check_rc "(ea) the queue is empty afterwards" 0 "$(grep -c . "$BQ/.claude/board-queue.jsonl" 2>/dev/null || true)"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"
# independent review 1: dedupe keeps ONLY the newest move per issue; a flagged older move never overrides it
_qsetup; _seen_all 981 981 981; _qlogs
printf '{"op":"move","issue":"981","status":"In progress","over_wip":"urgent fix","over_wip_by":"orchestrator","seq":"1","ts":"2020-01-01T00:00:01Z"}\n{"op":"move","issue":"981","status":"Backlog","seq":"2","ts":"2020-01-01T00:00:02Z"}\n' >"$BQ/.claude/board-queue.jsonl"
out="$(_bq FAKE_GH_ITEMS_JSON='{"items":[{"id":"ITEM_1","content":{"number":1},"status":"In progress"},{"id":"ITEM_981","content":{"number":981},"status":"Ready"}]}' -- flush)"
check_absent "(ea) dedupe: the flagged OLDER move is never applied over the newer plain one" "OVER WIP" "$out"
check "(ea) dedupe: only the newest move applies" "moved #981 -> Backlog" "$out"
check_rc "(ea) dedupe: exactly 1 edit" 1 "$(_cnt 'project item-edit')"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"


# --- (fa) next: PENDING lines print BEFORE #567's stale-QA report ---
echo "== board.sh next (#561 x #567): PENDING before STALE QA =="
_qsetup; _qlogs
_old="$(date -u -d '3 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-3d +%Y-%m-%dT%H:%M:%SZ)"
printf '{"kind":"transition","task":"777","from":"In review","to":"QA","ts":"%s"}\n' "$_old" >"$BQ/.claude/telemetry.jsonl"
printf '{"op":"move","issue":"5","status":"Backlog","reason":"HTTP 502","seq":"1","ts":"2020-01-01T00:00:01Z"}\n' >"$BQ/.claude/board-queue.jsonl"
out="$(_bq FAKE_GH_ITEMS_JSON='{"items":[{"id":"ITEM_777","content":{"number":777},"title":"FX-001: t","status":"QA"},{"id":"ITEM_5","content":{"number":5},"title":"FX-002: u","status":"Ready"}]}' FAKE_GH_EDIT_TRANSIENT=transient-http-502.txt -- next)"
check "(fa) next still prints the PENDING line" "PENDING: move #5 -> Backlog" "$out"
check "(fa) next still prints the stale QA report" "STALE QA: #777 in QA for 3d" "$out"
_pl="$(grep -n 'PENDING:' <<<"$out" | head -1 | cut -d: -f1)"; _sl="$(grep -n 'STALE QA:' <<<"$out" | head -1 | cut -d: -f1)"
if [[ -n "$_pl" && -n "$_sl" && "$_pl" -lt "$_sl" ]]; then echo "ok   (fa) PENDING precedes STALE QA"; else echo "FAIL (fa) PENDING (line '$_pl') must precede STALE QA (line '$_sl')"; fails=$((fails + 1)); fi
check_rc "(fa) PENDING printed exactly once" 1 "$(grep -c 'PENDING:' <<<"$out")"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"


# =====================================================================
# #561 independent review 1
# =====================================================================
echo "== board.sh queue (#561 independent review 1) =="

# --- (ga) the repro: flagged X kept by a guard, newer plain Y applies; X must never apply later ---
_qsetup; _qlogs
printf '{"op":"move","issue":"981","status":"In progress","over_wip":"urgent fix","over_wip_by":"orchestrator","seq":"1","ts":"2020-01-01T00:00:01Z"}\n{"op":"move","issue":"981","status":"Backlog","seq":"2","ts":"2020-01-01T00:00:02Z"}\n' >"$BQ/.claude/board-queue.jsonl"
J1='{"items":[{"id":"ITEM_1","content":{"number":1},"status":"In progress"},{"id":"ITEM_981","content":{"number":981},"status":"Ready"}]}'
out="$(_bq FAKE_GH_ITEMS_JSON="$J1" -- flush)"
check "(ga) the newest plain move applies" "moved #981 -> Backlog" "$out"
check_rc "(ga) flush 1: the older flagged entry is gone, queue empty" 0 "$(grep -c . "$BQ/.claude/board-queue.jsonl" 2>/dev/null || true)"
_seen_all 981 981 981
out="$(_bq FAKE_GH_ITEMS_JSON='{"items":[{"id":"ITEM_1","content":{"number":1},"status":"In progress"},{"id":"ITEM_981","content":{"number":981},"status":"Backlog"}]}' -- flush)"
check_absent "(ga) flush 2: the flagged move never applies later" "OVER WIP" "$out"
check_rc "(ga) total edits across both flushes: 1" 1 "$(_cnt 'project item-edit')"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"
# the flag is carried onto the newest move only when it targets the same status
_qsetup; _seen_all 981 981 981; _qlogs
printf '{"op":"move","issue":"981","status":"In progress","over_wip":"urgent fix","over_wip_by":"orchestrator","seq":"1","ts":"2020-01-01T00:00:01Z"}\n{"op":"move","issue":"981","status":"In progress","seq":"2","ts":"2020-01-01T00:00:02Z"}\n' >"$BQ/.claude/board-queue.jsonl"
out="$(_bq FAKE_GH_ITEMS_JSON="$J1" -- flush)"
check "(ga) same target status: the flag is carried onto the newest move" "OVER WIP" "$out"
check_rc "(ga) same target status: exactly 1 edit" 1 "$(_cnt 'project item-edit')"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"
# a move applied during REPLAY leaves a supersede marker holding that entry's seq
_qsetup; _qlogs
printf '{"op":"move","issue":"981","status":"Backlog","seq":"5000","ts":"2020-01-01T00:00:01Z"}\n' >"$BQ/.claude/board-queue.jsonl"
out="$(_bq FAKE_GH_ISSUES="981" FAKE_GH_ITEM_STATUS=Ready -- flush)"
check "(ga) replayed move: supersede marker holds the entry's seq" "5000" "$(cat "$BQ/.claude/board-queue.superseded/981" 2>/dev/null; cat "$BQ/.claude/board-queue.superseded/981" 2>/dev/null)"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"

# --- (gb) add-finish sets the first status only when the status is empty ---
_qsetup; _qlogs
printf '{"op":"add-finish","issue":"991","url":"https://github.com/fixture-owner/fixture-project/issues/991","first_status":"Backlog","prio":"P2","seq":"1","ts":"2020-01-01T00:00:01Z"}\n' >"$BQ/.claude/board-queue.jsonl"
out="$(_bq FAKE_GH_ISSUES="991" FAKE_GH_ITEM_STATUS="In review" -- flush)"
check "(gb) add-finish on a card a human/agent already moved: finished" "flush: finished add #991" "$out"
check_absent "(gb) add-finish never moves it back to the first status" "moved #991" "$out"
check_rc "(gb) add-finish on a moved card: 1 edit (priority only)" 1 "$(_cnt 'project item-edit')"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"
_qsetup; _qlogs
printf '{"op":"add-finish","issue":"991","url":"https://github.com/fixture-owner/fixture-project/issues/991","first_status":"Backlog","prio":"P2","seq":"1","ts":"2020-01-01T00:00:01Z"}\n' >"$BQ/.claude/board-queue.jsonl"
out="$(_bq FAKE_GH_ITEMS_JSON='{"items":[{"id":"ITEM_991","content":{"number":991}}]}' -- flush)"
check "(gb) add-finish on a card with an EMPTY status: first status set" "moved #991 -> Backlog" "$out"
check_rc "(gb) add-finish on an empty-status card: 2 edits" 2 "$(_cnt 'project item-edit')"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"

# --- (gc) a queued prio/est with an invalid option is dropped with a printed line ---
_qsetup; _qlogs
printf '{"op":"prio","issue":"930","priority":"P9","seq":"1","ts":"2020-01-01T00:00:01Z"}\n' >"$BQ/.claude/board-queue.jsonl"
out="$(_bq FAKE_GH_ISSUES="930" FAKE_GH_ITEM_STATUS=Backlog -- flush)"
check "(gc) invalid priority: dropped with a printed line" "flush: DROPPED prio #930" "$out"
check_rc "(gc) invalid priority: queue empty" 0 "$(grep -c . "$BQ/.claude/board-queue.jsonl" 2>/dev/null || true)"
check_rc "(gc) invalid priority: 0 edits" 0 "$(_cnt 'project item-edit')"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"

# --- (gd) persistent transient failure backs off: after 3 fails, at most one replay per 10 minutes ---
_qsetup; _qlogs
printf '{"op":"move","issue":"997","status":"Backlog","reason":"HTTP 502","seq":"1","ts":"2020-01-01T00:00:01Z"}\n' >"$BQ/.claude/board-queue.jsonl"
for _i in 1 2 3 4 5; do out="$(_bq FAKE_GH_ISSUES="997" FAKE_GH_ITEM_STATUS=Ready FAKE_GH_EDIT_TRANSIENT=transient-http-502.txt -- flush)"; done
check_rc "(gd) 5 polls of a persistently failing entry: only 3 board reads" 3 "$(_cnt 'project item-list')"
check_rc "(gd) 5 polls of a persistently failing entry: only 3 edits" 3 "$(_cnt 'project item-edit')"
check_rc "(gd) the entry counts its failures (the line keeps its compact style)" 1 "$(grep -cE '"fails": ?"3"' "$BQ/.claude/board-queue.jsonl")"
check "(gd) and stores when it last tried" '"last_try"' "$(cat "$BQ/.claude/board-queue.jsonl")"
check_rc "(gd) a backed-off poll makes 0 gh calls" 0 "$(: >"$LOG"; _bq FAKE_GH_ISSUES="997" -- flush >/dev/null; wc -l <"$LOG" | tr -d ' ')"
# once the 10 minutes are over the entry is tried again
sed -i 's/"last_try": \?"[0-9]*"/"last_try":"1"/' "$BQ/.claude/board-queue.jsonl"
: >"$LOG"; out="$(_bq FAKE_GH_ISSUES="997" FAKE_GH_ITEM_STATUS=Ready -- flush)"
check "(gd) after the back-off window the entry is replayed and applies" "moved #997 -> Backlog" "$out"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"


# --- (ha) runtime files a move writes are gitignored local state (a routine move must not dirty the tree) ---
echo "== board.sh runtime files are ignored local state (#561) =="
_qsetup; _qlogs
git -C "$BQ" init -q 2>/dev/null
bash "$PLUGIN/scripts/gitignore-sync.sh" "$BQ/.gitignore" >/dev/null
git -C "$BQ" add -A >/dev/null 2>&1
git -C "$BQ" -c user.name=t -c user.email=t@t commit -q -m base >/dev/null 2>&1
printf '{"op":"move","issue":"7","status":"Backlog","reason":"HTTP 502","seq":"1","ts":"2020-01-01T00:00:01Z"}\n' >"$BQ/.claude/board-queue.jsonl"
mkdir -p "$BQ/.claude/board-queue.spool" "$BQ/.claude/board-queue.file.lock.stale.1.2" "$BQ/.claude/board-wip.lock.stale.1.2"
: >"$BQ/.claude/board-queue.spool/0001-1-1"; : >"$BQ/.claude/board-queue.jsonl.drop.99"
out="$(_bq FAKE_GH_ISSUES="7 8" FAKE_GH_ITEM_STATUS=Ready -- move 8 Backlog)"
check "(ha) the direct move applied (it wrote a supersede marker)" "moved #8 -> Backlog" "$out"
check_rc "(ha) the supersede marker exists" 1 "$([[ -f "$BQ/.claude/board-queue.superseded/8" ]] && echo 1 || echo 0)"
check_rc "(ha) git status is clean after the move: every runtime path is ignored" 0 "$(git -C "$BQ" status --porcelain | grep -c . || true)"
rm -rf "$BQ" "$FGH" "$LOG" "$EDITCC" "$LISTCC"

echo "== setup-project: .gitignore covers the board-queue feed =="
check "local-state manifest ignores .claude/board-queue.jsonl" '.claude/board-queue.jsonl' "$(bash "$PLUGIN/scripts/lib/local-state.sh" ignore)"
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
