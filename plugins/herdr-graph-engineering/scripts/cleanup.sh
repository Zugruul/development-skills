#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# cleanup.sh -- find lanes ready for cleanup and ask the user; clean one up after they said yes.
# Usage:
#   cleanup.sh check [--lane L] [--repo DIR]   every done lane and finished review lane (or one):
#                                              never removes anything
#   cleanup.sh run --lane L [--repo DIR]       after the user's yes is recorded (cleanup=confirmed): close the lane's tabs,
#                                              herdr worktree remove (never --force), lane.sh close
# Why a script: whether a lane may go depends on its pull request, its checkout and its graph,
# and the user must be asked exactly once per reason; that is decided here and tested.
#
# A done lane is ready when its checkout is clean and:
#   review lane (branch look/pr-N, pattern review, or a posted-review check): nothing else. A review
#     lane needs no merge and need not be done: it is also a candidate while open once it is
#     finished, that is every poster node is done or skipped, or the user said no at the human
#     node before the posts (nothing will be posted), or its findings were forwarded (forwarded
#     = LANE/AGENT, recorded with lane.sh set).
#   pull request lane (a recorded pr, a pr node, or a draft-pr check): the pull request (the
#     recorded one, else the one a pr node opened, else the one for the branch) is MERGED and the checkout has no commit beyond its head.
#   report lane (anything else): no commit that is on no other branch or remote.
# check prints per done lane: CLEANUP <lane> (<why>) when it becomes ready (records cleanup=ready,
# asks the cleanup question, notifies), PENDING <lane> when that question was already asked,
# CONFIRMED <lane> when the user said yes (cleanup=confirmed, recorded with lane.sh set),
# BLOCKED <lane> (<reason>) for a merged lane that must not be removed (asks once per reason),
# WAIT <lane> (<why>) for a pull request not merged yet, DECLINED <lane> when the user said no.
# For a ready review lane whose findings were not forwarded (nor declined), it also prints, per
# reviewed pull request that an open lane owns (review-owner.sh: any repository with lanes):
#   FORWARD <lane> <pr url> <owner repo> <owner lane> <agent|-> <node|->
# and the cleanup question asks to send the findings to that agent first.
# With the feedback loop on (feedback.sh), a ready lane also prints FEEDBACK <lane> (...) until the
# orchestrator wrote its feedback note for it, and run refuses (FEEDBACK DUE, exit 6) until then.
# run refuses (exit 6) unless the lane is done or a finished review lane, the user's yes is recorded (cleanup=confirmed) and a fresh check
# still finds the lane ready; only then does it close tabs or remove anything.
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

# With the feedback loop on, a lane closes only after the orchestrator wrote its feedback note.
feedback_due() { bash "$HERE/feedback.sh" due --lane "$1" 2>/dev/null; }

# The checkout of a branch, from git's worktree list; empty when there is none.
checkout_of() { # branch
    git -C "$repo" worktree list --porcelain | awk -v b="branch refs/heads/$1" '/^worktree / {p = substr($0, 10)} $0 == b {print p; exit}'
}

plural() { # n word
    if [ "$1" -eq 1 ]; then printf '1 %s' "$2"; else printf '%s %ss' "$1" "$2"; fi
}

# Sets KIND (review|pr|report) and PR (the pull request of a pr lane, or empty) for the lane in file $1.
lane_kind() {
    local f="$1" br pattern checks
    br="$(yq -r '.branch // ""' "$f")"
    # the recorded pull request, else the one a pr node opened (its ref is the url)
    # shellcheck disable=SC2016  # $p and $k are jq variables
    PR="$(yq -r '.pr // ([.graph | to_entries[] | select(.value.pr) | .key] as $p | [.nodes | to_entries[] | select(.key as $k | $p | contains([$k])) | .value.ref // "" | select(test("^https?://"))] | .[0]) // ""' "$f")" pattern="$(yq -r '.pattern // ""' "$f")"
    checks="$(yq -o=json '.done // []' "$f")"
    KIND="report"
    if [ -n "$PR" ] || jq -e 'index("draft-pr")' <<<"$checks" >/dev/null; then KIND="pr"; fi
    case "$br" in look/pr-*) KIND="review" ;; esac
    if [ "$pattern" = review ] || jq -e 'index("posted-review")' <<<"$checks" >/dev/null; then KIND="review"; fi
}

