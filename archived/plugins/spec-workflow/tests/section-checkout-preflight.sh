#!/usr/bin/env bash
# Sourced by the suite; actual Git checkouts exercise the read-only startup decision.
set -uo pipefail
declare -F check >/dev/null 2>&1 || { echo "run via run-tests.sh" >&2; exit 2; }
echo "== checkout preservation and startup decision (#285) =="
python3 "$HERE/test_checkout_preflight.py"
check_rc "checkout preservation integration" 0 "$?"
