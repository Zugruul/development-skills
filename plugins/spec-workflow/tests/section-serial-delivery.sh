#!/usr/bin/env bash
# section-serial-delivery.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/hookjson) and set HERE/PLUGIN/FIX/fails/flaky
# before sourcing this file. This file assumes those are already in scope.
#
# Covers issue #272: methodology.serialDelivery — a stricter, orthogonal mode
# to maxInProgress that gates on MERGE rather than a parallel-lane count. Two
# enforcement points, tested independently:
#   1. next.py's picker: WAIT while a task is In review with nothing In
#      progress to resume (only a merge can unblock it); RESUME (never WAIT)
#      when something IS In progress — resuming/finishing that is always the
#      right next action, and WAIT with nothing In progress to work on would
#      deadlock the loop (review round 1, PR #279, MUST FIX #1).
#   2. guard-board-move.sh: defense in depth against a manual
#      `board.sh move <n> "In progress"` while another task is already
#      In progress/In review, read from the offline board-cache.json (never
#      a network call) — fail OPEN with a warning on a cache miss, and
#      correctly evaluated even when board.sh appears more than once in a
#      compound command (review round 1, MUST FIX #3).
#
# #423 (deliberate wording change): serialDelivery x maxInProgress>1 is now a
# COUNT-based slot model -- occupied = count(In progress) + count(In review);
# a WAIT/RESUME only fires once occupied >= maxInProgress. Every fixture in
# THIS file uses maxInProgress: 1 (valid.project.serial.json), under which
# "occupied >= 1" collapses to the exact old "any WIP blocks" behavior next.py
# used to hard-code -- so RESUME's wording is unchanged here, but WAIT's
# wording and the old In-progress-AND-In-review trailing NOTE both changed (a
# `Merge queue` block, always printed when anything is In review, replaces the
# old ad hoc NOTE line). See section-merge-dance.sh for the maxInProgress>1
# decision table and the guard-board-move.sh slot-count cases.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== next.py (serialDelivery picker gate, #272) =="

out="$(python3 "$PLUGIN/scripts/next.py" "$FIX/valid.project.serial.json" "" "$FIX/items.serial-review.json")"
# #423: WAIT's wording changed to the merge-dance form (bare issue numbers +
# slot count); the merge queue block above it is what names the title/status.
check "serial + In review only: merge queue block names #2" "Merge queue (In review, oldest-first by issue number):" "$out"
check "serial + In review only: merge queue lists #2 and its title" "#2  FX-002: auth model" "$out"
check "serial + In review only (nothing In progress): WAIT names #2, slots 1/1 occupied" "WAIT: merge-dance — #2 In review; slots 1/1 occupied — run the dance (merge oldest first) to free a slot" "$out"
check_absent "serial + In review only: no PICK line" "=> PICK:" "$out"
check_absent "serial + In review only: no RESUME line (nothing to resume)" "=> RESUME:" "$out"

# review round 1 MUST FIX #1: an In-progress item is never a WAIT target — it
# is exactly a RESUME, same as the ordinary maxInProgress guard would print
# (resuming/finishing in-flight work is the correct next action; WAIT here
# would deadlock the loop on a task that can only advance by being resumed).
out="$(python3 "$PLUGIN/scripts/next.py" "$FIX/valid.project.serial.json" "" "$FIX/items.serial-progress.json")"
check "serial + In progress only: RESUME (the old exact-line assertion), not WAIT" "=> RESUME: #2  FX-002: auth model" "$out"
check_absent "serial + In progress only: no WAIT line" "WAIT: serial delivery" "$out"

# review round 1 MUST FIX #1: BOTH an In-progress item and a separate
# In-review item -> RESUME wins (finishing in-flight work is always the
# right next action); the In-review blocker is a trailing NOTE, not a WAIT.
out="$(python3 "$PLUGIN/scripts/next.py" "$FIX/valid.project.serial.json" "" "$FIX/items.serial-both.json")"
check "serial + In progress AND In review: RESUME wins" "=> RESUME: #2  FX-002: auth model" "$out"
check_absent "serial + In progress AND In review: no WAIT line" "WAIT: serial delivery" "$out"
check_absent "serial + In progress AND In review: no WAIT line (merge-dance form either)" "WAIT: merge-dance" "$out"
# #423: the old ad hoc "NOTE: ... is also In review" trailing line is gone --
# the always-printed merge queue block is now the one place the In-review
# blocker is named.
check "serial + In progress AND In review: the In-review blocker is named in the merge queue, not a NOTE" "Merge queue (In review, oldest-first by issue number):" "$out"
check "serial + In progress AND In review: merge queue names #3" "#3  FX-003: sessions" "$out"
check_absent "serial + In progress AND In review: no more ad hoc NOTE line" "NOTE: serial delivery" "$out"

