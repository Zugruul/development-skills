#!/usr/bin/env bash
# Sourced by run-tests.sh; shared Python behavioral tests for #241.
# Contract: runner defines check helpers and HERE.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
python3 "$HERE/test_review_rounds.py"
check_rc "bounded autonomous review rounds" 0 "$?"
