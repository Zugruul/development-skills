#!/usr/bin/env bash
# section-notify.sh -- sourced by run-tests.sh; do not run standalone.
# Waking the orchestrator: one event per real change, delivered by the waiter, else pushed only
# onto an empty input box; never an agent's text; reminders, then "needs manual intervention".
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr-graph-engineering/tests/run-tests.sh" >&2; exit 2; }

N_TMP="$(mktemp -d)"
N_REPO="$N_TMP/repo"
git init -q -b main "$N_REPO" && git -C "$N_REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
N_STATE_OLD="$XDG_STATE_HOME"; export XDG_STATE_HOME="$N_TMP/state"
export N_CLOCK=1000000
ns() { local s="$1"; shift; (cd "$N_TMP" && PATH="$FIX/stub-herdr:$FIX/stub-gh:$PATH" HERDR_STUB_DIR="$N_TMP" GH_STUB_DIR="$N_TMP" HERDR_ENV=1 NO_COLOR=1 HERDR_GRAPH_CLOCK="$N_CLOCK" HERDR_GRAPH_NO_SIGNAL=1 HERDR_GRAPH_PUSH_GRACE=0 bash "$PLUGIN/scripts/$s.sh" "$@"); }
nst() { printf '%s' "$1" >"$N_TMP/state.json"; : >"$N_TMP/calls.log"; }
nsm() { jq -c "$1" "$N_TMP/state.json" >"$N_TMP/state.new" && mv "$N_TMP/state.new" "$N_TMP/state.json"; }
N_EV="$XDG_STATE_HOME/herdr-graph/sessions/graph.events.json"
nev() { jq -r "$1" "$N_EV" 2>/dev/null; }
nrec() { ns notify reconcile --session graph >/dev/null 2>&1; }
ntake() { ns notify take --session graph 2>&1; }
BOX='transcript
────────────────────────
❯ 
────────────────────────'
nagent() { jq -cn --arg n "$1" --arg p "$2" --arg s "$3" --arg t "${4:-}" '{name: $n, pane_id: $p, agent: "claude", agent_status: $s, state_change_seq: 3, screen: $t}'; }
nstate() { jq -cn --argjson o "$(nagent graph w1:p1 "${1:-idle}" "${2:-$BOX}")" --argjson a "$(nagent claude-a w2:p1 "${3:-idle}" 'NODE investigate RESULT: pass abc1234')" --argjson b "$(nagent claude-b w3:p1 "${4:-working}" '')" '{agents: {o: $o, a: $a, b: $b}}'; }
nst "$(nstate)"
ns session set --key pane --value w1:p1 >/dev/null
ns session set --key orchestrator --value graph >/dev/null
nlane() { ns lane new --repo "$N_REPO" --lane "$1" --pattern investigate --idea x --owner "${2:-graph}" >/dev/null
    ns lane node --repo "$N_REPO" --lane "$1" --node investigate --status running --agent "claude-$1" >/dev/null; }
nlane a; nlane b
ns lane new --repo "$N_REPO" --lane theirs --pattern investigate --idea x --owner graph-2 >/dev/null
ns lane node --repo "$N_REPO" --lane theirs --node investigate --status running --agent claude-theirs >/dev/null

echo "== notify: one change, one event =="
nrec
check "a finished agent is an event" "a investigate finished-pass" "$(nev '.open[] | "\(.lane) \(.node) \(.reason)"')"
check "another orchestrator's lane is not mine" "[]" "[$(nev '[.open[] | select(.lane == "theirs") | .lane] | join(" ")')]"
check "a working agent is none" "[]" "[$(nev '[.open[] | select(.lane == "b") | .reason] | join(" ")')]"
nrec; nrec
check "the same facts give one key" "1" "$(nev '.open | length')"
ns notify reconcile --session graph >/dev/null 2>&1 & ns notify reconcile --session graph >/dev/null 2>&1; wait
check "two parallel scans give one event" "1" "$(nev '.open | length')"
check "the pane index knows the lane's pane" "investigate" "$(jq -r .node "$XDG_STATE_HOME/herdr-graph/panes/w2_p1.lane" 2>/dev/null)"

