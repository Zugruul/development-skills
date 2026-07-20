#!/usr/bin/env bash
# two-pass-review-preflight.sh — hook-independent check: "did this task get
# BOTH documented review passes (spec-compliance, then code-quality) before
# advancing to QA?" (#236, CDX-031 gap #4, SPEC-CODEX-COMPAT.md §9.1
# invariant "independent two-pass review").
#
# Mirrors gate-preflight.sh's CLI shape/exit-code contract so any caller
# (board-queue.sh's _do_move(), a Codex explicit workflow step, or a human)
# can invoke the same logic identically. Read-only, no side effects.
#
# KNOWN LIMITATION, stated plainly: this verifies that TWO review-round
# telemetry records exist for the task with the right `pass` tags -- it does
# NOT verify they came from genuinely INDEPENDENT agent sessions. A single
# reviewer session that manually records both `pass` values without running
# two actual separate passes would satisfy this check. Closing that gap
# would require per-record session/agent identifiers, which telemetry.py's
# schema doesn't currently carry -- out of scope here (see docs/design/
# cdx-E3.md, "Follow-up: #236").
#
# Usage: two-pass-review-preflight.sh [--root <path>] [--task <id>]
#   --root default: git toplevel (or cwd if not in a git repo).
#   --task required: the task/issue number to check.
# Exit 0, silent stdout: both passes are recorded for the task.
# Exit 2, actionable message on stderr: one or both passes are missing.
set -uo pipefail

ROOT=""
TASK=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --root)
            [[ $# -ge 2 ]] || { echo "usage: two-pass-review-preflight.sh [--root <path>] [--task <id>]" >&2; exit 2; }
            ROOT="$2"; shift 2 ;;
        --task)
            [[ $# -ge 2 ]] || { echo "usage: two-pass-review-preflight.sh [--root <path>] [--task <id>]" >&2; exit 2; }
            TASK="$2"; shift 2 ;;
        *) echo "usage: two-pass-review-preflight.sh [--root <path>] [--task <id>]" >&2; exit 2 ;;
    esac
done
[[ -n "$ROOT" ]] || ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if [[ -z "$TASK" ]]; then
    echo "usage: two-pass-review-preflight.sh [--root <path>] [--task <id>]" >&2
    exit 2
fi

TELEMETRY="$ROOT/.claude/telemetry.jsonl"

MISSING="$(TASK="$TASK" python3 - "$TELEMETRY" <<'PY'
import json
import os
import sys

path = sys.argv[1]
task = os.environ["TASK"]
found = set()

try:
    with open(path) as fh:
        lines = fh.readlines()
except OSError:
    lines = []

for line in lines:
    line = line.strip()
    if not line:
        continue
    try:
        rec = json.loads(line)
    except ValueError:
        continue
    if not isinstance(rec, dict):
        continue
    if rec.get("kind") != "review-round":
        continue
    if str(rec.get("task")) != task:
        continue
    p = rec.get("pass")
    if p in ("spec-compliance", "code-quality"):
        found.add(p)

missing = [p for p in ("spec-compliance", "code-quality") if p not in found]
print(",".join(missing))
PY
)"

if [[ -z "$MISSING" ]]; then
    exit 0
fi

echo "BLOCKED: task #$TASK is missing recorded review pass(es): $MISSING. implement-task/SKILL.md §3 requires two independent review passes (spec-compliance, then code-quality) -- each recorded via \`telemetry.py $ROOT record '{\"kind\":\"review-round\",\"task\":\"$TASK\",...,\"pass\":\"<spec-compliance|code-quality>\"}'\` -- before moving to QA." >&2
exit 2
