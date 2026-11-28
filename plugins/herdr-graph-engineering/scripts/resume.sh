#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# resume.sh -- everything the orchestrator needs after a compaction or in a new session, in one block.
# Reads only (except --out and the hook's snapshot file). Any client: run it and follow it.
# Usage: resume.sh [--session NAME] [--repo DIR]... [--fetch] [--out FILE]
#        resume.sh --hook pre-compact|session-start      (Claude Code hooks; see hooks/hooks.json)
# Lanes come from every repository that may hold lanes (lane_repos in src/common.sh), the --repo
# ones and the repositories named in the session file. Per open lane: its nodes, its agents (live state from
# `herdr agent list`, or gone; drift.sh --quiet first reads finished agents' RESULT lines, so a
# node an agent finished or asked about before it was recorded shows that), the open question, pull requests (prs.sh's cache; --fetch refreshes
# it first), the done checks and the extra ones, its notes, and the next action. Then the session
# file: queued lanes, standing answers (and the standing kind and dialog choices kept in the
# scratch folder), renames, notes and files.
# Without --session, the session is the one whose pane is $HERDR_PANE_ID (session.sh find).
#   --hook pre-compact     write a fresh block to <session folder>/<session>.resume.md
#   --hook session-start   the same, and print it as Claude Code additionalContext JSON
#   A hook does nothing outside the orchestrator's pane and never fails the chat.
# shellcheck disable=SC2016
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/common.sh
. "$HERE/src/common.sh"
# shellcheck source=src/afk.sh
. "$HERE/src/afk.sh"

USAGE="resume.sh [--session NAME] [--repo DIR]... [--fetch] [--out FILE] | --hook pre-compact|session-start"
session="" repos="" fetch=0 out="" hook=""
while [ $# -gt 0 ]; do
    case "$1" in
        --session) need_value "$1" $#; session="$2"; shift 2 ;;
        --repo) need_value "$1" $#; repos="$repos
$2"; shift 2 ;;
        --fetch) fetch=1; shift ;;
        --out) need_value "$1" $#; out="$2"; shift 2 ;;
        --hook) need_value "$1" $#; hook="$2"; shift 2 ;;
        *) usage "$USAGE" ;;
    esac
done

write_file() { # path, text: temporary file, then rename
    local tmp
    mkdir -p "$(dirname "$1")" 2>/dev/null
    tmp="$(mktemp "$1.XXXXXX" 2>/dev/null)" || return 1
    printf '%s\n' "$2" >"$tmp" && mv "$tmp" "$1"
}

if [ -n "$hook" ]; then
    # Claude Code hook: only in the orchestrator's pane, never an error.
    case "$hook" in pre-compact | session-start) ;; *) usage "$USAGE" ;; esac
    cat >/dev/null 2>&1
    [ -n "${HERDR_PANE_ID:-}" ] || exit 0
    for t in jq yq git; do command -v "$t" >/dev/null 2>&1 || exit 0; done
    if ! name="$(bash "$HERE/session.sh" find --pane "$HERDR_PANE_ID" 2>/dev/null)"; then
        # an orchestrator whose session file was never written still gets the picture
        [ "$hook" = session-start ] && command -v herdr >/dev/null 2>&1 &&
            herdr agent list 2>/dev/null | jq -e --arg p "$HERDR_PANE_ID" \
                'any(.result.agents[]?; .pane_id == $p and ((.name // "") | test("^graph(-[0-9]+)?$")))' >/dev/null 2>&1 || exit 0
        text="NOTE: there is no session file for this pane ($HERDR_PANE_ID), so queued lanes and standing answers are unknown here. Run start.sh first.
$(bash "$HERE/resume.sh" 2>/dev/null)"
        jq -n --arg c "$text" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $c}}'
        exit 0
    fi
    snap="$(session_dir)/$name.resume.md"
    text="$(bash "$HERE/resume.sh" --session "${name:-graph}" 2>/dev/null)"
    if [ -n "$text" ]; then
        write_file "$snap" "$text" || true
    else
        text="$(cat "$snap" 2>/dev/null)"
    fi
    [ "$hook" = session-start ] && [ -n "$text" ] &&
        jq -n --arg c "$text" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $c}}'
    exit 0
fi

require_tools jq yq git
[ -z "$session" ] && [ -n "${HERDR_PANE_ID:-}" ] && session="$(bash "$HERE/session.sh" find --pane "$HERDR_PANE_ID" 2>/dev/null)"
sess='{}' sfile=""
if [ -n "$session" ]; then
    sfile="$(session_dir)/$session.yaml"
    [ -f "$sfile" ] && sess="$(read_json "$sfile")"
fi

