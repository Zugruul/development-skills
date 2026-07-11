#!/usr/bin/env bash
# Stop minikube (keeps the cluster + built images for the next `start.sh`).
# Also stops the port-forward supervisor so it doesn't thrash a stopped
# cluster, and cleans minikube's mount-pid file so the stop is quiet.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

"$SCRIPT_DIR/port-forward-stop.sh" >/dev/null 2>&1 || true

if ! mk_running; then
    mk_prune_mount_pids
    ok "minikube (profile: $MK_PROFILE) already stopped"
    exit 0
fi
mk_prune_mount_pids
log "minikube stop -p $MK_PROFILE"
minikube stop -p "$MK_PROFILE"
ok "stopped (run start.sh to resume; images are preserved)"
