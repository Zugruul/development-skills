#!/usr/bin/env bash
# src/events.sh -- sourced by notify.sh after common.sh, afk.sh and panes.sh; not run by itself.
# The events of one session: what the facts say now (reconcile), what is pending (take), and the
# push fallback. The state file is only ever written under its own lock.
# shellcheck disable=SC2016

clock() { printf '%s\n' "${HERDR_GRAPH_CLOCK:-$(date +%s)}"; }

STOP_HOLD="${HERDR_GRAPH_STOP_HOLD:-30}" REARM="${HERDR_GRAPH_REARM:-60}"
REMIND_1="${HERDR_GRAPH_REMIND_1:-300}" REMIND_2="${HERDR_GRAPH_REMIND_2:-900}"
SWEEP="${HERDR_GRAPH_SWEEP:-300}" PUSH_GAP="${HERDR_GRAPH_PUSH_GAP:-60}"
# how old a finished agent's screen read may be: 0 after an event (read now); the panel's tick raises it
DRIFT_AGE=0

events_file() { printf '%s/%s.events.json\n' "$(session_dir)" "$1"; }

sessions() { # every session that has a pane
    local f
    for f in "$(session_dir)"/*.yaml; do
        [ -f "$f" ] || continue
        [ -z "$(yq -r '.pane // ""' "$f" 2>/dev/null)" ] || basename "$f" .yaml
    done
}

orchestrator_name() { # session
    session_json "$1" | jq -r --arg s "$1" 'if (.orchestrator // "") != "" then .orchestrator else $s end'
}

# The live agent that is this session's orchestrator: its pane AND its name still match, so a
# message never reaches another agent that took the name, or whatever runs in the pane now.
orchestrator_agent() { # session -> the agent's JSON
    local pane name list
    pane="$(session_json "$1" | jq -r '.pane // ""')" name="$(orchestrator_name "$1")"
    [ -n "$pane" ] && command -v herdr >/dev/null 2>&1 || return 1
    list="$(herdr agent list 2>/dev/null)" || return 1
    jq -ce --arg p "$pane" --arg n "$name" '[.result.agents[]? | select(.pane_id == $p and .name == $n)][0] // empty' <<<"$list" 2>/dev/null
}

state_read() { # session
    local s
    s="$(jq -c 'objects' "$(events_file "$1")" 2>/dev/null)" || s=""
    jq -c '{open: {}, sent: {}, swept_at: 0, last_push: 0, notifications: "", gone_told: false, draft_told: false, acks: {}} + .' <<<"${s:-{\}}"
}

# Change the state under its lock: jq program (input: the state), extra jq args.
STATE_LOCK=""
state_lock() { # session
    local tries=0 pid
    STATE_LOCK="$(events_file "$1").lock"
    mkdir -p "$(session_dir)"
    while ! mkdir "$STATE_LOCK" 2>/dev/null; do
        pid="$(cat "$STATE_LOCK/pid" 2>/dev/null)"
        if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then rm -rf "$STATE_LOCK"; continue; fi
        tries=$((tries + 1))
        [ "$tries" -lt 200 ] || return 1
        sleep 0.05
    done
    printf '%s\n' "$$" >"$STATE_LOCK/pid"
}
state_unlock() { [ -n "$STATE_LOCK" ] && rm -rf "$STATE_LOCK"; STATE_LOCK=""; }
state_write() { # session, state JSON
    local f
    f="$(events_file "$1")"
    printf '%s\n' "$2" >"$f.$$" && mv "$f.$$" "$f"
}
state_change() { # session, jq program, jq args...
    local s="$1" prog="$2" out
    shift 2
    state_lock "$s" || return 1
    out="$(state_read "$s" | jq -c "$@" "$prog")" && state_write "$s" "$out"
    state_unlock
}

# A notification to the user. Herdr can show nothing and still exit 0 (notifications are off by
# default): that is remembered and said.
user_notify() { # session, title, body
    local out
    command -v herdr >/dev/null 2>&1 || return 0
    out="$(herdr notification show "$2" --body "$3" --sound request 2>/dev/null)" || out=""
    if [ "$(jq -r '.result.shown // empty | tostring' <<<"$out" 2>/dev/null)" = true ]; then
        state_change "$1" '.notifications = "on"'
    elif jq -e '.result.shown == false' >/dev/null 2>&1 <<<"$out"; then
        state_change "$1" '.notifications = "off"'
    fi
}

sweep_due() { # session
    [ $(($(clock) - $(state_read "$1" | jq -r .swept_at))) -ge "$SWEEP" ]
}

# The sweep: what no event reports. Pull requests, merges (cleanup.sh check, which only asks),
# and what auto-merge could merge now. Prints the merge-ready conditions as JSON.
sweep_facts() { # session, owned lanes view
    local s="$1" root lane out ready='[]'
    while IFS=$'\t' read -r root lane; do
        [ -n "$lane" ] || continue
        bash "$HERE/cleanup.sh" check --repo "$root" --lane "$lane" --session "$s" >/dev/null 2>&1
    done < <(jq -r '.[] | select(.section != "closed" and (.status == "done" or .cleanup != "" or .pr_merged != null or .recorded_pr != "" or .pattern == "review" or any(.prs[]; .state == "MERGED")
                    or any((.questions // [])[]; .kind == "merged-early"))) | [.root, .lane] | @tsv' <<<"$2")
    while IFS=$'\t' read -r root lane; do
        [ -n "$lane" ] || continue
        case "$(automerge_state "$s" "$root" "$lane")" in "on "*) ;; *) continue ;; esac
        out="$(bash "$HERE/merge.sh" check --repo "$root" --lane "$lane" --session "$s" 2>/dev/null)" || continue
        ready="$(jq -c --arg r "$root" --arg l "$lane" --arg h "${out##* }" --argjson v "$2" \
            '. + [{repo: $r, lane: $l, node: "", reason: "merge-ready", run: "", rev: 0, ref: $h, deliver: true,
                   lane_history: ([$v[] | select(.root == $r and .lane == $l) | .history][0])}]' <<<"$ready")"
    done < <(jq -r '.[] | select(.section != "closed" and .recorded_pr != "" and all(.nodes[]; .status == "done" or .status == "skipped")) | [.root, .lane] | @tsv' <<<"$2")
    printf '%s\n' "$ready"
}

# Acknowledged events (notify.sh ack, lane.sh answer) are kept in .acks by their fact: what
# happened, without the lane's record count, so writing the lane brings nothing back. A question
# of the lane's is its id. A node's event is its run, its ref and its stamp: when the evidence
# was written (a hook claim, a result file) or the gate's run.
# holds: an acknowledgement of a node's event ends when the node leaves running and blocked or
# gets a new run; one whose evidence has no stamp (a screen, Herdr's state) also when the agent
# is seen working again, or blocked after something else.
ACK_JQ='
    def fp: if (.drift != true) and ((.ref // "") | test("^q[0-9]+$")) then [.repo, .lane, "q", .ref] | join("|")
            else [.repo, .lane, .node, .reason, (.run // ""), (.ref // ""), (.stamp // "")] | join("|") end;
    def holds($view): . as $a
        | ($a.drift != true)
          or (([$view[] | select(.root == $a.repo and .lane == $a.lane) | .nodes[] | select(.node == $a.node)][0]) as $n
              | $n == null
                or (($n.status | IN("running", "blocked")) and (($a.run // "") == "" or $n.run == $a.run)
                    and (($a.stamp // "") != "" or ($n.live != "working" and ($n.live != "blocked" or $a.reason == "blocked")))));
    def ackof($note; $now): {repo, lane, node, reason, run: (.run // ""), stamp: (.stamp // ""), drift: (.drift // false), note: $note, at: $now};
    def capacks: .acks |= (to_entries | sort_by(.value.at) | .[-200:] | from_entries);'

# Mark the open events of a lane handled. Prints each; fails when none matches.
ack_events() { # session, lane, node or "" (every node; "-": the lane's own), reason or "", note
    local found
    state_lock "$1" || return 1
    found="$(state_read "$1" | jq -c --arg l "$2" --arg n "$3" --arg r "$4" \
        '[.open[] | select(.lane == $l and ($n == "" or .node == (if $n == "-" then "" else $n end)) and ($r == "" or .reason == $r))]')"
    if [ "$(jq length <<<"$found")" -eq 0 ]; then
        state_unlock
        return 1
    fi
    state_write "$1" "$(state_read "$1" | jq -c --argjson f "$found" --arg note "$5" --argjson now "$(clock)" "$ACK_JQ"'
        reduce $f[] as $e (.; .acks[$e.fp // $e.key] = ($e | ackof($note; $now))
            | .open[$e.key] |= (.acked = true | .ack_note = $note | .delivered_at //= $now | .due = false | .notify_due = false | .manual = false))
        | capacks')"
    state_unlock
    jq -r '.[] | "ACKED \(.lane)/\(if .node != "" then .node else "-" end) \(.reason)"' <<<"$found"
}

# The user's answer to a node's question (lane.sh answer) acknowledges the claim that asked it,
# for the lane's owner. The claim is read like drift.sh reads it (hook claim, then result file).
# A screen's claim leaves the cache while the node is blocked: then the session's own record
# of the question event, open or closed, says what was asked.
answered_event() { # repo, lane, node
    local f dir run output owner entry root claim s ack=""
    f="$(lane_file "$1" "$2")" dir="$(lane_dir "$1")"
    [ -f "$f" ] || return 0
    owner="$(yq -r '.owner // ""' "$f")" run="$(yq -r ".nodes[\"$3\"].run // \"\"" "$f")"
    output="$(yq -r ".nodes[\"$3\"].output // \"\"" "$f")"
    claim="$(jq -c --arg r "$run" 'select(.run == $r and (.kind | IN("none", "permission") | not)) | .stamp = (.at // "")' "$(claim_file "$dir" "$2" "$3")" 2>/dev/null)"
    [ -n "$claim" ] || claim="$(file_claim "$3" "$run" "$output")"
    entry="$(repo_entry "$1")" && root="${entry#*$'\t'}"
    [ -z "$claim" ] || ack="$(jq -c --arg repo "${root:-$1}" --arg l "$2" --arg n "$3" --arg run "$run" '
        select(.kind == "question" or .result == "question")
        | {repo: $repo, lane: $l, node: $n, reason: "question", run: $run, ref: (.ref // ""), stamp: (.stamp // ""), drift: true}' <<<"$claim")"
    for s in $(sessions); do
        [ "$(orchestrator_name "$s")" = "$owner" ] || continue
        state_change "$s" "$ACK_JQ"'
            (if $e != null then $e
             else [(.open + .sent)[] | select(.repo == $repo and .lane == $l and .node == $n and .reason == "question" and .run == $run)]
                  | max_by(.first_seen) end) as $q
            | if $q == null then . else .acks[$q | fp] = ($q | ackof("answered"; $now)) | capacks end' \
            --argjson e "${ack:-null}" --arg repo "${root:-$1}" --arg l "$2" --arg n "$3" --arg run "$run" --argjson now "$(clock)"
    done
}

# What the facts say needs the orchestrator or the user now, one object per condition.
CONDITIONS_JQ='
    [ .[] | . as $l | {repo: .root, lane: .lane} as $at
      | ( (.nodes[] | select(.drift != null and .drift.kind != "step-pass")
             | $at + {node: .node, run: .run, rev: .rev, deliver: true, drift: true, stamp: (.drift.stamp // ""),
                      reason: (.drift.kind | if . == "pass" then "finished-pass" elif . == "fail" then "finished-fail" else . end),
                      ref: (if .drift.kind == "gate-stalled" then "" else (.drift.ref // "") end)}),
          ( (.questions // [])[]
             | $at + {node: (.node // ""), run: "", rev: 0, ref: "q\(.id)"}
               + (if .asked_at == null and (.kind == "cleanup" or .kind == "merged-early" or .kind == "retry-limit") then
                      {deliver: true, reason: (if .kind == "cleanup" then (if ($l.cleanup | startswith("blocked")) then "cleanup-blocked" else "cleanup-ready" end) else .kind end)}
                  else {deliver: false, reason: "awaiting-user"} end)),
          ( select(.cleanup == "feedback-due") | $at + {node: "", run: "", rev: 0, ref: "", reason: "feedback-due", deliver: true} ),
          ( select(.cleanup == "confirmed") | $at + {node: "", run: "", rev: 0, ref: "", reason: "cleanup-confirmed", deliver: true} ) ) ]'

reconcile() { # session, full
    local s="$1" full="$2" sdir rescan lock pid n=0
    sdir="$(session_dir)"
    rescan="$sdir/$s.rescan" lock="$sdir/$s.scan"
    mkdir -p "$sdir"
    # one scan at a time; a signal that arrives during one is not lost: the scan runs again
    if ! mkdir "$lock" 2>/dev/null; then
        pid="$(cat "$lock/pid" 2>/dev/null)"
        if [ -z "$pid" ] || kill -0 "$pid" 2>/dev/null; then
            [ -z "$(find "$lock" -maxdepth 0 -mmin +10 2>/dev/null)" ] || rm -rf "$lock"
            : >"$rescan"
            return 0
        fi
        rm -rf "$lock"
        mkdir "$lock" 2>/dev/null || return 0
    fi
    printf '%s\n' "$$" >"$lock/pid"
    while [ "$n" -lt 3 ]; do
        rm -f "$rescan"
        scan "$s" "$full"
        [ -f "$rescan" ] || break
        n=$((n + 1)) full=0
    done
    rm -rf "$lock"
}

owned_view() { # orchestrator name
    local v
    v="$(bash "$HERE/status.sh" --json 2>/dev/null)" || v='[]'
    jq -c --arg o "$1" '[.[] | select(.owner == $o and .section != "closed")]' <<<"${v:-[]}"
}

scan() { # session, full
    local s="$1" full="$2" name view merges="" now before added roots
    name="$(orchestrator_name "$s")"
    view="$(owned_view "$name")"
    if [ "$full" -eq 1 ]; then
        roots="$(jq -r '[.[].root] | unique | .[]' <<<"$view")"
        if [ -n "$roots" ]; then
            local args=()
            while IFS= read -r r; do args+=(--repo "$r"); done <<<"$roots"
            bash "$HERE/prs.sh" fetch --max-age 60 "${args[@]}" >/dev/null 2>&1
        fi
    fi
    bash "$HERE/drift.sh" --quiet --max-age "$DRIFT_AGE" >/dev/null 2>&1
    view="$(owned_view "$name")"
    if [ "$full" -eq 1 ]; then
        merges="$(sweep_facts "$s" "$view")"
        view="$(owned_view "$name")"
    fi
    index_panes "$view"
    now="$(clock)"
    state_lock "$s" || return 0
    before="$(state_read "$s")"
    # shellcheck disable=SC2046
    added="$(jq -c --argjson now "$now" --argjson view "$view" --argjson merges "${merges:-null}" --argjson rearm "$REARM" \
        --argjson r1 "$REMIND_1" --argjson r2 "$REMIND_2" "
        def conditions: \$view | $CONDITIONS_JQ;
        $ACK_JQ"'
        def key: [.repo, .lane, .node, .reason, .run, (.rev | tostring), .ref] | join("|");
        # an acknowledgement ends with a status change; its record in sent goes with it
        (.acks | with_entries(select(.value | holds($view)))) as $acks
        | ((.acks | keys) - ($acks | keys)) as $ended
        | .acks = $acks
        | .sent |= with_entries(select((.value.fp // "") as $f | $ended | index($f) == null))
        | . as $st
        # a merge-ready event is only recomputed by the sweep; between sweeps it stays while its lane is not written
        | (conditions + (if $merges != null then $merges
              else [$st.open[] | select(.reason == "merge-ready") | . as $e
                    | select(any($view[]; .root == $e.repo and .lane == $e.lane and .history == $e.lane_history))
                    | {repo, lane, node, reason, run: "", rev: 0, ref, deliver: true, lane_history}] end)) as $c
        | ($c | map(.fp = fp | {(key): .}) | add // {}) as $want
        # a gate that recorded itself stays until its lane is written again
        | ($st.open | with_entries(select(.value.history != null
              and (.value as $e | any($view[]; .root == $e.repo and .lane == $e.lane and .history == $e.history))))) as $gates
        | ($st.open | with_entries(select((.key | in($want) | not) and (.key | in($gates) | not)))) as $closed
        | .sent = ((.sent + ($closed | with_entries(.value = (.value + {closed_at: $now}))))
                   | to_entries | sort_by(.value.closed_at) | .[-200:] | from_entries)
        | .sent as $sent
        # an acknowledged event with new evidence under the same key is a new one
        | def same($v): . != null and (.acked != true or .fp == $v.fp);
          .open = ($gates + ($want | with_entries(.key as $k | .value as $v
              | .value = (if ($st.open[$k] | same($v)) then $st.open[$k] + {fp: $v.fp, drift: ($v.drift // false), stamp: ($v.stamp // "")}
                          elif ($sent[$k] | same($v)) and ($now - $sent[$k].closed_at) < $rearm then ($sent[$k] | del(.closed_at))
                          else $v + {key: $k, first_seen: $now, delivered_at: null, reminders: 0, due: false, notify_due: false, manual: false} end))))
        | .sent |= (. as $m | with_entries(select(.key | in($want) | not)))
        | if $merges != null then .swept_at = $now else . end
        | .open |= with_entries(.value |= (
              if $acks[.fp // .key] != null then
                  .acked = true | .ack_note = $acks[.fp // .key].note | .delivered_at //= $now
                  | .due = false | .notify_due = false | .manual = false
              else del(.acked, .ack_note) end))
        | .open |= with_entries(.value |= if .acked then . else (
              (if .deliver then .delivered_at else .first_seen end) as $base
              | if $base == null then . else
                  (if ($now - $base) >= $r2 then 2 elif ($now - $base) >= $r1 then 1 else 0 end) as $level
                  | (if $level > .reminders then .reminders = $level | .due = .deliver | .notify_due = true else . end)
                  # the second reminder is the last: with it the lane needs the user by hand
                  | (if $level == 2 then .manual = true else . end)
                end) end)
    ' <<<"$before")" || { state_unlock; return 1; }
    state_write "$s" "$added"
    state_unlock
    remind_user "$s"
    # the panel redraws after a real change
    if [ "$(jq -c '.open | keys' <<<"$before")" != "$(jq -c '.open | keys' <<<"$added")" ] && command -v herdr >/dev/null 2>&1; then
        bash "$HERE/panel-action.sh" refresh >/dev/null 2>&1 || true
    fi
}

# The reminders due to the user, as one notification per lane.
remind_user() { # session
    local lane what
    while IFS=$'\t' read -r lane what; do
        [ -n "$lane" ] || continue
        user_notify "$1" "$lane needs you" "herdr-graph, unhandled: $what"
    done < <(state_read "$1" | jq -r '[.open[] | select(.notify_due)] | group_by(.lane)[] | [.[0].lane, (map("\(if .node != "" then .node else "lane" end) \(.reason)") | join(", "))] | @tsv')
    state_change "$1" '.open |= with_entries(.value.notify_due = false)'
}

# Which pane each running node's agent is in, for the hooks.
index_panes() { # owned lanes view
    local list pane root lane node agent
    list="$(herdr agent list 2>/dev/null)" || return 0
    while IFS=$'\t' read -r pane root lane node agent; do
        [ -n "$pane" ] && pane_lane_set "$pane" "$root" "$lane" "$node" "$agent"
    done < <(jq -r --argjson v "$1" '(reduce .result.agents[]? as $a ({}; .[$a.name // ""] = ($a.pane_id // ""))) as $p
        | $v[] | .root as $r | .lane as $l | .nodes[] | select(.agent != "" and (.status == "running" or .status == "blocked") and ($p[.agent] // "") != "")
        | [$p[.agent], $r, $l, .node, .agent] | @tsv' <<<"$list" 2>/dev/null)
}

PENDING_JQ='[.open[] | select(.deliver and (.acked | not) and (.due or (.delivered_at == null and (.reason != "stopped" or ($now - .first_seen) >= $hold))))]'

pending_list() { # session -> JSON array
    state_read "$1" | jq -c --argjson now "$(clock)" --argjson hold "$STOP_HOLD" "$PENDING_JQ"
}

pending() { # session: reminders brought up to date from the stored times
    [ "$(pending_list "$1" | jq length)" -gt 0 ]
}

# One line: the fixed prefix, then lane and node names (cut to safe characters) and fixed reason
# codes only. How to handle it is the orchestrate skill's, not the message's.
message() { # pending JSON
    jq -r --arg p "$EVENT_PREFIX" 'def safe: gsub("[^A-Za-z0-9._-]"; "") | .[0:40];
        $p + ([.[] | "\(.lane | safe)/\(if .node != "" then .node | safe else "-" end) \(.reason | safe)"
             + (if .delivered_at != null then " (reminder \(.reminders))" else "" end)] | join(", "))' <<<"$1"
}

mark_delivered() { # session, pending JSON
    state_change "$1" 'reduce $keys[] as $k (.; if .open[$k] != null then .open[$k] |= (.due = false | .delivered_at //= $now) else . end)' \
        --argjson keys "$(jq -c '[.[].key]' <<<"$2")" --argjson now "$(clock)"
}

take() { # session
    local p
    p="$(pending_list "$1")"
    [ "$(jq length <<<"$p")" -gt 0 ] || return 1
    message "$p"
    mark_delivered "$1" "$p"
}

waiter_alive() { # session
    local base pid
    base="$(session_dir)/$1"
    pid="$(cat "$base.waiter" 2>/dev/null)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ -z "$(find "$base.beat" -mmin +3 2>/dev/null)" ] && [ -f "$base.beat" ]
}

# Whether the client's input box on this screen (with its styles) is recognisably empty: the last
# prompt glyph has nothing after it but dim placeholder text. Claude's box sits under a rule.
# Anything else (a draft, a dialog, an unknown screen) is not: unsure means no push.
box_empty() { # screen text with ANSI styles, client kind
    printf '%s' "$1" | jq -Rse --arg kind "$2" '
        def plain: gsub("\u001b\\[[0-9;?]*[A-Za-z]"; "") | gsub("\u001b\\][^\u0007\u001b]*(\u0007|\u001b\\\\)"; "") | gsub("\r"; "");
        def undim: gsub("\u001b\\[2m.*?(\u001b\\[(0|22)?m|$)"; "");
        [split("\n")[]] as $lines
        | ([range(0; $lines | length) as $i | select($lines[$i] | plain | test("^\\s*[❯›]")) | $i] | last) as $at
        | $at != null
          and ($lines[$at] | undim | plain | test("^\\s*[❯›][\\s ]*$"))
          and ($kind != "claude" or ($at > 0 and ($lines[$at - 1] | plain | test("^[\\s╭─]*───"))
               and (($lines[$at + 1] // "───") | plain | test("^[\\s╰─]*───"))))' >/dev/null 2>&1
}

# A click on a prompt line of the orchestrator's NEEDS YOU entry (the panel): put that text in
# the orchestrator's input box, never submitted. Only into the recorded orchestrator pane, only
# while it is idle or done. The box is cleared with Ctrl+E (end of line) and Ctrl+U (delete to
# the line's start), which Claude Code, Codex and OpenCode all document; a further pair per
# extra line. Never Ctrl+C or Esc: they can exit a client or interrupt a turn. Claude Code and
# Codex must then show a recognisably empty box (box_empty), or nothing is typed; OpenCode's
# box cannot be recognised, so it gets CLEAR_ROUNDS pairs and the user is told to check.
# Prints one short line (the panel shows it); exit 0 only when the text was typed.
CLEAR_ROUNDS=20
orchestrator_ready() { # session -> READY_AGENT; says why not
    local status
    READY_AGENT="$(orchestrator_agent "$1")" || { echo "not typed: orchestrator not in its pane"; return 1; }
    status="$(jq -r '.agent_status // "unknown"' <<<"$READY_AGENT")"
    case "$status" in idle | done) ;; *) echo "not typed: the orchestrator is $status"; return 1 ;; esac
}
orchestrator_screen() { # agent name -> its visible screen, with styles
    local text
    text="$(herdr agent read "$1" --source visible --lines 40 --ansi 2>/dev/null)" || text=""
    if jq -e 'type == "object"' >/dev/null 2>&1 <<<"$text"; then
        text="$(jq -r '((.result | objects) // {}) as $r | [$r.text, $r.content, $r.output] | map(strings) | .[0] // ""' <<<"$text")"
    fi
    printf '%s' "$text"
}
type_prompt() { # session, entry id, prompt number (from 0)
    local s="$1" text pane name kind i=0 cleared=0
    text="$(session_json "$s" | jq -r --argjson id "$2" --argjson n "$3" '.needs // [] | .[] | select(.id == $id) | .prompts[$n] // empty')"
    [ -n "$text" ] || { echo "not typed: that prompt is gone"; return 1; }
    orchestrator_ready "$s" || return 1
    pane="$(jq -r .pane_id <<<"$READY_AGENT")" name="$(jq -r .name <<<"$READY_AGENT")" kind="$(jq -r '.agent // ""' <<<"$READY_AGENT")"
    while [ "$i" -lt "$CLEAR_ROUNDS" ]; do
        # checked before every keystroke: a turn may start, or the pane may change hands
        [ "$i" -eq 0 ] || orchestrator_ready "$s" || return 1
        herdr pane send-keys "$pane" ctrl+e ctrl+u >/dev/null 2>&1 || { echo "not typed: herdr could not send keys"; return 1; }
        i=$((i + 1))
        case "$kind" in
            claude | codex)
                sleep "${HERDR_GRAPH_KEY_WAIT:-0.1}"
                if box_empty "$(orchestrator_screen "$name")" "$kind"; then cleared=1; break; fi ;;
        esac
    done
    case "$kind" in claude | codex) [ "$cleared" -eq 1 ] || { echo "not typed: the input box did not clear"; return 1; } ;; esac
    orchestrator_ready "$s" || return 1
    herdr pane send-text "$pane" "$text" >/dev/null 2>&1 || { echo "not typed: herdr could not send the text"; return 1; }
    if [ "$cleared" -eq 1 ]; then echo "typed: press Enter there"; else echo "typed: check the box, then press Enter"; fi
}

push() { # session
    local s="$1" p agent status name screen_text out
    ! waiter_alive "$s" || return 0
    p="$(pending_list "$s")"
    [ "$(jq length <<<"$p")" -gt 0 ] || return 0
    [ $(($(clock) - $(state_read "$s" | jq -r .last_push))) -ge "$PUSH_GAP" ] || return 0
    if ! agent="$(orchestrator_agent "$s")"; then
        if [ "$(state_read "$s" | jq -r .gone_told)" != true ]; then
            state_change "$s" '.gone_told = true'
            user_notify "$s" "graph orchestrator not found" "$(jq length <<<"$p") events wait for it; they are kept. Start it again, or run resume.sh."
        fi
        return 0
    fi
    state_change "$s" '.gone_told = false'
    status="$(jq -r '.agent_status // "unknown"' <<<"$agent")" name="$(jq -r .name <<<"$agent")"
    # blocked: a dialog is open; working: its turn end delivers (its idle event, or its waiter)
    case "$status" in idle | done) ;; *) return 0 ;; esac
    screen_text="$(orchestrator_screen "$name")"
    if ! box_empty "$screen_text" "$(jq -r '.agent // ""' <<<"$agent")"; then
        if [ "$(state_read "$s" | jq -r .draft_told)" != true ]; then
            state_change "$s" '.draft_told = true'
            user_notify "$s" "graph events are waiting" "Not typed into the orchestrator: its input box holds a draft or cannot be read. $(jq -r '[.[] | "\(.lane) \(.reason)"] | join(", ")' <<<"$p")"
        fi
        return 0
    fi
    out="$(herdr agent prompt "$name" "$(message "$p")" 2>&1)" || return 0
    mark_delivered "$s" "$p"
    state_change "$s" '.last_push = $now | .draft_told = false' --argjson now "$(clock)"
}

list_events() { # session
    state_read "$1" | jq -r --argjson now "$(clock)" '
        (if .notifications == "off" then "Herdr notifications are off: reminders do not reach you (set [notifications] in Herdr'"'"'s config)." else empty end),
        (if (.open | length) == 0 then "No open events." else
           .open[] | "\(.lane)/\(if .node != "" then .node else "-" end) \(.reason)"
             + (if (.ref // "") != "" then " \(.ref | gsub("[\r\n]+"; " ") | .[0:200])" else "" end)
             + (if .acked then " [acknowledged" + (if (.ack_note // "") != "" then ": \(.ack_note | gsub("[\r\n]+"; " "))" else "" end)
                elif .delivered_at != null then " [delivered \($now - .delivered_at)s ago" elif .deliver then " [not delivered yet" else " [waits for the user, \($now - .first_seen)s" end)
             + (if .reminders > 0 then ", \(.reminders) reminders" else "" end) + (if .manual then ", needs manual intervention" else "" end) + "]" end)'
}

# A gate that ran in its tab recorded its own result, so no lane/agent mismatch remains: an
# event for the lane's owner, open until the lane is written again.
gate_event() { # repo, lane, node
    local f s owner entry root result history
    f="$(lane_file "$1" "$2")"
    [ -f "$f" ] || return 0
    owner="$(yq -r '.owner // ""' "$f")" history="$(yq -r '.history | length' "$f")"
    result="$(yq -r ".nodes[\"$3\"].result // \"fail\"" "$f")"
    entry="$(repo_entry "$1")" && root="${entry#*$'\t'}"
    for s in $(sessions); do
        [ "$(orchestrator_name "$s")" = "$owner" ] || continue
        state_change "$s" '.open[$k] = {key: $k, fp: $k, repo: $r, lane: $l, node: $n, reason: ("gate-" + $res), ref: "", run: "", rev: 0, history: $h,
                deliver: true, first_seen: $now, delivered_at: null, reminders: 0, due: false, notify_due: false, manual: false}' \
            --arg k "${root:-$1}|$2|$3|gate|$history" --arg r "${root:-$1}" --arg l "$2" --arg n "$3" --arg res "$result" --argjson h "$history" --argjson now "$(clock)"
        [ -n "${HERDR_GRAPH_NO_SIGNAL:-}" ] || push "$s"
    done
}
