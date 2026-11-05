#!/usr/bin/env bash
# Create or remove worktrees through herdr when the `herdr` config object enables it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$HERE/herdr_worktree.py" "$@"
