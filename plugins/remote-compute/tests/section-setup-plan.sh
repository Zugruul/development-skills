#!/usr/bin/env bash
set -uo pipefail
declare -F check >/dev/null 2>&1 || { echo "run tests/run-tests.sh" >&2; exit 2; }
echo "== remote-compute capability setup plans =="
out="$(python3 "$PLUGIN/tests/test_setup_plan.py" 2>&1)"; rc=$?
check_rc "install shows setup plan, asks on a TTY, runs declared steps in order" 0 "$rc"
if [[ "$rc" -ne 0 ]]; then echo "$out"; fi
