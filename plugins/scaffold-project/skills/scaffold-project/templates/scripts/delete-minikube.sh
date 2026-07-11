#!/usr/bin/env bash
# Full teardown of {{PROJECT_NAME}}'s minikube profile (deletes the cluster
# and all its images — start.sh recreates from scratch). Use stop.sh instead
# for a routine pause that preserves state.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

"$SCRIPT_DIR/port-forward-stop.sh" >/dev/null 2>&1 || true
log "minikube delete -p $MK_PROFILE"
minikube delete -p "$MK_PROFILE"
ok "profile '$MK_PROFILE' deleted"
