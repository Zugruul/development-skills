#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# adopt.sh -- watch an agent that was started outside the graph: a one-node lane around it.
# Usage:
#   adopt.sh --agent A --idea TEXT --access read|write [--lane L] [--repo DIR] [--session S]
#   adopt.sh --protocol --lane L [--repo DIR]    send the result protocol, if it was not sent yet
# Why a script: several things must hold before an agent is adopted: it is live and no open lane
# records it; for write access no other lane writes in that checkout (never a second writer).
# The lane is marked adopted, its node "work" runs with the agent, and no tab is recorded, so
# close-done.sh never closes it; cleanup.sh only ever closes its record, never the checkout. A
# read adoption keeps the checkout's HEAD and status as its baseline. The agent is sent the
# result protocol once, whenever it is not blocked (a blocked agent shows a dialog the text could
# answer). That message contains no line the strict reader counts as a result.
# Exit codes: 0 ok, 1 error, 2 usage, 6 refused.
# shellcheck disable=SC2016
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/common.sh
. "$HERE/src/common.sh"
# shellcheck source=src/afk.sh
. "$HERE/src/afk.sh"

USAGE="adopt.sh --agent A --idea T --access read|write [--lane L] [--repo DIR] | adopt.sh --protocol --lane L [--repo DIR]"
agent="" idea="" access="" lane="" repo="" session="" protocol=0
while [ $# -gt 0 ]; do
    case "$1" in
        --agent) need_value "$1" $#; agent="$2"; shift 2 ;;
        --idea) need_value "$1" $#; idea="$2"; shift 2 ;;
        --access) need_value "$1" $#; access="$2"; shift 2 ;;
        --lane) need_value "$1" $#; lane="$2"; shift 2 ;;
        --repo) need_value "$1" $#; repo="$2"; shift 2 ;;
        --session) need_value "$1" $#; session="$2"; shift 2 ;;
        --protocol) protocol=1; shift ;;
        *) usage "$USAGE" ;;
    esac
done
require_tools jq yq git herdr

live_agent() { # name -> its JSON
    herdr agent list 2>/dev/null | jq -ce --arg a "$1" '[.result.agents[]? | select(.name == $a)][0] // empty' 2>/dev/null
}

send_protocol() { # repo, lane
    local f a j status text
    f="$(lane_file "$1" "$2")"
    [ -f "$f" ] || die "NO LANE: $2" 6
    [ "$(yq -r '.adopted // false' "$f")" = true ] || die "NOT ADOPTED: lane $2 was not adopted" 6
    [ "$(yq -r '.protocol_sent // ""' "$f")" = "" ] || { echo "ALREADY SENT: the protocol for lane $2"; return 0; }
    a="$(yq -r '.nodes.work.agent // ""' "$f")"
    j="$(live_agent "$a")" || { echo "PROTOCOL NOT SENT: agent $a is gone"; return 0; }
    status="$(jq -r '.agent_status // "unknown"' <<<"$j")"
    case "$status" in
        idle | done | working) ;;
        *) echo "PROTOCOL NOT SENT: agent $a is $status; send it later: adopt.sh --protocol --lane $2 --repo $1"; return 0 ;;
    esac
    text="This message is from the graph orchestrator, not the user, and approves nothing: your task, its limits and your permissions are unchanged. The orchestrator now watches this pane (lane $2, node work). When the whole task is done, or you need an answer, end your final message with this as its last line, alone, with your own values in place of the angle brackets: \"NODE work RESULT: <pass|fail|question> <commit id or file path>\". After a finished step with more to do, you may print: \"NODE work STEP: <name> <pass|fail> <ref>\"."
    herdr agent prompt "$a" "$text" >/dev/null 2>&1 || { echo "PROTOCOL NOT SENT: herdr agent prompt $a failed; try again: adopt.sh --protocol --lane $2 --repo $1"; return 0; }
    bash "$HERE/lane.sh" set --repo "$1" --lane "$2" --key protocol_sent --value "$(now)" >/dev/null || return 1
    echo "PROTOCOL SENT to $a"
}

