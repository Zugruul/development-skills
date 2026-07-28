#!/usr/bin/env bash
# repo-root.sh — shared PRIMARY repo-root resolver, sourced by every shell
# script in plugins/spec-workflow/scripts/ that reads or writes .claude/
# local loop state (gate-pass, board-queue.jsonl, telemetry.jsonl,
# lessons.jsonl, merge-dance.lock, ui-hub/, identities/, CHECKPOINT, ...).
# bash 3.2-compatible; no external commands beyond git/dirname/pwd.
#
# THE PROBLEM (#463): `git rev-parse --show-toplevel` returns the CURRENT
# tree's root -- for a linked worktree, that is the worktree's own path, not
# the main checkout. All of the build loop's local state lives under
# `.claude/` in the MAIN checkout and is gitignored, so it simply does not
# exist at a worktree's own `<worktree>/.claude/`. A script that resolves
# its root this way, invoked with a worktree cwd, silently reads/writes the
# wrong (usually nonexistent) `.claude/` directory instead of failing loud.
#
# THE FIX: `git rev-parse --path-format=absolute --git-common-dir` returns
# the path to the ONE git dir shared by the main checkout and every one of
# its linked worktrees (typically ".../.git"); the main checkout is that
# path's parent directory, from anywhere in the repo (main or any worktree).
#
# CANONICALIZATION (macOS pitfall, found live by the ui-hub/design-registry
# lane): `--path-format=absolute --git-common-dir` returns the RESOLVED form
# (e.g. /private/tmp/... on macOS, where /tmp is itself a symlink), while
# `--show-toplevel` and a raw $SPEC_WORKFLOW_REPO_ROOT override return the
# UNRESOLVED form (/tmp/...). A caller that mixes a root from one code path
# with a path from the other (relpath/startswith/prefix-stripping math) gets
# garbage ("../../../../../../private/var/...") or a spurious
# FileNotFoundError. Every value this function can return — override,
# git-common-dir's parent, show-toplevel, or the final pwd fallback — is run
# through _spec_workflow_rr_canon below, so the result is ALWAYS in the same
# (physical, symlink-resolved) form no matter which branch produced it.
#
# Usage: . "$(dirname "${BASH_SOURCE[0]}")/lib/repo-root.sh"
#        root="$(spec_workflow_repo_root)" || exit 1
#
# Precedence:
#   1. $SPEC_WORKFLOW_REPO_ROOT, if set — trusted as a path (documented
#      escape hatch for tests and unusual layouts; not validated beyond
#      existing), but still canonicalized like every other branch.
#   2. `git rev-parse --path-format=absolute --git-common-dir` — the parent
#      of that path is the PRIMARY (main-checkout) root, whether invoked
#      from the main checkout or any linked worktree. This is the normal
#      case for every repo this plugin runs in.
#   3. `git rev-parse --show-toplevel` — older git without
#      --path-format=absolute support, or a git dir layout where
#      --git-common-dir fails; this is CWD's own tree root (correct for a
#      non-worktree repo; for a worktree it is a same-as-before fallback,
#      not a regression).
#   4. `pwd` — not a git repo at all.
#
# NOT for scripts that inspect or test the CURRENT tree (tree-state.sh's
# fingerprint, red-first-preflight.sh's branch/commit walk, or the actual
# code under test in gate.sh) — those must keep resolving via
# --show-toplevel (or plain git, cwd-relative) so they describe the tree
# actually being worked on, not wherever its local state happens to live.
set -uo pipefail

# _spec_workflow_rr_canon <path> -- print <path> in physical (symlink-
# resolved) form. `cd -P`/`pwd -P` requires the directory to actually
# exist, which a test fixture root or an env override is not guaranteed to
# (e.g. a caller pointing SPEC_WORKFLOW_REPO_ROOT at a path that does not
# exist yet) -- so walk up to the nearest EXISTING ancestor, canonicalize
# that, then re-append the nonexistent tail verbatim (never resolved,
# since there is nothing on disk to resolve). Falls back to the input
# unchanged only if no ancestor at all exists (shouldn't happen: "/" always
# does), so this never fails or errors out the caller.
_spec_workflow_rr_canon() {
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

spec_workflow_repo_root() {
    local override common_dir toplevel

    override="${SPEC_WORKFLOW_REPO_ROOT:-}"
    if [[ -n "$override" ]]; then
        _spec_workflow_rr_canon "$override"
        return 0
    fi

    common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    if [[ -n "$common_dir" ]]; then
        _spec_workflow_rr_canon "$(dirname "$common_dir")"
        return 0
    fi

    toplevel="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -n "$toplevel" ]]; then
        _spec_workflow_rr_canon "$toplevel"
        return 0
    fi

    pwd -P
}
