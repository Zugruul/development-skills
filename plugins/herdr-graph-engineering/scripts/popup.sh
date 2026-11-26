#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# popup.sh -- the graph plugin's popups. Herdr starts it with HERDR_PLUGIN_ENTRYPOINT_ID:
#   answer  show the lane's question; send your answer to the orchestrator chat, which relays it
#   detail  the lane's idea, branch, node chain, retries, references and recent history
#   viewer  a clicked report file or pull request, in a pager
# The lane comes from GRAPH_LANE and GRAPH_REPO, the clicked address from GRAPH_URL.
# Usage outside Herdr: popup.sh answer|detail|viewer
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/common.sh
. "$HERE/src/common.sh"

mode="${1:-${HERDR_PLUGIN_ENTRYPOINT_ID:-}}"
lane="${GRAPH_LANE:-}" repo="${GRAPH_REPO:-}"
pause() { printf '\n%s' "${1:-Press any key to close.}"; IFS= read -rsn1 _ || true; }

lane_json() {
    local f
    f="$(lane_file "$repo" "$lane")"
    [ -f "$f" ] || die "no lane $lane in $repo"
    read_json "$f"
}

case "$mode" in
answer)
    require_tools jq yq git herdr
    l="$(lane_json)"
    q="$(jq -r '.question // ""' <<<"$l")" owner="$(jq -r '.owner // ""' <<<"$l")"
    printf '\n  %s\n\n  %s\n\n' "$lane" "${q:-This lane asks nothing right now.}"
    [ -n "$q" ] || { pause; exit 0; }
    [ -n "$owner" ] || { pause "No orchestrator owns this lane; answer in its chat. Press any key."; exit 0; }
    printf '  > '
    IFS= read -r answer || answer=""
    if [ -z "$answer" ]; then
        exit 0
    fi
    if herdr agent prompt "$owner" "Answer for lane $lane, to: \"$q\" -- $answer" >/dev/null 2>&1; then
        printf '\n  Sent to %s.\n' "$owner"
        sleep 1
    else
        pause "Could not reach $owner; answer in its chat. Press any key."
    fi ;;
detail)
    require_tools jq yq git
    lane_json | jq -r '
        "\(.lane)  ·  \(.pattern)  ·  \(.status)",
        "idea    \(.idea)",
        (if .branch != "" then "branch  \(.branch)" else empty end),
        (if .gate != "" then "gate    \(.gate)" else empty end),
        "",
        (.nodes | to_entries[] | "  \(.key)  \(.value.status)\(if .value.result then " " + .value.result else "" end)\(if (.value.retries // 0) > 0 then "  retries \(.value.retries)" else "" end)\(if .value.ref then "  " + .value.ref else "" end)"),
        (if (.question // "") != "" then "", "? \(.question)" else empty end),
        "", "history", (.history[-10:][] | "  \(.)")' | ${PAGER:-less} -R
    ;;
viewer)
    url="${GRAPH_URL:-}"
    case "$url" in
        file://*) path="${url#file://}" ;;
        /*) path="$url" ;;
        *) path="" ;;
    esac
    if [ -n "$path" ] && [ -f "$path" ]; then
        ${PAGER:-less} -R "$path"
    elif printf '%s' "$url" | grep -Eq '^https://github\.com/[^/]+/[^/]+/pull/[0-9]+'; then
        gh pr view "$url" --comments 2>&1 | ${PAGER:-less} -R
    else
        pause "Nothing to show for $url. Press any key."
    fi ;;
*) usage "popup.sh answer|detail|viewer" ;;
esac
