#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# cleanup.sh -- close finished lanes, ask about the rest, and remove a worktree only on the user's word.
# Usage:
#   cleanup.sh run --afk --lane L [--session S]  remove without asking, only when the AFK scope ticked
#                                              worktree removal and all nine checks hold (afk_run below); recorded
#                                              as a decision (decide.sh), never as the user's yes; else AFK WAIT
#   cleanup.sh facts --lane L [--repo DIR]     what removing it takes and keeps, ignored files named (the preview
#                                              of its question); reads only
#   cleanup.sh reopen --lane L [--repo DIR]    take back a recorded no (cleanup=declined)
#   cleanup.sh check [--lane L] [--repo DIR] [--session S]   every done lane and finished review lane
#                                              (or one): closes the finished ones (auto_close below),
#                                              never removes a worktree. With neither --lane nor
#                                              --repo: every repository that may hold lanes
#                                              (lane_repos), a REPO <dir> line before each one's
#   cleanup.sh run --lane L [--repo DIR]       after the user's yes is recorded (cleanup=confirmed): close the lane's tabs,
#                                              herdr worktree remove (never --force), lane.sh close
#   cleanup.sh remove --lane L [--lose-ignored] [--repo DIR]   a CLOSED lane's worktree, when the
#                                              user asks (the panel's [x] on CLOSED runs it): never
#                                              --force, never a dirty one, a main checkout, or one an
#                                              agent or an open lane uses; ignored files that are not
#                                              build output only with --lose-ignored (the user's yes).
#                                              Prints REMOVED, or NO WORKTREE (nothing to remove)
# A lane closes by itself (unless session.sh set --key autoclose --value off) when its recorded pull
# request is MERGED and every node is done or skipped, or it is a finished review lane with nothing
# left to forward. Unmet extra done criteria do not hold it: they stay listed as open. It records a
# restore note (checkout, each agent's resume command), closes the lane's workspace so its agents
# leave Herdr, keeps worktree and branch, closes the lane: AUTOCLOSED <lane> (...). The workspace
# stays when it is not the lane's alone. It waits, AUTOCLOSE-WAIT <lane> (<why>), while an agent is
# working or blocked, a question is open, the feedback is due (FEEDBACK) or Herdr refuses. Never for
# a lane the user kept or restored, one they confirmed for removal, or one AFK removes.
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
# A merged pull request on the lane's branch that is not its recorded one is only a lane note,
# SIDE-MERGE <lane> (...). An unfinished lane whose own pull request merged gets MERGED-EARLY <lane>: its own question (keep
# working, finish, or dismiss the entry), asked once per pull request, never a cleanup. A question
# that no longer holds (the verdict is WAIT, or what it showed changed) is withdrawn: WITHDRAWN <lane>.
# Only the recorded pull request counts; with none, the branch's when it is newer than the lane.
# A yes covers only what was shown (cleanup_offer: pull request, head, checkout): else run refuses.
# Ignored files are deleted with a worktree: those outside build folders (src/lost.sh) are named.
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
# shellcheck source=src/merged.sh
. "$HERE/src/merged.sh"
# shellcheck source=src/lost.sh
. "$HERE/src/lost.sh"
# shellcheck source=src/afk.sh
. "$HERE/src/afk.sh"

USAGE="cleanup.sh check [--lane L] [--repo DIR] [--session S] | cleanup.sh run [--afk [--session S]]|facts|reopen|remove [--lose-ignored] --lane L [--repo DIR]"
cmd="${1:-}"
case "$cmd" in check | run | facts | reopen | remove) shift ;; *) usage "$USAGE" ;; esac
repo="" lane="" afk=0 session="" lose=0
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) need_value "$1" $#; repo="$2"; shift 2 ;;
        --lane) need_value "$1" $#; lane="$2"; shift 2 ;;
        --afk) afk=1; shift ;;
        --lose-ignored) lose=1; shift ;;
        --session) need_value "$1" $#; session="$2"; shift 2 ;;
        *) usage "$USAGE" ;;
    esac
done
[ "$cmd" = check ] || [ -n "$lane" ] || usage "$USAGE"
require_tools jq yq git
sweep=0
[ "$cmd" != check ] || [ -n "$repo" ] || [ -n "$lane" ] || sweep=1
[ -n "$repo" ] || repo="$(pwd)"
repo="$(cd "$repo" 2>/dev/null && pwd)" || die "no such directory: $repo" 2
dir=""
[ "$sweep" -eq 1 ] || dir="$(lane_dir "$repo")"
GH="${GRAPH_GH:-gh}"

lane_sh() { bash "$HERE/lane.sh" "$@" --repo "$repo" >/dev/null; }

# With the feedback loop on, a lane closes only after the orchestrator wrote its feedback note.
feedback_due() { bash "$HERE/feedback.sh" due --lane "$1" ${2:+--session "$2"} 2>/dev/null; }

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

is_adopted() { [ "$(yq -r '.adopted // false' "$1")" = true ]; }

