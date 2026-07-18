#!/usr/bin/env bash
# gate-preflight.sh — hook-independent check: "is there a recorded gate pass
# for the current tree fingerprint?" (CDX-030, SPEC-CODEX-COMPAT.md §9.1/§12).
#
# Extracted from guard-board-move.sh's marker-exists + fingerprint-match
# check so any caller (the Claude PreToolUse hook, board-queue.sh's
# _do_move(), a Codex explicit workflow step, or a human) can invoke the
# same logic identically -- one implementation, not a copy per host/call
# site. Read-only, no side effects.
#
# Usage: gate-preflight.sh [--root <path>]  (default root: git toplevel, or
# cwd if not in a git repo -- --root exists for tests that want to check a
# fixture repo without cd'ing into it first).
# Exit 0, silent stdout: a valid pass exists for the current tree.
# Exit 2, actionable message on stderr: the pass is missing or stale.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --root)
            [[ $# -ge 2 ]] || { echo "usage: gate-preflight.sh [--root <path>]" >&2; exit 2; }
            ROOT="$2"; shift 2 ;;
        *) echo "usage: gate-preflight.sh [--root <path>]" >&2; exit 2 ;;
    esac
done
[[ -n "$ROOT" ]] || ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

MARKER="$ROOT/.claude/gate-pass"
if [[ ! -f "$MARKER" ]]; then
    echo "BLOCKED: no recorded gate pass. Run \`bash \"$HERE/gate.sh\"\` to green (it records the pass), then retry the move to 'In review'." >&2
    exit 2
fi
if [[ "$(cat "$MARKER")" != "$(cd "$ROOT" && bash "$HERE/tree-state.sh")" ]]; then
    echo "BLOCKED: the tree changed since the last recorded gate pass. Re-run \`bash \"$HERE/gate.sh\"\`, then retry the move to 'In review'." >&2
    exit 2
fi
exit 0
