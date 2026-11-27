#!/usr/bin/env bash
# Kill the host port-forwards started by port-forward.sh. Safe to run even if
# nothing is forwarding (no-op).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

PID_FILE="$STATE_DIR/port-forward.pids"
[[ -f "$PID_FILE" ]] || { log "no port-forward.pids file — nothing to stop"; exit 0; }

killed=0
while read -r pid; do
    [[ -n "$pid" ]] || continue
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null && killed=$((killed + 1))
    fi
done <"$PID_FILE"
rm -f "$PID_FILE"
ok "stopped $killed port-forward(s)"
