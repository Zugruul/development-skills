#!/usr/bin/env bash
# Build {{PROJECT_NAME}}'s service images straight into minikube's docker
# daemon (no registry push, no `minikube image load`).
#   scripts/build.sh <service> [<service> ...]   build just these
#   scripts/build.sh                             build everything in SERVICES
#
# CUSTOMIZE: fill in SERVICES and each service's Dockerfile/build-args below.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# SERVICES=(api worker web)   # example — replace with your project's services

eval "$(minikube docker-env -p "$MK_PROFILE")" || { err "minikube docker-env failed"; exit 1; }

targets=("$@")
if [ ${#targets[@]} -eq 0 ]; then
    targets=("${SERVICES[@]}")
fi

for svc in "${targets[@]}"; do
    log "building $svc"
    docker build -t "{{PROJECT_NAME}}/$svc:${IMAGE_TAG}" -f "$svc/Dockerfile" "$REPO_ROOT" \
        || { err "build failed: $svc"; exit 1; }
    ok "built {{PROJECT_NAME}}/$svc:${IMAGE_TAG}"
done
