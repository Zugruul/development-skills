#!/usr/bin/env bash
# Sourced in the shared runner; Python owns and cleans up its fixture state.
declare -F check >/dev/null 2>&1 || { echo "run: bash plugins/peer-review/tests/run-tests.sh" >&2; exit 2; }
echo "== shipped egress contract (#529) =="
python3 "$PLUGIN/tests/test-egress-contract.py"
check_rc "egress contract and shipped provider routing" 0 "$?"