# Every repository that may hold lanes.
repos="$repos
$(jq -r '[.queued, .standing, .renames, .notes, .files] | map(. // []) | add | .[] | .repo // empty' <<<"$sess")"
repos="$repos
$(lane_repos)"
rargs=() seen=""
while IFS= read -r r; do
    [ -n "$r" ] && [ -d "$r" ] || continue
    case "$seen" in *"|$r|"*) continue ;; esac
    seen="$seen|$r|"
    rargs+=(--repo "$r")
done <<EOF
$repos
EOF
[ "${#rargs[@]}" -gt 0 ] || rargs=(--repo "$(pwd)")

[ "$fetch" -eq 0 ] || bash "$HERE/prs.sh" fetch "${rargs[@]}" >/dev/null 2>&1
# what finished agents printed as their RESULT line (drift.sh writes only its cache)
command -v herdr >/dev/null 2>&1 && bash "$HERE/drift.sh" --quiet "${rargs[@]}" >/dev/null 2>&1
view="$(bash "$HERE/status.sh" --json "${rargs[@]}" 2>/dev/null)" || view="[]"
[ -n "$view" ] || view="[]"

# Add each open lane's own facts that status.sh leaves out: done checks, extra ones, notes.
lanes="[]"
while IFS="$(printf '\t')" read -r root lane; do
    [ -n "$lane" ] || continue
    f="$(lane_file "$root" "$lane")"
    extra='{}'
    [ -f "$f" ] && extra="$(read_json "$f" | jq -c '{cleanup: (.cleanup // ""), done: (.done // []), done_extra: (.done_extra // []), notes: (.notes // [])}')"
    lanes="$(jq -c --argjson v "$view" --argjson e "$extra" --arg r "$root" --arg l "$lane" \
        '. + [($v[] | select(.root == $r and .lane == $l)) + $e]' <<<"$lanes")"
done < <(jq -r '.[] | select(.section != "closed") | [.root, .lane] | @tsv' <<<"$view")

# Per lane: the text block, and the next action (READY when ready.sh decides it).
LANE_JQ='
def one: gsub("[\r\n]+"; " ") | if length > 200 then .[0:200] + "..." else . end;
def openprs: [.prs[] | select(.state == "OPEN")];
def donecheck: if type == "string" then .
    elif .gate then "gate \(.gate)" elif .human then "human: \(.human)" else tostring end;
def donenext($l):
    [ $l.done[] | if . == "draft-pr" then
            (if ($l | openprs | length) > 0 then "push and update the draft PR #\(($l | openprs)[0].number)" else "open draft PR" end)
        elif . == "report" then "show the user the report"
        elif . == "posted-review" then "verify the posted reviews"
        elif type == "object" and .human then "ask the user: \(.human)"
        else empty end ]
    | (if length == 0 then "" else join(", ") + ", then " end) + "lane.sh set --lane \($l.lane) --key status --value done";
