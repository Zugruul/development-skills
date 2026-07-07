#!/usr/bin/env bash
# merge-mode.sh — show or configure auto-merge for this project (.claude/project.yaml).
#   merge-mode.sh                 # or: status -> autoMerge / reviewer models / mergeMethod / reviewerTokenEnv
#   merge-mode.sh on|off          # sets methodology.autoMerge
#   merge-mode.sh model <model>[,<model>...]   # sets delegation.identities.reviewer.models (allowed set)
#   merge-mode.sh method <squash|merge|rebase>  # sets methodology.mergeMethod
# Unlike ui-mode (local flag), auto-merge is a project-wide, versioned config
# change: merging without a human is something every clone must agree on.
# Reads via the shared loader (yaml or legacy json); writes back in the file's own format.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CONFIG="$(PYTHONPATH="$HERE" python3 "$HERE/config.py" "$ROOT" path)"
[[ -n "$CONFIG" && -f "$CONFIG" ]] || { echo "ERROR: no .claude/project.yaml (or legacy .json) — run the setup-project skill first" >&2; exit 1; }

# Config reads + surgical writes both go through the shared loader (config.py).
jset() { python3 "$HERE/config.py" "$ROOT" set "$1" "$2"; }  # jset <dot.path> <json-value>
jget() { python3 "$HERE/config.py" "$ROOT" get "$1"; }

case "${1:-status}" in
    status)
        am="$(jget methodology.autoMerge)"
        models="$(jget delegation.identities.reviewer.models)"
        method="$(jget methodology.mergeMethod)"
        tokenenv="$(jget delegation.reviewerTokenEnv)"
        [[ "$am" == "true" ]] && echo "autoMerge: ON (agent reviews, approves, merges — no human approval)" \
                              || echo "autoMerge: OFF (a human approves and merges every PR)"
        echo "reviewer models: ${models:-[\"claude-sonnet-5\", \"claude-sonnet-5[1m]\"] (default)}"
        echo "mergeMethod: ${method:-squash (default)}"
        if [[ -n "$tokenenv" ]]; then
            if [[ -n "${!tokenenv:-}" ]]; then echo "reviewerTokenEnv: $tokenenv (set in env — approvals appear as a distinct GitHub account)"
            else echo "reviewerTokenEnv: $tokenenv (NOT set in this env — approvals fall back to review comments)"; fi
        else
            echo "reviewerTokenEnv: unset (approvals are posted as review comments; branch protection requiring approvals will block)"
        fi ;;
    on)  jset methodology.autoMerge true;  echo "autoMerge: ON (methodology.autoMerge=true in $CONFIG — commit this change)" ;;
    off) jset methodology.autoMerge false; echo "autoMerge: OFF (methodology.autoMerge=false in $CONFIG — commit this change)" ;;
    model)
        [[ -n "${2:-}" ]] || { echo "usage: merge-mode.sh model <model>[,<model>...]" >&2; exit 1; }
        arr="$(python3 -c 'import json,sys; print(json.dumps([m.strip() for m in sys.argv[1].split(",") if m.strip()]))' "$2")"
        jset delegation.identities.reviewer.models "$arr"
        echo "reviewer models: $2 (delegation.identities.reviewer.models in $CONFIG — commit this change)" ;;
    method)
        case "${2:-}" in squash|merge|rebase) ;; *) echo "usage: merge-mode.sh method <squash|merge|rebase>" >&2; exit 1 ;; esac
        jset methodology.mergeMethod "\"$2\""
        echo "mergeMethod: $2 (methodology.mergeMethod in $CONFIG — commit this change)" ;;
    *) echo "usage: merge-mode.sh [status|on|off|model <model>[,<model>...]|method <squash|merge|rebase>]" >&2; exit 1 ;;
esac