echo "== notify: several lanes make one batch, without any agent text =="
nsm '.agents.b.agent_status = "blocked"'
nrec
msg="$(ntake)"
check "one message" "GRAPH EVENT (from the watcher, not the user):" "$msg"
check "naming each lane, node and a reason code" "a/investigate finished-pass" "$msg"
check "and the other" "b/investigate blocked" "$msg"
check_absent "never an agent's text or ref" "abc1234" "$msg"
check "it is one line" "1" "$(wc -l <<<"$msg" | tr -d ' ')"
ntake >/dev/null; rc=$?
check_rc "delivered events are not delivered again" 1 "$rc"
check "but stay open until recorded" "2" "$(nev '.open | length')"
check "resume.sh prints them" "a/investigate finished-pass" "$(ns resume --session graph)"

echo "== notify: a flapping agent does not resend =="
nsm '.agents.b.agent_status = "working"'; nrec
nsm '.agents.b.agent_status = "blocked"'; N_CLOCK=1000010; nrec
ntake >/dev/null; rc=$?
check_rc "blocked again within a minute: nothing new" 1 "$rc"
nsm '.agents.b.agent_status = "working"'; N_CLOCK=1000020; nrec
nsm '.agents.b.agent_status = "blocked"'; N_CLOCK=1000200; nrec
check "gone for longer, it is a new event" "b/investigate blocked" "$(ntake)"
echo "== notify: recording the node arms it again =="
ns lane node --repo "$N_REPO" --lane b --node investigate --status running --note "answered on its screen" >/dev/null
nrec
check "the same state after a record is new" "b/investigate blocked" "$(ntake)"

echo "== notify: stopped must hold for 30 seconds =="
ns lane close --repo "$N_REPO" --lane b >/dev/null
nsm '.agents.a.screen = "thinking"'; ns lane node --repo "$N_REPO" --lane a --node investigate --status running --note again >/dev/null
rm -f "$N_REPO/.git/herdr-graph/live.json"
N_CLOCK=1001000; nrec
ntake >/dev/null; rc=$?
check_rc "just stopped: not yet" 1 "$rc"
N_CLOCK=1001031; nrec
check "still stopped after 30 s" "a/investigate stopped" "$(ntake)"

echo "== notify: reminders after 5 and 15 minutes, then manual intervention =="
N_CLOCK=1001200; nrec
ntake >/dev/null; rc=$?
check_rc "before 5 minutes nothing" 1 "$rc"
: >"$N_TMP/calls.log"
N_CLOCK=1001332; nrec
check "after 5 minutes: a reminder" "a/investigate stopped (reminder 1)" "$(ntake)"
check "and a notification to the user" "notification show" "$(cat "$N_TMP/calls.log")"
N_CLOCK=1001600; nrec; ntake >/dev/null; rc=$?
check_rc "no more until 15 minutes" 1 "$rc"
N_CLOCK=1001932; nrec
check "after 15 minutes: the second" "(reminder 2)" "$(ntake)"
nman() { ns status --json --repo "$N_REPO" | jq -r '.[] | select(.lane == "a") | "\(.manual) \(.attention | join(" | "))"'; }
check_absent "not yet marked" "needs manual intervention" "$(nman)"
N_CLOCK=1002232; nrec
ntake >/dev/null; rc=$?
check_rc "no third reminder" 1 "$rc"
check "the lane is marked" "true" "$(nman)"
check "with what is unhandled" "needs manual intervention: investigate stopped" "$(nman)"
frame="$(cd "$N_REPO" && env -u HERDR_PANE_ID -u HERDR_TAB_ID PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$N_TMP" HERDR_ENV=1 NO_COLOR=1 bash "$PLUGIN/scripts/panel.sh" --frame --width 160)"
check "the graph panel shows the mark" "needs manual intervention" "$frame"
ns lane node --repo "$N_REPO" --lane a --node investigate --status "done" --result pass >/dev/null
nrec
check "recorded: the event closes" "0" "$(nev '.open | length')"
check_absent "and the mark goes" "needs manual" "$(nman)"

