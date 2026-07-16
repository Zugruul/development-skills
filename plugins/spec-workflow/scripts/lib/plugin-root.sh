#!/usr/bin/env bash
# plugin-root.sh — shared plugin-root resolver, sourced by every shell script
# in plugins/spec-workflow/scripts/ that needs its own plugin root.
# bash 3.2-compatible; no external commands beyond dirname/pwd/readlink.
#
# Usage: . "$(dirname "${BASH_SOURCE[0]}")/lib/plugin-root.sh"
#        root="$(spec_workflow_plugin_root)" || exit 1
#
# Precedence (SPEC-CODEX-COMPAT.md §5/§6.3/§6.4; docs/design/cdx-E0.md):
#   1. $SPEC_WORKFLOW_PLUGIN_ROOT, if set — validated; invalid -> error (never
#      silently skipped).
#   2. $CLAUDE_PLUGIN_ROOT, if set — same validation, same fail-loud behavior
#      (this is Claude Code's existing fast path; behavior stays unchanged
#      for a valid value, it is just now validated instead of blindly
#      trusted).
#   3. Script-relative discovery: starting from this file's own physical
#      on-disk location (symlinks resolved), walk up ancestor directories
#      until one contains .claude-plugin/plugin.json or
#      .codex-plugin/plugin.json (the sentinel).
#   4. No sentinel found -> actionable error on stderr, non-zero return.
# Never falls back to the current working directory at any step.
set -uo pipefail

# _spec_workflow_pr_is_valid_root <dir> -- true iff <dir> exists and directly
# contains one of the two recognized plugin-manifest sentinels.
_spec_workflow_pr_is_valid_root() {
    [[ -d "$1" ]] || return 1
    [[ -f "$1/.claude-plugin/plugin.json" || -f "$1/.codex-plugin/plugin.json" ]]
}

# _spec_workflow_pr_resolver_dir [path] -- the directory containing [path]
# (default: THIS file's own BASH_SOURCE[0]), resolved through symlinks to
# its physical path. BASH_SOURCE[0], inside a function defined in this file,
# is always this file's own path regardless of who sourced it or their CWD;
# the optional argument exists solely so tests can exercise the walk against
# a crafted path (e.g. a symlink cycle) without needing this file itself to
# sit inside one.
# The walk below dereferences one symlink hop at a time via `[[ -L ]]`
# (lstat) + `readlink` (single-hop) rather than an `open()`/`stat()` that
# transparently follows the whole chain -- so, unlike a real file open, it
# gets none of the kernel's own ELOOP protection against a genuine cycle
# (two symlinks whose targets point at each other, neither ever resolving to
# a real file). _SPEC_WORKFLOW_PR_MAX_HOPS caps it at a bound comparable to
# typical kernel ELOOP limits (Linux/macOS: ~40), so a cycle fails loud
# instead of spinning forever.
_SPEC_WORKFLOW_PR_MAX_HOPS=40
_spec_workflow_pr_resolver_dir() {
    local src link hops
    src="${1:-${BASH_SOURCE[0]}}"
    hops=0
    while [[ -L "$src" ]]; do
        hops=$((hops + 1))
        if [[ "$hops" -gt "$_SPEC_WORKFLOW_PR_MAX_HOPS" ]]; then
            echo "spec_workflow_plugin_root: symlink loop resolving '$src' (exceeded $_SPEC_WORKFLOW_PR_MAX_HOPS hops)" >&2
            return 1
        fi
        link="$(readlink "$src")"
        case "$link" in
            /*) src="$link" ;;
            *) src="$(dirname "$src")/$link" ;;
        esac
    done
    ( cd -P "$(dirname "$src")" && pwd -P )
}

spec_workflow_plugin_root() {
    local override resolver_dir dir prev

    override="${SPEC_WORKFLOW_PLUGIN_ROOT:-}"
    if [[ -n "$override" ]]; then
        if _spec_workflow_pr_is_valid_root "$override"; then
            ( cd -P "$override" && pwd -P )
            return 0
        fi
        echo "spec_workflow_plugin_root: \$SPEC_WORKFLOW_PLUGIN_ROOT='$override' is not a valid plugin root (missing .claude-plugin/plugin.json or .codex-plugin/plugin.json)" >&2
        return 1
    fi

    override="${CLAUDE_PLUGIN_ROOT:-}"
    if [[ -n "$override" ]]; then
        if _spec_workflow_pr_is_valid_root "$override"; then
            ( cd -P "$override" && pwd -P )
            return 0
        fi
        echo "spec_workflow_plugin_root: \$CLAUDE_PLUGIN_ROOT='$override' is not a valid plugin root (missing .claude-plugin/plugin.json or .codex-plugin/plugin.json)" >&2
        return 1
    fi

    resolver_dir="$(_spec_workflow_pr_resolver_dir)" || return 1
    dir="$resolver_dir"
    while :; do
        if _spec_workflow_pr_is_valid_root "$dir"; then
            printf '%s\n' "$dir"
            return 0
        fi
        prev="$dir"
        dir="$(dirname "$dir")"
        [[ "$dir" == "$prev" ]] && break
    done

    echo "spec_workflow_plugin_root: could not locate a plugin root (no .claude-plugin/plugin.json or .codex-plugin/plugin.json found above $resolver_dir); set \$SPEC_WORKFLOW_PLUGIN_ROOT or \$CLAUDE_PLUGIN_ROOT" >&2
    return 1
}
