#!/usr/bin/env bash
# gate.sh — run the project's gate command and RECORD the pass.
# The recorded pass is bound to the exact tree state (HEAD + uncommitted diff);
# the guard-board-move hook refuses 'move ... "In review"' unless a matching
# pass exists, so a red/unrun gate cannot be bypassed by prose.
set -uo pipefail
# dev#96: the recorded gate pass MUST be a full-suite run. run-tests.sh honors
# SPEC_TESTS_SECTION as a section filter, so if it is set here a gate run would
# record a pass covering only a subset of the suite. Refuse up front — before
# reading config or running anything — so a filtered pass can never be recorded.
if [[ -n "${SPEC_TESTS_SECTION:-}" ]]; then
    echo "gate.sh: refusing to run with SPEC_TESTS_SECTION set (=${SPEC_TESTS_SECTION}) — the recorded gate pass must be a full-suite run, never a filtered subset. Unset SPEC_TESTS_SECTION and re-run." >&2
    exit 2
fi
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONPATH="$HERE${PYTHONPATH:+:$PYTHONPATH}"
# shellcheck source=plugins/spec-workflow/scripts/lib/repo-root.sh
source "$HERE/lib/repo-root.sh"
# #463: TWO roots, deliberately different.
#   ROOT (TREE_ROOT)  -- the CURRENT tree, via --show-toplevel, unchanged.
#     This is the tree actually under test: the gate command below `cd`s
#     here to run, `commands.gate` is read from ITS project.yaml, and
#     tree-state.sh (invoked with this same cwd) fingerprints THIS tree.
#     Testing a worktree's own code must never silently run against the
#     main checkout's tree instead.
#   STATE_ROOT (PRIMARY_ROOT) -- via lib/repo-root.sh, the main checkout
#     from anywhere. The gate-pass marker, red-gate lessons, and gate
#     telemetry are shared loop state that must live in ONE place so
#     guard-board-move.sh/gate-preflight.sh can find them regardless of
#     which worktree they are invoked from.
# The marker's CONTENT is still the tree-state fingerprint of TREE_ROOT (the
# tree that was actually tested) -- only its FILE LOCATION moves to
# STATE_ROOT. gate-preflight.sh mirrors this: it looks the marker up at
# STATE_ROOT but compares it against a fresh fingerprint of ITS OWN current
# tree, so the pass is only "valid" from the exact tree it was recorded for.
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CONFIG="$(python3 "$HERE/config.py" "$ROOT" path)"
STATE_ROOT="$(spec_workflow_repo_root)" || { echo "ERROR: could not resolve repo root" >&2; exit 1; }
MARKER="$STATE_ROOT/.claude/gate-pass"
# SPEC §8.1: on a red gate, the failing command's tail output + a timestamp
# is appended here (as JSONL) before the pass marker is cleared, so the next
# retro has the richest failure signal the loop produces. Distinct from
# .claude/telemetry.jsonl (pass/fail bookkeeping only, no output captured).
# Gitignored like the other local loop-state files (see tree-state.sh, which
# excludes it from the fingerprint the same way).
LESSONS="$STATE_ROOT/.claude/lessons.jsonl"
GATE_OUT_LINES=40

GATE="$(python3 -c 'import sys; import config as C; print(C.load_config(path=sys.argv[1], warn=False)["commands"]["gate"])' "$CONFIG")" ||
    { echo "ERROR: cannot read commands.gate from $CONFIG" >&2; exit 1; }

echo "gate: $GATE"
# gate.sh has no task id in scope; the current branch name stands in for it in telemetry
# (see telemetry.py's module docstring for the record schema).
TASK="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
record_gate() { # $1=ok (true|false) — best-effort, must never affect gate.sh's own exit status
    python3 "$HERE/telemetry.py" "$STATE_ROOT" record \
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
    mkdir -p "$(dirname "$MARKER")"
    # Explicit `cd "$ROOT"` (TREE_ROOT), not STATE_ROOT: the fingerprint must
    # describe the tree that was actually just tested above.
    # #443 review round 2 (MEDIUM): tree-state.sh now exits nonzero (and
    # prints nothing) rather than silently degrading to a stable placeholder
    # when it cannot reliably fingerprint the tree -- checking that exit
    # status here is what actually makes that fail LOUD end to end. Without
    # this check, a failed tree-state.sh run would still write an EMPTY
    # $MARKER and this script would still print "GATE PASS recorded" --
    # exactly the silent-blind outcome the fix exists to prevent, just moved
    # one call site up.
    if ! (cd "$ROOT" && bash "$HERE/tree-state.sh") >"$MARKER"; then
        rm -f "$MARKER"
        echo "ERROR: could not fingerprint the tree (tree-state.sh failed) -- no pass recorded. See its stderr above." >&2
        exit 1
    fi
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
