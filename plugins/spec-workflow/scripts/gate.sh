#!/usr/bin/env bash
# gate.sh — run the project's gate command and RECORD the pass.
# The recorded pass is bound to the exact tree state (HEAD + uncommitted diff);
# the guard-board-move hook refuses 'move ... "In review"' unless a matching
# pass exists, so a red/unrun gate cannot be bypassed by prose.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CONFIG="${PROJECT_CONFIG:-$ROOT/.claude/project.json}"
MARKER="$ROOT/.claude/gate-pass"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GATE="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["commands"]["gate"])' "$CONFIG")" ||
    { echo "ERROR: cannot read commands.gate from $CONFIG" >&2; exit 1; }

echo "gate: $GATE"
if (cd "$ROOT" && bash -c "$GATE"); then
    bash "$HERE/tree-state.sh" >"$MARKER"
    echo "GATE PASS recorded ($MARKER) for the current tree — 'In review' moves are unlocked until the tree changes."
else
    rc=$?
    rm -f "$MARKER"
    echo "GATE RED (exit $rc) — pass cleared; fix and re-run. Do NOT move the task forward." >&2
    exit "$rc"
fi
