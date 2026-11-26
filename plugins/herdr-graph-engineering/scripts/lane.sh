#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# lane.sh -- the only writer of lane state files.
#
# A lane file, <git common dir>/herdr-graph/<lane>.yaml, holds only what Herdr and git
# cannot show: the idea, the pattern and a copy of its graph, the gate command the user
# approved, each node's last result, retries, the open question, the owner and history.
# Every write takes the repository's lock, writes a temporary file and renames it.
#
# Usage (every command takes --repo DIR, default: the current directory):
#   lane.sh new --lane L (--pattern P | --pattern-file FILE) --idea TEXT [--input K=V]... [--gate CMD] [--branch B]
#               [--workspace ID] [--owner NAME]
#   lane.sh show --lane L [--json]
#   lane.sh list [--all]                          open lanes (--all: closed ones too)
#   lane.sh node --lane L --node N --status waiting|running|done|failed|blocked|skipped
#               [--result pass|changes|fail|question] [--ref X] [--exit N] [--agent NAME] [--tab TAB] [--note TEXT]
#                                                 --tab: the Herdr tab the node runs in (a new tab clears tab_closed)
#   lane.sh tab-closed --lane L --node N          record that the node's tab was closed (by close-done.sh)
#   lane.sh retry --lane L --node N               N failed: rerun its retry target; exit 7 at the limit
#   lane.sh ask --lane L --text Q [--node N]      record an open question for the user
#   lane.sh answer --lane L --text A              record the user's answer and clear the question
#   lane.sh set --lane L --key owner|workspace|branch|gate|status|pr|cleanup|forwarded --value V
#                                                 pr: the lane's pull request; cleanup: ready or blocked: REASON
#                                                 (written by cleanup.sh), confirmed or declined (the user's
#                                                 answer; confirmed only after ready); forwarded (a review
#                                                 lane): OWNER-LANE/AGENT its findings were sent to, or declined
#   lane.sh close --lane L                        move the file to closed/
#   lane.sh clear --lane L                        a closed lane: move its file to closed/cleared/ (kept, off the panel)
# Exit codes: 0 ok, 1 error, 2 usage, 6 invalid pattern or lane, 7 retry limit reached.
# jq programs are single-quoted on purpose: $names in them are jq variables.
# shellcheck disable=SC2016
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/common.sh
. "$HERE/src/common.sh"
# shellcheck source=src/pattern.sh
. "$HERE/src/pattern.sh"

USAGE="lane.sh new|show|list|node|tab-closed|retry|ask|answer|set|close|clear [options] (see the header of lane.sh)"
cmd="${1:-}"
[ -n "$cmd" ] || usage "$USAGE"
shift
repo="$(pwd)" lane="" pattern="" pattern_file="" idea="" gate="" branch="" workspace="" owner="" node="" status=""
result="" ref="" exitc="" agent="" tab="" note="" text="" key="" value="" as_json=0 all=0 inputs="{}"
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) need_value "$1" $#; repo="$2"; shift 2 ;;
        --lane) need_value "$1" $#; lane="$2"; shift 2 ;;
        --pattern) need_value "$1" $#; pattern="$2"; shift 2 ;;
        --pattern-file) need_value "$1" $#; pattern_file="$2"; shift 2 ;;
        --idea) need_value "$1" $#; idea="$2"; shift 2 ;;
        --input) need_value "$1" $#
            case "$2" in *=*) ;; *) die "--input needs KEY=VALUE" 2 ;; esac
            inputs="$(jq -cn --argjson i "$inputs" --arg k "${2%%=*}" --arg v "${2#*=}" '$i + {($k): $v}')"; shift 2 ;;
        --gate) need_value "$1" $#; gate="$2"; shift 2 ;;
        --branch) need_value "$1" $#; branch="$2"; shift 2 ;;
        --workspace) need_value "$1" $#; workspace="$2"; shift 2 ;;
        --owner) need_value "$1" $#; owner="$2"; shift 2 ;;
        --node) need_value "$1" $#; node="$2"; shift 2 ;;
        --status) need_value "$1" $#; status="$2"; shift 2 ;;
        --result) need_value "$1" $#; result="$2"; shift 2 ;;
        --ref) need_value "$1" $#; ref="$2"; shift 2 ;;
        --exit) need_value "$1" $#; exitc="$2"; shift 2 ;;
        --agent) need_value "$1" $#; agent="$2"; shift 2 ;;
        --tab) need_value "$1" $#; tab="$2"; shift 2 ;;
        --note) need_value "$1" $#; note="$2"; shift 2 ;;
        --text) need_value "$1" $#; text="$2"; shift 2 ;;
        --key) need_value "$1" $#; key="$2"; shift 2 ;;
        --value) need_value "$1" $#; value="$2"; shift 2 ;;
        --json) as_json=1; shift ;;
        --all) all=1; shift ;;
        *) usage "$USAGE" ;;
    esac