# Why a review lane is finished, or nothing while it is not: its findings were forwarded, the
# user said no at a human node a poster node needs, or every poster node is done or skipped.
review_finished() { # file
    # shellcheck disable=SC2016  # $g, $s, $p and $h are jq variables
    read_json "$1" | jq -r '
        .graph as $g | .nodes as $s
        | [$g | to_entries[] | select(.value.agent == "poster") | .key] as $p
        | ([$p[] | ($g[.].needs // [])[] | select($g[.].human)] | unique) as $h
        | if (.forwarded // "") != "" and .forwarded != "declined" then "its findings were forwarded to \(.forwarded)"
          elif ($p | length) > 0 and any($h[]; $s[.].status == "done" and $s[.].result == "fail") then "the user decided not to post"
          elif ($p | length) > 0 and all($p[]; $s[.].status == "done" or $s[.].status == "skipped") then
              (if all($p[]; $s[.].status == "skipped") then "the user decided not to post" else "its review was posted" end)
          else empty end'
}

# Whether cleanup looks at the lane at all: it is done, or it is a finished review lane.
candidate() { # file
    [ "$(yq -r '.status' "$1")" = "done" ] && return 0
    lane_kind "$1"
    [ "$KIND" = review ] && [ -n "$(review_finished "$1")" ]
}

# The reviewed pull requests of a review lane: its pr input and every URL in a poster's brief.
reviewed_prs() { # file
    read_json "$1" | jq -r '[(.inputs.pr // empty), (.graph[] | select(.agent == "poster") | .brief // "" | scan("https?://[^ ,]*[0-9]"))] | unique[]'
}

# Sets FORWARDS: one FORWARD line per owned reviewed pull request, unless already forwarded or declined.
forwards() { # file, lane
    local p line
    FORWARDS=""
    [ -z "$(yq -r '.forwarded // ""' "$1")" ] || return 0
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        while IFS= read -r line; do
            case "$line" in "OWNER "*) FORWARDS="$FORWARDS${FORWARDS:+
}FORWARD $2 $p ${line#OWNER }" ;; esac
        done <<OWNERS
$(cd "$repo" && bash "$HERE/review-owner.sh" --pr "$p" 2>/dev/null)
OWNERS
    done <<PRS
$(reviewed_prs "$1")
PRS
}

# Sets VERDICT (READY|BLOCKED|WAIT), WHY and WT for the lane in file $1.
judge() {
    local f="$1" br pr kind ref pj state url head n fin gch
    br="$(yq -r '.branch // ""' "$f")"
    lane_kind "$f"
    kind="$KIND" pr="$PR"
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
        # what a gate run changed there (its heartbeat), so it can be restored rather than guessed at
        gch="$(jq -r '(.changed // []) as $c | select($c | length > 0)
            | "changed by gate \(.node): \($c | map(sub("^\\s+"; "")) | join(", "))"' \
            "$(lane_dir "$repo")/gates/$(basename "$f" .yaml)"/*.json 2>/dev/null | paste -sd ';' - | sed 's/;/; /g')"
        [ -z "$gch" ] || WHY="$WHY; $gch"
        return
    fi
    case "$kind" in
        pr)
            git -C "$WT" cat-file -e "$head^{commit}" 2>/dev/null || { VERDICT=BLOCKED WHY="the pull request's head ${head:0:7} is not in the checkout; cannot tell whether everything was pushed ($WT)"; return; }
            n="$(git -C "$WT" rev-list --count HEAD "^$head")"
            [ "$n" -eq 0 ] || { VERDICT=BLOCKED WHY="$(plural "$n" commit) not in the pull request (its head is ${head:0:7}; $WT)"; return; }
            VERDICT=READY WHY="pull request $url is merged, the checkout is clean and everything is pushed" ;;
        review)
            fin="$(review_finished "$f")"
            if [ -n "$fin" ]; then VERDICT=READY WHY="review lane: $fin; the checkout is clean"
            else VERDICT=READY WHY="review lane is done, the checkout is clean"; fi ;;
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
    local f="$1" l was ws br q fw o p ol oa
    l="$(yq -r '.lane' "$f")" was="$(yq -r '.cleanup // ""' "$f")"
    candidate "$f" || return 0
    [ "$was" != declined ] || { printf 'DECLINED %s (the user kept it)\n' "$l"; return 0; }
    judge "$f"
    ws="$(yq -r '.workspace // ""' "$f")" br="$(yq -r '.branch // ""' "$f")"
    case "$VERDICT" in
        WAIT) printf 'WAIT %s (%s)\n' "$l" "$WHY" ;;
        READY)
            FORWARDS=""
            [ "$KIND" != review ] || forwards "$f" "$l"
            [ -z "$FORWARDS" ] || printf '%s\n' "$FORWARDS"
            if [ "$was" = ready ]; then printf 'PENDING %s (cleanup question asked)\n' "$l"; feedback_due "$l"; return 0; fi
            if [ "$was" = confirmed ]; then printf 'CONFIRMED %s (the user said yes; cleanup.sh run)\n' "$l"; feedback_due "$l"; return 0; fi
            fw=""
            while IFS=' ' read -r _ _ p _ ol oa _; do
                [ -n "${p:-}" ] || continue
                o="$ol/$oa"
                [ "$oa" != "-" ] || o="$ol (its agent is not running)"
                fw="$fw Send the findings of review $l on $p to $o first?"
            done <<FWD
$FORWARDS
FWD
            q="Cleanup $l: $WHY.$fw Remove the worktree $WT (workspace ${ws:-?}) and close the lane? Its tabs close; the branch $br is kept."
            lane_sh set --lane "$l" --key cleanup --value ready || exit 1
            lane_sh ask --lane "$l" --text "$q" || exit 1
            notify "$l" "$q"
            printf 'CLEANUP %s (%s)\n' "$l" "$WHY"
            feedback_due "$l" ;;
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
    candidate "$f" || die "NOT READY: lane $lane is not done (nor a finished review lane)" 6
    [ "$(yq -r '.cleanup // ""' "$f")" = confirmed ] || die "NOT CONFIRMED: lane $lane: the user has not said yes to the cleanup (cleanup is '$(yq -r '.cleanup // ""' "$f")'). Ask, then record the yes: lane.sh set --key cleanup --value confirmed" 6
    if due="$(feedback_due "$lane")"; then die "FEEDBACK DUE: $due" 6; fi
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
    lane_sh close --lane "$lane" || exit 1
    printf '%s\n' "$tabs" | grep -E '^(CLOSE|GONE) ' || true
    printf 'CLEANED %s (worktree %s removed, lane closed, branch %s kept)\n' "$lane" "$WT" "$br" ;;
esac