echo "== notify: a question waiting for the user reminds the user, never wakes the chat =="
ns lane ask --repo "$N_REPO" --lane a --text "ship it?" >/dev/null
N_CLOCK=1003000; nrec; ntake >/dev/null; rc=$?
check_rc "the orchestrator knows its own question" 1 "$rc"
: >"$N_TMP/calls.log"; N_CLOCK=1003301; nrec; ntake >/dev/null; rc=$?
check_rc "no wake at 5 minutes" 1 "$rc"
check "the user is reminded" "notification show a needs you" "$(cat "$N_TMP/calls.log")"
N_CLOCK=1004300; nrec; N_CLOCK=1004301; nrec
check "and the lane marked in the end" "true" "$(nman)"
nsm '.notify = "disabled"'
ns lane answer --repo "$N_REPO" --lane a --text yes >/dev/null
ns lane ask --repo "$N_REPO" --lane a --text "again?" >/dev/null
N_CLOCK=1005000; nrec; N_CLOCK=1005301; nrec
check "notifications that show nothing are noticed" "off" "$(nev .notifications)"
check "and said" "Herdr notifications are off" "$(ns notify list --session graph)"
ns lane answer --repo "$N_REPO" --lane a --text yes >/dev/null; nrec

echo "== notify: the push fallback =="
nlane c; nsm '.agents.c = {name: "claude-c", pane_id: "w4:p1", agent: "claude", agent_status: "blocked", state_change_seq: 1}'
N_CLOCK=1006000; nrec
push() { : >"$N_TMP/calls.log"; ns notify push --session graph >/dev/null 2>&1; cat "$N_TMP/calls.log"; }
mkdir -p "$(dirname "$N_EV")"
printf '%s' "$$" >"${N_EV%.events.json}.waiter"; touch "${N_EV%.events.json}.beat"
check_absent "with a live waiter nothing is pushed" "agent prompt" "$(push)"
rm -f "${N_EV%.events.json}.waiter" "${N_EV%.events.json}.beat"
nsm '.agents.o.agent_status = "blocked"'
check_absent "an orchestrator with a dialog open gets nothing" "agent prompt" "$(push)"
nsm '.agents.o.agent_status = "working"'
check_absent "nor a working one: its idle event delivers" "agent prompt" "$(push)"
nsm '.agents.o.agent_status = "idle"'
nsm '.agents.o.screen = "────\n❯ please do not\n────"'
out="$(push)"
check_absent "never onto a half-typed draft" "agent prompt" "$out"
check "the user is told instead" "notification show" "$out"
check_absent "once" "notification show" "$(push)"
nsm '.agents.o.screen = "Do you want to proceed?\n❯ 1. Yes\n  2. No"'
check_absent "never onto a dialog that is not detected as blocked" "agent prompt" "$(push)"
nsm '.agents.o.screen = "nothing recognisable here"'
check_absent "never when the box cannot be read" "agent prompt" "$(push)"
nsm '.agents.o.screen = "────\n❯ \u001b[2mTry \"fix lint errors\"\u001b[0m\n────"'
out="$(push)"
check "a dim placeholder is an empty box" "agent prompt graph GRAPH EVENT" "$out"
check "the screen is read with its styles" "--ansi" "$out"
check "pushed events are delivered" "1" "$(nev '[.open[] | select(.delivered_at != null)] | length')"
nlane d; nsm '.agents.d = {name: "claude-d", pane_id: "w5:p1", agent: "claude", agent_status: "blocked", state_change_seq: 1} | .agents.o.agent_status = "idle" | .agents.o.screen = "────\n❯ \n────"'
N_CLOCK=1006030; nrec
check_absent "at most one push a minute" "agent prompt" "$(push)"
N_CLOCK=1006062
check "then the next" "d/investigate blocked" "$(push)"

