#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# merge.sh -- merge a lane's pull request while auto-merge is on for it, after its gate and its
# reviews passed on that very commit. The only way the orchestrator ever merges.
# Usage:
#   merge.sh check --lane L [--repo DIR] [--session S]                       would it merge now?
#   merge.sh run   --lane L [--repo DIR] [--session S] [--method squash|merge|rebase]
# Why a script: a merge cannot be unsent, so every condition is checked here, from the lane file,
# the checkout and a fresh gh answer, and the merge is pinned to the checked commit:
#   auto-merge is on for the lane (session.sh automerge; off by default); the pull request is
#   recorded (lane.sh set --key pr, or a pr node); not a review lane; no open question; every
#   node done with a pass, or skipped (a gate or a review is never skipped), with at least one
#   gate; each gate and review passed on the pull request's head; a {human:} done check is met
#   (the lane is done); the pull request is open, from the lane's branch, at the checkout's head,
#   the checkout clean; no changes requested or review required; no conflict; every CI check
#   passed.
# A draft is marked ready first, since GitHub merges no draft. Never --admin, --auto or
# --delete-branch; never approves; never pushes. The merge is recorded for the user like any AFK
# decision (decide.sh), whether or not AFK is on.
# Exit codes: 0 ok, 1 error (gh refused), 2 usage, 6 not mergeable.
# shellcheck disable=SC2016
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/common.sh
. "$HERE/src/common.sh"
# shellcheck source=src/afk.sh
. "$HERE/src/afk.sh"

USAGE="merge.sh check|run --lane L [--repo DIR] [--session S] [--method squash|merge|rebase]"
cmd="${1:-}"
case "$cmd" in check | run) shift ;; *) usage "$USAGE" ;; esac
repo="$(pwd)" lane="" session="" method=squash
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) need_value "$1" $#; repo="$2"; shift 2 ;;
        --lane) need_value "$1" $#; lane="$2"; shift 2 ;;
        --session) need_value "$1" $#; session="$2"; shift 2 ;;
        --method) need_value "$1" $#; method="$2"; shift 2 ;;
        *) usage "$USAGE" ;;
    esac
done
[ -n "$lane" ] || usage "$USAGE"
case "$method" in squash | merge | rebase) ;; *) die "--method must be squash, merge or rebase" 2 ;; esac
require_tools jq yq git
GH="${GRAPH_GH:-gh}"
command -v "$GH" >/dev/null 2>&1 || die "NOT MERGEABLE: $lane: gh is not installed" 6
repo="$(cd "$repo" 2>/dev/null && pwd)" || die "no such directory: $repo" 2
file="$(lane_file "$repo" "$lane")"
[ -f "$file" ] || die "NO LANE: $lane" 6
session="${session:-$(default_session)}"

no() { die "NOT MERGEABLE: $lane: $1" 6; }

