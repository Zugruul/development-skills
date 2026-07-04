#!/usr/bin/env bash
# guard-board-move.sh — PreToolUse(Bash) hook: block `board.sh move <n> "In review"`
# unless gate.sh recorded a pass for the CURRENT tree state. Exit 2 = block (stderr
# goes back to the model); exit 0 = allow. Must stay fast — it runs on every Bash call.
set -uo pipefail

CMD="$(python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("tool_input",{}).get("command",""))
except Exception: pass' 2>/dev/null)" || exit 0

case "$CMD" in
    *board.sh*move*) ;;
    *) exit 0 ;;
esac
printf '%s' "$CMD" | grep -qi "in.review" || exit 0

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
MARKER="$ROOT/.claude/gate-pass"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "$MARKER" ]]; then
    echo "BLOCKED: no recorded gate pass. Run \`bash \"$HERE/gate.sh\"\` to green (it records the pass), then retry the move to 'In review'." >&2
    exit 2
fi
if [[ "$(cat "$MARKER")" != "$(bash "$HERE/tree-state.sh")" ]]; then
    echo "BLOCKED: the tree changed since the last recorded gate pass. Re-run \`bash \"$HERE/gate.sh\"\`, then retry the move to 'In review'." >&2
    exit 2
fi
exit 0