done
require_tools jq yq git
repo="$(cd "$repo" 2>/dev/null && pwd)" || die "no such directory: $repo" 2
dir="$(lane_dir "$repo")"

need_lane() {
    [ -n "$lane" ] || usage "lane.sh $cmd --lane L ..."
    file="$dir/$lane.yaml"
    [ -f "$file" ] || die "NO LANE: $lane (no $file)" 6
}

# Apply a jq program to the lane under the lock, append one history line, write back.
update() { # jq program, history text, extra jq args...
    local prog="$1" msg="$2" out
    shift 2
    lock "$repo"
    out="$(read_json "$file" | jq -c --arg now "$(now)" --arg msg "$msg" "$@" "$prog | .history += [\"\(\$now) \(\$msg)\"]")" || die "could not update $file"
    printf '%s' "$out" | write_yaml "$file"
    unlock
}

case "$cmd" in
new)
    if [ -z "$lane" ] || [ -z "$idea" ] || { [ -z "$pattern" ] && [ -z "$pattern_file" ]; }; then
        usage "lane.sh new --lane L (--pattern P | --pattern-file FILE) --idea TEXT ..."
    fi
    [ "$(slug "$lane")" = "$lane" ] || die "LANE NAME: '$lane' must be a lowercase slug of at most 24 characters, for example $(slug "$lane")" 2
    if [ -n "$pattern_file" ]; then
        [ -f "$pattern_file" ] || die "NO PATTERN FILE: $pattern_file" 6
        pfile="$pattern_file" pwhere="custom"
        [ -n "$pattern" ] || pattern="custom"
    else
        found="$(resolve patterns "$pattern" "$repo")" || die "NO PATTERN: $pattern" 6
        pfile="${found%%	*}" pwhere="${found##*	}"
    fi
    pjson="$(yq -o=json '.' "$pfile")" || die "PROBLEM: $pfile is not valid YAML" 6
    problems="$(pattern_problems "$pjson" "$repo")"
    [ -z "$problems" ] || die "$(printf '%s\n' "$problems" | sed 's/^/PROBLEM: /')" 6
    # every declared input must be given (idea is always given)
    missing="$(jq -rn --argjson p "$pjson" --argjson i "$inputs" '[($p.inputs // [])[] | . as $n | select($n != "idea" and ($i | has($n) | not))] | join(", ")')" || die "could not read the pattern's inputs"
    [ -z "$missing" ] || die "MISSING INPUT: $missing (pass --input KEY=VALUE)" 2
    if jq -en --argjson p "$pjson" 'any($p.nodes[]; (.gate // "") | test("\\{gate\\}"))' >/dev/null && [ -z "$gate" ]; then
        die "MISSING GATE: this pattern runs the approved gate command; pass --gate CMD after the user approved it" 2
    fi
    lock "$repo"
    [ ! -e "$dir/$lane.yaml" ] || { unlock; die "LANE EXISTS: $lane ($dir/$lane.yaml); pick another name" 6; }
    jq -cn --argjson p "$pjson" --argjson i "$inputs" --arg lane "$lane" --arg repo "$repo" --arg idea "$idea" \
        --arg pattern "$pattern" --arg from "$pwhere" --arg gate "$gate" --arg branch "$branch" \
        --arg ws "$workspace" --arg owner "$owner" --arg now "$(now)" '
        ($i + {idea: $idea, gate: $gate}) as $vals
        | def fill: if type == "string" then
              reduce ($vals | to_entries[]) as $e (.; gsub("\\{" + $e.key + "\\}"; $e.value | gsub("\\\\"; "\\\\\\\\"))) else . end;
        {lane: $lane, repo: $repo, idea: $idea, status: "open", pattern: $pattern, pattern_from: $from,
         gate: $gate, branch: $branch, workspace: $ws, owner: $owner, inputs: $i, created: $now,
         graph: ($p.nodes | map_values(walk(fill))), done: ($p.done // []),
         nodes: ($p.nodes | map_values({status: "waiting", retries: 0})),
         question: "", history: ["\($now) lane created from pattern \($pattern) (\($from))"]}' | write_yaml "$dir/$lane.yaml"
    unlock
    printf 'LANE %s %s\n' "$lane" "$dir/$lane.yaml" ;;
show)
    need_lane
    if [ "$as_json" -eq 1 ]; then read_json "$file"; else cat "$file"; fi ;;
