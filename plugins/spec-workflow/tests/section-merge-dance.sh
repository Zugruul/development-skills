#!/usr/bin/env bash
# section-merge-dance.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/hookjson) and set HERE/PLUGIN/FIX/fails/flaky
# before sourcing this file. This file assumes those are already in scope.
#
# Covers issue #423: methodology.serialDelivery x methodology.maxInProgress: N>1
# as ONE coherent mode -- N parallel implementation lanes, merges strictly ONE
# at a time (the "synchronization dance"). A slot is occupied from PICK until
# MERGE: both In-progress AND In-review count. Slots are COUNT-based, not
# identified -- the board is the sole state, no slot ids, no side-car file.
#
#   occupied = count(status == "In progress") + count(status == "In review")
#   occupied <  maxInProgress -> PICK proceeds normally (headroom exists)
#   occupied >= maxInProgress -> an In-progress item is the actionable next
#                                 step (=> RESUME), UNLESS every occupying
#                                 item is In review (nothing to resume)
#                                 -> WAIT on the merge dance
#
# This generalizes #272's old "any WIP blocks" rule, which was exactly the
# maxInProgress=1 special case of this same formula (see
# section-serial-delivery.sh, which pins that case byte-for-byte plus the
# deliberately-changed WAIT/merge-queue wording).
#
# Merge-queue ordering: a live `gh project item-list --format json` was
# inspected for this task (#423) -- its item/content shape carries NO
# per-item timestamp field at all: content = {body, number, repository,
# title, type, url}; item = {content, estimate, id, labels, priority,
# repository, status, title}. There is no updatedAt/createdAt anywhere. The
# only deterministic, monotonic, immutable field available is content.number
# (the GitHub issue number, assigned once at creation) -- so next.py sorts
# the In-review merge queue ascending by issue number as its "oldest first"
# proxy. Fixtures below deliberately list In-review items OUT of numeric
# order in the source JSON to prove next.py sorts them, rather than merely
# preserving input order.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== next.py (serialDelivery x maxInProgress>1 decision table, #423) =="

# check_seq name  expected-multiline-block  actual-output -- like check(), but
# ORDER-sensitive: grep -F splits a multi-line PATTERN into per-line OR
# alternatives (verified empirically), so it can't prove a block appears in a
# specific order -- only that each line appears SOMEWHERE. Bash's `[[ ==
# *pat* ]]` glob match treats the whole pattern (embedded newlines included)
# as one literal substring, so it correctly rejects an out-of-order block.
# Used below to prove the merge queue is actually SORTED ascending by issue
# number, not merely that every expected line is present somewhere.
check_seq() {
    if [[ "$3" == *"$2"* ]]; then
        echo "ok   $1"
    else
        echo "FAIL $1 — expected block (in order):"
        echo "     $2"
        fails=$((fails + 1))
    fi
}

# --- (a) 3 In-progress + 1 In-review, maxInProgress=5 -> occupied=4 < 5:
#     headroom exists, PICK proceeds; the merge queue is still surfaced. ---
out="$(python3 "$PLUGIN/scripts/next.py" "$FIX/valid.project.serial5.json" "" "$FIX/items.dance-headroom.json")"
check "N=5, occupied=4 (3 IP + 1 IR): PICK proceeds (headroom)" "=> PICK: #1  FX-001: scaffold" "$out"
check_absent "N=5, occupied=4: no RESUME line" "=> RESUME:" "$out"
check_absent "N=5, occupied=4: no WAIT line" "WAIT: merge-dance" "$out"
check "N=5, occupied=4: merge queue still surfaced for the 1 In-review item" "Merge queue (In review, oldest-first by issue number):" "$out"
check "N=5, occupied=4: merge queue names #5" "#5  FX-005: refresh" "$out"

# --- (b) 4 In-progress, maxInProgress=4 -> occupied=4 >= 4, all occupying
#     items are In-progress: RESUME (the oldest In-progress lane), not WAIT. ---
out="$(python3 "$PLUGIN/scripts/next.py" "$FIX/valid.project.serial4.json" "" "$FIX/items.dance-full-progress.json")"
check "N=4, occupied=4 (4 IP, 0 IR): RESUME wins" "=> RESUME: #2  FX-002: auth model" "$out"
check_absent "N=4, occupied=4 (4 IP, 0 IR): no WAIT line" "WAIT: merge-dance" "$out"
check_absent "N=4, occupied=4 (4 IP, 0 IR): no merge queue (nothing In review)" "Merge queue" "$out"

