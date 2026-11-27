#!/usr/bin/env bash
# AST-080 restricted client/server boundary, including isolated local OpenSSH.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== restricted assistant remote control (AST-080) =="
_remote_control_out="$(python3 "$HERE/test_remote_control.py" 2>&1)"; _remote_control_rc=$?
printf '%s\n' "$_remote_control_out"
check_rc "restricted remote control unit/integration suite" 0 "$_remote_control_rc"