# Sets VERDICT (READY|BLOCKED|WAIT), WHY and WT for the lane in file $1.
judge() {
    local f="$1" br pr kind ref pj state url head n fin gch made created
    PRURL="" PRHEAD="" CODE=""
    br="$(yq -r '.branch // ""' "$f")"
    lane_kind "$f"
    kind="$KIND" pr="$PR"
    WT="" head=""
    # an adopted lane's checkout was never the graph's: only the record is ever closed
    if is_adopted "$f"; then
        WT="$(checkout_of "$br")"
        VERDICT=READY WHY="adopted lane: only its record is closed, and its checkout is left as it is"
        return
    fi
    if [ "$kind" = pr ]; then
        ref="${pr:-$br}"
        [ -n "$ref" ] || { VERDICT=WAIT WHY="no pull request or branch recorded"; return; }
        command -v "$GH" >/dev/null 2>&1 || { VERDICT=WAIT WHY="gh is not installed, cannot see the pull request"; return; }
        pj="$(pr_view "$ref")" || { VERDICT=WAIT WHY="no pull request found for $ref"; return; }
        state="$(jq -r '.state // ""' <<<"$pj")" url="$(jq -r '.url // ""' <<<"$pj")" head="$(jq -r '.headRefOid // ""' <<<"$pj")"
        PRURL="$url" PRHEAD="$head"
        if [ -z "$pr" ]; then
            made="$(jq -r '.createdAt // ""' <<<"$pj")" created="$(yq -r '.created // ""' "$f")"
            [ -z "$made" ] || [[ ! "$made" < "$created" ]] ||
                { VERDICT=WAIT WHY="the pull request $url for branch $br is older than the lane; record the right one with lane.sh set --key pr"; return; }
        fi
        ! dismissed "$f" "$url" || { VERDICT=WAIT WHY="pull request $url was dismissed for this lane"; return; }
        [ "$state" = MERGED ] || { VERDICT=WAIT WHY="pull request $url is $state"; return; }
    fi
    [ -n "$br" ] || { VERDICT=BLOCKED CODE=no-branch WHY="no branch recorded, cannot find the checkout"; return; }
    WT="$(checkout_of "$br")"
    [ -n "$WT" ] || { VERDICT=BLOCKED CODE=no-checkout WHY="no checkout found for branch $br"; return; }
    if [ -n "$(git -C "$WT" status --porcelain 2>/dev/null)" ]; then
        VERDICT=BLOCKED CODE=dirty WHY="the checkout has uncommitted changes ($WT)"
        # what a gate run changed there (its heartbeat), so it can be restored rather than guessed at
        gch="$(jq -r '(.changed // []) as $c | select($c | length > 0)
            | "changed by gate \(.node): \($c | map(sub("^\\s+"; "")) | join(", "))"' \
            "$(lane_dir "$repo")/gates/$(basename "$f" .yaml)"/*.json 2>/dev/null | paste -sd ';' - | sed 's/;/; /g')"
        [ -z "$gch" ] || WHY="$WHY; $gch"
        return
    fi
    case "$kind" in
        pr)
            git -C "$WT" cat-file -e "$head^{commit}" 2>/dev/null || { VERDICT=BLOCKED CODE=head-missing WHY="the pull request's head ${head:0:7} is not in the checkout; cannot tell whether everything was pushed ($WT)"; return; }
            n="$(git -C "$WT" rev-list --count HEAD "^$head")"
            [ "$n" -eq 0 ] || { VERDICT=BLOCKED CODE=unpushed WHY="$(plural "$n" commit) not in the pull request (its head is ${head:0:7}; $WT)"; return; }
            VERDICT=READY WHY="pull request $url is merged, the checkout is clean and everything is pushed" ;;
        review)
            fin="$(review_finished "$f")"
            if [ -n "$fin" ]; then VERDICT=READY WHY="review lane: $fin; the checkout is clean"
            else VERDICT=READY WHY="review lane is done, the checkout is clean"; fi ;;
        report)
            n="$(git -C "$WT" rev-list --count HEAD --not --exclude="refs/heads/$br" --branches --remotes)"
            [ "$n" -eq 0 ] || { VERDICT=BLOCKED CODE=unpushed WHY="$(plural "$n" commit) on no other branch or remote ($WT)"; return; }
            VERDICT=READY WHY="report lane is done, the checkout is clean and nothing is unpushed" ;;
    esac
}

notify() { # lane, question
    command -v herdr >/dev/null 2>&1 || return 0
    herdr notification show "$1 needs you" --body "$2" --sound request >/dev/null 2>&1 || true
}

pr_view() { # reference
    (cd "$repo" && "$GH" pr view "$1" --json state,url,number,headRefOid,headRefName,createdAt 2>/dev/null)
}

dismissed() { # file, pull request url
    read_json "$1" | jq -e --arg u "$2" "$MERGED_JQ"' dismissed_urls | index($u) != null' >/dev/null
}

# Whether an open question of this kind is waiting.
asking() { # file, kind
    read_json "$1" | jq -e --arg k "$2" 'any((.questions // [])[]; .answer == null and
        (.kind == $k or ($k == "cleanup" and .kind == null and (.text | startswith("Cleanup ")))))' >/dev/null
}

# What no longer holds goes: the cleanup question and its state. Node states stay as they are.
withdraw() { # file, lane
    local was
    was="$(yq -r '.cleanup // ""' "$1")"
    case "$was" in
        ready | confirmed | "blocked: "* | afk-approved*) ;;
        *) asking "$1" cleanup || return 0 ;;
    esac
    ! asking "$1" cleanup || lane_sh withdraw --lane "$2" --kind cleanup || exit 1
    lane_sh set --lane "$2" --key cleanup --value "" || exit 1
    printf 'WITHDRAWN %s (the cleanup question no longer holds)\n' "$2"
}