state="$(automerge_state "$session" "$repo" "$lane")"
case "$state" in "on "*) ;; *) no "auto-merge is off for this lane ($state): the merge waits for the user" ;; esac
l="$(read_json "$file")" || die "could not read $file"
branch="$(jq -r '.branch // ""' <<<"$l")"
url="$(jq -r '. as $l | if (.pr // "") != "" then .pr else ([.graph | to_entries[] | select(.value.pr) | .key as $k | $l.nodes[$k].ref // "" | select(test("^https?://"))] | .[0] // "") end' <<<"$l")"
[ -n "$url" ] || no "no pull request is recorded (lane.sh set --key pr)"
[ -n "$branch" ] || no "no branch is recorded"
case "$branch" in look/pr-*) no "a review lane never merges" ;; esac
[ "$(jq -r '.pattern' <<<"$l")" != review ] || no "a review lane never merges"
[ "$(jq -r '.status' <<<"$l")" != closed ] || no "the lane is closed"
jq -e '(.question // "") == ""' >/dev/null <<<"$l" || no "the lane has an open question"
bad="$(jq -r '. as $l | [.nodes | to_entries[] | .key as $n | .value as $s | $l.graph[$n] as $g
    | select((($s.status == "done" and (($s.result // "pass") == "pass"))
              or ($s.status == "skipped" and ($g.gate // "") == "" and (($g.agent // "") | test("review") | not))) | not) | $n] | join(", ")' <<<"$l")"
[ -z "$bad" ] || no "nodes not passed: $bad"
jq -e 'any(.graph[]; .gate)' >/dev/null <<<"$l" || no "the lane's graph has no gate: nothing was verified"
if jq -e '.status != "done" and any((.done // [])[]; type == "object" and .human)' >/dev/null <<<"$l"; then
    no "a done check that asks the user is not met"
fi

wt="$(git -C "$repo" worktree list --porcelain | awk -v b="branch refs/heads/$branch" '/^worktree / {p = substr($0, 10)} $0 == b {print p; exit}')"
head="$(git -C "$repo" rev-parse --verify -q "refs/heads/$branch")" || no "branch $branch is not in $repo"
[ -z "$wt" ] || [ -z "$(git -C "$wt" status --porcelain 2>/dev/null)" ] || no "the checkout has uncommitted changes ($wt)"
stale="$(jq -r --arg h "$head" '. as $l | [.nodes | to_entries[] | .key as $n | .value as $s | $l.graph[$n] as $g
    | select($s.status == "done" and (($g.gate // "") != "" or (($g.agent // "") | test("review"))))
    | select(($s.head // "") != $h) | $n] | join(", ")' <<<"$l")"
[ -z "$stale" ] || no "$stale passed on an older commit than the branch head ${head:0:7}"

pj="$(cd "$repo" && "$GH" pr view "$url" --json state,url,number,headRefOid,headRefName,isDraft,reviewDecision,mergeable,statusCheckRollup 2>/dev/null)" ||
    no "gh could not read $url"
[ "$(jq -r .state <<<"$pj")" = OPEN ] || no "the pull request is $(jq -r .state <<<"$pj")"
[ "$(jq -r .headRefName <<<"$pj")" = "$branch" ] || no "the pull request's head branch is not the lane's branch $branch"
[ "$(jq -r .headRefOid <<<"$pj")" = "$head" ] || no "the pull request's head $(jq -r '.headRefOid[0:7]' <<<"$pj") is not the checked branch head ${head:0:7}: push it, or run the gate again"
case "$(jq -r '.reviewDecision // ""' <<<"$pj")" in CHANGES_REQUESTED | REVIEW_REQUIRED) no "the pull request's review is $(jq -r .reviewDecision <<<"$pj")" ;; esac
case "$(jq -r '.mergeable // ""' <<<"$pj")" in MERGEABLE) ;; CONFLICTING) no "the pull request has a conflict" ;; *) no "GitHub has not said yet whether it can merge; try again later" ;; esac
checks="$(jq -r '[(.statusCheckRollup // [])[] | select(if has("conclusion") or has("status")
        then (.status != "COMPLETED" or ((.conclusion // "") | IN("SUCCESS", "NEUTRAL", "SKIPPED") | not))
        else (.state != "SUCCESS") end) | .name // .context // "check"] | join(", ")' <<<"$pj")"
[ -z "$checks" ] || no "CI checks not passed: $checks"

if [ "$cmd" = check ]; then
    printf 'MERGE READY %s %s %s\n' "$lane" "$url" "$head"
    exit 0
fi
if [ "$(jq -r .isDraft <<<"$pj")" = true ]; then
    (cd "$repo" && "$GH" pr ready "$url") >/dev/null 2>&1 || die "MERGE FAILED $lane: gh pr ready $url failed; tell the user"
fi
out="$(cd "$repo" && "$GH" pr merge "$url" "--$method" --match-head-commit "$head" 2>&1)" ||
    die "MERGE FAILED $lane: gh pr merge $url failed: $out
Nothing else was tried; tell the user."
bash "$HERE/decide.sh" add --by merge --session "$session" --class merge --lane "$lane" --repo "$repo" \
    --what "merged $url ($method) at ${head:0:7}" --why "its gate and reviews passed on that commit, and every CI check" \
    --source "auto-merge $state" --reversible partly --undo "revert the merge with a new pull request" >/dev/null ||
    echo "NOT RECORDED: tell the user $url was merged" >&2
bash "$HERE/lane.sh" note --repo "$repo" --lane "$lane" --text "auto-merged $url at ${head:0:7}" >/dev/null 2>&1 || true
printf 'MERGED %s %s\n' "$lane" "$url"
