#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# cleanup.sh -- find lanes ready for cleanup and ask the user; clean one up after they said yes.
# Usage:
#   cleanup.sh check [--lane L] [--repo DIR]   every done lane (or one): never removes anything
#   cleanup.sh run --lane L [--repo DIR]       after the user confirmed: close the lane's tabs,
#                                              herdr worktree remove (never --force), lane.sh close
# Why a script: whether a lane may go depends on its pull request, its checkout and its graph,
# and the user must be asked exactly once per reason; that is decided here and tested.
#
# A done lane is ready when its checkout is clean and:
#   review lane (branch look/pr-N, pattern review, or a posted-review check): nothing else.
#   pull request lane (a recorded pr, a pr node, or a draft-pr check): the pull request (the
#     recorded one, else the one a pr node opened, else the one for the branch) is MERGED and the checkout has no commit beyond its head.
#   report lane (anything else): no commit that is on no other branch or remote.
# check prints per done lane: CLEANUP <lane> (<why>) when it becomes ready (records cleanup=ready,
# asks the cleanup question, notifies), PENDING <lane> when that question was already asked,
# BLOCKED <lane> (<reason>) for a merged lane that must not be removed (asks once per reason),
# WAIT <lane> (<why>) for a pull request not merged yet, DECLINED <lane> when the user said no.
# run re-checks the lane and refuses (exit 6) unless it is ready and the question was asked.
# GRAPH_GH names the gh binary (default gh), as for prs.sh.
# Prints CLEANED <lane> (...). Exit codes: 0 ok, 1 error, 2 usage, 6 not ready.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/common.sh
. "$HERE/src/common.sh"

USAGE="cleanup.sh check [--lane L] [--repo DIR] | cleanup.sh run --lane L [--repo DIR]"
cmd="${1:-}"
case "$cmd" in check | run) shift ;; *) usage "$USAGE" ;; esac
repo="$(pwd)" lane=""
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) need_value "$1" $#; repo="$2"; shift 2 ;;
        --lane) need_value "$1" $#; lane="$2"; shift 2 ;;
        *) usage "$USAGE" ;;
    esac
done
[ "$cmd" = check ] || [ -n "$lane" ] || usage "$USAGE"
require_tools jq yq git
repo="$(cd "$repo" 2>/dev/null && pwd)" || die "no such directory: $repo" 2
dir="$(lane_dir "$repo")"
GH="${GRAPH_GH:-gh}"

lane_sh() { bash "$HERE/lane.sh" "$@" --repo "$repo" >/dev/null; }

# The checkout of a branch, from git's worktree list; empty when there is none.
checkout_of() { # branch
    git -C "$repo" worktree list --porcelain | awk -v b="branch refs/heads/$1" '/^worktree / {p = substr($0, 10)} $0 == b {print p; exit}'
}

plural() { # n word
    if [ "$1" -eq 1 ]; then printf '1 %s' "$2"; else printf '%s %ss' "$1" "$2"; fi
}

# Sets VERDICT (READY|BLOCKED|WAIT), WHY and WT for the lane in file $1.
judge() {
    local f="$1" br pr pattern checks kind ref pj state url head n
    br="$(yq -r '.branch // ""' "$f")"
    # the recorded pull request, else the one a pr node opened (its ref is the url)
    # shellcheck disable=SC2016  # $p and $k are jq variables
    pr="$(yq -r '.pr // ([.graph | to_entries[] | select(.value.pr) | .key] as $p | [.nodes | to_entries[] | select(.key as $k | $p | contains([$k])) | .value.ref // "" | select(test("^https?://"))] | .[0]) // ""' "$f")" pattern="$(yq -r '.pattern // ""' "$f")"
    checks="$(yq -o=json '.done // []' "$f")"
    kind="report"
    if [ -n "$pr" ] || jq -e 'index("draft-pr")' <<<"$checks" >/dev/null; then kind="pr"; fi
    case "$br" in look/pr-*) kind="review" ;; esac
    if [ "$pattern" = review ] || jq -e 'index("posted-review")' <<<"$checks" >/dev/null; then kind="review"; fi
    WT="" head=""
    if [ "$kind" = pr ]; then
        ref="${pr:-$br}"
        [ -n "$ref" ] || { VERDICT=WAIT WHY="no pull request or branch recorded"; return; }
        command -v "$GH" >/dev/null 2>&1 || { VERDICT=WAIT WHY="gh is not installed, cannot see the pull request"; return; }
        pj="$(cd "$repo" && "$GH" pr view "$ref" --json state,url,number,headRefOid 2>/dev/null)" || { VERDICT=WAIT WHY="no pull request found for $ref"; return; }
        state="$(jq -r '.state // ""' <<<"$pj")" url="$(jq -r '.url // ""' <<<"$pj")" head="$(jq -r '.headRefOid // ""' <<<"$pj")"
        [ "$state" = MERGED ] || { VERDICT=WAIT WHY="pull request $url is $state"; return; }
    fi
    [ -n "$br" ] || { VERDICT=BLOCKED WHY="no branch recorded, cannot find the checkout"; return; }
    WT="$(checkout_of "$br")"
    [ -n "$WT" ] || { VERDICT=BLOCKED WHY="no checkout found for branch $br"; return; }
    if [ -n "$(git -C "$WT" status --porcelain 2>/dev/null)" ]; then
        VERDICT=BLOCKED WHY="the checkout has uncommitted changes ($WT)"
        return
    fi
    case "$kind" in
        pr)
            git -C "$WT" cat-file -e "$head^{commit}" 2>/dev/null || { VERDICT=BLOCKED WHY="the pull request's head ${head:0:7} is not in the checkout; cannot tell whether everything was pushed ($WT)"; return; }
            n="$(git -C "$WT" rev-list --count HEAD "^$head")"
            [ "$n" -eq 0 ] || { VERDICT=BLOCKED WHY="$(plural "$n" commit) not in the pull request (its head is ${head:0:7}; $WT)"; return; }
            VERDICT=READY WHY="pull request $url is merged, the checkout is clean and everything is pushed" ;;
        review) VERDICT=READY WHY="review lane is done, the checkout is clean" ;;
        report)
            n="$(git -C "$WT" rev-list --count HEAD --not --exclude="refs/heads/$br" --branches --remotes)"
            [ "$n" -eq 0 ] || { VERDICT=BLOCKED WHY="$(plural "$n" commit) on no other branch or remote ($WT)"; return; }
            VERDICT=READY WHY="report lane is done, the checkout is clean and nothing is unpushed" ;;
    esac
}

