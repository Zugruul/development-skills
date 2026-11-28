#!/usr/bin/env bash
# section-ack.sh -- sourced by run-tests.sh; do not run standalone.
# Acknowledging an event: no reminder and no second message until the lane's facts really
# change (a new RESULT line, a new question, a new gate run, a status change). Answering a
# question acknowledges it.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr-graph-engineering/tests/run-tests.sh" >&2; exit 2; }

K_TMP="$(mktemp -d)"
K_REPO="$K_TMP/repo"
git init -q -b main "$K_REPO" && git -C "$K_REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
K_STATE_OLD="$XDG_STATE_HOME"; export XDG_STATE_HOME="$K_TMP/state"
K_CLOCK=2000000
ks() { local s="$1"; shift; (cd "$K_TMP" && PATH="$FIX/stub-herdr:$FIX/stub-gh:$PATH" HERDR_STUB_DIR="$K_TMP" GH_STUB_DIR="$K_TMP" HERDR_ENV=1 NO_COLOR=1 HERDR_GRAPH_CLOCK="$K_CLOCK" HERDR_GRAPH_NO_SIGNAL=1 bash "$PLUGIN/scripts/$s.sh" "$@"); }
ksm() { jq -c "$@" "$K_TMP/state.json" >"$K_TMP/state.new" && mv "$K_TMP/state.new" "$K_TMP/state.json"; }
K_EV="$XDG_STATE_HOME/herdr-graph/sessions/graph.events.json"
K_DIR="$K_REPO/.git/herdr-graph"
jq -cn '{agents: {o: {name: "graph", pane_id: "w1:p1", agent: "claude", agent_status: "working", state_change_seq: 1}}}' >"$K_TMP/state.json"
: >"$K_TMP/calls.log"
ks session set --key pane --value w1:p1 >/dev/null
ks session set --key orchestrator --value graph >/dev/null
# lane, status, screen
kagent() { ksm --arg l "$1" --arg s "$2" --arg t "$3" '.agents[$l] = {name: "claude-\($l)", pane_id: "w2-\($l):p1", agent: "claude", agent_status: $s, state_change_seq: ((.agents[$l].state_change_seq // 0) + 1), screen: $t}'; }
klane() { ks lane new --repo "$K_REPO" --lane "$1" --pattern investigate --idea x --owner graph >/dev/null
    ks lane node --repo "$K_REPO" --lane "$1" --node investigate --status running --agent "claude-$1" ${2:+--output "$2"} >/dev/null; }
krec() { ks notify reconcile --session graph >/dev/null 2>&1; }
ktake() { ks notify take --session graph 2>&1; }
kat() { K_CLOCK="$1"; krec; ktake; }
kack() { ks notify ack --session graph "$@" 2>&1; }
krecord() { ks lane node --repo "$K_REPO" --lane "$1" --node investigate --status running --note "$2" >/dev/null; }
kquiet() { local out; out="$(kat "$2")"; check "$1" "[]" "[$out]"; }

echo "== ack: an acknowledged event is quiet =="
klane a; klane z
kagent a idle 'NODE investigate RESULT: pass abc1111'; kagent z blocked ''
out="$(kat 2000000)"
check "delivered once" "a/investigate finished-pass" "$out"
out="$(kack --lane a --note "kept open on purpose")"; rc=$?
check_rc "ack succeeds" 0 "$rc"
check "and says what it acknowledged" "ACKED a/investigate finished-pass" "$out"
check_absent "only that lane's" "z/investigate" "$out"
check "list shows it with the note" "acknowledged: kept open on purpose" "$(ks notify list --session graph | grep '^a/')"
out="$(kat 2000400)"
check_absent "no reminder after 5 minutes" "a/" "$out"
check "while another event still has one" "z/investigate blocked (reminder 1)" "$out"
out="$(kat 2001000)"
check_absent "nor after 15" "a/" "$out"
check "never marked for manual intervention" "false" "$(jq -r '[.open[] | select(.lane == "a")][0].manual' "$K_EV")"
krecord a "looked at it"
kquiet "writing the lane is no new fact: nothing is sent again" 2001100
check "still listed as acknowledged" "acknowledged" "$(ks notify list --session graph | grep '^a/')"
kagent a idle 'NODE investigate RESULT: pass abc2222'
check "a new RESULT line is a new event" "a/investigate finished-pass" "$(kat 2001200)"

