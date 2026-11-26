#!/usr/bin/env bash
# repo-root.sh -- sourced helper: the PRIMARY repository root.
# Local, gitignored state (.claude/ui-hub/, .claude/ITERATIVE_UI_OFF) lives once
# per repository, in the main checkout, so every linked worktree sees the same
# hub and the same flag. Resolution order:
#   1. $UI_DESIGN_REPO_ROOT (explicit override, for callers and tests);
#   2. the parent of `git rev-parse --git-common-dir` (the main checkout, even
#      when called from a linked worktree);
#   3. `git rev-parse --show-toplevel`;
#   4. the current directory.
# Paths are canonicalized (macOS /tmp is /private/tmp) so callers can compare them.

# _ui_design_canon <path> -- physical path; a path that does not exist yet is
# resolved through its deepest existing parent.
_ui_design_canon() {
    local p="$1" tail="" existing canon
    if [[ -d "$p" ]]; then
        ( cd -P "$p" && pwd -P )
        return 0
    fi
    existing="$p"
    while [[ "$existing" != "/" && -n "$existing" && ! -d "$existing" ]]; do
        tail="$(basename "$existing")${tail:+/$tail}"
        existing="$(dirname "$existing")"
    done
    if [[ -d "$existing" ]]; then
        canon="$(cd -P "$existing" && pwd -P)"
        if [[ -n "$tail" ]]; then
            printf '%s/%s\n' "${canon%/}" "$tail"
        else
            printf '%s\n' "$canon"
        fi
        return 0
    fi
    printf '%s\n' "$p"
}

ui_design_repo_root() {
    local common_dir toplevel
    if [[ -n "${UI_DESIGN_REPO_ROOT:-}" ]]; then
        _ui_design_canon "$UI_DESIGN_REPO_ROOT"
        return 0
    fi
    common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    if [[ -n "$common_dir" ]]; then
        _ui_design_canon "$(dirname "$common_dir")"
        return 0
    fi
    toplevel="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -n "$toplevel" ]]; then
        _ui_design_canon "$toplevel"
        return 0
    fi
    pwd -P
}
