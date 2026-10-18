#!/usr/bin/env bash
# closure-preflight.sh --task ID [--root DIR]
# Read-only, host-neutral task closure check (#238). Default state belongs
# to the primary checkout even when called from a linked worktree. Explicit
# --root is honored. Structural attestations do not prove content/authenticity.
# Exit 0 silently on success; exit 2 with actionable refusal otherwise.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/spec-workflow/scripts/lib/repo-root.sh
source "$HERE/lib/repo-root.sh"
ROOT=""
TASK=""
usage() { echo "usage: closure-preflight.sh --task ID [--root DIR]" >&2; }
while [[ $# -gt 0 ]]; do
    case "$1" in
        --root|--task)
            [[ $# -ge 2 && -n "$2" ]] || { usage; exit 2; }
            if [[ "$1" == "--root" ]]; then ROOT="$2"; else TASK="$2"; fi
            shift 2 ;;
        *) usage; exit 2 ;;
    esac
done
[[ -n "$TASK" ]] || { usage; exit 2; }
[[ -n "$ROOT" ]] || ROOT="$(spec_workflow_repo_root)" || { echo "ERROR: could not resolve repo root" >&2; exit 2; }
exec python3 "$HERE/telemetry.py" "$ROOT" closure-check "$TASK"