echo "== ack: what it matches =="
out="$(kack --lane z --reason stopped)"; rc=$?
check_rc "no such event: exit 1" 1 "$rc"
check "and says so" "NOTHING TO ACK" "$out"
out="$(kack --lane z --node other)"; rc=$?
check_rc "nor for another node" 1 "$rc"
out="$(kack --lane z --node investigate --reason blocked)"
check "lane, node and reason together" "ACKED z/investigate blocked" "$out"
ks notify ack --session graph >/dev/null 2>&1; rc=$?
check_rc "a lane is required" 2 "$rc"

echo "== ack: a status change ends it =="
kagent z working ''; krec
kagent z blocked ''
check "blocked again after working is a new event" "z/investigate blocked" "$(kat 2001400)"
kack --lane z >/dev/null
ks lane node --repo "$K_REPO" --lane z --node investigate --status waiting >/dev/null; krec
krecord z "again"
check "recorded as waiting, then running: a new event" "z/investigate blocked" "$(kat 2001600)"
ks lane close --repo "$K_REPO" --lane z >/dev/null; ks lane close --repo "$K_REPO" --lane a >/dev/null; krec

echo "== ack: a stopped agent =="
klane s; kagent s idle 'thinking'
K_CLOCK=2002000; krec
check "stopped" "s/investigate stopped" "$(kat 2002040)"
kack --lane s >/dev/null
kquiet "acknowledged: no reminder" 2002400
kagent s done 'thinking'
kquiet "seen by the user (idle to done) is no change" 2002460
kagent s working ''; krec
kagent s idle 'thinking more'
K_CLOCK=2002600; krec
check "it worked and stopped again: a new event" "s/investigate stopped" "$(kat 2002640)"
ks lane close --repo "$K_REPO" --lane s >/dev/null; krec

echo "== ack: answering a question acknowledges it =="
klane q "$K_TMP/q.md"
qrun="$(ks lane show --repo "$K_REPO" --lane q --json | jq -r .nodes.investigate.run)"
qfile() { jq -cn --arg r "$qrun" '{node: "investigate", run: $r, result: "question", ref: "q.md", final: true}' >"$K_TMP/q.md.result.json"; touch -t "$1" "$K_TMP/q.md.result.json"; }
qanswer() { # ask the user, record their answer
    local id
    id="$(ks lane ask --repo "$K_REPO" --lane q --node investigate --text "$1" | awk '{print $2}')"
    ks lane asked --repo "$K_REPO" --lane q --id "$id" >/dev/null
    ks lane answer --repo "$K_REPO" --lane q --id "$id" --text yes >/dev/null
}
qfile 202601010101
kagent q idle ''
check "the question is an event" "q/investigate question" "$(kat 2003000)"
qanswer "UTC?"
kquiet "answered: not sent again, though the agent's evidence is still there" 2003100
kquiet "and no reminder" 2003500
kagent q working ''; krec
kagent q idle ''
kquiet "the same old result file stays answered after the agent worked" 2003600
qfile 202601010202
check "a result file written again is a new question" "q/investigate question" "$(kat 2003700)"
ks lane close --repo "$K_REPO" --lane q >/dev/null; krec

