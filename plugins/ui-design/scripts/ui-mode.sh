#!/usr/bin/env bash
# ui-mode.sh — show or toggle Iterative UI mode for this clone.
#   ui-mode.sh            # or: status  -> "ON" / "OFF (reason)"
#   ui-mode.sh off        # stop delegating UI decisions (touches .claude/ITERATIVE_UI_OFF)
#   ui-mode.sh on         # delegate UI decisions again (removes the flag)
# Effective rule: ON unless the local flag exists. The flag is local, gitignored
# state in the PRIMARY checkout, so every worktree of the repository agrees.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/ui-design/scripts/src/repo-root.sh
source "$HERE/src/repo-root.sh"
ROOT="$(ui_design_repo_root)" || { echo "ERROR: could not resolve repo root" >&2; exit 1; }
FLAG="$ROOT/.claude/ITERATIVE_UI_OFF"

case "${1:-status}" in
    status)
        if [[ -f "$FLAG" ]]; then echo "OFF (local flag $FLAG — 'ui-mode.sh on' re-enables)"
        else echo "ON (UI decisions are delegated to the human — 'ui-mode.sh off' disables for this clone)"
        fi ;;
    off)
        mkdir -p "$(dirname "$FLAG")"; touch "$FLAG"
        echo "Iterative UI mode: OFF for this clone (flag: $FLAG)" ;;
    on)
        rm -f "$FLAG"
        echo "Iterative UI mode: ON" ;;
    *) echo "usage: ui-mode.sh [status|on|off]" >&2; exit 1 ;;
esac
