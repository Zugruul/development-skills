#!/usr/bin/env bash
# Run {{PROJECT_NAME}}'s inner dev loop on minikube via Skaffold.
#   scripts/dev.sh              skaffold dev (HMR/watch loop)
#   scripts/dev.sh --release    built images, one-shot (skaffold run)
#   scripts/dev.sh --no-forward skip the port-forward supervisor
#
# CUSTOMIZE: this is a skeleton — wire in your project's actual source-sync
# strategy (bind mount / Mutagen / skaffold sync), Dockerfiles, and service
# list. The one thing every customization must keep is: every `minikube` and
# `kubectl config use-context` call below stays pinned to "$MK_PROFILE".
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

MODE="dev"; FORWARD=1
for a in "$@"; do case "$a" in
    --release) MODE="release" ;;
    --no-forward) FORWARD=0 ;;
esac; done

if ! mk_running; then
    log "minikube is not running — bringing it up via start.sh"
    "$SCRIPT_DIR/start.sh" || { err "start.sh failed — cannot bring minikube up"; exit 1; }
fi
kubectl config use-context "$MK_PROFILE" >/dev/null 2>&1 || true

# `minikube start` on an existing node is the supported heal-and-is-a-no-op path
# when the apiserver is up but degraded.
if ! kubectl get nodes >/dev/null 2>&1; then
    warn "minikube host is up but the apiserver is not responding — healing with 'minikube start'"
    minikube start -p "$MK_PROFILE" --memory="${MK_MEMORY}" --cpus="${MK_CPUS}" --driver="${MK_DRIVER}" \
        || { err "minikube start could not heal the node — try ./scripts/stop.sh && ./scripts/start.sh"; exit 1; }
fi

# Point docker at minikube's daemon so built images land straight in the
# cluster (no `minikube image load` round-trip).
log "pointing docker at minikube's daemon (eval \$(minikube docker-env -p $MK_PROFILE))"
eval "$(minikube docker-env -p "$MK_PROFILE")" || { err "minikube docker-env failed"; exit 1; }

if [ "$FORWARD" = "1" ]; then
    "$SCRIPT_DIR/port-forward.sh" &
    trap '"$SCRIPT_DIR/port-forward-stop.sh" >/dev/null 2>&1 || true' EXIT
fi

case "$MODE" in
    release)
        log "skaffold run -p $MK_PROFILE (one-shot, built images)"
        skaffold run -p "$MK_PROFILE"
        ;;
    dev)
        log "skaffold dev -p $MK_PROFILE (HMR/watch loop — Ctrl-C to stop)"
        skaffold dev -p "$MK_PROFILE"
        ;;
esac
