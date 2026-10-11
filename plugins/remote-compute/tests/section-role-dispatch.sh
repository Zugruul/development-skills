#!/usr/bin/env bash
set -uo pipefail
declare -F check >/dev/null 2>&1 || { echo "run tests/run-tests.sh" >&2; exit 2; }
echo "== remote-compute role dispatch =="
out="$(python3 "$PLUGIN/tests/test_role_dispatch.py" 2>&1)"; rc=$?
check_rc "role dispatch and real target admission regressions" 0 "$rc"
if [[ "$rc" -ne 0 ]]; then echo "$out"; fi
