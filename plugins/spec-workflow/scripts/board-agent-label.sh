#!/usr/bin/env bash
# board-agent-label.sh -- "who is on this card": maintain the `agent: <name>` label (#566).
# Called by board.sh: board-agent-label.sh <owner/repo> <issue#> <name>|--clear
#
# REST only (never GraphQL, never `gh project`). Budget per call: 1 GET of the
# issue's labels + 1 DELETE per stale `agent: *` label + 1 POST per set.
# The label is cosmetic: any gh failure (rate limit included) prints a warning
# and exits 0 -- never queued. Only invalid arguments exit 2.
set -uo pipefail

usage() { echo "usage: board.sh agent <issue#> <agent-name> | board.sh agent <issue#> --clear" >&2; exit 2; }
[[ $# -eq 3 ]] || usage
REPO="$1"; N="$2"; WHO="$3"
[[ "$N" =~ ^[0-9]+$ ]] || usage
[[ "$WHO" == --* && "$WHO" != "--clear" ]] && usage

_enc() { python3 -c 'import sys, urllib.parse as u; print(u.quote(sys.argv[1], safe=""))' "$1"; }

_soft_fail() { # captured-output step -> warn, exit 0
    if grep -qi "rate limit" <<<"$1"; then
        echo "agent label: GitHub rate limit hit during $2; label skipped (cosmetic, not queued)"
    else
        echo "WARN: agent label: $2 failed (label skipped): $(head -c 300 <<<"$1")"
    fi
    exit 0
}

LABEL=""
if [[ "$WHO" != "--clear" ]]; then
    slug="$(printf '%s' "$WHO" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '-' | tr -s '-')"
    [[ -n "${slug//-/}" ]] || usage
    LABEL="$(printf 'agent: %s' "$slug" | cut -c1-50)"  # GitHub label limit: 50 chars
fi

out="$(gh api "repos/$REPO/issues/$N/labels?per_page=100" --jq '.[].name' 2>&1)" || _soft_fail "$out" "label read"

present=0
while IFS= read -r name; do
    [[ "$name" == "agent: "* ]] || continue
    if [[ -n "$LABEL" && "$name" == "$LABEL" ]]; then present=1; continue; fi
    dout="$(gh api -X DELETE "repos/$REPO/issues/$N/labels/$(_enc "$name")" 2>&1)" || _soft_fail "$dout" "label remove"
    echo "removed label: $name"
done <<<"$out"

[[ -n "$LABEL" ]] || { echo "cleared agent label on #$N"; exit 0; }
[[ $present -eq 1 ]] && { echo "agent label already set on #$N: $LABEL"; exit 0; }

if ! pout="$(gh api -X POST "repos/$REPO/issues/$N/labels" -f "labels[]=$LABEL" 2>&1)"; then
    # Only a missing label (404/422) justifies creating it; a rate limit or any
    # other error soft-fails right here with no further call.
    grep -qi "rate limit" <<<"$pout" && _soft_fail "$pout" "label set"
    grep -qE "HTTP (404|422)" <<<"$pout" || _soft_fail "$pout" "label set"
    cout="$(gh api -X POST "repos/$REPO/labels" -f "name=$LABEL" -f "color=1D76DB" -f "description=Agent working on this card" 2>&1)" || {
        grep -q "already_exists" <<<"$cout" || _soft_fail "$cout" "label create"
    }
    pout="$(gh api -X POST "repos/$REPO/issues/$N/labels" -f "labels[]=$LABEL" 2>&1)" || _soft_fail "$pout" "label set"
fi
echo "agent label on #$N: $LABEL"
