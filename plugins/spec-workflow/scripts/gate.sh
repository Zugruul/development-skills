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
# SPEC §8.1: on a red gate, the failing command's tail output + a timestamp
# is appended here (as JSONL) before the pass marker is cleared, so the next
# retro has the richest failure signal the loop produces. Distinct from
# .claude/telemetry.jsonl (pass/fail bookkeeping only, no output captured).
# Gitignored like the other local loop-state files (see tree-state.sh, which
# excludes it from the fingerprint the same way).
LESSONS="$ROOT/.claude/lessons.jsonl"
GATE_OUT_LINES=40

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
record_lesson() { # $1=exit-code, tail text on stdin — best-effort, appends before the marker is cleared
    mkdir -p "$(dirname "$LESSONS")"
    python3 -c '
import datetime, json, sys
rec = {
    "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "exit": int(sys.argv[1]),
    "tail": sys.stdin.read(),
}
with open(sys.argv[2], "a") as f:
    f.write(json.dumps(rec) + "\n")
' "$1" "$LESSONS" >/dev/null 2>&1 || true
}

GATE_TMP="$(mktemp)"
trap 'rm -f "$GATE_TMP"' EXIT
(cd "$ROOT" && bash -c "$GATE") 2>&1 | tee "$GATE_TMP"
rc="${PIPESTATUS[0]}"
if [[ "$rc" -eq 0 ]]; then
    # Recording telemetry before fingerprinting the tree (rather than after) is
    # redundant-but-harmless, not the defense: tree-state.sh itself excludes
    # .claude/telemetry.jsonl from the fingerprint (see its own comment) so
    # that a routine status transition — for any task, from any concurrent
    # lane — can never invalidate a still-current, unrelated gate pass.
    record_gate true
    bash "$HERE/tree-state.sh" >"$MARKER"
    echo "GATE PASS recorded ($MARKER) for the current tree — 'In review' moves are unlocked until the tree changes."
else
    # Persist the failure signal (SPEC §8.1) before clearing the marker: a
    # process killed between the two steps should still leave the tail
    # captured, not just the (weaker, telemetry-only) fact that it failed.
    tail -n "$GATE_OUT_LINES" "$GATE_TMP" | record_lesson "$rc"
    rm -f "$MARKER"
    record_gate false
    echo "GATE RED (exit $rc) — pass cleared; fix and re-run. Do NOT move the task forward." >&2
    exit "$rc"
fi
