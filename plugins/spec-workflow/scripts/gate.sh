#!/usr/bin/env bash
# gate.sh — run the project's gate command and RECORD the pass.
# The recorded pass is bound to the exact tree state (HEAD + uncommitted diff);
# the guard-board-move hook refuses 'move ... "In review"' unless a matching
# pass exists, so a red/unrun gate cannot be bypassed by prose.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONPATH="$HERE${PYTHONPATH:+:$PYTHONPATH}"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CONFIG="$(python3 "$HERE/config.py" "$ROOT" path)"
MARKER="$ROOT/.claude/gate-pass"

GATE="$(python3 -c 'import sys; import config as C; print(C.load_config(path=sys.argv[1], warn=False)["commands"]["gate"])' "$CONFIG")" ||
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
