#!/usr/bin/env bash
# Sourced by run-tests.sh; the standalone Python module also supports focused runs.
set -uo pipefail
declare -F check >/dev/null 2>&1 || { echo "run tests/run-tests.sh" >&2; exit 2; }
echo "== bounded ComfyUI workflow import =="
out="$(python3 "$PLUGIN/tests/test_comfy_import.py" 2>&1)"; rc=$?
check_rc "ComfyUI import boundaries and API compatibility" 0 "$rc"
if [[ "$rc" -ne 0 ]]; then echo "$out"; fi
