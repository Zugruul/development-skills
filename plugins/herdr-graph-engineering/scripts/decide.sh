#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# decide.sh -- the record of what the orchestrator decided without the user, and the "decided
# while you were away" list. Kept in the session file.
# Usage:
#   decide.sh add --tier 1|2 --class C --lane L [--repo DIR] [--node N] --what T --why T
#                 [--source T] [--second-opinion FILE] --reversible yes|no|partly --undo T [--session S]
#       record a decision made while AFK, BEFORE acting on it. Refuses (exit 6) while AFK is off,
#       outside its scope, and every class that is not tier 1 or tier 2 (tier 3 always waits).
#       tier 1: start-node retry record-result answer prompt-finish close-tab push-branch draft-pr
#               start-queued              (answer needs --source: the user's words it follows from)
#       tier 2: choice replace-agent rerun-gate   (needs --second-opinion: a file with the opinion
#               of a fresh read-only agent of another kind that agrees)
#       merge and cleanup-remove are recorded only by merge.sh and cleanup.sh (--by), which check
#       their own conditions; a merge is recorded whether or not AFK is on.
#   decide.sh list [--unseen] [--json]     the decisions
#   decide.sh digest                       the unseen ones as a table, then what waits for the user
#   decide.sh seen                         mark them shown
# A written rule, not a guard: it cannot stop a command that was never recorded.
# Exit codes: 0 ok, 1 error, 2 usage, 6 refused.
# shellcheck disable=SC2016
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/common.sh
. "$HERE/src/common.sh"
# shellcheck source=src/afk.sh
. "$HERE/src/afk.sh"

USAGE="decide.sh add|list|digest|seen [options] (see the header of decide.sh)"
cmd="${1:-}"
case "$cmd" in add | list | digest | seen) shift ;; *) usage "$USAGE" ;; esac
tier="" class="" lane="" repo="$(pwd)" node="" what="" why="" source="" opinion="" reversible="" undo="" session="" by="" unseen=0 as_json=0
while [ $# -gt 0 ]; do
    case "$1" in
        --tier) need_value "$1" $#; tier="$2"; shift 2 ;;
        --class) need_value "$1" $#; class="$2"; shift 2 ;;
        --lane) need_value "$1" $#; lane="$2"; shift 2 ;;
        --repo) need_value "$1" $#; repo="$2"; shift 2 ;;
        --node) need_value "$1" $#; node="$2"; shift 2 ;;
        --what) need_value "$1" $#; what="$2"; shift 2 ;;
        --why) need_value "$1" $#; why="$2"; shift 2 ;;
        --source) need_value "$1" $#; source="$2"; shift 2 ;;
        --second-opinion) need_value "$1" $#; opinion="$2"; shift 2 ;;
        --reversible) need_value "$1" $#; reversible="$2"; shift 2 ;;
        --undo) need_value "$1" $#; undo="$2"; shift 2 ;;
        --session) need_value "$1" $#; session="$2"; shift 2 ;;
        --by) need_value "$1" $#; by="$2"; shift 2 ;;
        --unseen) unseen=1; shift ;;
        --json) as_json=1; shift ;;
        *) usage "$USAGE" ;;
    esac
done
require_tools jq yq git
session="${session:-$(default_session)}"
[ "$(slug "$session")" = "$session" ] || die "SESSION NAME: '$session' must be a lowercase slug" 2
dir="$(session_dir)"
file="$dir/$session.yaml"

update() { # jq program, jq args...
    local prog="$1" out cur='{}'
    shift
    lock_in "$dir"
    [ -f "$file" ] && cur="$(read_json "$file")"
    [ -n "$cur" ] && [ "$cur" != null ] || cur='{}'
    out="$(jq -c --arg now "$(now)" --arg s "$session" "$@" '{session: $s} + . | '"$prog"' | .updated = $now' <<<"$cur")" || die "could not update $file"
    printf '%s' "$out" | write_yaml "$file"
    unlock
}

