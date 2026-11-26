#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# popup.sh -- the graph plugin's popups. Herdr starts it with HERDR_PLUGIN_ENTRYPOINT_ID:
#   answer  show the lane's question; send your answer to the orchestrator chat, which relays it
#   detail  the lane's idea, branch, node chain, retries, references and recent history
#   viewer  a clicked report file or pull request, in a pager
# The lane comes from GRAPH_LANE and GRAPH_REPO, the clicked address from GRAPH_URL.
# Styled like the panel (src/style.sh): bold lane names and headings, red questions, grey
# secondary text; no colour when NO_COLOR is set.
# Usage outside Herdr: popup.sh answer|detail|viewer
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/common.sh
. "$HERE/src/common.sh"
# shellcheck source=src/style.sh
. "$HERE/src/style.sh"

mode="${1:-${HERDR_PLUGIN_ENTRYPOINT_ID:-}}"
lane="${GRAPH_LANE:-}" repo="${GRAPH_REPO:-}"
pause() { printf '\n%s%s%s' "$S_GREY" "${1:-Press any key to close.}" "$S_FG"; IFS= read -rsn1 _ || true; }

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
    if [ -n "$q" ]; then
        printf '\n  %s%s%s\n\n  %s? %s%s\n\n' "$S_BOLD" "$lane" "$S_UNBOLD" "$S_RED" "$q" "$S_FG"
    else
        printf '\n  %s%s%s\n\n  %sThis lane asks nothing right now.%s\n\n' "$S_BOLD" "$lane" "$S_UNBOLD" "$S_GREY" "$S_FG"
    fi
    [ -n "$q" ] || { pause; exit 0; }
    [ -n "$owner" ] || { pause "No orchestrator owns this lane; answer in its chat. Press any key."; exit 0; }
    printf '  > '
    IFS= read -r answer || answer=""
    if [ -z "$answer" ]; then
        exit 0
    fi
    if herdr agent prompt "$owner" "Answer for lane $lane, to: \"$q\" -- $answer" >/dev/null 2>&1; then
        printf '\n  %sSent to %s.%s\n' "$S_GREY" "$owner" "$S_FG"
        sleep 1
    else
        pause "Could not reach $owner; answer in its chat. Press any key."
    fi ;;
detail)
    require_tools jq yq git
    # shellcheck disable=SC2016
    lane_json | jq -r --argjson c "$(style_json)" "$STYLE_JQ_MARK"'
        def field($k): "\($c.grey)\($k)\($c.fg)";
        "\($c.bold)\(.lane)\($c.unbold)\($c.grey) · \(.pattern) · \(.status)\($c.fg)",
        "\(field("idea"))    \(.idea)",
        (if (.branch // "") != "" then "\(field("branch"))  \(.branch)" else empty end),
        (if (.gate // "") != "" then "\(field("gate"))    \(.gate)" else empty end),
        "",
        (.nodes | to_entries[] | .key as $n | .value
         | "  \($n) \(markcolour)\(mark)\($c.fg)\($c.grey)  \(.status)\(if .result then " " + .result else "" end)\(if (.retries // 0) > 0 then "  retries \(.retries)" else "" end)\(if .ref then "  " + .ref else "" end)\($c.fg)"),
        (if (.question // "") != "" then "", "\($c.red)? \(.question)\($c.fg)" else empty end),
        "", "\($c.bold)history\($c.unbold)", (.history[-10:][] | "  \($c.grey)\(.)\($c.fg)")' | ${PAGER:-less} -R
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