echo "== ack: an answered question on the screen =="
klane r
kagent r idle 'NODE investigate RESULT: question r.md'
check "a screen question" "r/investigate question" "$(kat 2004000)"
id="$(ks lane ask --repo "$K_REPO" --lane r --node investigate --text "which?" | awk '{print $2}')"; krec
ks lane asked --repo "$K_REPO" --lane r --id "$id" >/dev/null
ks lane answer --repo "$K_REPO" --lane r --id "$id" --text this >/dev/null
kquiet "answered before the agent was told: quiet" 2004100
kagent r working ''; krec
kagent r idle 'NODE investigate RESULT: question r.md'
check "asked again after it worked: a new question" "r/investigate question" "$(kat 2004300)"
ks lane close --repo "$K_REPO" --lane r >/dev/null; krec

echo "== ack: a hook's question =="
klane h
hrun="$(ks lane show --repo "$K_REPO" --lane h --json | jq -r .nodes.investigate.run)"
hclaim() { mkdir -p "$K_DIR/claims/h"; jq -cn --arg r "$hrun" --arg at "$1" '{run: $r, source: "stop-hook", at: $at, kind: "result", result: "question", ref: "h.md"}' >"$K_DIR/claims/h/investigate.json"; }
hclaim 2026-11-26T10:00:00Z; kagent h idle ''
check "a hook question" "h/investigate question" "$(kat 2005000)"
check "ack takes it" "ACKED h/investigate question" "$(kack --lane h)"
hclaim 2026-11-26T11:00:00Z
check "a later turn's question is new" "h/investigate question" "$(kat 2005200)"
ks lane close --repo "$K_REPO" --lane h >/dev/null; krec

echo "== ack: merged early, kept open =="
klane m; kagent m working ''
ks lane ask --repo "$K_REPO" --lane m --kind merged-early --text "PR 1 merged early. Keep the lane?" >/dev/null
check "merged-early is sent" "m/- merged-early" "$(kat 2006000)"
check "ack takes it" "ACKED m/- merged-early" "$(kack --lane m --reason merged-early)"
ks lane note --repo "$K_REPO" --lane m --text "kept open" >/dev/null
kquiet "no reminder" 2006400
kquiet "nor the second" 2007000
ks lane withdraw --repo "$K_REPO" --lane m --kind merged-early >/dev/null; krec
ks lane ask --repo "$K_REPO" --lane m --kind merged-early --text "PR 2 merged early. Keep the lane?" >/dev/null
check "a new question is a new event" "m/- merged-early" "$(kat 2007100)"
ks lane close --repo "$K_REPO" --lane m >/dev/null; krec

echo "== ack: a stalled gate, until a new run =="
ks lane new --repo "$K_REPO" --lane g --pattern solo --idea x --gate true --owner graph >/dev/null
ks lane node --repo "$K_REPO" --lane g --node impl --status "done" --result pass >/dev/null
ks lane node --repo "$K_REPO" --lane g --node tests --status running >/dev/null
sleep 60 >/dev/null 2>&1 & idle_pid=$!
mkdir -p "$K_DIR/gates/g"; echo "ok   one" >"$K_DIR/gates/g/tests.log"; touch -t 202001010000 "$K_DIR/gates/g/tests.log"
kgate() { jq -cn --arg r "$1" --arg log "$K_DIR/gates/g/tests.log" --argjson p "$idle_pid" '{lane: "g", node: "tests", run: $r, pane: "w1:p2", pid: $p, log: $log, started: 1, finished: false}' >"$K_DIR/gates/g/tests.json"; }
kgate 1
check "stalled" "g/tests gate-stalled" "$(kat 2008000)"
kack --lane g >/dev/null
kquiet "acknowledged" 2008400
kgate 2
check "a new gate run that stalls is a new event" "g/tests gate-stalled" "$(kat 2008500)"
kill "$idle_pid" 2>/dev/null; wait "$idle_pid" 2>/dev/null

rm -rf "$K_TMP"
export XDG_STATE_HOME="$K_STATE_OLD"
unset -f ks ksm kagent klane krec ktake kat kack krecord kquiet qfile qanswer hclaim kgate