withdraw_early() { # file, lane
    ! asking "$1" merged-early || { lane_sh withdraw --lane "$2" --kind merged-early && printf 'WITHDRAWN %s (merged early no longer holds)\n' "$2"; }
}

# Notes, once each, the merged pull requests on the lane's branch that are not its recorded one.
side_merges() { # file, lane
    local url br
    br="$(yq -r '.branch // ""' "$1")"
    while IFS= read -r url; do
        [ -n "$url" ] || continue
        lane_sh note --lane "$2" --ref "$url" --text "side pull request $url merged on branch $br; it is not the lane's recorded pull request" || exit 1
        printf 'SIDE-MERGE %s (%s merged; not the recorded pull request, noted only)\n' "$2" "$url"
    done < <(read_json "$1" | jq -r --argjson p "$(jq -c --arg l "$2" '.lanes[$l] // []' "$dir/prs.json" 2>/dev/null || echo '[]')" --arg own "$PR" "$MERGED_JQ"'
        . as $l | [(.notes // [])[].ref // empty] as $noted | dismissed_urls as $gone
        | $p[] | select(.state == "MERGED" and (.headRefName // "") == ($l.branch // "") and ($l.branch // "") != ""
            and ((.createdAt // "") == "" or .createdAt >= ($l.created // "")))
        | .url | select(. != $own and (. as $u | ($noted + $gone) | index($u) == null))')
}

# Whether the lane is finished so that it closes by itself; sets AUTOWHY and judge's VERDICT, WHY, WT.
# BLOCKED still counts: what is left in the worktree stays there, and the note names it.
finished() { # file, lane
    local fin
    case "$(yq -r '.status' "$1")" in open | done) ;; *) return 1 ;; esac
    lane_kind "$1"
    if [ "$KIND" = review ]; then
        fin="$(review_finished "$1")"
        [ -n "$fin" ] || [ "$(yq -r '.status' "$1")" = "done" ] || return 1
        # findings an open lane owns are offered to it first: that is the user's call
        forwards "$1" "$2"
        [ -z "$FORWARDS" ] || return 1
        judge "$1"
        AUTOWHY="finished review${fin:+: $fin}"
    else
        [ -n "$PR" ] || return 1
        read_json "$1" | jq -e '(.nodes | length) > 0 and all(.nodes[]; .status == "done" or .status == "skipped")' >/dev/null || return 1
        judge "$1"
        if is_adopted "$1"; then
            ! dismissed "$1" "$PR" && [ "$(pr_view "$PR" | jq -r '.state // ""')" = MERGED ] || return 1
            PRURL="$PR"
        fi
        AUTOWHY="pull request $PRURL is merged and every node is done"
    fi
    [ "$VERDICT" != WAIT ]
}

# AFK with worktree removal in its scope removes a merged lane itself (afk_run), so it stays open for it.
afk_removes() { # file, lane, session
    [ "$KIND" = pr ] && ! is_adopted "$1" &&
        afk_json "$3" | jq -e --arg l "$2" '.state == "on" and .cleanup == true and ((.lanes | length) == 0 or (.lanes | index($l)) != null)' >/dev/null
}

# Forget a wait that no longer applies.
drop_wait() { # file, lane
    case "$(yq -r '.cleanup // ""' "$1")" in feedback-due | "auto-wait: "*) lane_sh set --lane "$2" --key cleanup --value "" || exit 1 ;; esac
}

# The lane stays open for now, with no question of its own: the next check tries again.
auto_wait() { # file, lane, cleanup value, why
    if asking "$1" cleanup || asking "$1" merged-early; then
        withdraw "$1" "$2" >/dev/null
        withdraw_early "$1" "$2" >/dev/null
    fi
    [ "$(yq -r '.cleanup // ""' "$1")" = "$3" ] || lane_sh set --lane "$2" --key cleanup --value "$3" || exit 1
    printf 'AUTOCLOSE-WAIT %s (%s)\n' "$2" "$4"
}

lane_agents() { # file -> the agents its nodes record
    read_json "$1" | jq -r '[.nodes[].agent // empty | select(. != "")] | unique[]'
}

# A lane's agent, or one in its workspace or checkout, that is working or blocked.
active_agent() { # file, Herdr's agent list
    read_json "$1" | jq -r --argjson l "$2" --arg wt "$WT" '
        [.nodes[].agent // empty] as $mine | (.workspace // "") as $ws
        | $l.result.agents[] | (.name // .pane_id // "?") as $n | (.agent_status // "") as $s
        | select(($s == "working" or $s == "blocked") and (($mine | index($n)) != null or ($ws != "" and .workspace_id == $ws)
            or ($wt != "" and ([.cwd, .foreground_cwd] | any(strings; . == $wt or startswith($wt + "/"))))))
        | "agent \($n) is \($s)"' | head -1
}

is_linked() { # checkout
    [ -n "$1" ] && [ "$(git -C "$1" rev-parse --path-format=absolute --git-dir)" != "$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)" ]
}

# Why the lane's workspace must stay open, or nothing: only a workspace that is the lane's alone closes.
workspace_keep() { # file, lane, workspace, Herdr's agent list
    local f other
    ! is_adopted "$1" || { echo "adopted lane: the graph did not create it"; return 0; }
    [ -n "$3" ] || { echo "no workspace is recorded"; return 0; }
    [ "$3" != "${HERDR_WORKSPACE_ID:-}" ] || { echo "it is the caller's own workspace"; return 0; }
    for f in "$(session_dir)"/*.yaml; do
        [ -f "$f" ] || continue
        case "$(yq -r '.pane // ""' "$f")" in "$3":*) echo "an orchestrator's pane is in it"; return 0 ;; esac
    done
    is_linked "$WT" || { echo "the lane has no linked worktree of its own"; return 0; }
    for other in "$dir"/*.yaml; do
        [ "$other" != "$1" ] && [ -f "$other" ] || continue
        [ "$(yq -r '.workspace // ""' "$other")" != "$3" ] || { echo "lane $(basename "$other" .yaml) uses it"; return 0; }
    done
    read_json "$1" | jq -r --argjson l "$4" --arg ws "$3" '[.nodes[].agent // empty] as $mine
        | $l.result.agents[] | select(.workspace_id == $ws) | (.name // .pane_id // "?") as $n
        | select(($mine | index($n)) == null) | "agent \($n), not one of this lane, is in it"' | head -1
}

# What brings the lane back: its checkout and, per agent, its session (live, or kept when its tab
# closed) with the command that resumes it in its client.
restore_json() { # file
    local a s kept='[]'
    while IFS= read -r a; do
        [ -n "$a" ] || continue
        s="$(herdr agent get "$a" 2>/dev/null | jq -c '.result.agent | select(.agent_session != null)
            | .agent_session + {agent: (.agent // .agent_session.agent)}' 2>/dev/null)"
        [ -n "$s" ] || s="$(read_json "$1" | jq -c --arg a "$a" '[.nodes[] | select(.agent == $a) | .session // empty][-1] // {}')"
        kept="$(jq -c --arg n "$a" --argjson s "$s" '. + [{name: $n, kind: ($s.agent // ""), session_kind: ($s.kind // ""), session_id: ($s.value // "")}]' <<<"$kept")"
    done < <(lane_agents "$1")
    jq -c --arg path "$WT" --arg ws "$(yq -r '.workspace // ""' "$1")" --arg br "$(yq -r '.branch // ""' "$1")" '
        # an id that is not a plain word never goes into a command the user pastes
        def resume: if .session_kind != "id" or (.session_id | test("^[A-Za-z0-9][A-Za-z0-9._-]*$") | not) then ""
            elif .kind == "claude" then "claude --resume \(.session_id)"
            elif .kind == "codex" then "codex resume \(.session_id)"
            elif .kind == "opencode" then "opencode --session \(.session_id)" else "" end;
        {workspace_path: $path, workspace: $ws, branch: $br,
         agents: map(resume as $r | . + {resume: $r, command: (if $r == "" then ""
             elif $path == "" then $r
             else "cd \($path | if test("^[A-Za-z0-9_./-]+$") then . else @sh end) && \($r)" end)})}' <<<"$kept"
}

# Closes a finished lane by itself. Returns 1 when this lane is not one to close: check goes on.
auto_close() { # file, lane
    local f="$1" l="$2" sn list why ws keep note restore out open_extra
    case "$(yq -r '.cleanup // ""' "$f")" in declined | confirmed) return 1 ;; esac
    [ "$(yq -r '.restored // false' "$f")" != true ] || return 1
    sn="$(lane_session "$session" "$(yq -r '.owner // ""' "$f")")"
    if ! autoclose_on "$sn" || ! finished "$f" "$l" || afk_removes "$f" "$l" "$sn"; then
        drop_wait "$f" "$l"
        return 1
    fi
    if read_json "$f" | jq -e 'any((.questions // [])[]; .answer == null and .kind != "cleanup" and .kind != "merged-early"
            and (.kind != null or (.text | startswith("Cleanup ") | not)))' >/dev/null; then
        auto_wait "$f" "$l" "auto-wait: an open question waits for the user" "an open question waits for the user"
        return 0
    fi
    list="$(herdr agent list 2>/dev/null)" || list=""
    if ! jq -e '.result.agents | type == "array"' >/dev/null 2>&1 <<<"$list"; then
        auto_wait "$f" "$l" "auto-wait: herdr does not say which agents are live" "herdr does not say which agents are live"
        return 0
    fi
    why=""
    is_adopted "$f" || why="$(active_agent "$f" "$list")"
    [ -z "$why" ] || { auto_wait "$f" "$l" "auto-wait: $why" "$why"; return 0; }
    if why="$(feedback_due "$l" "$sn")"; then
        printf '%s\n' "$why"
        auto_wait "$f" "$l" feedback-due "the feedback is due"
        return 0
    fi
    ws="$(yq -r '.workspace // ""' "$f")"
    restore="$(restore_json "$f")" || die "could not make the restore note of lane $l"
    keep="$(workspace_keep "$f" "$l" "$ws" "$list")"
    if [ -z "$keep" ]; then
        if ! out="$(herdr workspace close "$ws" 2>&1)"; then
            case "$out" in
                *workspace_not_found*) ;;
                *) auto_wait "$f" "$l" "auto-wait: herdr workspace close $ws failed" "herdr workspace close $ws failed: $out"; return 0 ;;
            esac
        fi
    fi
    withdraw "$f" "$l" >/dev/null
    withdraw_early "$f" "$l" >/dev/null
    drop_wait "$f" "$l"
    restore="$(jq -c --arg k "$keep" '. + {workspace_closed: ($k == "")} + (if $k != "" then {workspace_kept: $k} else {} end)' <<<"$restore")"
    lane_sh restore-note --lane "$l" --value "$restore" || exit 1
    note="closed by itself: $AUTOWHY.${WT:+ The worktree $WT and the branch are kept.}"
    [ "$VERDICT" != BLOCKED ] || note="$note Left in the worktree: $WHY."
    open_extra="$(read_json "$f" | jq -r '[(.done_extra // [])[] | select(.met != true) | .text] | join("; ")')"
    [ -z "$open_extra" ] || note="$note open done criteria: $open_extra"
    lane_sh note --lane "$l" --text "$note" || echo "NOT NOTED: tell the user: $note" >&2
    lane_sh close --lane "$l" || exit 1
    # a workspace that stays still loses the lane's finished tabs
    if [ -n "$keep" ] && ! is_adopted "$f"; then bash "$HERE/close-done.sh" --lane "$l" --repo "$repo" >/dev/null 2>&1 || true; fi
    herdr notification show "$l closed" --body "$note" >/dev/null 2>&1 || true
    printf 'AUTOCLOSED %s (%s%s%s%s)\n' "$l" "$AUTOWHY" "${WT:+; worktree $WT kept}" "${keep:+; workspace kept: $keep}" "${open_extra:+; open: $open_extra}"
}

# A closed lane's worktree, on the user's word. The branch is always kept.
remove_closed() { # lane
    local f="$dir/closed/$1.yaml" br other why wsid out
    [ -f "$f" ] && [ ! -f "$dir/$1.yaml" ] || die "NOT CLOSED: $1; only a closed lane's worktree is removed this way (an open one: cleanup.sh run)" 6
    ! is_adopted "$f" || { printf 'NO WORKTREE %s (adopted lane: its checkout is left as it is)\n' "$1"; return 0; }
    br="$(yq -r '.branch // ""' "$f")" WT=""
    [ -z "$br" ] || WT="$(checkout_of "$br")"
    [ -n "$WT" ] && [ -d "$WT" ] || { printf 'NO WORKTREE %s (no checkout of its branch is left)\n' "$1"; return 0; }
    is_linked "$WT" || { printf 'NO WORKTREE %s (%s is a main checkout, never removed)\n' "$1" "$WT"; return 0; }
    for other in "$dir"/*.yaml; do
        [ -f "$other" ] || continue
        [ "$(yq -r '.branch // ""' "$other")" != "$br" ] || die "NOT REMOVED: $1: lane $(basename "$other" .yaml) uses the branch $br" 6
    done
    [ -z "$(git -C "$WT" status --porcelain)" ] || die "NOT REMOVED: $1: the checkout has uncommitted changes ($WT)" 6
    why="$(busy_agents "$f" "$WT")"
    [ -z "$why" ] || die "NOT REMOVED: $1: $why" 6
    ignored_split "$WT"
    [ -z "$LOST" ] || [ "$lose" -eq 1 ] || die "NOT REMOVED: $1: ignored files would be deleted: $LOST. Ask the user, then cleanup.sh remove --lane $1 --lose-ignored" 6
    # a workspace still open on the checkout goes with it, through herdr
    wsid="$(herdr workspace list 2>/dev/null | jq -r --arg w "$WT" '[.result.workspaces[]? | select(.worktree.checkout_path == $w) | .workspace_id][0] // empty' 2>/dev/null)"
    if [ -n "$wsid" ]; then
        out="$(herdr worktree remove --workspace "$wsid" 2>&1)" || die "NOT REMOVED: $1: herdr worktree remove --workspace $wsid failed: $out" 1
    else
        out="$(git -C "$repo" worktree remove "$WT" 2>&1)" || die "NOT REMOVED: $1: git worktree remove $WT failed: $out" 1
    fi
    printf 'REMOVED %s (worktree %s removed, branch %s kept)\n' "$1" "$WT" "$br"
}

# A lane that is not up for cleanup but whose own pull request merged: its own question, never
# "cleanup". Only a recorded pull request, or the cache's by the branch rule, then a fresh look.
early_check() { # file, lane
    local f="$1" l="$2" url pj q unfinished
    withdraw "$f" "$l"
    if [ "$(yq -r '.status' "$f")" != open ] || [ "$(yq -r '.cleanup // ""' "$f")" = declined ]; then return 0; fi
    lane_kind "$f"
    url="$PR"
    side_merges "$f" "$l"
    if [ -z "$url" ] || dismissed "$f" "$url"; then withdraw_early "$f" "$l"; return 0; fi
    command -v "$GH" >/dev/null 2>&1 || return 0
    pj="$(pr_view "$url")" || return 0
    [ "$(jq -r '.state // ""' <<<"$pj")" = MERGED ] || { withdraw_early "$f" "$l"; return 0; }
    url="$(jq -r '.url // ""' <<<"$pj")"
    [ "$(yq -r '.merged_early // ""' "$f")" != "$url" ] || return 0
    unfinished="$(read_json "$f" | jq -r '[.nodes | to_entries[] | select(.value.status != "done" and .value.status != "skipped") | .key] | join(", ")')"
    q="Merged early: pull request $url of lane $l merged, but the lane is unfinished (${unfinished:-its done checks}). Should I keep working, finish the lane, or dismiss this entry (it is not this lane's pull request)?"
    lane_sh ask --lane "$l" --kind merged-early --text "$q" || exit 1
    lane_sh set --lane "$l" --key merged_early --value "$url" || exit 1
    notify "$l" "$q"
    printf 'MERGED-EARLY %s (%s merged; unfinished: %s)\n' "$l" "$url" "${unfinished:-done checks}"
}

# Whether what the user was shown still holds: the same pull request, head and checkout.
offer_holds() { # file (after judge)
    local head="$PRHEAD"
    [ -n "$head" ] || head="$(git -C "$WT" rev-parse HEAD 2>/dev/null)"
    OFFER_HEAD="$head"
    read_json "$1" | jq -e --arg pr "$PRURL" --arg h "$head" --arg p "$WT" \
        '(.cleanup_offer // null) as $o | $o == null or ($o.pr == $pr and $o.head == $h and $o.path == $p)' >/dev/null
}

check_lane() { # file
    local f="$1" l was ws br q fw o p ol oa code lost
    l="$(yq -r '.lane' "$f")"
    ! auto_close "$f" "$l" || return 0
    candidate "$f" || { early_check "$f" "$l"; return 0; }
    was="$(yq -r '.cleanup // ""' "$f")"
    [ "$was" != declined ] || { printf 'DECLINED %s (the user kept it)\n' "$l"; return 0; }
    withdraw_early "$f" "$l"
    judge "$f"
    ws="$(yq -r '.workspace // ""' "$f")" br="$(yq -r '.branch // ""' "$f")"
    case "$VERDICT" in
        WAIT) withdraw "$f" "$l"; printf 'WAIT %s (%s)\n' "$l" "$WHY" ;;
        READY)
            FORWARDS=""
            [ "$KIND" != review ] || forwards "$f" "$l"
            [ -z "$FORWARDS" ] || printf '%s\n' "$FORWARDS"
            case "$was" in
                ready | confirmed) offer_holds "$f" || { withdraw "$f" "$l"; was=""; } ;;
            esac
            if [ "$was" = ready ]; then printf 'PENDING %s (cleanup question asked)\n' "$l"; feedback_due "$l"; return 0; fi
            if [ "$was" = confirmed ]; then printf 'CONFIRMED %s (the user said yes; cleanup.sh run)\n' "$l"; feedback_due "$l"; return 0; fi
            withdraw "$f" "$l"
            fw=""
            while IFS=' ' read -r _ _ p _ ol oa _; do
                [ -n "${p:-}" ] || continue
                o="$ol/$oa"
                [ "$oa" != "-" ] || o="$ol (its agent is not running)"
                fw="$fw Send the findings of review $l on $p to $o first?"
            done <<FWD
$FORWARDS
FWD
            ignored_split "$WT"
            lost="${LOST:+ It also deletes ignored files that are not build output: $LOST.}"
            q="Cleanup $l: $WHY.$fw Remove the worktree $WT (workspace ${ws:-?}) and close the lane? Its tabs close; the branch $br is kept.$lost"
            if is_adopted "$f"; then
                q="Cleanup $l: $WHY.$fw Close the lane?"
            else
                offer_holds "$f" || true
                lane_sh offer --lane "$l" --ref "$PRURL" --head "$OFFER_HEAD" --path "$WT" || exit 1
            fi
            lane_sh set --lane "$l" --key cleanup --value ready || exit 1
            lane_sh ask --lane "$l" --kind cleanup --text "$q" || exit 1
            notify "$l" "$q"
            printf 'CLEANUP %s (%s)\n' "$l" "$WHY"
            feedback_due "$l" ;;
        BLOCKED)
            # the kind of reason and the head, not the counts and names that only change
            code="$CODE $PRHEAD"
            case "$was" in "blocked: "*) o="$(yq -r '.cleanup_code // ""' "$f")" ;; *) o="" ;; esac
            if [ "$o" != "$code" ]; then
                withdraw "$f" "$l"
                q="Cleanup $l is blocked: $WHY. The lane is done, but it will not be removed until this is resolved. What should happen to it?"
                lane_sh set --lane "$l" --key cleanup --value "blocked: $WHY" || exit 1
                lane_sh set --lane "$l" --key cleanup_code --value "$code" || exit 1
                lane_sh ask --lane "$l" --kind cleanup --text "$q" || exit 1
                notify "$l" "$q"
            elif [ "$was" != "blocked: $WHY" ]; then
                lane_sh set --lane "$l" --key cleanup --value "blocked: $WHY" || exit 1
            fi
            printf 'BLOCKED %s (%s)\n' "$l" "$WHY" ;;
    esac
}

# Close the lane's tabs and remove its worktree, never with --force. Sets tabs, ws and br.
remove_worktree() { # file, lane
    local out
    ws="$(yq -r '.workspace // ""' "$1")" br="$(yq -r '.branch // ""' "$1")"
    [ -n "$ws" ] || die "NOT READY: lane $2 has no workspace recorded; remove its worktree by hand" 6
    tabs="$(bash "$HERE/close-done.sh" --lane "$2" --repo "$repo")" || die "could not close the lane's tabs"
    if printf '%s\n' "$tabs" | grep -qE '^KEEP [^ ]+ \((running|blocked|agent is )'; then
        die "NOT READY: an agent of lane $2 is still active:
$(printf '%s\n' "$tabs" | grep -E '^KEEP [^ ]+ \((running|blocked|agent is )')" 6
    fi
    out="$(herdr worktree remove --workspace "$ws" 2>&1)" || die "WORKTREE NOT REMOVED: herdr worktree remove --workspace $ws failed: $out
The lane stays open; tell the user."
}

afk_wait() { die "AFK WAIT $lane: $1" 6; }

# The agents Herdr shows in the checkout, or of this lane, that rule out a removal: any that is
# working or blocked, and any in the folder that the lane does not record.
busy_agents() { # file, checkout
    local list
    list="$(herdr agent list 2>/dev/null)" || list=""
    jq -e '.result.agents | type == "array"' >/dev/null 2>&1 <<<"$list" || { echo "herdr does not say which agents are live"; return 0; }
    read_json "$1" | jq -r --argjson l "$list" --arg wt "$2" '
        [.nodes[].agent // empty] as $mine
        | $l.result.agents[] | (.name // .pane_id // "?") as $n | (.agent_status // "unknown") as $s
        | ([.cwd, .foreground_cwd] | map(strings | select(. == $wt or startswith($wt + "/"))) | length > 0) as $in
        | ($mine | index($n) != null) as $own
        | if ($in or $own) and ($s == "working" or $s == "blocked") then "agent \($n) is \($s)"
          elif $in and ($own | not) then "agent \($n), not one of this lane, uses the folder"
          else empty end' | head -1
}

# An AFK removal: allowed only when every one of these nine holds; one failure and the lane waits.
afk_run() { # file, lane
    local f="$1" l="$2" session_name afk why other o id
    [ -f "$f" ] || die "NO LANE: $l" 6
    session_name="${session:-$(default_session)}"
    # 1. AFK is on, with worktree removal in its scope, for this lane
    afk="$(afk_json "$session_name")"
    [ "$(jq -r .state <<<"$afk")" = on ] || afk_wait "AFK is off"
    [ "$(jq -r .cleanup <<<"$afk")" = true ] || afk_wait "worktree removal is not in the AFK scope"
    jq -e --arg l "$l" '(.lanes | length) == 0 or (.lanes | index($l)) != null' >/dev/null <<<"$afk" || afk_wait "the lane is not in the AFK scope"
    # never alone: kept, blocked, dismissed or merged-early lanes, review and report lanes
    [ "$(yq -r '.cleanup // ""' "$f")" != declined ] || afk_wait "the user kept this lane"
    case "$(yq -r '.cleanup // ""' "$f")" in "blocked: "*) afk_wait "its cleanup is blocked" ;; esac
    [ "$(yq -r '.dismissed // [] | length' "$f")" -eq 0 ] || afk_wait "it has a dismissed entry"
    ! asking "$f" merged-early || afk_wait "it was merged early"
    ! is_adopted "$f" || afk_wait "it is an adopted lane"
    # 2. done: every node done or skipped, and every extra done criterion met
    read_json "$f" | jq -e '.status == "done" and all(.nodes[]; .status == "done" or .status == "skipped") and all((.done_extra // [])[]; .met == true)' >/dev/null ||
        afk_wait "the lane is not done (every node, and every extra done criterion)"
    # 3. a recorded pull request, which gh says is merged, from the lane's branch
    lane_kind "$f"
    [ "$KIND" = pr ] || afk_wait "only a pull request lane is removed alone (this is a $KIND lane)"
    [ -n "$PR" ] || afk_wait "no pull request is recorded"
    # 4. clean: no changed or untracked file, no commit beyond the pull request's head
    judge "$f"
    [ "$VERDICT" = READY ] || afk_wait "$WHY"
    [ "$(pr_view "$PRURL" | jq -r '.headRefName // ""')" = "$(yq -r '.branch // ""' "$f")" ] ||
        afk_wait "the pull request's head branch is not the lane's branch"
    # 5. no ignored file that is not build output
    ignored_split "$WT"
    [ -z "$LOST" ] || afk_wait "ignored files would be deleted: $LOST"
    # 6. no busy agent in it, no other agent or lane using the folder
    why="$(busy_agents "$f" "$WT")"
    [ -z "$why" ] || afk_wait "$why"
    for other in "$dir"/*.yaml; do
        [ "$other" != "$f" ] && [ -f "$other" ] || continue
        o="$(read_json "$other" | jq -r --arg b "$(yq -r '.branch // ""' "$f")" --arg w "$(yq -r '.workspace // ""' "$f")" \
            'select(.branch == $b or (.workspace // "") == $w) | .lane')"
        [ -z "$o" ] || afk_wait "lane $o uses the same branch or workspace"
    done
    # 7. no other open question, and the feedback collected when the loop is on
    read_json "$f" | jq -e '(if has("questions") then [.questions[] | select(.answer == null and .kind != "cleanup")] | length == 0
        else (.question // "") == "" or (.question | startswith("Cleanup ")) end)' >/dev/null || afk_wait "it has another open question"
    if why="$(feedback_due "$l")"; then afk_wait "$why"; fi
    # 8. a linked worktree made for this lane: not a main checkout or clone, not adopted
    [ "$(git -C "$WT" rev-parse --path-format=absolute --git-dir)" != "$(git -C "$WT" rev-parse --path-format=absolute --git-common-dir)" ] ||
        afk_wait "$WT is a main checkout, not a linked worktree"
    # 9. herdr worktree remove without --force; the branch is kept
    withdraw "$f" "$l" >/dev/null
    remove_worktree "$f" "$l"
    id="$(bash "$HERE/decide.sh" add --by cleanup --session "$session_name" --class cleanup-remove --lane "$l" --repo "$repo" \
        --what "removed the worktree $WT of merged lane $l" --why "all nine AFK removal checks held" --source "$PRURL merged; AFK scope ticked worktree removal" \
        --reversible partly --undo "git worktree add $WT $br, then lane.sh restore --lane $l (agent tabs, chats and ignored build output do not come back)" | awk '/^DECIDED / {print $2}')"
    [ -n "$id" ] || echo "NOT RECORDED: tell the user lane $l was removed under AFK" >&2
    lane_sh set --lane "$l" --key cleanup --value "afk-approved: ${id:-?}" || exit 1
    lane_sh close --lane "$l" || exit 1
    printf '%s\n' "$tabs" | grep -E '^(CLOSE|GONE) ' || true
    printf 'CLEANED %s under AFK (decision %s; worktree %s removed, lane closed, branch %s kept)\n' "$l" "${id:-?}" "$WT" "$br"
}

check_all() { # every lane of the repository in $repo, its lane folder in $dir
    local f
    for f in "$dir"/*.yaml; do
        [ -f "$f" ] && check_lane "$f"
    done
    return 0
}

# What a cleanup question is about, for its preview: what goes and what stays.
facts() { # file, lane
    judge "$1"
    printf 'lane %s: %s (%s)\n' "$2" "$VERDICT" "$WHY"
    [ -z "$PRURL" ] || printf 'pull request: %s\n' "$PRURL"
    [ -n "$WT" ] || WT="$(checkout_of "$(yq -r '.branch // ""' "$1")")"
    printf 'worktree: %s\n' "${WT:-none found}"
    printf 'branch %s is kept\n' "$(yq -r '.branch // "?"' "$1")"
    ignored_split "$WT"
    printf 'ignored files LOST: %s\n' "${LOST:-nothing}"
    printf 'ignored files safe to lose: %s\n' "${SAFE:-none}"
    printf 'tabs:\n'
    bash "$HERE/close-done.sh" --lane "$2" --repo "$repo" --dry-run 2>/dev/null | sed 's/^/  /' || true
}

case "$cmd" in
check)
    if [ "$sweep" -eq 1 ]; then
        rc=0
        while IFS= read -r repo; do
            [ -n "$repo" ] || continue
            dir="$(lane_dir "$repo" 2>/dev/null)" || continue
            out="$(check_all)" || rc=1
            [ -z "$out" ] || printf 'REPO %s\n%s\n' "$repo" "$out"
        done <<REPOS
$(lane_repos)
REPOS
        exit "$rc"
    elif [ -n "$lane" ]; then
        [ -f "$dir/$lane.yaml" ] || die "NO LANE: $lane" 6
        check_lane "$dir/$lane.yaml"
    else
        check_all
    fi ;;
remove)
    require_tools herdr
    remove_closed "$lane" ;;
facts)
    [ -f "$dir/$lane.yaml" ] || die "NO LANE: $lane" 6
    facts "$dir/$lane.yaml" "$lane" ;;
reopen)
    f="$dir/$lane.yaml"
    [ -f "$f" ] || die "NO LANE: $lane" 6
    [ "$(yq -r '.cleanup // ""' "$f")" = declined ] || die "NOT KEPT: lane $lane was not declined" 6
    lane_sh set --lane "$lane" --key cleanup --value "" || exit 1
    printf 'REOPENED %s (cleanup.sh check asks again)\n' "$lane" ;;
run)
    [ "$afk" -eq 0 ] || { require_tools herdr; afk_run "$dir/$lane.yaml" "$lane"; exit 0; }
    require_tools herdr
    f="$dir/$lane.yaml"
    [ -f "$f" ] || [ ! -f "$dir/closed/$lane.yaml" ] || die "ALREADY CLOSED: $lane; its worktree goes with cleanup.sh remove --lane $lane" 6
    [ -f "$f" ] || die "NO LANE: $lane" 6
    candidate "$f" || die "NOT READY: lane $lane is not done (nor a finished review lane)" 6
    [ "$(yq -r '.cleanup // ""' "$f")" = confirmed ] || die "NOT CONFIRMED: lane $lane: the user has not said yes to the cleanup (cleanup is '$(yq -r '.cleanup // ""' "$f")'). Ask, then record the yes: lane.sh set --key cleanup --value confirmed" 6
    if due="$(feedback_due "$lane")"; then die "FEEDBACK DUE: $due" 6; fi
    judge "$f"
    [ "$VERDICT" = READY ] || die "NOT READY: $lane: $WHY" 6
    if is_adopted "$f"; then
        lane_sh close --lane "$lane" || exit 1
        printf 'CLEANED %s (adopted lane: its record is closed; the checkout and its agent are left as they are)\n' "$lane"
        exit 0
    fi
    offer_holds "$f" || { withdraw "$f" "$lane" >/dev/null; die "NOT READY: lane $lane changed since the user was asked (pull request, head or checkout); run cleanup.sh check and ask again" 6; }
    remove_worktree "$f" "$lane"
    lane_sh close --lane "$lane" || exit 1
    printf '%s\n' "$tabs" | grep -E '^(CLOSE|GONE) ' || true
    printf 'CLEANED %s (worktree %s removed, lane closed, branch %s kept)\n' "$lane" "$WT" "$br" ;;
esac