out="$(python3 "$PLUGIN/scripts/next.py" "$FIX/valid.project.serial.json" "" "$FIX/items.serial-safe.json")"
check "serial + only QA/Ready/Deployed: PICK proceeds normally" "=> PICK: #1  FX-001: scaffold" "$out"
check_absent "serial + only QA/Ready/Deployed: no WAIT line" "WAIT: serial delivery" "$out"

# regression: mode OFF (existing fixtures/project, no serialDelivery key) is
# byte-identical to the pre-#272 behavior -- same assertions section-next-similar.sh
# already makes, repeated here so this file alone proves the golden case too.
out="$(python3 "$PLUGIN/scripts/next.py" "$FIX/valid.project.json" "" "$FIX/items.wip.json")"
check "serial off: wip resume guard unchanged" "=> RESUME: #2  FX-002: auth model" "$out"
check_absent "serial off: no WAIT line ever printed" "WAIT: serial delivery" "$out"
out="$(python3 "$PLUGIN/scripts/next.py" "$FIX/valid.project.json" "" "$FIX/items.serial-review.json")"
check "serial off: an In review item never triggers WAIT" "=> PICK: #1  FX-001: scaffold" "$out"
check_absent "serial off: no WAIT line for an In review item" "WAIT: serial delivery" "$out"

echo "== guard-board-move.sh (serialDelivery move guard, #272) =="

_serial_repo() { # sets T (fixture repo dir) with .claude/project.yaml (serialDelivery=<1>) + optional board-cache.json (arg2, "-" = none)
    T="$(mktemp -d)"
    ( cd "$T" && git init -q . && git commit -q --allow-empty -m init )
    mkdir -p "$T/.claude"
    cp "$FIX/valid.project.yaml" "$T/.claude/project.yaml"
    if [[ "${1:-1}" == "1" ]]; then
        # review round 1 MUST FIX #4: merge into the EXISTING `methodology:`
        # block, not a second top-level key -- YAML last-wins would silently
        # replace the whole block (tdd/isolationSuite/maxInProgress lost),
        # not just add serialDelivery.
        python3 - "$T/.claude/project.yaml" <<'PY'
import sys
p = sys.argv[1]
text = open(p).read()
assert text.count("methodology:") == 1, "fixture assumption broken: expected exactly one methodology: block"
text = text.replace("methodology:\n", "methodology:\n    serialDelivery: true\n", 1)
open(p, "w").write(text)
PY
    fi
    if [[ "${2:-}" != "-" ]]; then
        printf '%s' "${2:-{\}}" >"$T/.claude/board-cache.json"
    fi
}

# --- (a) another task already In progress -> blocked, blocker named, override documented ---
_serial_repo 1 '{"5": {"itemId": "ITEM_5", "status": "In progress"}}'
out="$(hookjson 'bash board.sh move 7 \"In progress\"' | (cd "$T" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "serial move guard: blocks with the blocking issue named" "#5" "$out"
check "serial move guard: names the blocking status" "In progress" "$out"
check "serial move guard: mentions the override env var" "SERIAL_DELIVERY_OVERRIDE" "$out"
check "serial move guard: exits nonzero" "rc=2" "$out"
rm -rf "$T"

# --- (b) another task already In review -> also blocks ---
_serial_repo 1 '{"5": {"itemId": "ITEM_5", "status": "In review"}}'
out="$(hookjson 'bash board.sh move 7 \"In progress\"' | (cd "$T" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "serial move guard: In review blocker also blocks" "#5" "$out"
check "serial move guard: In review blocker exits nonzero" "rc=2" "$out"
rm -rf "$T"

# --- (c) override env var allows the move through ---
_serial_repo 1 '{"5": {"itemId": "ITEM_5", "status": "In progress"}}'
out="$(hookjson 'bash board.sh move 7 \"In progress\"' | (cd "$T" && SERIAL_DELIVERY_OVERRIDE=1 bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "serial move guard: SERIAL_DELIVERY_OVERRIDE=1 allows the move" "rc=0" "$out"
rm -rf "$T"

