#!/usr/bin/env bash
# merge-mode.sh — show or configure auto-merge for this project (.claude/project.json).
#   merge-mode.sh                 # or: status -> autoMerge / prReviewModel / mergeMethod / reviewerTokenEnv
#   merge-mode.sh on|off          # sets methodology.autoMerge
#   merge-mode.sh model <model>   # sets delegation.prReviewModel
#   merge-mode.sh method <squash|merge|rebase>  # sets methodology.mergeMethod
# Unlike ui-mode (local flag), auto-merge is a project-wide, versioned config
# change: merging without a human is something every clone must agree on.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CONFIG="${PROJECT_CONFIG:-$ROOT/.claude/project.json}"
[[ -f "$CONFIG" ]] || { echo "ERROR: no $CONFIG — run the setup-project skill first" >&2; exit 1; }

jset() { # jset <dot.path> <json-value>
    python3 - "$CONFIG" "$1" "$2" <<'EOF'
import json, sys
path, cfgfile, keys, val = sys.argv[2], sys.argv[1], sys.argv[2].split("."), json.loads(sys.argv[3])
cfg = json.load(open(cfgfile))
node = cfg
for k in keys[:-1]:
    node = node.setdefault(k, {})
node[keys[-1]] = val
json.dump(cfg, open(cfgfile, "w"), indent=4, ensure_ascii=False)
open(cfgfile, "a").write("\n")
EOF
}

jget() { python3 -c 'import json,sys; cfg=json.load(open(sys.argv[1]));
node=cfg
for k in sys.argv[2].split("."):
    node = node.get(k) if isinstance(node, dict) else None
print("" if node is None else node)' "$CONFIG" "$1"; }

case "${1:-status}" in
    status)
        am="$(jget methodology.autoMerge)"
        model="$(jget delegation.prReviewModel)"
        method="$(jget methodology.mergeMethod)"
        tokenenv="$(jget delegation.reviewerTokenEnv)"
        [[ "$am" == "True" ]] && echo "autoMerge: ON (agent reviews, approves, merges — no human approval)" \
                              || echo "autoMerge: OFF (a human approves and merges every PR)"
        echo "prReviewModel: ${model:-claude-sonnet-5[1m] (default)}"
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
        [[ -n "${2:-}" ]] || { echo "usage: merge-mode.sh model <model>" >&2; exit 1; }
        jset delegation.prReviewModel "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$2")"
        echo "prReviewModel: $2 (delegation.prReviewModel in $CONFIG — commit this change)" ;;
    method)
        case "${2:-}" in squash|merge|rebase) ;; *) echo "usage: merge-mode.sh method <squash|merge|rebase>" >&2; exit 1 ;; esac
        jset methodology.mergeMethod "\"$2\""
        echo "mergeMethod: $2 (methodology.mergeMethod in $CONFIG — commit this change)" ;;
    *) echo "usage: merge-mode.sh [status|on|off|model <model>|method <squash|merge|rebase>]" >&2; exit 1 ;;
esac
