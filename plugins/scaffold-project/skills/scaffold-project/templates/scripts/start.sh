#!/usr/bin/env bash
# Start minikube with the canonical {{PROJECT_NAME}} parameters (idempotent).
#   MK_MEMORY / MK_CPUS / MK_DRIVER override the defaults.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

mk_prune_mount_pids

if mk_running; then
    ok "minikube (profile: $MK_PROFILE) already running"
    kubectl config use-context "$MK_PROFILE" >/dev/null 2>&1 || true
    exit 0
fi

log "minikube start -p $MK_PROFILE --memory=${MK_MEMORY} --cpus=${MK_CPUS} --driver=${MK_DRIVER}"
minikube start -p "$MK_PROFILE" --memory="${MK_MEMORY}" --cpus="${MK_CPUS}" --driver="${MK_DRIVER}"
kubectl config use-context "$MK_PROFILE" >/dev/null 2>&1 || true
ok "minikube ready (profile: $MK_PROFILE): $(kubectl get nodes --no-headers 2>/dev/null | awk '{print $1, $2}')"
