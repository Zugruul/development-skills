#!/usr/bin/env bash
# section-section-guard.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent) and set HERE/PLUGIN/FIX/fails/flaky
# before sourcing this file. This file assumes those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== section standalone-run guard (#94) =="

# Every section-*.sh carries a one-line guard as its FIRST executable
# statement: if the harness helpers aren't in scope (i.e. the file was run
# directly instead of sourced by run-tests.sh) it prints a pointer to the
# real entrypoint and exits 2, instead of spewing 'check: command not found'
# / empty-$PLUGIN path noise. Three reviewers (sw-073/085/090) each burned
# minutes on that noise before spotting the header comment; #94 makes the
# friendly message structural, and this section pins it can't regress.
_GUARD_PROBE='declare -F check >/dev/null 2>&1 ||'
_GUARD_MSG='section files are sourced by run-tests.sh'

# 1. STATIC: every section file on disk carries the guard. Globbing the
#    directory (not the runner's SECTIONS array) means a newly added section
#    file is held to the contract even before it's registered.
_missing=""
for _f in "$HERE"/section-*.sh; do
    grep -qF -- "$_GUARD_PROBE" "$_f" || _missing="$_missing $(basename "$_f")"
done
if [[ -z "$_missing" ]]; then
    echo "ok   every section-*.sh carries the standalone guard"
else
    echo "FAIL section-*.sh missing the standalone guard:$_missing"
    fails=$((fails + 1))
fi

# 2. BEHAVIORAL: running a real section file directly actually trips the
#    guard -- exits 2 with the pointer, not a wall of harness-undefined
#    noise. Proves the guard fires, not merely that a string is present.
_out="$(bash "$HERE/section-syntax.sh" 2>&1)"; _rc=$?
check    "standalone section prints the run-tests pointer" "$_GUARD_MSG" "$_out"
check_rc "standalone section exits 2"                      2 "$_rc"