echo "== notify: a gone orchestrator keeps the events and never pushes to a namesake =="
nlane e; nsm '.agents.e = {name: "claude-e", pane_id: "w6:p1", agent: "claude", agent_status: "blocked", state_change_seq: 1} | .agents.o.pane_id = "w9:p9"'
N_CLOCK=1007000; nrec
out="$(push)"
check_absent "another pane named graph gets nothing" "agent prompt" "$out"
check "the user is told" "notification show" "$out"
check_absent "once" "notification show" "$(push)"
check "the event is kept" "e/investigate blocked" "$(ns notify list --session graph)"
nsm '.agents.o.pane_id = "w1:p1"'

echo "== notify: herdr events: the plugin hook =="
ev() { HERDR_PLUGIN_EVENT_JSON="$1" ns signal herdr >/dev/null 2>&1; }
: >"$N_TMP/calls.log"
ev '{"event":"pane_agent_status_changed","data":{"pane_id":"w77:p1","agent_status":"idle","agent":"claude"}}'
check "a pane that is no lane's and not the orchestrator's: nothing runs" "[]" "[$(cat "$N_TMP/calls.log")]"
ntake >/dev/null
nlane f; nsm '.agents.f = {name: "claude-f", pane_id: "w8:p1", agent: "claude", agent_status: "blocked", state_change_seq: 1}'
N_CLOCK=1008000; nrec
nsm '.agents.o.agent_status = "idle"'
: >"$N_TMP/calls.log"
ev '{"event":"pane_agent_status_changed","data":{"pane_id":"w1:p1","agent_status":"idle","agent":"claude"}}'
check "the orchestrator turning idle flushes the queue" "agent prompt graph GRAPH EVENT" "$(cat "$N_TMP/calls.log")"
N_CLOCK=1008100
nsm '.agents.o.agent_status = "idle" | .agents.f.agent_status = "working"'; nrec; N_CLOCK=1008200; nsm '.agents.f.agent_status = "blocked"'
: >"$N_TMP/calls.log"
ev '{"event":"pane_agent_status_changed","data":{"pane_id":"w8:p1","agent_status":"blocked","agent":"claude"}}'
check "a lane pane's event reconciles and delivers" "f/investigate blocked" "$(cat "$N_TMP/calls.log")"
ns lane node --repo "$N_REPO" --lane f --node investigate --status "done" --result pass >/dev/null
N_CLOCK=1008300
nsm 'del(.agents.e)'
: >"$N_TMP/calls.log"
ev '{"event":"workspace_closed","data":{"type":"workspace_closed","workspace_id":"w6"}}'
check "a closed workspace has no pane: everything is reconciled" "e/investigate gone" "$(ns notify list --session graph)"
check_absent "a closed pane never closes a lane" "closed" "$(ns lane list --repo "$N_REPO" --all | grep '^e')"

echo "== notify: a gate that records itself still wakes the chat =="
ns lane close --repo "$N_REPO" --lane e >/dev/null
ns lane new --repo "$N_REPO" --lane g --pattern solo --idea x --gate true --owner graph >/dev/null
ns lane node --repo "$N_REPO" --lane g --node tests --status "done" --result pass >/dev/null
N_CLOCK=1009000; ns notify gate --repo "$N_REPO" --lane g --node tests >/dev/null 2>&1; nrec
check "the gate's result is an event" "g/tests gate-pass" "$(ntake)"
ns lane note --repo "$N_REPO" --lane g --text "seen it" >/dev/null; nrec
check_absent "closed once the lane is written again" "g/tests" "$(ns notify list --session graph)"
check "gate.sh signals the end of a gate run in its tab" 'notify.sh" gate' "$(sed -n '/^exec)/,/^start)/p' "$PLUGIN/scripts/gate.sh")"