list)
    [ -d "$dir" ] || exit 0
    for f in "$dir"/*.yaml; do
        [ -f "$f" ] || continue
        st="$(yq -r '.status' "$f")"
        [ "$all" -eq 1 ] || [ "$st" != "closed" ] || continue
        printf '%s\t%s\t%s\n' "$(basename "$f" .yaml)" "$st" "$(yq -r '.pattern' "$f")"
    done
    if [ "$all" -eq 1 ] && [ -d "$dir/closed" ]; then
        for f in "$dir"/closed/*.yaml; do
            [ -f "$f" ] && printf '%s\tclosed\t%s\n' "$(basename "$f" .yaml)" "$(yq -r '.pattern' "$f")"
        done
    fi ;;
node)
    need_lane
    [ -n "$node" ] && [ -n "$status" ] || usage "lane.sh node --lane L --node N --status S ..."
    case "$status" in waiting | running | done | failed | blocked | skipped) ;; *) die "--status must be waiting, running, done, failed, blocked or skipped" 2 ;; esac
    case "$result" in '' | pass | changes | fail | question) ;; *) die "--result must be pass, changes, fail or question" 2 ;; esac
    case "$exitc" in '' | *[!0-9]*) [ -z "$exitc" ] || die "--exit must be a number" 2 ;; esac
    yq -e ".graph | has(\"$node\")" "$file" >/dev/null 2>&1 || die "NO NODE: $node in lane $lane" 6
    msg="$node $status${result:+ $result}${exitc:+ EXIT=$exitc}${ref:+ $ref}${tab:+ tab $tab}${note:+ - $note}"
    update '.nodes[$n] |= (. + {status: $s}
            + (if $r != "" then {result: $r} else {} end)
            + (if $ref != "" then {ref: $ref} else {} end)
            + (if $x != "" then {exit: ($x | tonumber)} else {} end)
            + (if $a != "" then {agent: $a} else {} end))
        | if $t != "" then .nodes[$n] |= (.tab = $t | del(.tab_closed)) else . end' "$msg" \
        --arg n "$node" --arg s "$status" --arg r "$result" --arg ref "$ref" --arg x "$exitc" --arg a "$agent" --arg t "$tab" ;;
tab-closed)
    need_lane
    [ -n "$node" ] || usage "lane.sh tab-closed --lane L --node N"
    t="$(yq -r ".nodes[\"$node\"].tab // \"\"" "$file")"
    [ -n "$t" ] || die "NO TAB: node $node in lane $lane has no tab recorded" 6
    update '.nodes[$n].tab_closed = true' "$node tab $t closed" --arg n "$node" ;;
retry)
    need_lane
    [ -n "$node" ] || usage "lane.sh retry --lane L --node N"
    nstatus="$(yq -r ".nodes[\"$node\"].status // \"\"" "$file")" nresult="$(yq -r ".nodes[\"$node\"].result // \"\"" "$file")"
    [ "$nstatus" = failed ] || [ "$nresult" = changes ] || die "NOT FAILED: $node is $nstatus${nresult:+ ($nresult)}; only a failed node, or one that asks for changes, is retried" 6
    spec="$(yq -o=json ".graph[\"$node\"].retry // null" "$file")"
    [ "$spec" != "null" ] || die "NO RETRY: node $node has no retry edge; ask the user" 7
    to="$(printf '%s' "$spec" | jq -r .to)" max="$(printf '%s' "$spec" | jq -r .max)"
    done_retries="$(yq -r ".nodes[\"$to\"].retries // 0" "$file")"
    if [ "$done_retries" -ge "$max" ]; then
        update '.nodes[$n].status = "blocked" | .question = "Retry limit reached: \($to) was retried \($max) times and \($n) still fails. What now?"' \
            "$node failed, retry limit $max reached for $to" --arg n "$node" --arg to "$to" --argjson max "$max"
        printf 'RETRY LIMIT %s: %s retried %s/%s times; ask the user\n' "$lane" "$to" "$done_retries" "$max"
        exit 7
    fi
    # reset the target and everything downstream of it, keep the counters
    update '
        .graph as $g
        | def down($s): [$s] + ([$g | to_entries[] | select((.value.needs // []) | index($s)) | .key] | map(down(.)) | add // []);
        (down($to) | unique) as $reset
        | .nodes |= with_entries(if (.key | IN($reset[])) then .value.status = "waiting" | del(.value.result) | del(.value.exit) else . end)
        | .nodes[$to].retries += 1' \
        "$node failed, retry $to $((done_retries + 1))/$max" --arg to "$to"
    printf 'RETRY %s %s %s/%s\n' "$lane" "$to" "$((done_retries + 1))" "$max" ;;
ask)
    need_lane
    [ -n "$text" ] || usage "lane.sh ask --lane L --text Q [--node N]"
    update '.question = $q | (if $n != "" then .nodes[$n].status = "blocked" else . end)' "question${node:+ from $node}: $text" --arg q "$text" --arg n "$node" ;;
answer)
    need_lane
    [ -n "$text" ] || usage "lane.sh answer --lane L --text A"
    update '.question = "" | .nodes |= map_values(if .status == "blocked" then .status = "waiting" else . end)' "answer: $text" ;;
set)
    need_lane
    case "$key" in owner | workspace | branch | gate | status | pr | cleanup | forwarded) ;; *) die "--key must be owner, workspace, branch, gate, status, pr, cleanup or forwarded" 2 ;; esac
    [ "$key" != forwarded ] || case "$value" in declined | ?*/?*) ;; *) die "forwarded must be LANE/AGENT or declined" 2 ;; esac
    [ "$key" != cleanup ] || case "$value" in '' | ready | confirmed | declined | "blocked: "?*) ;; *) die "cleanup must be ready, confirmed, declined or blocked: REASON" 2 ;; esac
    # a yes only answers a cleanup question that was asked
    if [ "$key" = cleanup ] && [ "$value" = confirmed ]; then
        was="$(yq -r '.cleanup // ""' "$file")"
        [ "$was" = ready ] || [ "$was" = confirmed ] || die "NOT ASKED: lane $lane has no cleanup question to confirm (cleanup is '$was')" 6
    fi
    [ "$key" != status ] || case "$value" in open | done) ;; *) die "status must be open or done (use close to close)" 2 ;; esac
    update '.[$k] = $v' "$key = $value" --arg k "$key" --arg v "$value" ;;
close)
    need_lane
    update '.status = "closed"' "lane closed"
    mkdir -p "$dir/closed"
    lock "$repo"
    mv "$file" "$dir/closed/$lane.yaml"
    unlock
    printf 'CLOSED %s %s\n' "$lane" "$dir/closed/$lane.yaml" ;;
clear)
    # Only a closed lane, never an open one: its file leaves closed/ for closed/cleared/.
    [ -n "$lane" ] || usage "lane.sh clear --lane L"
    [ "$(slug "$lane")" = "$lane" ] || die "LANE NAME: '$lane' is not a lane name" 2
    src="$dir/closed/$lane.yaml"
    [ -f "$src" ] || die "NOT CLOSED: $lane (no $src); only a closed lane is cleared" 6
    lock "$repo"
    mkdir -p "$dir/closed/cleared"
    dest="$dir/closed/cleared/$lane.yaml" n=2
    while [ -e "$dest" ]; do dest="$dir/closed/cleared/$lane.$n.yaml" n=$((n + 1)); done
    mv "$src" "$dest"
    unlock
    printf 'CLEARED %s %s\n' "$lane" "$dest" ;;
*) usage "$USAGE" ;;
esac