# --- (c) 4 In-review (0 In-progress), maxInProgress=4 -> occupied=4 >= 4,
#     NOTHING to resume: WAIT on the merge dance, oldest-first FIFO queue. ---
out="$(python3 "$PLUGIN/scripts/next.py" "$FIX/valid.project.serial4.json" "" "$FIX/items.dance-full-review.json")"
check "N=4, occupied=4 (0 IP, 4 IR): WAIT names all four slots, oldest-first" \
    "WAIT: merge-dance — #2,#3,#5,#8 In review; slots 4/4 occupied — run the dance (merge oldest first) to free a slot" "$out"
check_absent "N=4, occupied=4 (0 IP, 4 IR): no RESUME line" "=> RESUME:" "$out"
check_absent "N=4, occupied=4 (0 IP, 4 IR): no PICK line" "=> PICK:" "$out"
check_seq "N=4, occupied=4 (0 IP, 4 IR): merge queue sorted ascending by issue number, not input order" \
    "$(printf 'Merge queue (In review, oldest-first by issue number):\n  #2  FX-002: auth model\n  #3  FX-003: sessions\n  #5  FX-005: refresh\n  #8  FX-008: telemetry')" "$out"

# --- (d) 2 In-progress + 2 In-review, maxInProgress=4 -> occupied=4 >= 4,
#     an In-progress lane exists: RESUME wins over WAIT; the 2 In-review
#     items still appear in the merge queue, sorted, for visibility. ---
out="$(python3 "$PLUGIN/scripts/next.py" "$FIX/valid.project.serial4.json" "" "$FIX/items.dance-mixed.json")"
check "N=4, occupied=4 (2 IP + 2 IR): RESUME wins" "=> RESUME: #2  FX-002: auth model" "$out"
check_absent "N=4, occupied=4 (2 IP + 2 IR): no WAIT line" "WAIT: merge-dance" "$out"
check_seq "N=4, occupied=4 (2 IP + 2 IR): merge queue still lists the 2 In-review items, sorted" \
    "$(printf 'Merge queue (In review, oldest-first by issue number):\n  #5  FX-005: refresh\n  #8  FX-008: telemetry')" "$out"

echo "== guard-board-move.sh (serialDelivery slot-count move guard, #423) =="

# _dance_repo maxInProgress cache-json -- like section-serial-delivery.sh's
# _serial_repo, but ALSO overwrites methodology.maxInProgress (fixture
# defaults to 1) so the guard's slot-count math has real headroom to test.
_dance_repo() {
    T="$(mktemp -d)"
    ( cd "$T" && git init -q . && git commit -q --allow-empty -m init )
    mkdir -p "$T/.claude"
    cp "$FIX/valid.project.yaml" "$T/.claude/project.yaml"
    python3 - "$T/.claude/project.yaml" "$1" <<'PY'
import sys
p, n = sys.argv[1], sys.argv[2]
text = open(p).read()
assert text.count("methodology:") == 1, "fixture assumption broken: expected exactly one methodology: block"
text = text.replace("maxInProgress: 1", f"maxInProgress: {n}", 1)
text = text.replace("methodology:\n", "methodology:\n    serialDelivery: true\n", 1)
open(p, "w").write(text)
PY
    printf '%s' "$2" >"$T/.claude/board-cache.json"
}

# --- (e) maxInProgress=4, 3 OTHER items already occupying (In progress/In
#     review mix) -> occupied=3 < 4: headroom, the move is allowed. ---
_dance_repo 4 '{"5": {"itemId": "ITEM_5", "status": "In progress"}, "6": {"itemId": "ITEM_6", "status": "In progress"}, "8": {"itemId": "ITEM_8", "status": "In review"}}'
out="$(hookjson 'bash board.sh move 7 \"In progress\"' | (cd "$T" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "slot-count guard: N=4, occupied=3 -> allowed (headroom)" "rc=0" "$out"
rm -rf "$T"

# --- (f) maxInProgress=4, 4 OTHER items already occupying -> occupied=4 >= 4:
#     no headroom, the move is blocked, all four blockers named. ---
_dance_repo 4 '{"5": {"itemId": "ITEM_5", "status": "In progress"}, "6": {"itemId": "ITEM_6", "status": "In progress"}, "8": {"itemId": "ITEM_8", "status": "In review"}, "9": {"itemId": "ITEM_9", "status": "In review"}}'
out="$(hookjson 'bash board.sh move 7 \"In progress\"' | (cd "$T" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "slot-count guard: N=4, occupied=4 -> blocked (no headroom)" "rc=2" "$out"
check "slot-count guard: N=4, occupied=4 -> all four blockers named" "#5" "$out"
check "slot-count guard: N=4, occupied=4 -> names #9 too" "#9" "$out"
rm -rf "$T"

