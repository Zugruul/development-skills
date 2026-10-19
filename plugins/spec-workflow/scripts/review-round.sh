#!/usr/bin/env bash
# review-round.sh admit --task ID --ts ISO8601 [--root DIR]
# review-round.sh approval-check --task ID [--root DIR]
# Default: primary checkout state, including from linked worktrees.
# An explicit --root must name an existing consumer directory.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/spec-workflow/scripts/lib/repo-root.sh
source "$HERE/lib/repo-root.sh"
usage() { echo "usage: review-round.sh {admit --task ID --ts ISO8601|approval-check --task ID} [--root DIR]" >&2; }
[[ $# -ge 1 ]] || { usage; exit 2; }
MODE="$1"; shift
ROOT="" TASK="" TS=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --root|--task|--ts)
            [[ $# -ge 2 && -n "$2" ]] || { usage; exit 2; }
            case "$1" in
                --root) ROOT="$2" ;;
                --task) TASK="$2" ;;
                --ts) TS="$2" ;;
            esac
            shift 2 ;;
        *) usage; exit 2 ;;
    esac
done
[[ -n "$TASK" ]] || { usage; exit 2; }
[[ -n "$ROOT" ]] || ROOT="$(spec_workflow_repo_root)" || exit 2
case "$MODE" in
    admit)
        [[ -n "$TS" ]] || { usage; exit 2; }
        exec python3 "$HERE/telemetry.py" "$ROOT" review-admit "$TASK" "$TS" ;;
    approval-check)
        [[ -z "$TS" ]] || { usage; exit 2; }
        exec python3 "$HERE/telemetry.py" "$ROOT" review-approval-check "$TASK" ;;
    *) usage; exit 2 ;;
esac
