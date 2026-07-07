#!/usr/bin/env bash
# ui-mode.sh — show or toggle Iterative UI mode for this clone.
#   ui-mode.sh            # or: status  -> "ON" / "OFF (reason)"
#   ui-mode.sh off        # stop delegating UI decisions (touches .claude/ITERATIVE_UI_OFF)
#   ui-mode.sh on         # delegate UI decisions again (removes the flag)
# Effective rule: ON unless the local flag exists OR project.yaml sets
# methodology.iterativeUI=false (the config is the project-wide kill switch).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONPATH="$HERE${PYTHONPATH:+:$PYTHONPATH}"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
FLAG="$ROOT/.claude/ITERATIVE_UI_OFF"
CONFIG="$(python3 "$HERE/config.py" "$ROOT" path)"

cfg_off() { [[ -n "$CONFIG" && -f "$CONFIG" ]] && python3 -c 'import sys; import config as C; sys.exit(0 if (C.load_config(path=sys.argv[1], warn=False) or {}).get("methodology",{}).get("iterativeUI") is False else 1)' "$CONFIG" 2>/dev/null; }

case "${1:-status}" in
    status)
        if cfg_off; then echo "OFF (methodology.iterativeUI=false in the project config — project-wide)"
        elif [[ -f "$FLAG" ]]; then echo "OFF (local flag $FLAG — 'ui-mode.sh on' re-enables)"
        else echo "ON (UI decisions are delegated to the human — 'ui-mode.sh off' disables for this clone)"
        fi ;;
    off)
        mkdir -p "$(dirname "$FLAG")"; touch "$FLAG"
        echo "Iterative UI mode: OFF for this clone (flag: $FLAG)" ;;
    on)
        rm -f "$FLAG"
        if cfg_off; then echo "flag removed, but still OFF: methodology.iterativeUI=false in the project config"
        else echo "Iterative UI mode: ON"; fi ;;
    *) echo "usage: ui-mode.sh [status|on|off]" >&2; exit 1 ;;
esac