# --- (g) maxInProgress=4, cache has 4 entries but ONE of them IS the issue
#     being moved (re-moving/self) -> excluded from the count, leaving 3
#     OTHER occupying items < 4: still allowed (mirrors the #272 review round
#     1 MUST FIX #4 self-exclusion rule, generalized to slot counting). ---
_dance_repo 4 '{"5": {"itemId": "ITEM_5", "status": "In progress"}, "6": {"itemId": "ITEM_6", "status": "In progress"}, "7": {"itemId": "ITEM_7", "status": "In progress"}, "8": {"itemId": "ITEM_8", "status": "In review"}}'
out="$(hookjson 'bash board.sh move 7 \"In progress\"' | (cd "$T" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "slot-count guard: self-entry excluded from the count -> allowed" "rc=0" "$out"
rm -rf "$T"

echo "== docs-with-behavior: the merge-dance protocol is documented (#423) =="

NEXT_TASK_SKILL="$(cat "$PLUGIN/skills/next-task/SKILL.md")"
check "next-task SKILL.md explains PICK under slot semantics (headroom)" "occupied" "$NEXT_TASK_SKILL"
check "next-task SKILL.md explains RESUME under slot semantics" "RESUME" "$NEXT_TASK_SKILL"
check "next-task SKILL.md explains WAIT under slot semantics (merge dance)" "merge dance" "$NEXT_TASK_SKILL"
check "next-task SKILL.md tells the orchestrator to run the dance FIFO on WAIT" "FIFO" "$NEXT_TASK_SKILL"

BUILD_NEXT_SKILL="$(cat "$PLUGIN/skills/build-next/SKILL.md")"
check "build-next SKILL.md's concurrency rule states slots are COUNT-based (no slot ids)" "COUNT-based" "$BUILD_NEXT_SKILL"

CONCURRENCY_REF="$(cat "$PLUGIN/skills/build-next/references/concurrency.md")"
check "concurrency.md documents the merge-dance lock (mkdir + owner file)" "dance lock" "$CONCURRENCY_REF"
check "concurrency.md's lock has an owner file" "owner" "$CONCURRENCY_REF"
check "concurrency.md's lock has a staleness/steal rule" "stale" "$CONCURRENCY_REF"
check "concurrency.md's staleness window is 25 minutes" "25" "$CONCURRENCY_REF"
check "concurrency.md's dance picks the OLDEST In-review task first (FIFO)" "FIFO" "$CONCURRENCY_REF"
check "concurrency.md's dance rebases the picked branch before re-gating" "rebase" "$CONCURRENCY_REF"
check "concurrency.md states In-progress lanes are never force-rebased mid-flight" "never" "$CONCURRENCY_REF"

IMPLEMENT_TASK_SKILL="$(cat "$PLUGIN/skills/implement-task/SKILL.md")"
check "implement-task SKILL.md §3 states In review still occupies a slot" "slot" "$IMPLEMENT_TASK_SKILL"

ARBODY="$(cat "$PLUGIN/skills/build-next/references/auto-review.md")"
check "auto-review.md's merge-freshness step notes one merger at a time" "one merger" "$ARBODY"

echo "== local-state manifest covers the merge-dance lock (review round 1 MUST FIX, #423) =="
# Review round 1 (code-quality CHANGES-NEEDED): concurrency.md instructs
# agents to `mkdir .claude/merge-dance.lock` + write an owner file inside it,
# but the manifest (the SOURCE OF TRUTH for every runtime-written path, per
# its own header) never listed it. Failure scenario the reviewer proved: a
# broad `git add -A` during a held dance commits the lock directory into the
# repo; every future mkdir then fails forever (the path already exists as a
# tracked file/dir), and the staleness-steal `rm -rf` step would delete a
# TRACKED path instead of an untracked scratch lock -- the dance wedges
# repo-wide. The manifest entry (ignore = local state, gitignored, never
# committed) is what .gitignore generation and any future "is this path safe
# to rm -rf / git add -A over" check consult -- same mechanism board-cache.json
# and board-queue.jsonl already rely on (section-board-cache.sh /
# section-board-queue.sh, MEM-010).
check "local-state manifest ignores .claude/merge-dance.lock/" ".claude/merge-dance.lock/" "$(bash "$PLUGIN/scripts/lib/local-state.sh" ignore)"
