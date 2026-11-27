#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# review-owner.sh -- who owns a reviewed pull request: the open lane whose branch is the pull
# request's head branch, in any repository with lanes, and that lane's implementer agent.
# Usage: review-owner.sh --pr URL [--repo DIR]...
# Without --repo: every repository that may hold lanes (lane_repos in src/common.sh).
# --repo adds to that list.
# Prints one line per owning lane:
#   OWNER <repo> <lane> <agent|-> <node|->
#     node: the lane's implementer node (its first agent node with write access);
#     agent: the agent recorded on that node when Herdr shows it live, else -
#   NONE <url> (head <branch>)        no open lane works on that branch
#   UNKNOWN <url> (<reason>)          the pull request could not be read (exit 1)
# Why a script: closing a review lane offers to forward its findings to this owner; the lookup
# must not be left to judgement. GRAPH_GH names the gh binary (default gh).
# Exit codes: 0 ok (OWNER or NONE), 1 pull request unreadable, 2 usage.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/common.sh
. "$HERE/src/common.sh"

USAGE="review-owner.sh --pr URL [--repo DIR]..."
url="" repos=""
while [ $# -gt 0 ]; do
    case "$1" in
        --pr) need_value "$1" $#; url="$2"; shift 2 ;;
        --repo) need_value "$1" $#; repos="$repos
$2"; shift 2 ;;
        *) usage "$USAGE" ;;
    esac
done
[ -n "$url" ] || usage "$USAGE"
require_tools jq yq git
GH="${GRAPH_GH:-gh}"

command -v "$GH" >/dev/null 2>&1 || { printf 'UNKNOWN %s (gh is not installed)\n' "$url"; exit 1; }
pj="$("$GH" pr view "$url" --json number,url,headRefName 2>/dev/null)" || { printf 'UNKNOWN %s (gh could not read the pull request)\n' "$url"; exit 1; }
head="$(jq -r '.headRefName // ""' <<<"$pj" 2>/dev/null)"
[ -n "$head" ] || { printf 'UNKNOWN %s (no head branch in the answer)\n' "$url"; exit 1; }

live="[]"
if command -v herdr >/dev/null 2>&1; then
    live="$(herdr agent list 2>/dev/null | jq -c '[.result.agents[]?.name // empty]' 2>/dev/null)" || live="[]"
    [ -n "$live" ] || live="[]"
fi
repos="$repos
$(lane_repos)"

found=0 seen=""
while IFS= read -r r; do
    [ -n "$r" ] || continue
    d="$(lane_dir "$r" 2>/dev/null)" || continue
    case "$seen" in *"|$d|"*) continue ;; esac
    seen="$seen|$d|"
    for f in "$d"/*.yaml; do
        [ -f "$f" ] || continue
        # shellcheck disable=SC2016  # $h, $live and $n are jq variables
        line="$(read_json "$f" | jq -r --arg h "$head" --argjson live "$live" '
            select(.status != "closed" and (.branch // "") == $h)
            | ([.graph | to_entries[] | select(.value.agent and .value.access == "write") | .key][0] // "") as $n
            | ((.nodes[$n].agent // "") as $a | if $a != "" and ($live | index($a)) then $a else "-" end) as $agent
            | "\(.lane) \($agent) \(if $n == "" then "-" else $n end)"')" || continue
        [ -n "$line" ] || continue
        printf 'OWNER %s %s\n' "$r" "$line"
        found=1
    done
done <<EOF
$repos
EOF
[ "$found" -eq 1 ] || printf 'NONE %s (head %s)\n' "$url" "$head"
exit 0
