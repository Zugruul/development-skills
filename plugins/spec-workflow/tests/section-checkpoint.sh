#!/usr/bin/env bash
# Sourced by the suite; behavioral command tests use isolated git/gh fixtures.
declare -F check >/dev/null 2>&1 || { echo "run via run-tests.sh" >&2; exit 2; }
echo "== host-neutral checkpoint admission (#239) =="
python3 "$HERE/test_checkpoint.py"
check_rc "checkpoint command contracts" 0 "$?"
