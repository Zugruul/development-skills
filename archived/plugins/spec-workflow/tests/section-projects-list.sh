#!/usr/bin/env bash
# Sourced by run-tests.sh; deterministic local inventory and discovery checks.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== projects-list =="
_projects_list_out="$(python3 -B "$HERE/test-projects-list.py" 2>&1)"
_projects_list_rc=$?
printf '%s\n' "$_projects_list_out"
check_rc "project inventory behavior and registration" 0 "$_projects_list_rc"