notify() { # lane, question
    command -v herdr >/dev/null 2>&1 || return 0
    herdr notification show "$1 needs you" --body "$2" --sound request >/dev/null 2>&1 || true
}

check_lane() { # file
    local f="$1" l status was ws br q
    l="$(yq -r '.lane' "$f")" status="$(yq -r '.status' "$f")" was="$(yq -r '.cleanup // ""' "$f")"
    [ "$status" = "done" ] || return 0
    [ "$was" != declined ] || { printf 'DECLINED %s (the user kept it)\n' "$l"; return 0; }
    judge "$f"
    ws="$(yq -r '.workspace // ""' "$f")" br="$(yq -r '.branch // ""' "$f")"
    case "$VERDICT" in
        WAIT) printf 'WAIT %s (%s)\n' "$l" "$WHY" ;;
        READY)
            if [ "$was" = ready ]; then printf 'PENDING %s (cleanup question asked)\n' "$l"; return 0; fi
            q="Cleanup $l: $WHY. Remove the worktree $WT (workspace ${ws:-?}) and close the lane? Its tabs close; the branch $br is kept."
            lane_sh set --lane "$l" --key cleanup --value ready || exit 1
            lane_sh ask --lane "$l" --text "$q" || exit 1
            notify "$l" "$q"
            printf 'CLEANUP %s (%s)\n' "$l" "$WHY" ;;
        BLOCKED)
            if [ "$was" != "blocked: $WHY" ]; then
                q="Cleanup $l is blocked: $WHY. The lane is done, but it will not be removed until this is resolved. What should happen to it?"
                lane_sh set --lane "$l" --key cleanup --value "blocked: $WHY" || exit 1
                lane_sh ask --lane "$l" --text "$q" || exit 1
                notify "$l" "$q"
            fi
            printf 'BLOCKED %s (%s)\n' "$l" "$WHY" ;;
    esac
}

case "$cmd" in
check)
    if [ -n "$lane" ]; then
        [ -f "$dir/$lane.yaml" ] || die "NO LANE: $lane" 6
        check_lane "$dir/$lane.yaml"
    else
        for f in "$dir"/*.yaml; do
            [ -f "$f" ] && check_lane "$f"
        done
    fi ;;
run)
    require_tools herdr
    f="$dir/$lane.yaml"
    [ -f "$f" ] || die "NO LANE: $lane" 6
    [ "$(yq -r '.status' "$f")" = "done" ] || die "NOT READY: lane $lane is not done" 6
    [ "$(yq -r '.cleanup // ""' "$f")" = ready ] || die "NOT ASKED: run cleanup.sh check and ask the user first (cleanup is '$(yq -r '.cleanup // ""' "$f")')" 6
    judge "$f"
    [ "$VERDICT" = READY ] || die "NOT READY: $lane: $WHY" 6
    ws="$(yq -r '.workspace // ""' "$f")" br="$(yq -r '.branch // ""' "$f")"
    [ -n "$ws" ] || die "NOT READY: lane $lane has no workspace recorded; remove its worktree by hand" 6
    tabs="$(bash "$HERE/close-done.sh" --lane "$lane" --repo "$repo")" || die "could not close the lane's tabs"
    if printf '%s\n' "$tabs" | grep -qE '^KEEP [^ ]+ \((running|blocked|agent is )'; then
        die "NOT READY: an agent of lane $lane is still active:
$(printf '%s\n' "$tabs" | grep -E '^KEEP [^ ]+ \((running|blocked|agent is )')" 6
    fi
    out="$(herdr worktree remove --workspace "$ws" 2>&1)" || die "WORKTREE NOT REMOVED: herdr worktree remove --workspace $ws failed: $out
The lane stays open; tell the user."
    lane_sh answer --lane "$lane" --text "cleanup confirmed" || exit 1
    lane_sh close --lane "$lane" || exit 1
    printf '%s\n' "$tabs" | grep -E '^(CLOSE|GONE) ' || true
    printf 'CLEANED %s (worktree %s removed, lane closed, branch %s kept)\n' "$lane" "$WT" "$br" ;;
esac
