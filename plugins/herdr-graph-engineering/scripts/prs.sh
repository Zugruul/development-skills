#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# prs.sh -- each lane's pull requests, cached for the graph panel and status.sh.
# Usage: prs.sh fetch [--repo DIR]... [--max-age S]
#   For every open lane, and every closed lane until its pull requests are final (merged or
#   closed): the pull requests of its branch, in every state, and every GitHub
#   pull request the lane mentions (its idea, question, references, history): what an
#   orchestrator report lists as an agent's pull requests. Asked of gh, written to
#   <lane folder>/prs.json: {"fetched": epoch seconds, "lanes": {lane: [{number, url, state,
#   isDraft, reviewDecision}]}}, oldest first.
#   --max-age S  leave a repository whose cache is younger than S seconds (default 0: always fetch)
# Without --repo: every repository with a workspace open in Herdr, plus the current one.
# It never fails its caller: without gh, on a failed call or while another fetch holds the
# lock, the cache stays as it was (a failed lane keeps its last known pull requests).
# GRAPH_GH names the gh binary (default gh).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/common.sh
. "$HERE/src/common.sh"

USAGE="prs.sh fetch [--repo DIR]... [--max-age S]"
[ "${1:-}" = fetch ] || usage "$USAGE"
shift
repos="" max_age=0
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) need_value "$1" $#; repos="$repos
$2"; shift 2 ;;
        --max-age) need_value "$1" $#; max_age="$2"; shift 2 ;;
        *) usage "$USAGE" ;;
    esac
done
GH="${GRAPH_GH:-gh}"
command -v "$GH" >/dev/null 2>&1 || exit 0
require_tools jq yq git

if [ -z "$repos" ]; then
    command -v herdr >/dev/null 2>&1 &&
        repos="$(herdr workspace list 2>/dev/null | jq -r '.result.workspaces[]?.worktree.repo_root // empty' 2>/dev/null)"
    here_root="$(git rev-parse --show-toplevel 2>/dev/null)" && repos="$repos
$here_root"
fi

FIELDS="number,url,state,isDraft,reviewDecision"
PR_URL='https://github\.com/[^/ "]+/[^/ "]+/pull/[0-9]+'

fetch_repo() { # repo dir
    local r="$1" d cache lock now fetched old new f json lane branch list ok url one
    d="$(lane_dir "$r" 2>/dev/null)" || return 0
    [ -d "$d" ] || return 0
    cache="$d/prs.json" lock="$d/prs.lock"
    now="$(date +%s)"
    if [ "$max_age" -gt 0 ] && [ -f "$cache" ]; then
        fetched="$(jq -r '.fetched // 0' "$cache" 2>/dev/null)" || fetched=0
        [ $((now - ${fetched:-0})) -ge "$max_age" ] || return 0
    fi
    # One fetch per repository at a time; a lock left by a fetch that died is taken after 5 minutes.
    if ! mkdir "$lock" 2>/dev/null; then
        [ -n "$(find "$lock" -maxdepth 0 -mmin +5 2>/dev/null)" ] || return 0
        rm -rf "$lock" && mkdir "$lock" 2>/dev/null || return 0
    fi
    old="$(cat "$cache" 2>/dev/null)"
    jq -e '.lanes' >/dev/null 2>&1 <<<"$old" || old='{"lanes":{}}'
    new="$old"
    for f in "$d"/*.yaml "$d"/closed/*.yaml; do
        [ -f "$f" ] || continue
        json="$(read_json "$f")" || continue
        lane="$(jq -r '.lane' <<<"$json")"
        # a closed lane whose known pull requests are all final is not asked again
        if [ "$(jq -r '.status // ""' <<<"$json")" = closed ] &&
            jq -e --arg l "$lane" '.lanes | has($l) and all(.[$l][]; .state == "MERGED" or .state == "CLOSED")' >/dev/null 2>&1 <<<"$new"; then
            continue
        fi
        lane="$(jq -r '.lane' <<<"$json")" branch="$(jq -r '.branch // ""' <<<"$json")"
        list="[]" ok=1
        if [ -n "$branch" ]; then
            list="$(cd "$r" && "$GH" pr list --head "$branch" --state all --json "$FIELDS" --limit 20 2>/dev/null)" || { list="[]" ok=0; }
        fi
        while IFS= read -r url; do
            [ -n "$url" ] || continue
            jq -e --arg u "$url" 'any(.[]; .url == $u)' >/dev/null 2>&1 <<<"$list" && continue
            if one="$(cd "$r" && "$GH" pr view "$url" --json "$FIELDS" 2>/dev/null)"; then
                list="$(jq -c --argjson p "$one" '. + [$p]' <<<"$list")" || ok=0
            else
                ok=0
            fi
        done < <(grep -oE "$PR_URL" <<<"$json" | sort -u)
        [ "$ok" -eq 1 ] || continue
        new="$(jq -c --arg l "$lane" --argjson p "$list" '.lanes[$l] = ($p | unique_by(.url) | sort_by(.number))' <<<"$new")" || new="$old"
    done
    new="$(jq -c --argjson t "$now" '.fetched = $t' <<<"$new")" &&
        printf '%s\n' "$new" >"$cache.tmp" && mv "$cache.tmp" "$cache"
    rmdir "$lock" 2>/dev/null
    return 0
}

seen=""
while IFS= read -r r; do
    [ -n "$r" ] || continue
    case "$seen" in *"|$r|"*) continue ;; esac
    seen="$seen|$r|"
    fetch_repo "$r"
done <<EOF
$repos
EOF
exit 0
