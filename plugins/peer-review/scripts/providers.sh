#!/usr/bin/env bash
# providers.sh -- lists the review providers /peer-review can send a diff to
# (CDX-053, SPEC-PEER-REVIEW.md §6.12). Reads the small TSV registry
# (providers.tsv: id \t display_name \t list_models_script \t run_script)
# and emits on stdout:
#   {"providers":[{"id","display_name","available"}, ...]}
# "available" is true iff the row's run_script column is non-empty --
# a provider can be registered (so a human can see and pick it) before its
# backend exists (e.g. "claude" as of CDX-053; its actual review backend is
# CDX-054).
#
# This script has zero per-provider branching -- adding a provider is a
# one-line registry edit. See provider-dispatch.sh, which reads the same
# registry to actually invoke a provider's scripts.
#
# PEER_REVIEW_PROVIDERS_FILE overrides the registry path (tests point this
# at a fixture copy -- e.g. one with an extra row -- to prove the registry,
# not this script's logic, drives what's selectable).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY="${PEER_REVIEW_PROVIDERS_FILE:-$HERE/providers.tsv}"

if [[ ! -f "$REGISTRY" ]]; then
    echo "ERROR: provider registry not found: $REGISTRY" >&2
    exit 1
fi

python3 -c '
import json
import sys

path = sys.argv[1]
providers = []
with open(path, "r", encoding="utf-8") as f:
    for line in f:
        line = line.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = line.split("\t")
        provider_id = fields[0].strip() if len(fields) > 0 else ""
        if not provider_id:
            continue
        display_name = fields[1].strip() if len(fields) > 1 and fields[1].strip() else provider_id
        run_script = fields[3].strip() if len(fields) > 3 else ""
        providers.append({
            "id": provider_id,
            "display_name": display_name,
            "available": bool(run_script),
        })

if not providers:
    sys.exit(1)

print(json.dumps({"providers": providers}))
' "$REGISTRY"
exit $?
