#!/usr/bin/env bash
# provider-dispatch.sh <provider-id> <list-models|run> [-- <args...>] --
# looks up <provider-id> in the same TSV registry providers.sh reads
# (CDX-053, SPEC-PEER-REVIEW.md §6.12) and execs its list_models_script or
# run_script column (selected by <stage>), forwarding any args after `--`
# verbatim. Zero per-provider branching: a provider whose registry row names
# real scripts is fully dispatchable with no change to this file -- that's
# what makes a third provider a one-line registry edit.
#
# Script paths in the registry are resolved relative to the registry file's
# OWN directory (not this script's), so a test fixture registry can point at
# fixture scripts living alongside it without touching the real scripts/
# directory.
#
# If the looked-up script column is empty -- a provider registered but not
# yet backed by an implementation (e.g. "claude" as of CDX-053; its backend
# is CDX-054) -- prints a clear "<display name> backend not yet available."
# message and exits 1. Never crashes on a missing/empty script path.
#
# PEER_REVIEW_PROVIDERS_FILE overrides the registry path (see providers.sh).
set -uo pipefail

usage() {
    echo "usage: provider-dispatch.sh <provider-id> <list-models|run> [-- <args...>]" >&2
}

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY="${PEER_REVIEW_PROVIDERS_FILE:-$HERE/providers.tsv}"

PROVIDER_ID="${1:-}"
STAGE="${2:-}"
if [[ -z "$PROVIDER_ID" || -z "$STAGE" ]]; then
    usage
    exit 2
fi
case "$STAGE" in
    list-models|run) ;;
    *)
        echo "ERROR: unknown stage: $STAGE (expected list-models or run)" >&2
        usage
        exit 2
        ;;
esac
shift 2
if [[ $# -gt 0 && "$1" == "--" ]]; then
    shift
fi

if [[ ! -f "$REGISTRY" ]]; then
    echo "ERROR: provider registry not found: $REGISTRY" >&2
    exit 1
fi

REGDIR="$(cd "$(dirname "$REGISTRY")" && pwd)"

found=0
display_name=""
script=""
while IFS=$'\t' read -r id dname list_script run_script || [[ -n "$id" ]]; do
    [[ -n "$id" && "$id" != \#* ]] || continue
    if [[ "$id" == "$PROVIDER_ID" ]]; then
        found=1
        display_name="${dname:-$id}"
        if [[ "$STAGE" == "list-models" ]]; then
            script="$list_script"
        else
            script="$run_script"
        fi
        break
    fi
done <"$REGISTRY"

if [[ "$found" -ne 1 ]]; then
    echo "ERROR: unknown provider: $PROVIDER_ID" >&2
    exit 2
fi

if [[ -z "$script" ]]; then
    echo "ERROR: $display_name backend not yet available." >&2
    exit 1
fi

script_path="$REGDIR/$script"
if [[ ! -f "$script_path" ]]; then
    echo "ERROR: registered script not found for $display_name: $script_path" >&2
    exit 1
fi

exec bash "$script_path" "$@"
