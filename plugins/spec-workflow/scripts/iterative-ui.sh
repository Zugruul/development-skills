#!/usr/bin/env bash
# iterative-ui.sh — is Iterative UI mode on for this project? Read-only.
#   iterative-ui.sh   -> "ON (...)" / "OFF (reason)"
# Mocking and deciding UI lives in the standalone ui-design plugin; this is
# spec-workflow's own reader of the two switches its build loop honours:
#   - methodology.iterativeUI=false in the project config: project-wide off
#     (spec-workflow's own setting; ui-design never reads it);
#   - the .claude/ITERATIVE_UI_OFF flag in the main checkout: the per-clone
#     off that ui-design's ui-mode skill toggles (a shared file, not a path
#     into that plugin).
# Whether ui-design is installed is a skill-level question (are the
# ui-design:* skills available?), answered by the agent, not by this script.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONPATH="$HERE${PYTHONPATH:+:$PYTHONPATH}"
# shellcheck source=plugins/spec-workflow/scripts/lib/repo-root.sh
source "$HERE/lib/repo-root.sh"
ROOT="$(spec_workflow_repo_root)" || { echo "ERROR: could not resolve repo root" >&2; exit 1; }
FLAG="$ROOT/.claude/ITERATIVE_UI_OFF"
CONFIG="$(python3 "$HERE/config.py" "$ROOT" path 2>/dev/null)"

cfg_off() { [[ -n "$CONFIG" && -f "$CONFIG" ]] && python3 -c 'import sys; import config as C; sys.exit(0 if (C.load_config(path=sys.argv[1], warn=False) or {}).get("methodology",{}).get("iterativeUI") is False else 1)' "$CONFIG" 2>/dev/null; }

if cfg_off; then echo "OFF (methodology.iterativeUI=false in the project config — project-wide)"
elif [[ -f "$FLAG" ]]; then echo "OFF (local flag $FLAG — the ui-design plugin's ui-mode skill re-enables)"
else echo "ON (UI decisions go to the human through the ui-design plugin when it is installed)"
fi
