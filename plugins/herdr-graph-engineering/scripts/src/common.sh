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

# The registry of repositories lane.sh made or restored a lane in, one primary checkout per
# line, per user: ${XDG_STATE_HOME:-~/.local/state}/herdr-graph/repos. Never inside a repository.
repo_registry() {
    printf '%s/herdr-graph/repos\n' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

# A folder's repository, as "<git common dir><TAB><primary checkout>". The primary checkout
# outlives the repository's linked worktrees. Fails when the folder is in no repository.
repo_entry() { # dir
    local out common top="" root
    [ -d "$1" ] || return 1
    # inside a .git folder --show-toplevel fails, after the common dir was printed
    out="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir --show-toplevel 2>/dev/null)"
    common="${out%%$'\n'*}"
    [ "$common" = "$out" ] || top="${out#*$'\n'}"
    case "$common" in
        /*/.git) root="${common%/.git}" ;;
        /*) root="${top:-$common}" ;;
        *) return 1 ;;
    esac
    printf '%s\t%s\n' "$common" "$root"
}

# Add a repository to the registry, once. A registry that cannot be written never fails the
# caller: the lane is already recorded.
register_repo() { # repo dir
    local entry root file
    entry="$(repo_entry "$1")" || return 0
    root="${entry#*$'\t'}" file="$(repo_registry)"
    (
        mkdir -p "$(dirname "$file")" 2>/dev/null || exit 1
        lock_in "$(dirname "$file")"
        grep -qxF -- "$root" "$file" 2>/dev/null || printf '%s\n' "$root" >>"$file"
    ) || printf 'NOT REGISTERED: could not write %s; %s shows in the panel only while a Herdr pane is open in it\n' "$file" "$root" >&2
    return 0
}

# Every repository that may hold lanes, one primary checkout per line, each once. Every script
# that sweeps all lanes uses this. Sources, in this order:
#   1. the repository root Herdr records for a worktree workspace;
#   2. the folder of every pane: a plain workspace ("herdr workspace create --cwd") has no
#      .worktree, and its workspace record has no folder of its own;
#   3. the registry: a repository stays known after its workspaces close;
#   4. the current folder.
# A path that is gone or is no repository is skipped; the registry keeps it, since a drive may
# only be away for a while.
lane_repos() {
    local dirs dir entry common seen=""
    dirs="$(
        if command -v herdr >/dev/null 2>&1; then
            herdr workspace list 2>/dev/null | jq -r '.result.workspaces[]?.worktree.repo_root // empty' 2>/dev/null
            herdr pane list 2>/dev/null | jq -r '.result.panes[]? | .cwd, .foreground_cwd | strings' 2>/dev/null
        fi
        cat "$(repo_registry)" 2>/dev/null
        pwd
    )"
    # each folder once before asking git: many panes share one
    while IFS= read -r dir; do
        entry="$(repo_entry "$dir")" || continue
        common="${entry%%$'\t'*}"
        case "$seen" in *"|$common|"*) continue ;; esac
        seen="$seen|$common|"
        printf '%s\n' "${entry#*$'\t'}"
    done < <(printf '%s\n' "$dirs" | awk 'NF && !seen[$0]++')
}

# Text that looks like a credential is never written to a session or lane file.
looks_secret() { # text -> 0 when it looks like a token, key or password
    printf '%s' "$1" | grep -qiE 'gh[pousr]_[A-Za-z0-9]{16,}|github_pat_|(^|[^a-z])sk-[A-Za-z0-9_-]{16,}|xox[abprs]-|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY|bearer [A-Za-z0-9._~+/=-]{16,}|(password|passwd|secret|token|api[_-]?key)[[:space:]]*[=:][[:space:]]*[^[:space:]]+'
}
