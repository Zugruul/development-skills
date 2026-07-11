#!/usr/bin/env bash
# Shared config + helpers for {{PROJECT_NAME}}'s minikube scripts.
# Source this from the other scripts: `source "$(dirname "$0")/common.sh"`.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck disable=SC2034  # used by sibling scripts that source this file
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# minikube parameters — the SINGLE source of truth (override via env).
MK_MEMORY="${MK_MEMORY:-8192}"
MK_CPUS="${MK_CPUS:-4}"
MK_DRIVER="${MK_DRIVER:-docker}"
# The minikube profile every script targets EXPLICITLY (every `minikube ...`
# invocation below passes `-p "$MK_PROFILE"`) — override via MINIKUBE_PROFILE.
# Never rely on minikube's own "active profile" default: without `-p`, the CLI
# falls back to the hardcoded name "minikube", NOT whatever profile a bare
# `minikube start -p <other>` last created. Two scaffolded projects running
# side by side would otherwise silently fight over (or ignore) that shared
# default — one project's stop.sh can no-op while an unrelated stray profile
# from a DIFFERENT project keeps running. The default below is derived from
# the project name at scaffold time (kebab-case), never a fixed literal, so
# no two scaffolded projects collide on the same profile out of the box.
MK_PROFILE="${MINIKUBE_PROFILE:-{{PROJECT_NAME}}}"

# shellcheck disable=SC2034  # used by sibling scripts that source this file
NS="${PROJECT_NS:-{{PROJECT_NAME}}}"
# shellcheck disable=SC2034  # used by sibling scripts that source this file
IMAGE_TAG="${PROJECT_TAG:-dev}"

# State dir for pidfiles + logs. FIXED path (NOT $TMPDIR-derived): $TMPDIR
# differs between an interactive shell and a tool/agent shell (the harness
# overrides it), so a TMPDIR-based path means a supervisor/monitor/pidfile
# started from one shell is invisible to the other. Override with
# PROJECT_STATE_DIR.
STATE_DIR="${PROJECT_STATE_DIR:-/tmp/{{PROJECT_NAME}}}"
mkdir -p "$STATE_DIR/pf"

log()  { printf '\033[36m▸ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
err()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; }

mk_running() { minikube status -p "$MK_PROFILE" 2>/dev/null | grep -q 'host: Running'; }

# Node reachable for `minikube ssh` even when DEGRADED (e.g. InsufficientStorage
# — the node can still be SSH'd into, exactly when cleanup is most needed).
mk_node_reachable() {
    minikube status -p "$MK_PROFILE" 2>/dev/null \
        | grep -Eq 'host: (Running|InsufficientStorage)|kubelet: Running|apiserver: Running'
}

# ── minikube mount-pid hygiene ───────────────────────────────────────────────
# `minikube mount` (9p) can leave stale pids in a per-profile bookkeeping file
# after a crash. Prunes any dead entries so `minikube stop`/`delete` doesn't
# emit "stale pid" warnings. Called defensively by start.sh/stop.sh.
mk_prune_mount_pids() {
    local home file out pid
    home="${MINIKUBE_HOME:-$HOME/.minikube}"
    for file in "$home/profiles/${MK_PROFILE}/.mount-process" "$home/.mount-process"; do
        [ -f "$file" ] || continue
        out=""
        for pid in $(tr -s '[:space:]' ' ' < "$file" 2>/dev/null); do
            case "$pid" in '' | *[!0-9]*) continue ;; esac
            kill -0 "$pid" 2>/dev/null || continue
            case "$(ps -p "$pid" -o comm= 2>/dev/null)" in *minikube*) ;; *) continue ;; esac
            case "$(ps -p "$pid" -o command= 2>/dev/null)" in *' mount '*) ;; *) continue ;; esac
            out="${out} ${pid}"
        done
        if [ -n "$out" ]; then
            printf '%s' "$out" >"$file"
        else
            rm -f "$file"
        fi
    done
}

# Run a command with a hard wall-clock cap (macOS ships no `timeout`). Returns
# the command's exit code, or 137 if it had to be killed.
run_bounded() { # $1=seconds  $2..=cmd
    local secs="$1"; shift
    "$@" &
    local pid=$!
    ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) &
    local watcher=$!
    local rc=0
    wait "$pid" 2>/dev/null || rc=$?
    kill "$watcher" 2>/dev/null
    wait "$watcher" 2>/dev/null
    return "$rc"
}
