#!/usr/bin/env bash
# SessionStart hook — inject spec-workflow status so the loop's rules are active
# from message one (stdout becomes session context). Silent in repos without config.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONPATH="$HERE${PYTHONPATH:+:$PYTHONPATH}"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CONFIG="$(python3 "$HERE/config.py" "$ROOT" path 2>/dev/null)"
[[ -n "$CONFIG" && -f "$CONFIG" ]] || exit 0

NAME="$(python3 -c 'import sys; import config as C; print(C.load_config(path=sys.argv[1], warn=False)["project"]["name"])' "$CONFIG" 2>/dev/null)" || exit 0
GATE="$(python3 -c 'import sys; import config as C; print(C.load_config(path=sys.argv[1], warn=False)["commands"]["gate"])' "$CONFIG" 2>/dev/null || echo "?")"

echo "spec-workflow is active for '$NAME' (config: ${CONFIG#"$ROOT"/})."
echo "- The GitHub Project board is the source of truth; work runs via /spec-workflow:build-next (or next-task -> implement-task). Scripts decide, you obey: PICK/RESUME/BLOCKED/PREFLIGHT lines are decisions already made."
echo "- Gate: \`$GATE\` — run it via \`bash \"\$CLAUDE_PLUGIN_ROOT/scripts/gate.sh\"\` so the pass is RECORDED; moving a task to 'In review' is blocked by a hook unless the recorded pass matches the current tree."
if [[ -f "$ROOT/.claude/CHECKPOINT" ]]; then
    echo "- CHECKPOINT flag is present: the build loop is PAUSED ($(head -c 200 "$ROOT/.claude/CHECKPOINT" 2>/dev/null || true)). Do not start loop work; see the checkpoint skill."
fi
if [[ -x "$HERE/ui-mode.sh" ]]; then
    echo "- Iterative UI mode: $(bash "$HERE/ui-mode.sh" status 2>/dev/null | head -1)"
fi
exit 0