case "$cmd" in
add)
    if [ -z "$class" ] || [ -z "$lane" ] || [ -z "$what" ] || [ -z "$why" ] || [ -z "$undo" ]; then usage "$USAGE"; fi
    case "$reversible" in yes | no | partly) ;; *) die "--reversible must be yes, no or partly" 2 ;; esac
    for t in "$what" "$why" "$source" "$undo"; do
        ! looks_secret "$t" || die "SECRET: that looks like a token, key or password; it is never stored" 2
    done
    case "$class" in
        start-node | retry | record-result | answer | prompt-finish | close-tab | push-branch | draft-pr | start-queued) need=1 ;;
        choice | replace-agent | rerun-gate) need=2 ;;
        merge | cleanup-remove)
            want=merge
            [ "$class" = merge ] || want=cleanup
            [ "$by" = "$want" ] || die "TIER 3: $class always waits for the user; only $want.sh does it, after its own checks" 6
            need=0 ;;
        *) die "TIER 3: $class always waits for the user, in every mode" 6 ;;
    esac
    afk="$(afk_json "$session")"
    if [ "$need" -ne 0 ]; then
        [ "$(jq -r .state <<<"$afk")" = on ] || die "NOT DECIDED: AFK is off; ask the user" 6
        [ "$tier" = "$need" ] || die "NOT DECIDED: $class is tier $need, not tier ${tier:-?}" 6
        jq -e --argjson t "$need" '.tiers | index($t) != null' >/dev/null <<<"$afk" || die "NOT DECIDED: tier $need is not in the AFK scope; ask the user" 6
        jq -e --arg l "$lane" '(.lanes | length) == 0 or (.lanes | index($l)) != null' >/dev/null <<<"$afk" || die "NOT DECIDED: lane $lane is not in the AFK scope" 6
        [ "$class" != start-queued ] || [ "$(jq -r .queued <<<"$afk")" = true ] || die "NOT DECIDED: queued ideas are not in the AFK scope" 6
        [ "$class" != answer ] || [ -n "$source" ] || die "NOT DECIDED: an answer must follow from the user's recorded words or a standing answer: quote them with --source" 6
        [ "$need" -ne 2 ] || [ -s "$opinion" ] || die "NOT DECIDED: tier 2 needs the second opinion, from a fresh read-only agent of another kind, as a file (--second-opinion)" 6
    else
        tier="$class"
    fi
    entry="$(repo_entry "$repo")" && repo="${entry#*$'\t'}"
    update '.decisions = (.decisions // []) | .decisions += [{id: (([.decisions[].id] | max // 0) + 1), at: $now, tier: $tier, class: $c,
            lane: $l, repo: $r, node: $n, what: $w, why: $y, source: $src, second_opinion: $op, reversible: $rv, undo: $u, seen: false}]' \
        --arg tier "$tier" --arg c "$class" --arg l "$lane" --arg r "$repo" --arg n "$node" --arg w "$what" --arg y "$why" \
        --arg src "$source" --arg op "$opinion" --arg rv "$reversible" --arg u "$undo"
    printf 'DECIDED %s %s\n' "$(yq -r '.decisions[-1].id' "$file")" "$class" ;;
list)
    session_json "$session" | jq -r --argjson u "$unseen" --argjson j "$as_json" \
        '[(.decisions // [])[] | select($u == 0 or .seen != true)] | if $j == 1 then tojson else .[] | "#\(.id) \(.at) tier \(.tier) \(.class) \(.lane)\(if .node != "" then "/" + .node else "" end): \(.what)" end' ;;
digest)
    session_json "$session" | jq -r '
        def cell: gsub("[\r\n]+"; " ") | gsub("\\|"; "\\|");
        [(.decisions // [])[] | select(.seen != true)]
        | if length == 0 then "Nothing was decided while you were away." else
            "Decided while you were away:", "",
            "| # | Lane/node | Decision | Why, source | Tier | Undo |", "|---|---|---|---|---|---|",
            (.[] | "| \(.id) | \(.lane)\(if .node != "" then "/" + .node else "" end) | \(.what | cell) | \(.why | cell)"
                + (if .source != "" then "; " + (.source | cell) else "" end)
                + (if .second_opinion != "" then "; second opinion: " + (.second_opinion | cell) else "" end)
                + " | \(.tier) | " + (if .reversible == "yes" then "yes" elif .reversible == "partly" then "partly" else "**no**" end) + ": \(.undo | cell) |")
          end'
    # what waited: every open question of the open lanes
    waiting="$(bash "$HERE/status.sh" --json 2>/dev/null | jq -r '.[] | select(.section != "closed" and .question != "") | "- \(.lane): \(.question | gsub("[\r\n]+"; " "))"')"
    [ -z "$waiting" ] || printf '\nWaiting for you:\n%s\n' "$waiting" ;;
seen)
    update '.decisions = [(.decisions // [])[] | .seen = true]'
    echo SEEN ;;
esac
