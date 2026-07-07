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
# gate.sh has no task id in scope; the current branch name stands in for it in telemetry
# (see telemetry.py's module docstring for the record schema).
TASK="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
record_gate() { # $1=ok (true|false) — best-effort, must never affect gate.sh's own exit status
    python3 "$HERE/telemetry.py" "$ROOT" record \
        "{\"kind\":\"gate\",\"task\":\"$TASK\",\"ok\":$1,\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
        >/dev/null 2>&1 || true
}
if (cd "$ROOT" && bash -c "$GATE"); then
    # record telemetry BEFORE fingerprinting the tree: telemetry.jsonl itself is an
    # untracked file, so writing it after the marker would make the very next
    # tree-state check see a "changed" tree and wrongly re-block the move.
    record_gate true
    bash "$HERE/tree-state.sh" >"$MARKER"
    echo "GATE PASS recorded ($MARKER) for the current tree — 'In review' moves are unlocked until the tree changes."
else
    rc=$?
    rm -f "$MARKER"
    record_gate false
    echo "GATE RED (exit $rc) — pass cleared; fix and re-run. Do NOT move the task forward." >&2
    exit "$rc"
fi
