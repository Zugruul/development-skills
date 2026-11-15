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
# Usage: gate-preflight.sh [--root <path>]
#   --root, if given, overrides BOTH roots below to the same explicit value
#   (tests: check a fixture repo without cd'ing into it first, and without
#   any worktree/main-checkout split to worry about).
#   Default (#463, no --root): TREE_ROOT (the tree the fingerprint is
#   computed against) is the CURRENT tree via git toplevel/cwd; STATE_ROOT
#   (where the marker is looked up) is the PRIMARY repo root (lib/repo-
#   root.sh) -- the main checkout from anywhere, including a linked
#   worktree, since that is where gate.sh writes it. This means: a pass
#   gate.sh recorded FOR THIS TREE is found and matches; a pass recorded for
#   a different tree (or no pass at all) is correctly reported missing/stale.
#   #581: the marker is per worktree (lib/repo-root.sh spec_workflow_gate_marker):
#   .claude/gate-pass for the primary checkout, .claude/gate-pass.d/<key> for a
#   linked worktree, so another lane's gate never invalidates this one.
# Exit 0, silent stdout: a valid pass exists for the current tree.
# Exit 2, actionable message on stderr: the pass is missing or stale.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/spec-workflow/scripts/lib/repo-root.sh
source "$HERE/lib/repo-root.sh"
ROOT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --root)
            [[ $# -ge 2 ]] || { echo "usage: gate-preflight.sh [--root <path>]" >&2; exit 2; }
            ROOT="$2"; shift 2 ;;
        *) echo "usage: gate-preflight.sh [--root <path>]" >&2; exit 2 ;;
    esac
done
if [[ -n "$ROOT" ]]; then
    TREE_ROOT="$ROOT"
    # #581: the marker of a linked worktree lives in its PRIMARY checkout, so --root on a
    # worktree resolves the primary from git; a plain repo is its own primary (as before).
    _common="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
    STATE_ROOT="${_common:+$(dirname "$_common")}"
    STATE_ROOT="${STATE_ROOT:-$ROOT}"
else
    TREE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    STATE_ROOT="$(spec_workflow_repo_root)" || { echo "ERROR: could not resolve repo root" >&2; exit 2; }
fi

MARKER="$(spec_workflow_gate_marker "$STATE_ROOT" "$TREE_ROOT")" || { echo "ERROR: could not resolve the gate-pass marker path" >&2; exit 2; }
if [[ ! -f "$MARKER" ]]; then
    echo "BLOCKED: no recorded gate pass at $MARKER (checked for tree $TREE_ROOT). Run \`bash \"$HERE/gate.sh\"\` to green (it records the pass), then retry the move to 'In review'." >&2
    exit 2
fi
if [[ "$(cat "$MARKER")" != "$(cd "$TREE_ROOT" && bash "$HERE/tree-state.sh")" ]]; then
    echo "BLOCKED: the tree changed since the last recorded gate pass (marker $MARKER, tree $TREE_ROOT). Re-run \`bash \"$HERE/gate.sh\"\`, then retry the move to 'In review'." >&2
    exit 2
fi
exit 0