def next:
    . as $l
    | [.nodes[] | select(.status == "running" or (.status == "blocked" and .agent != "" and .live == "blocked"))] as $run
    | [.nodes[] | select(.status == "failed" or (.status == "done" and .result == "changes"))] as $failed
    | [(.done_extra // [])[] | select(.met != true) | .text] as $unmet
    | ([.nodes[] | select(.drift.kind == "question")][0].node // "") as $asked
    | if .question_live == true then "record the agent'"'"'s question (lane.sh ask --lane \($l.lane) --node \($asked)), then ask the user: \(.question | one)"
      elif .question != "" then "ask the user: \(.question | one) (answer with herdr:prompt when an agent asked, then lane.sh answer)"
      elif ($run | length) > 0 then
        [ $run[] | if .drift.kind == "pass" then "\(.agent) finished: pass \(.drift.ref): check it, then lane.sh node --lane \($l.lane) --node \(.node) --status done --result pass --ref \(.drift.ref)"
          elif .drift.kind == "fail" then "\(.agent) finished: fail \(.drift.ref): check it, then lane.sh node --lane \($l.lane) --node \(.node) --status failed --result fail --ref \(.drift.ref)"
          elif .drift.kind == "agent-failed" then "\(.agent) failed (\(.drift.ref)): read its screen and tell the user"
          elif ((.drift.kind // "") | startswith("step-")) then "\(.agent) step \(.drift.ref): check it, then lane.sh step --lane \($l.lane) --node \(.node)"
          elif .drift.kind == "stopped" then "\(.agent) stopped without a NODE \(.node) RESULT line: read its screen, prompt it to finish or record what it did"
          elif .agent == "" then "gate \(.node) is running: read its tab for the GATE line (gate.sh records it)"
          elif .live == "" then "\(.agent) is gone: check \(.node)'"'"'s checkout for its commits and its NODE RESULT, then record \(.node) or start it again"
          elif .live == "blocked" then "\(.agent) is blocked: read its screen, lane.sh ask, ask the user"
          elif .live == "working" then "wait: the watcher wakes you when \(.agent) changes"
          else "\(.agent) has settled (\(.live)): read its screen for NODE \(.node) RESULT, check it, record it" end ] | join("; ")
      elif ($failed | length) > 0 then [ $failed[] | "lane.sh retry --lane \($l.lane) --node \(.node)" ] | join("; ")
      elif .section == "done" then
        if (openprs | length) > 0 then "ask the user to merge #\(openprs[0].number)" + (if openprs[0].isDraft then " (it is a draft: ask before marking it ready)" else "" end)
        elif ($unmet | length) > 0 then "finish extra done: \($unmet | join("; "))"
        elif (.cleanup // "") == "confirmed" then "cleanup.sh run --lane \(.lane) --repo \(.root) (the user said yes)"
        elif (.cleanup // "") == "declined" then "nothing: the user declined cleanup"
        elif (.cleanup // "") == "ready" then "ask the user to confirm cleanup (cleanup.sh check already asked; their yes or no is not recorded yet)"
        elif (.cleanup // "") | startswith("blocked") then "cleanup \(.cleanup): relay it to the user"
        else "cleanup.sh check --lane \(.lane) --repo \(.root) (offer cleanup)" end
      else "READY" end;
def block:
    "lane \(.lane)  [\(.section)]  \(.pattern)  repo \(.root)" + (if .branch != "" then "  branch \(.branch)" else "" end)
      + (if .workspace != "" then "  workspace \(.workspace)" else "" end) + (if .owner != "" then "  owner \(.owner)" else "" end),
    "  idea: \(.idea | one)",
    "  nodes: \([.nodes[] | "\(.node) \(.status)" + (if .result != "" then " \(.result)" else "" end)
                 + (if .max > 0 and .retries > 0 then " retry \(.retries)/\(.max)" else "" end)
                 + (if .ref != "" then " \(.ref)" else "" end)] | join(" → "))",
    (if any(.nodes[]; .agent != "") then "  agents: \([.nodes[] | select(.agent != "") | "\(.agent) (\(.node)) \(if .live == "" then "gone" else .live end)"] | join("; "))" else empty end),
    (if .question != "" then "  question: \(.question | one)" else empty end),
    ((.attention // [])[] | "  attention: \(. | one)"),
    (.prs[] | "  pr: #\(.number) \(.state)\(if .isDraft then " draft" else "" end) \(.url)"),
    "  done: \([.done[] | donecheck] | join(", "))",
    ((.done_extra // [])[] | "  extra: [\(if .met == true then "x" else " " end)] \(.text | one)"),
    ((.notes // [])[] | "  note: \(.at) \(.text | one)" + (if .node then " (\(.node))" else "" end) + (if .ref then " \(.ref)" else "" end));
'
running="$(jq -r '[.[] | .nodes[] | select(.status == "running" or .status == "blocked") | select(.agent != "" and .live != "") | .agent] | unique | length' <<<"$lanes")"

render() {
    local name="${session:-}" n l nx r ready
    if [ -n "$name" ] && [ -f "$sfile" ]; then
        printf 'RESUME %s (pane %s) at %s\n' "$name" "$(jq -r '.pane // "?"' <<<"$sess")" "$(now)"
        printf 'orchestrator: %s  scratch: %s  session file: %s\n' "$(jq -r '.orchestrator // ""' <<<"$sess")" "$(jq -r '.scratch // ""' <<<"$sess")" "$sfile"
    else
        printf 'RESUME at %s: no session file%s; record one with session.sh set --key pane --value "$HERDR_PANE_ID"\n' "$(now)" "${HERDR_PANE_ID:+ for pane $HERDR_PANE_ID}"
    fi
    echo 'Do now: follow "After a compaction (or a new session)" in the orchestrate skill. The watcher wakes you on changes (do not poll or start listeners); take each lane'"'"'s next action. Briefs and follow-ups in the notes were already sent: do not send them again.'
    echo
    printf 'LANES (%s open; %s agents running)\n' "$(jq 'length' <<<"$lanes")" "$running"
    n="$(jq 'length' <<<"$lanes")"
    for ((i = 0; i < n; i++)); do
        l="$(jq -c ".[$i]" <<<"$lanes")"
        jq -r "$LANE_JQ block" <<<"$l"
        nx="$(jq -r "$LANE_JQ next" <<<"$l")"
        if [ "$nx" = READY ]; then
            r="$(jq -r .root <<<"$l")"
            ready="$(bash "$HERE/ready.sh" --lane "$(jq -r .lane <<<"$l")" --repo "$r" 2>&1)"
            case "$ready" in
                "ALL NODES DONE"*) nx="$(jq -r "$LANE_JQ donenext(.)" <<<"$l")" ;;
                *) nx="$(printf '%s\n' "$ready" | awk -v lane="$(jq -r .lane <<<"$l")" '
                        /^READY / {n = $2; t = $3; $1 = $2 = $3 = ""; sub(/^ +/, ""); out = out sep "start " n " (" t " " $0 ")"; sep = "; "; next}
                        /^SKIP / {out = out sep "lane.sh node --lane " lane " --node " $2 " --status skipped"; sep = "; "; next}
                        {out = out sep tolower(substr($0, 1, 1)) substr($0, 2); sep = "; "}
                        END {print out}')" ;;
            esac
        fi
        printf '  next: %s\n' "$nx"
    done
    [ "$n" -gt 0 ] || echo "  (no open lanes)"
    echo
    echo "QUEUED (start them unless the user set a cap)"
    jq -r '(.queued // []) | if length == 0 then "  (none)" else .[] | "  #\(.id) \(.lane)" + (if .repo then " (repo \(.repo))" else "" end) + (if .ref then " brief \(.ref)" else "" end) + ": \(.text)" end' <<<"$sess"
    if [ -n "$name" ]; then
        afk_line "$name"
        printf 'AUTOMERGE %s\n' "$(jq -r '(.automerge // {}) as $a | "session \($a.session // "" | if . == "" then "off" else . end)" + ([($a.repos // {}) | to_entries[] | ", repository \(.key) \(.value)"] + [($a.lanes // {}) | to_entries[] | ", lane \(.key) \(.value)"] | join(""))' <<<"$sess")"
        n="$(jq '[(.decisions // [])[] | select(.seen != true)] | length' <<<"$sess")"
        [ "$n" -eq 0 ] || echo "DECIDED AND NOT SHOWN: $n (decide.sh digest, then decide.sh seen)"
    fi
    if [ -n "$name" ] && [ -f "$(session_dir)/$name.events.json" ]; then
        echo "OPEN EVENTS (notify.sh; each stays until its lane's facts change)"
        bash "$HERE/notify.sh" list --session "$name" 2>/dev/null | sed 's/^/  /'
    fi
    echo "STANDING ANSWERS"
    jq -r '(.standing // []) | if length == 0 then "  (none)" else .[] | "  #\(.id) \(.text)" end' <<<"$sess"
    fbline="$(bash "$HERE/feedback.sh" state --session "${name:-graph}" 2>/dev/null | awk '{print $2}')"
    if [ "$fbline" = on ]; then
        printf 'FEEDBACK LOOP: on (%s; feedback.sh show). Before each cleanup, collect feedback (cleanup.sh prints FEEDBACK lines).\n' "$(bash "$HERE/feedback.sh" show --json --session "${name:-graph}" 2>/dev/null | jq -r '[.lessons // [] | .[] | select(.used == null)] as $l | ([$l[] | select(.pr != null)] | length) as $w
            | "\(.notes // [] | length) notes, \(($l | length) - $w) open lessons" + (if $w > 0 then ", \($w) in a pull request not yet merged: feedback.sh used --ref once it merged, reopen --ref if it closed" else "" end)')"
    else
        echo "FEEDBACK LOOP: off (herdr-graph-engineering:feedback-loop turns it on)"
    fi
    # Standing kind and dialog choices stay where kind.sh (--remember) and section 4 keep them.
    scratch="$(jq -r '.scratch // ""' <<<"$sess")"
    [ -n "$scratch" ] || echo "  (scratch folder not recorded: standing kind and dialog choices in <scratch>/graph-kinds and <scratch>/graph-dialogs cannot be read; session.sh set --key scratch)"
    if [ -n "$scratch" ] && [ -s "$scratch/graph-kinds" ]; then
        echo "STANDING KINDS (role kind, from $scratch/graph-kinds)"
        sed 's/^/  /' "$scratch/graph-kinds"
    fi
    if [ -n "$scratch" ] && [ -s "$scratch/graph-dialogs" ]; then
        echo "STANDING DIALOGS (from $scratch/graph-dialogs)"
        sed 's/^/  /' "$scratch/graph-dialogs"
    fi
    echo "WAITING FOR THE USER (in the panel's NEEDS YOU; session.sh del --list needs --id N once done)"
    jq -r '(.needs // []) | if length == 0 then "  (none)" else .[] | "  #\(.id) \(.text)" + ([.prompts // [] | .[] | "\n    prompt: \(.)"] | join("")) end' <<<"$sess"
    for s in renames:RENAMES notes:NOTES files:FILES; do
        echo "${s#*:}"
        jq -r --arg k "${s%%:*}" '(.[$k] // []) | if length == 0 then "  (none)" else .[] | "  #\(.id) " + (if .lane then "\(.lane): " else "" end) + .text + (if .ref then " \(.ref)" else "" end) end' <<<"$sess"
    done
    echo "END RESUME"
}

text="$(render)"
if [ -n "$out" ]; then
    write_file "$out" "$text" || die "could not write $out"
fi
printf '%s\n' "$text"
