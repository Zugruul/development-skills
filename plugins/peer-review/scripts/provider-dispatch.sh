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

# Row lookup is done in Python, not bash's `IFS=$'\t' read`: bash treats tab
# as "IFS whitespace" even when it's the sole IFS character, so adjacent
# tabs (an empty middle column, e.g. a row with an empty list_models_script
# but a populated run_script) get collapsed instead of producing an empty
# field -- silently shifting run_script's value into the list_script slot.
# \x1f (unit separator) is not IFS whitespace, so splitting the single-line
# result on it below preserves empty fields exactly.
row="$(python3 -c '
import sys

path, target = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    for line in f:
        line = line.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = line.split("\t")
        provider_id = fields[0].strip() if fields else ""
        if not provider_id or provider_id != target:
            continue
        display_name = fields[1].strip() if len(fields) > 1 and fields[1].strip() else provider_id
        list_script = fields[2].strip() if len(fields) > 2 else ""
        run_script = fields[3].strip() if len(fields) > 3 else ""
        sys.stdout.write("\x1f".join([display_name, list_script, run_script]))
        sys.exit(0)
sys.exit(1)
' "$REGISTRY" "$PROVIDER_ID")"
lookup_rc=$?

if [[ "$lookup_rc" -ne 0 ]]; then
    echo "ERROR: unknown provider: $PROVIDER_ID" >&2
    exit 2
fi

IFS=$'\x1f' read -r display_name list_script run_script <<<"$row"
if [[ "$STAGE" == "list-models" ]]; then
    script="$list_script"
else
    script="$run_script"
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
