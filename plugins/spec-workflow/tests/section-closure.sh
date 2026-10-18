#!/usr/bin/env bash
# section-closure.sh -- sourced by run-tests.sh; exercises real command boundaries.
# Contract: runner defines check helpers, HERE/PLUGIN/FIX/fails/flaky.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== task closure evidence (#238) =="
python3 "$HERE/test_closure.py"
check_rc "closure command contract" 0 "$?"
