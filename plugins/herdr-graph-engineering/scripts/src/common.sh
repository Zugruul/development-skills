#!/usr/bin/env bash
# src/common.sh -- sourced by the scripts one level up; not run by itself.
# Shared helpers: errors, tool checks, the lane folder, the lock, pattern and role lookup.
# bash 3.2 (macOS), Linux and WSL. Needs jq, yq (mikefarah v4) and git.
# The variables are read by the scripts that source this file.
# shellcheck disable=SC2034

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INTERVAL="${HERDR_GRAPH_INTERVAL:-2}"

die() { # message [exit code]
    printf '%s\n' "$1" >&2
    exit "${2:-1}"
}

usage() { # usage line
    printf 'usage: %s\n' "$1" >&2
    exit 2
}

need_value() { # flag, number of arguments left
    [ "$2" -ge 2 ] || die "$1 needs a value" 2
}

require_tools() { # tool...
    local t
    for t in "$@"; do
        command -v "$t" >/dev/null 2>&1 || die "MISSING TOOL: $t is not on PATH. Install it (jq: https://jqlang.org, yq: https://github.com/mikefarah/yq)." 2
    done
}

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

slug() { # text -> lowercase kebab slug, at most 24 characters
    printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sed -e 's/[^a-z0-9][^a-z0-9]*/-/g' -e 's/^-*//' -e 's/-*$//' | cut -c1-24 | LC_ALL=C sed -e 's/-*$//'
}

# The folder that holds a repository's lane files: <git common dir>/herdr-graph.
# Shared by every worktree of the repository, never committed.
lane_dir() { # repo dir
    local common
    common="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || die "$1 is not in a git repository"
    printf '%s/herdr-graph\n' "$common"
}

lane_file() { # repo dir, lane
    printf '%s/%s.yaml\n' "$(lane_dir "$1")" "$2"
}

# A lock is a folder (mkdir is atomic everywhere) holding the owner's pid.
# A lock whose process is gone is stale and is taken over.
LOCK_DIR=""
lock() { # repo dir
    lock_in "$(lane_dir "$1")"
}

lock_in() { # folder: take the lock folder inside it
    local dir="$1" tries=0 pid
    mkdir -p "$dir"
    LOCK_DIR="$dir/.lock"
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        pid="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
        if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
            rm -rf "$LOCK_DIR"
            continue
        fi
        tries=$((tries + 1))
        [ "$tries" -lt 100 ] || die "LOCKED: $LOCK_DIR is held by process ${pid:-?}"
        sleep 0.1
    done
    printf '%s\n' "$$" >"$LOCK_DIR/pid"
    trap 'unlock' EXIT
}

unlock() {
    [ -n "$LOCK_DIR" ] && rm -rf "$LOCK_DIR"
    LOCK_DIR=""
}

# Write JSON on stdin to a YAML file atomically: temporary file, then rename.
write_yaml() { # path
    local tmp
    tmp="$(mktemp "$1.XXXXXX")" || die "could not create a temporary file next to $1"
    if yq -p=json -o=yaml -P '.' >"$tmp"; then
        mv "$tmp" "$1"
    else
        rm -f "$tmp"
        die "could not write $1"
    fi
}

read_json() { # yaml path -> JSON on stdout
    yq -o=json '.' "$1"
}

# Find a pattern or role: the repository's .herdr-graph/, then the user's
# ~/.config/herdr-graph/, then this plugin. First found wins.
#   resolve patterns|roles NAME REPO -> prints "<path>\t<repo|user|plugin>"
resolve() {
    local kind="$1" name="$2" repo="${3:-}" ext="yaml" p
    [ "$kind" = roles ] && ext="md"
    case "$name" in '' | *[!a-z0-9-]*) return 1 ;; esac
    for p in "${repo:+$repo/.herdr-graph/$kind/$name.$ext}|repo" \
        "${XDG_CONFIG_HOME:-$HOME/.config}/herdr-graph/$kind/$name.$ext|user" \
        "$PLUGIN_ROOT/$kind/$name.$ext|plugin"; do
        [ -f "${p%|*}" ] && { printf '%s\t%s\n' "${p%|*}" "${p##*|}"; return 0; }
    done
    return 1
}

# The folder of the orchestrator's session files, per user (they span repositories):
# ${XDG_STATE_HOME:-~/.local/state}/herdr-graph/sessions. Never inside a repository.
session_dir() {
    printf '%s/herdr-graph/sessions\n' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

# Text that looks like a credential is never written to a session or lane file.
looks_secret() { # text -> 0 when it looks like a token, key or password
    printf '%s' "$1" | grep -qiE 'gh[pousr]_[A-Za-z0-9]{16,}|github_pat_|(^|[^a-z])sk-[A-Za-z0-9_-]{16,}|xox[abprs]-|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY|bearer [A-Za-z0-9._~+/=-]{16,}|(password|passwd|secret|token|api[_-]?key)[[:space:]]*[=:][[:space:]]*[^[:space:]]+'
}
