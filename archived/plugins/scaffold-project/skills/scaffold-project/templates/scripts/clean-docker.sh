#!/usr/bin/env bash
# Reclaim disk on {{PROJECT_NAME}}'s minikube node: drop dangling image layers
# + cap the build cache. Safe by default — running pods keep their images.
#   MK_CACHE_KEEP  build-cache ceiling to retain (default 10GB)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

mk_running || { warn "minikube (profile: $MK_PROFILE) is not running"; exit 0; }

eval "$(minikube docker-env -p "$MK_PROFILE")" || { err "minikube docker-env failed"; exit 1; }

keep="${MK_CACHE_KEEP:-10GB}"
log "pruning dangling images + capping build cache at $keep"
docker image prune -f >/dev/null 2>&1 || true
docker builder prune -f --max-used-space "$keep" >/dev/null 2>&1 || true
ok "reclaim done — node disk now $(minikube ssh -p "$MK_PROFILE" -- 'df -h /var 2>/dev/null | tail -1' 2>/dev/null | awk '{print $4" free, "$5" used"}')"
