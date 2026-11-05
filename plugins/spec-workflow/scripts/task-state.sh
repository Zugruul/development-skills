#!/usr/bin/env bash
# Local record of the tasks agents are working on; see skills/task-state/SKILL.md.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$HERE/task_state.py" "$@"
