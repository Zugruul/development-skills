#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# make-review-stack.sh -- the graph for reviewing several related pull requests together.
# Usage: make-review-stack.sh --pr URL --pr URL [--pr URL]... [--out FILE]
# A pattern cannot repeat nodes by itself (the language has no expressions), so this writes
# a plain pattern file with one node per pull request:
#   review-1..n (pr-reviewer, parallel) -> cross (pr-reviewer on the seams) -> approve (you)
#   -> post-1..n (poster, one per pull request)
# Validate it with check-pattern.sh and start it with lane.sh new --pattern-file.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/common.sh
. "$HERE/src/common.sh"

prs=() out=""
while [ $# -gt 0 ]; do
    case "$1" in
        --pr) need_value "$1" $#; prs+=("$2"); shift 2 ;;
        --out) need_value "$1" $#; out="$2"; shift 2 ;;
        *) usage "make-review-stack.sh --pr URL --pr URL [--pr URL]... [--out FILE]" ;;
    esac
done
[ "${#prs[@]}" -ge 2 ] || die "a review stack needs at least two pull requests (one pull request: the review pattern)" 2
[ "${#prs[@]}" -le 8 ] || die "at most 8 pull requests in one stack; split the group" 2
require_tools jq yq

json="$(jq -cn --args '
    $ARGS.positional as $p | ($p | length) as $n
    | {when: "Review related pull requests together: \($p | join(", "))", inputs: ["idea"],
       nodes: (
         ([range(0; $n) as $i | {("review-\($i + 1)"): {agent: "pr-reviewer", access: "read",
             brief: "Review pull request \($p[$i]) as part of a group: \($p | join(", ")). The user said: {idea}"}}] | add)
         + {cross: {agent: "pr-reviewer", access: "read", needs: [range(0; $n) | "review-\(. + 1)"],
             brief: "The cross-PR check across \($p | join(", ")): every place one pull request assumes something about another."}}
         + {approve: {human: "Post the reviews of \($p | join(", "))? The merged posting files are ready.", needs: ["cross"]}}
         + ([range(0; $n) as $i | {("post-\($i + 1)"): {agent: "poster", needs: ["approve"], when: "pass",
             brief: "Post the merged posting file for \($p[$i])."}}] | add)),
       done: ["posted-review"]}' "${prs[@]}")"
if [ -n "$out" ]; then
    printf '%s' "$json" | yq -p=json -o=yaml -P '.' >"$out" || die "could not write $out"
    printf 'PATTERN FILE %s\n' "$out"
else
    printf '%s' "$json" | yq -p=json -o=yaml -P '.'
fi