echo "== notify: the full sweep checks cleanup and merges =="
git -C "$N_REPO" worktree add -q -b feat/s "$N_TMP/wt-s" main
git -C "$N_TMP/wt-s" -c user.name=t -c user.email=t@t commit -q --allow-empty -m work
ns lane new --repo "$N_REPO" --lane s --pattern investigate --idea x --branch feat/s --workspace w-s --owner graph >/dev/null
ns lane node --repo "$N_REPO" --lane s --node investigate --status "done" --result pass >/dev/null
ns lane set --repo "$N_REPO" --lane s --key status --value "done" >/dev/null
N_CLOCK=1010000
ns notify reconcile --session graph >/dev/null 2>&1
check_absent "an event reconcile asks nothing" "cleanup-ready" "$(ns notify list --session graph)"
ns notify reconcile --session graph --full >/dev/null 2>&1
check "the sweep asks and wakes" "s/- cleanup-ready" "$(ntake)"
sid="$(ns lane show --repo "$N_REPO" --lane s --json | jq -r '.questions[-1].id')"
ns lane asked --repo "$N_REPO" --lane s --id "$sid" >/dev/null; nrec
check "once asked it waits for the user" "s/- awaiting-user" "$(ns notify list --session graph)"
ns lane answer --repo "$N_REPO" --lane s --text yes >/dev/null
ns lane set --repo "$N_REPO" --lane s --key cleanup --value confirmed >/dev/null
N_CLOCK=1010100; nrec
check "a yes that was never run is its own event" "s/- cleanup-confirmed" "$(ntake)"

echo "== notify: the panel's tick does not poll =="
for l in a c d f g s; do ns lane close --repo "$N_REPO" --lane "$l" >/dev/null 2>&1; done
nlane t; nsm '.agents.t = {name: "claude-t", pane_id: "w11:p1", agent: "claude", agent_status: "idle", state_change_seq: 1, screen: "NODE investigate RESULT: pass t1"} | .agents.o.agent_status = "working"'
N_CLOCK=1010500; : >"$N_TMP/calls.log"; ns notify tick >/dev/null 2>&1
check "a tick reads a finished agent" "agent read claude-t" "$(cat "$N_TMP/calls.log")"
: >"$N_TMP/calls.log"; N_CLOCK=1010505; ns notify tick >/dev/null 2>&1
check_absent "the next tick within 10 s reads no screen" "agent read claude-t" "$(cat "$N_TMP/calls.log")"
echo "== notify: a gone orchestrator's events still close =="
ns lane node --repo "$N_REPO" --lane t --node investigate --status "done" --result pass >/dev/null
nsm 'del(.agents.o)'; N_CLOCK=1010600; ns notify tick >/dev/null 2>&1
check "what was handled closes, so no mark sticks" "0" "$(nev '[.open[] | select(.lane == "t")] | length')"
nst "$(nstate)"