# --- (d) no blocker in the cache -> allowed ---
_serial_repo 1 '{"5": {"itemId": "ITEM_5", "status": "QA"}}'
out="$(hookjson 'bash board.sh move 7 \"In progress\"' | (cd "$T" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "serial move guard: no In progress/In review blocker -> allowed" "rc=0" "$out"
rm -rf "$T"

# --- (e) cache miss (file absent) -> fail OPEN with a warning, never wedges the loop ---
_serial_repo 1 -
out="$(hookjson 'bash board.sh move 7 \"In progress\"' | (cd "$T" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "serial move guard: cache miss fails open (exit 0)" "rc=0" "$out"
check "serial move guard: cache miss warns" "WARNING" "$out"
rm -rf "$T"

# --- (f) mode off -> guard never engages even with a blocker in the cache ---
_serial_repo 0 '{"5": {"itemId": "ITEM_5", "status": "In progress"}}'
out="$(hookjson 'bash board.sh move 7 \"In progress\"' | (cd "$T" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "serial move guard: mode off allows the move" "rc=0" "$out"
check_absent "serial move guard: mode off never blocks" "BLOCKED" "$out"
rm -rf "$T"

# --- (g) moves to a non-"In progress" status are unaffected, even with a blocker ---
_serial_repo 1 '{"5": {"itemId": "ITEM_5", "status": "In progress"}}'
out="$(hookjson 'bash board.sh move 7 \"QA\"' | (cd "$T" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "serial move guard: non-'In progress' target status is unaffected" "rc=0" "$out"
rm -rf "$T"

# --- (h) review round 1 MUST FIX #4: re-moving issue #N itself, while #N is
# the ONLY cached In-progress entry, must NOT self-block (it's not "another"
# task) ---
_serial_repo 1 '{"7": {"itemId": "ITEM_7", "status": "In progress"}}'
out="$(hookjson 'bash board.sh move 7 \"In progress\"' | (cd "$T" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "serial move guard: re-moving the same issue does not self-block" "rc=0" "$out"
check_absent "serial move guard: re-moving the same issue never prints BLOCKED" "BLOCKED" "$out"
rm -rf "$T"

# --- (i) review round 1 MUST FIX #3: evaluate() must not return on the FIRST
# board.sh match in a compound command -- a review-move earlier in the same
# command line must not shadow a later progress-move's own serial check.
# Set up a genuinely valid recorded gate pass so the FIRST segment (move 5 to
# "In review") legitimately succeeds on its own merits; the SECOND segment
# (move 7 to "In progress") must still be independently blocked by the
# serial guard because of the #9 In-progress entry in the cache -- proving
# both board.sh occurrences were actually evaluated, not just the first.
_serial_repo 1 '{"9": {"itemId": "ITEM_9", "status": "In progress"}}'
(cd "$T" && bash "$PLUGIN/scripts/gate.sh" >/dev/null 2>&1)
out="$(hookjson 'bash board.sh move 5 \"In review\" && bash board.sh move 7 \"In progress\"' | (cd "$T" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "compound command: the second segment's progress-move is still serial-checked" "#9" "$out"
check "compound command: still blocked despite a valid gate pass for the first segment" "rc=2" "$out"
rm -rf "$T"

echo "== docs-with-behavior: WAIT protocol documented (review round 1 MUST FIX #2) =="
BUILD_NEXT_SKILL="$(cat "$PLUGIN/skills/build-next/SKILL.md")"
# shellcheck disable=SC2016  # literal backticked markdown text being asserted against, not a shell expansion
check "build-next SKILL.md Operating Rule 1 adds WAIT to the decision vocabulary" '`PICK` / `RESUME` / `WAIT` / `BLOCKED` / `PREFLIGHT FAIL` lines are decisions already made' "$BUILD_NEXT_SKILL"
NEXT_TASK_SKILL="$(cat "$PLUGIN/skills/next-task/SKILL.md")"
# #423: WAIT's wording moved from "WAIT: serial delivery" to the merge-dance
# form -- see section-merge-dance.sh for the full doc-pinning coverage of the
# new slot semantics (RESUME/WAIT/PICK meanings, the dance protocol).
check "next-task SKILL.md documents WAIT" "WAIT: merge-dance" "$NEXT_TASK_SKILL"
check "next-task SKILL.md's WAIT protocol checks the named PR's merge state" "gh pr view" "$NEXT_TASK_SKILL"
check "next-task SKILL.md's WAIT protocol: a merged PR moves the item to QA and re-runs next" "QA" "$NEXT_TASK_SKILL"
