#!/usr/bin/env bash
# concurrency.sh — show or set how many tasks the build loop works CONCURRENTLY.
#   concurrency.sh              # or: status -> current methodology.maxInProgress
#   concurrency.sh set <n>      # set methodology.maxInProgress (positive integer)
# maxInProgress is THE concurrency knob: the board WIP limit AND the number of
# parallel implementation lanes. 1 (default) = strictly sequential. N>1 = up to N
# tasks in parallel, each its own git worktree + branch + dev agent — only safe
# when the tasks don't overlap (see skills/build-next/references/concurrency.md).
# Like auto-merge, it is a project-wide, versioned config change every clone obeys.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CONFIG="$(python3 "$HERE/config.py" "$ROOT" path)"
[[ -n "$CONFIG" && -f "$CONFIG" ]] || { echo "ERROR: no .claude/project.yaml (or legacy .json) — run the setup-project skill first" >&2; exit 1; }

get() { python3 "$HERE/config.py" "$ROOT" get "$1"; }

case "${1:-status}" in
    status)
        n="$(get methodology.maxInProgress)"; n="${n:-1}"
        if [[ "$n" == "1" ]]; then
            echo "concurrency: 1 (strictly sequential — one task at a time; the default)"
        else
            echo "concurrency: $n (up to $n tasks in parallel lanes — each its own worktree + branch + dev agent; only for non-overlapping tasks)"
        fi ;;
    set)
        v="${2:-}"
        [[ "$v" =~ ^[1-9][0-9]*$ ]] || { echo "usage: concurrency.sh set <positive-integer>" >&2; exit 1; }
        python3 "$HERE/config.py" "$ROOT" set methodology.maxInProgress "$v"
        echo "concurrency: $v (methodology.maxInProgress=$v in $CONFIG — commit this change)"
        [[ "$v" != "1" ]] && echo "note: parallel lanes need NON-overlapping tasks (epics/covers); a merge forces other lanes to rebase — see concurrency.md" ;;
    *) echo "usage: concurrency.sh [status|set <n>]" >&2; exit 1 ;;
esac