echo "== notify: what auto-merge could merge =="
git -C "$N_REPO" worktree add -q -b feat/mr "$N_TMP/wt-mr" main
git -C "$N_TMP/wt-mr" -c user.name=t -c user.email=t@t commit -q --allow-empty -m work
ns lane new --repo "$N_REPO" --lane mr --pattern solo --idea x --gate true --branch feat/mr --owner graph >/dev/null
ns lane set --repo "$N_REPO" --lane mr --key pr --value https://github.com/o/r/pull/8 >/dev/null
for n in impl tests; do ns lane node --repo "$N_REPO" --lane mr --node "$n" --status "done" --result pass >/dev/null; done
jq -cn --arg h "$(git -C "$N_TMP/wt-mr" rev-parse HEAD)" '{"https://github.com/o/r/pull/8": {number: 8, url: "https://github.com/o/r/pull/8", state: "OPEN", headRefName: "feat/mr", headRefOid: $h, isDraft: false, reviewDecision: "", mergeable: "MERGEABLE", statusCheckRollup: []}}' >"$N_TMP/gh.json"
N_CLOCK=1010700; ns notify reconcile --session graph --full >/dev/null 2>&1
check_absent "auto-merge off: nothing to merge" "merge-ready" "$(ns notify list --session graph)"
ns session automerge on --repo "$N_REPO" --lane mr >/dev/null
ns notify reconcile --session graph --full >/dev/null 2>&1
check "on: the sweep says it can merge" "mr/- merge-ready" "$(ns notify list --session graph)"
nrec
check "it stays between sweeps" "mr/- merge-ready" "$(ns notify list --session graph)"
ns lane note --repo "$N_REPO" --lane mr --text "something happened" >/dev/null; nrec
check_absent "and goes once the lane is written, until a sweep looks again" "merge-ready" "$(ns notify list --session graph)"
ns lane close --repo "$N_REPO" --lane mr >/dev/null
ns lane close --repo "$N_REPO" --lane t >/dev/null

echo "== await: the waiter =="
aw() { HERDR_GRAPH_TICK=0.2 HERDR_GRAPH_BATCH=0 HERDR_GRAPH_WAIT_MAX="${AW_MAX:-3}" HERDR_PANE_ID="${AW_PANE:-w1:p1}" ns await "$@"; }
for l in a c d f g s; do ns lane close --repo "$N_REPO" --lane "$l" >/dev/null 2>&1; done
N_CLOCK=1011000; nrec; ntake >/dev/null
out="$(AW_MAX=1 aw --session graph 2>&1)"; rc=$?
check_rc "with nothing to say it ends quietly at its limit" 0 "$rc"
check "silently, so no turn is spent" "[]" "[$out]"
nlane w; nsm '.agents.w = {name: "claude-w", pane_id: "w10:p1", agent: "claude", agent_status: "blocked", state_change_seq: 1}'
out="$(aw --session graph 2>"$N_TMP/aw.err")"; rc=$?
check_rc "an event ends it with exit 2, which wakes the chat" 2 "$rc"
check "the message goes to stderr" "GRAPH EVENT (from the watcher, not the user): w/investigate blocked" "$(cat "$N_TMP/aw.err")"
check "the waiter swept" "$N_CLOCK" "$(nev .swept_at)"
AW_MAX=30 aw --session graph >"$N_TMP/aw1.out" 2>&1 & first=$!
for _ in $(seq 50); do [ -s "${N_EV%.events.json}.waiter" ] && break; sleep 0.1; done
check "a running waiter keeps a heartbeat" "yes" "$([ -f "${N_EV%.events.json}.beat" ] && echo yes)"
AW_MAX=1 aw --session graph >/dev/null 2>&1
wait "$first"; rc=$?
check_rc "a newer waiter takes over: only one per session" 0 "$rc"
out="$(printf '{}' | AW_PANE=w77:p1 aw --hook 2>&1)"; rc=$?
check_rc "the hook in another pane does nothing" 0 "$rc"
nsm '.agents.o.agent = "codex"'
start=$(date +%s); out="$(printf '{}' | AW_MAX=30 aw --hook 2>&1)"; rc=$?
check_rc "for a client that cannot be woken this way the hook returns" 0 "$rc"
check "at once, so its turn is never held" "yes" "$([ $(($(date +%s) - start)) -lt 10 ] && echo yes)"
nsm '.agents.o.agent = "claude"'
ns lane node --repo "$N_REPO" --lane w --node investigate --status running --note rearm >/dev/null
out="$(printf '{"stop_hook_active":false}' | aw --hook 2>&1)"; rc=$?
check_rc "armed by the hook in the orchestrator's Claude pane" 2 "$rc"

rm -rf "$N_TMP"
export XDG_STATE_HOME="$N_STATE_OLD"; unset N_CLOCK
unset -f ns nst nsm nev nrec ntake nagent nstate nlane nman push ev aw
