#!/usr/bin/env bash
# SessionStart hook — inject spec-workflow status so the loop's rules are active
# from message one (stdout becomes session context). Silent in repos without config.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONPATH="$HERE${PYTHONPATH:+:$PYTHONPATH}"
# shellcheck source=plugins/spec-workflow/scripts/lib/repo-root.sh
source "$HERE/lib/repo-root.sh"
# #463: PRIMARY repo root -- the CHECKPOINT flag and project config live once
# per repo in the main checkout; a session started with a worktree cwd must
# still see them.
ROOT="$(spec_workflow_repo_root)" || exit 0
CONFIG="$(python3 "$HERE/config.py" "$ROOT" path 2>/dev/null)"
[[ -n "$CONFIG" && -f "$CONFIG" ]] || exit 0

# Advisory only, including malformed configuration; bootstrap stays silent.
bash "$HERE/checkpoint-preflight.sh" --root "$ROOT" 2>&1 || true

NAME="$(python3 -c 'import sys; import config as C; print(C.load_config(path=sys.argv[1], warn=False)["project"]["name"])' "$CONFIG" 2>/dev/null)" || exit 0
GATE="$(python3 -c 'import sys; import config as C; print(C.load_config(path=sys.argv[1], warn=False)["commands"]["gate"])' "$CONFIG" 2>/dev/null || echo "?")"

echo "spec-workflow is active for '$NAME' (config: ${CONFIG#"$ROOT"/})."
echo "- The GitHub Project board is the source of truth; work runs via /spec-workflow:build-next (or next-task -> implement-task). Scripts decide, you obey: PICK/RESUME/BLOCKED/PREFLIGHT lines are decisions already made."
# methodology.gateScope (affected|full, default affected) + commands.gateAffected
# decide what gate.sh actually runs; say so, so agents don't assume a full run.
GATE_SCOPE_LINE="$(python3 -c '
import sys; import config as C
c = C.load_config(path=sys.argv[1], warn=False)
scope = (c.get("methodology") or {}).get("gateScope") or "affected"
aff = (c.get("commands") or {}).get("gateAffected")
if scope == "affected" and aff:
    print("affected (gate.sh runs commands.gateAffected over the changed files; --full runs everything)")
elif scope == "affected":
    print("affected, but no commands.gateAffected is set, so gate.sh runs the full gate")
else:
    print("full")
' "$CONFIG" 2>/dev/null || echo "?")"
echo "- Gate: \`$GATE\` — run it via \`bash \"\$CLAUDE_PLUGIN_ROOT/scripts/gate.sh\"\` so the pass is RECORDED; moving a task to 'In review' is blocked by a hook unless the recorded pass matches the current tree."
echo "- Gate scope (methodology.gateScope): $GATE_SCOPE_LINE."
if [[ -x "$HERE/iterative-ui.sh" ]]; then
    echo "- Iterative UI mode: $(bash "$HERE/iterative-ui.sh" 2>/dev/null | head -1)"
fi
exit 0