if [ "$protocol" -eq 1 ]; then
    [ -n "$lane" ] || usage "$USAGE"
    send_protocol "${repo:-$(pwd)}" "$lane"
    exit
fi
if [ -z "$agent" ] || [ -z "$idea" ]; then usage "$USAGE"; fi
case "$access" in read) role=investigator ;; write) role=implementer ;; *) die "--access must be read or write" 2 ;; esac

# 1. the agent is live, and no open lane records it
j="$(live_agent "$agent")" || die "NOT ADOPTED: no live agent named $agent (herdr agent list)" 6
# 2. its checkout, branch and workspace
cwd="$(jq -r '.foreground_cwd // .cwd // ""' <<<"$j")" ws="$(jq -r '.workspace_id // ""' <<<"$j")"
wt="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || die "NOT ADOPTED: agent $agent is in no git checkout ($cwd)" 6
entry="$(repo_entry "$wt")" || die "NOT ADOPTED: no repository for $wt" 6
primary="${entry#*$'\t'}"
repo="${repo:-$primary}"
branch="$(git -C "$wt" symbolic-ref --short -q HEAD)" || branch=""
repos="$( { printf '%s\n' "$repo" "$primary"; lane_repos; } | awk '!seen[$0]++')"
seen=""
while IFS= read -r r; do
    d="$(lane_dir "$r" 2>/dev/null)" || continue
    case "$seen" in *"|$d|"*) continue ;; esac
    seen="$seen|$d|"
    for f in "$d"/*.yaml; do
        [ -f "$f" ] || continue
        hit="$(read_json "$f" | jq -r --arg a "$agent" 'select(.status != "closed" and any(.nodes[]; .agent == $a)) | .lane')"
        [ -z "$hit" ] || die "NOT ADOPTED: lane $hit already records agent $agent ($f)" 6
        # 3. never a second writer in a checkout
        [ "$access" = write ] || continue
        [ "$d" = "$(lane_dir "$wt")" ] || continue
        other="$(read_json "$f" | jq -r --arg b "$branch" --arg w "$ws" '. as $l | select(.status != "closed" and (($b != "" and .branch == $b) or ($w != "" and .workspace == $w)))
            | [.nodes | to_entries[] | .key as $n | select((.value.status == "running" or .value.status == "blocked") and $l.graph[$n].access == "write") | "\(.value.agent // "a gate") (lane \($l.lane), node \($n))"][0] // empty')"
        [ -z "$other" ] || die "NOT ADOPTED: $other already writes in that checkout; adopt $agent with --access read, or wait" 6
    done
done <<<"$repos"

# 4 and 5. a one-node lane, marked adopted
lane="${lane:-$(slug "$idea")}"
session="${session:-$(default_session)}"
owner="$(session_json "$session" | jq -r --arg s "$session" 'if (.orchestrator // "") != "" then .orchestrator else $s end')"
baseline=""
if [ "$access" = read ]; then
    baseline="$(jq -cn --arg h "$(git -C "$wt" rev-parse HEAD)" --arg s "$(git -C "$wt" status --porcelain)" '{head: $h, status: $s}')"
fi
pat="$(mktemp "${TMPDIR:-/tmp}/graph-adopt.XXXXXX")" || die "could not create a temporary file"
trap 'rm -f "$pat"' EXIT
printf 'when: "An agent that was started outside the graph."\ninputs: [idea]\nnodes:\n  work:\n    agent: %s\n    access: %s\n    brief: "{idea}"\ndone:\n  - report\n' "$role" "$access" >"$pat"
bash "$HERE/lane.sh" new --repo "$repo" --lane "$lane" --pattern adopted --pattern-file "$pat" --idea "$idea" --branch "$branch" \
    --workspace "$ws" --owner "$owner" --adopted ${baseline:+--baseline "$baseline"} >/dev/null || exit 6
bash "$HERE/lane.sh" node --repo "$repo" --lane "$lane" --node work --status running --agent "$agent" >/dev/null || exit 1
printf 'ADOPTED %s %s (%s access, checkout %s)\n' "$lane" "$agent" "$access" "$wt"
# 6. the protocol, once
send_protocol "$repo" "$lane"
