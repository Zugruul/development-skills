#!/usr/bin/env bash
declare -F check >/dev/null 2>&1 || { echo "run tests/run-tests.sh" >&2; exit 2; }
echo "== remote-compute adversarial regressions =="
out="$(python3 "$PLUGIN/tests/test_hardening.py" 2>&1)"; rc=$?
check_rc "adversarial and backward-compatibility regressions" 0 "$rc"
if [[ "$rc" -ne 0 ]]; then echo "$out"; fi
