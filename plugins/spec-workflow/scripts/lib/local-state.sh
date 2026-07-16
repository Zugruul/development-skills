#!/usr/bin/env bash
# local-state.sh — reader for scripts/local-state.manifest, the single source of
# truth for which plugin-written runtime paths are gitignored local state
# (`ignore`) vs tracked shared memory (`track`) — SPEC-MEMORY.md §7.1/§7.4/§9.2.
# bash 3.2-compatible; no associative arrays, no external commands beyond the
# manifest read.
#
# Manifest format: one "<policy>\t<path>" record per line; '#'-comment and blank
# lines ignored (see the manifest header).
#
# Sourced use:
#   . "$(dirname "${BASH_SOURCE[0]}")/lib/local-state.sh"
#   spec_workflow_local_state_paths ignore     # newline-separated ignore paths
#   spec_workflow_local_state_paths track      # newline-separated track paths
#   spec_workflow_local_state_policy .claude/CHECKPOINT   # -> "ignore" (rc 0)
#                                                         # unknown -> rc 1
#   spec_workflow_local_state_manifest         # resolved manifest path
#
# Executed directly (not sourced) it prints the paths for the policy in $1, so a
# caller with no bash context can emit the ignore list:
#   bash "$CLAUDE_PLUGIN_ROOT/scripts/lib/local-state.sh" ignore >> .gitignore
#
# $SPEC_WORKFLOW_LOCAL_STATE_MANIFEST overrides the resolved manifest path (tests).
set -uo pipefail

# spec_workflow_local_state_manifest -- resolve the manifest's path from this
# file's own on-disk location (lib/ -> scripts/), honoring an env override.
spec_workflow_local_state_manifest() {
    if [[ -n "${SPEC_WORKFLOW_LOCAL_STATE_MANIFEST:-}" ]]; then
        printf '%s\n' "$SPEC_WORKFLOW_LOCAL_STATE_MANIFEST"
        return 0
    fi
    local libdir
    libdir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || return 1
    printf '%s\n' "$(dirname "$libdir")/local-state.manifest"
}

# spec_workflow_local_state_paths <ignore|track> [manifest]
# Emit, newline-separated in manifest order, every path with the given policy.
spec_workflow_local_state_paths() {
    local want="$1" manifest="${2:-}" line policy path
    [[ -n "$manifest" ]] || manifest="$(spec_workflow_local_state_manifest)" || return 1
    [[ -f "$manifest" ]] || { echo "local-state: manifest not found: $manifest" >&2; return 1; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in ''|'#'*) continue ;; esac
        policy="${line%%$'\t'*}"
        path="${line#*$'\t'}"
        [[ "$policy" == "$want" ]] && printf '%s\n' "$path"
    done < "$manifest"
}

# spec_workflow_local_state_policy <path> [manifest]
# Print the policy for an exact-match path (rc 0), or nothing + rc 1 if absent.
spec_workflow_local_state_policy() {
    local target="$1" manifest="${2:-}" line policy path
    [[ -n "$manifest" ]] || manifest="$(spec_workflow_local_state_manifest)" || return 1
    [[ -f "$manifest" ]] || { echo "local-state: manifest not found: $manifest" >&2; return 1; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in ''|'#'*) continue ;; esac
        policy="${line%%$'\t'*}"
        path="${line#*$'\t'}"
        if [[ "$path" == "$target" ]]; then
            printf '%s\n' "$policy"
            return 0
        fi
    done < "$manifest"
    return 1
}

# Direct execution: `local-state.sh <ignore|track>` emits that policy's paths.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    spec_workflow_local_state_paths "${1:?usage: local-state.sh <ignore|track>}"
fi
