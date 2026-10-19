#!/usr/bin/env bash
# Behavioral mutation-boundary admission tests; isolated fake GitHub state.
declare -F check >/dev/null 2>&1 || { echo "run via run-tests.sh" >&2; exit 2; }
echo "== host-neutral WIP admission (#240) =="
python3 "$HERE/test_wip_admission.py"
check_rc "WIP mutation admission contracts" 0 "$?"
