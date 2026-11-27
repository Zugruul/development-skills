#!/usr/bin/env bash
# One-shot cluster bootstrap for {{PROJECT_NAME}} — installs cluster-wide
# operators/CRDs the stack depends on (ingress, cert-manager, metrics-server,
# etc.). STANDALONE: deliberately does NOT source common.sh (this may run
# before the rest of scripts/ is checked out, e.g. from a bare `curl | bash`
# bootstrap), so it carries its OWN independent MINIKUBE_PROFILE-aware
# default rather than depending on common.sh ever existing.
set -uo pipefail
MK_PROFILE="${MINIKUBE_PROFILE:-{{PROJECT_NAME}}}"

echo "▸ bootstrapping cluster-wide operators on profile '$MK_PROFILE'"
kubectl config use-context "$MK_PROFILE" >/dev/null 2>&1 || true

minikube addons enable metrics-server -p "$MK_PROFILE" >/dev/null 2>&1 || true

# CUSTOMIZE: add your project's cluster-wide installs here, e.g.:
#   helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
#       --kube-context "$MK_PROFILE" -n ingress-nginx --create-namespace

echo "✓ bootstrap done (profile: $MK_PROFILE)"
