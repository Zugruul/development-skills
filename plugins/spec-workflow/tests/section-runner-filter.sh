#!/usr/bin/env bash
# section-runner-filter.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail, has sourced _lib.sh
# (check/check_rc/check_absent) and set HERE/PLUGIN/FIX/fails/flaky before
# sourcing this file. This file assumes those are already in scope.
#
# Exercises run-tests.sh's own --section filter (dev#96): a single section can
# be run without paying the full suite's minutes.
#
# Recursion guard: this section SPAWNS `bash run-tests.sh` as a subprocess to
# drive the filter end-to-end. A spawned child re-sources every section file,
# including THIS one; without a sentinel the child would spawn again forever
# (and on a pre-filter tree, where --section is ignored, each child runs the
# WHOLE suite). Every spawn below is prefixed _RUNNER_FILTER_META=1; when that
# is set we return immediately so the child skips this section.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
if [[ -n "${_RUNNER_FILTER_META:-}" ]]; then
    return 0
fi
echo "== run-tests.sh --section filter =="
RT="$HERE/run-tests.sh"

# 1. --section <name> runs ONLY the matching section (green exit).
out="$(_RUNNER_FILTER_META=1 bash "$RT" --section preflight 2>&1)"; rc=$?
check        "single --section runs the match"        "== preflight ==" "$out"
check_absent "single --section excludes non-matches"  "== syntax =="    "$out"
check_rc     "single --section exits 0"               0 "$rc"

# 2. Comma-separated and repeated flags both select the union.
out="$(_RUNNER_FILTER_META=1 bash "$RT" --section preflight,concurrency 2>&1)"
check        "comma list selects first"   "== preflight =="  "$out"
check        "comma list selects second"  "== concurrency (maxInProgress surgical set) ==" "$out"
check_absent "comma list excludes rest"   "== syntax =="     "$out"
out="$(_RUNNER_FILTER_META=1 bash "$RT" --section preflight --section concurrency 2>&1)"
check        "repeated flag selects first"   "== preflight =="  "$out"
check        "repeated flag selects second"  "== concurrency (maxInProgress surgical set) ==" "$out"

# 3. Match is a substring of the section base-name ("flight" -> "preflight").
out="$(_RUNNER_FILTER_META=1 bash "$RT" --section flight 2>&1)"; rc=$?
check        "substring match runs preflight" "== preflight ==" "$out"
check_rc     "substring match exits 0"        0 "$rc"

# 4. No match -> error naming the bad filter + listing available sections,
#    non-zero exit, and NOT a single section runs.
out="$(_RUNNER_FILTER_META=1 bash "$RT" --section zzz-nonexistent 2>&1)"; rc=$?
check        "no-match names the bad filter"       "zzz-nonexistent" "$out"
check        "no-match lists available sections"   "board-queue"     "$out"
check_rc     "no-match exits 2"                     2 "$rc"
check_absent "no-match runs no section"            "== preflight =="  "$out"

# 5. The SPEC_TESTS_SECTION env var is an equivalent filter source (this is
#    also the handle gate.sh guards on, below).
out="$(_RUNNER_FILTER_META=1 SPEC_TESTS_SECTION=preflight bash "$RT" 2>&1)"
check        "env filter runs the match"       "== preflight ==" "$out"
check_absent "env filter excludes non-matches" "== syntax =="    "$out"

# 6. gate.sh REFUSES to record a pass when SPEC_TESTS_SECTION is set: the
#    recorded gate pass must always be a full-suite run, never a filtered
#    subset. Driven in a throwaway git repo whose commands.gate is the cheap
#    fixture ("true") so there is no suite recursion here.
gt="$(mktemp -d)"
( cd "$gt" && git init -q . && mkdir -p .claude && cp "$FIX/valid.project.json" .claude/project.json )
out="$(cd "$gt" && SPEC_TESTS_SECTION=preflight bash "$PLUGIN/scripts/gate.sh" 2>&1)"; rc=$?
check        "gate refuses a filtered run"  "SPEC_TESTS_SECTION" "$out"
check_rc     "gate refusal exits 2"         2 "$rc"
check_absent "gate wrote no pass marker"    "GATE PASS recorded" "$out"
rm -rf "$gt"

# --- round 2 review findings (dev#96 r2) ---------------------------------
# F1: sections that only make sense as a group must still run when filtered
# to ONE of them. The guard-hook helpers (hookjson/hookjsonpy) are shared by
# gate-core/gate-lessons/gate-fingerprint/guard-pr-create; if they live only
# in gate-core, filtering to a consumer leaves them undefined -> the guard
# gets empty stdin -> spurious FAILs. Each consumer must exit 0 standalone.
out="$(_RUNNER_FILTER_META=1 bash "$RT" --section gate-lessons 2>&1)"; rc=$?
check_rc     "gate-lessons runs standalone (shared helpers in _lib.sh)"    0 "$rc"
out="$(_RUNNER_FILTER_META=1 bash "$RT" --section gate-fingerprint 2>&1)"; rc=$?
check_rc     "gate-fingerprint runs standalone (shared helpers in _lib.sh)" 0 "$rc"
# guard-pr-create carries its own hookjson_pr helper, so it is already
# standalone-clean; this is a regression guard that it stays that way.
out="$(_RUNNER_FILTER_META=1 bash "$RT" --section guard-pr-create 2>&1)"; rc=$?
check_rc     "guard-pr-create runs standalone (self-contained helper)"  0 "$rc"

# F2: filtering to only ONE half of the ui-hub -> neural-view-lifecycle
# teardown pair must be a harmless no-op (as the run-tests.sh comment
# claims), not a set -u crash on the unbound cross-section _hubtmp var.
out="$(_RUNNER_FILTER_META=1 bash "$RT" --section neural-view-lifecycle 2>&1)"; rc=$?
check_rc     "neural-view-lifecycle runs standalone (no unbound _hubtmp)" 0 "$rc"
check_absent "no unbound _hubtmp crash"          "_hubtmp: unbound variable" "$out"

# F3: an explicit-but-empty filter (--section= / --section "") must not crash
# on an unbound array under bash 3.2 + set -u; empty terms are ignored, and a
# filter that resolves to no terms falls through to the no-match error (exit
# 2), never a stack trace.
out="$(_RUNNER_FILTER_META=1 bash "$RT" --section= 2>&1)"; rc=$?
check_absent "--section= does not crash on an empty term" "unbound variable" "$out"
check_rc     "--section= exits 2 (no section matched)"    2 "$rc"
out="$(_RUNNER_FILTER_META=1 bash "$RT" --section "" 2>&1)"; rc=$?
check_absent "--section '' does not crash on an empty term" "unbound variable" "$out"
check_rc     "--section '' exits 2 (no section matched)"     2 "$rc"
# A mix of empty and real terms keeps only the real ones (empties ignored).
out="$(_RUNNER_FILTER_META=1 bash "$RT" --section ,preflight, 2>&1)"; rc=$?
check        "mixed empty/real terms keeps the real one" "== preflight ==" "$out"
check_absent "mixed empty/real terms ignores the empties" "== syntax =="   "$out"
check_rc     "mixed empty/real terms exits 0"             0 "$rc"
