#!/usr/bin/env bash
# AST-082: engine-owned remote audit, acknowledged persistence and recovery.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh" >&2; exit 2; }
echo "== assistant remote audit and retention (AST-082) =="
_remote_audit_out="$(python3 "$HERE/test_remote_audit.py" 2>&1)"; _remote_audit_rc=$?
printf '%s\n' "$_remote_audit_out"
check_rc "remote audit engine/queue/SQLite contract suite" 0 "$_remote_audit_rc"
