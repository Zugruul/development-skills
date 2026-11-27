#!/usr/bin/env bash
# Host port-forwards for {{PROJECT_NAME}}. Skips services that don't exist yet.
# Blocks (foreground) — Ctrl+C, or scripts/port-forward-stop.sh from another
# shell, both clean up (each forward's PID is recorded below).
#
# CUSTOMIZE: fill in PORT_FORWARDS with your project's actual services, e.g.
#   PORT_FORWARDS=("svc/api 8080:8080" "svc/web 3000:3000")
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# PORT_FORWARDS=()   # example — replace with your project's services

PID_FILE="$STATE_DIR/port-forward.pids"
: >"$PID_FILE"
cleanup() { scripts_dir="$(cd "$(dirname "$0")" && pwd)"; bash "$scripts_dir/port-forward-stop.sh" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

log "port-forwards (ns=$NS, profile=$MK_PROFILE):"
for spec in "${PORT_FORWARDS[@]}"; do
    # shellcheck disable=SC2086  # deliberate word-split: spec is "<target> <ports>"
    set -- $spec
    target="$1" ports="$2"
    if ! kubectl -n "$NS" get "${target%%/*}" "${target##*/}" >/dev/null 2>&1; then
        warn "skip $target (not deployed yet)"
        continue
    fi
    kubectl -n "$NS" port-forward "$target" "$ports" >/dev/null 2>&1 &
    pid=$!
    echo "$pid" >>"$PID_FILE"
    ok "$target -> $ports (pid $pid)"
done

wait
