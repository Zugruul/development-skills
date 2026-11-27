#!/usr/bin/env bash
# section-assistant-terminal.sh -- AST-016: terminal smoke chat +
# status/default subcommands (SPEC-ASSISTANT.md §7.6, issue #314). Sourced
# by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
# shellcheck disable=SC2016  # lifecycle_start command-strings are single-quoted on
# purpose -- they're expanded when eval'd inside the function, not at call site.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== assistant terminal (AST-016: chat/status/default subcommands, SPEC-ASSISTANT.md §7.6) =="

AT_NV="$PLUGIN/scripts/neural-view.py"
# Only referenced inside lifecycle_start's single-quoted command strings
# below (expanded at eval time), invisible to shellcheck's static usage check.
# shellcheck disable=SC2034
AT_STUB_CODEX="$FIX/stub-codex"

# at_repo <dir> <main-name> -- a marker'd repo with a structurally valid,
# enabled assistant: section wired to the openai/codex provider (mirrors
# section-assistant-engine.sh's ae_repo / section-assistant-default.sh's
# ad_repo).
at_repo() {
    local dir="$1" main="$2"
    mkdir -p "$dir/.claude" "$dir/.neural-network"
    printf '%s\n' '# neural-network' >"$dir/.neural-network/marker"
    printf '%s\n' \
        'schemaVersion: 2' \
        'assistant:' \
        '    version: 1' \
        '    enabled: true' \
        "    names: [$main]" \
        '    systemPrompt: |' \
        "        You are $main." \
        '    llm:' \
        '        provider: openai' \
        '        model: gpt-5.6-sol' \
        '    capabilities:' \
        '        codex:' \
        '            enabled: true' \
        '            provisioning:' \
        '                bin: codex' \
        >"$dir/.neural-network/project.yaml"
}

# at_no_assistant_repo <dir> -- marker'd but no assistant: section, i.e.
# not a candidate (mirrors ae_repo_b in section-assistant-engine.sh).
at_no_assistant_repo() {
    local dir="$1"
    mkdir -p "$dir/.claude" "$dir/.neural-network"
    printf '%s\n' '# neural-network' >"$dir/.neural-network/marker"
}

# review r1 LOW 1: PATH is scoped to the ONE `lifecycle_start`/`start`
# command that spawns the server (a VAR=value prefix on that single command
# string, same convention section-assistant-adapter.sh's aa_run uses) --
# never a bare `export PATH=...` left dangling for the rest of this
# (sourced, same-process) run-tests.sh run to trip up a later section.

# ----------------------------------------------------- A: happy path (sole assistant, stub codex)
echo "-- happy path: sole assistant + stub codex provider --"
_at_a_root="$(mktemp -d)"
_at_a_state="$(mktemp -d)"
_at_a_scan_empty="$(mktemp -d)"
at_repo "$_at_a_root" jarvis

export NEURAL_VIEW_STATE="$_at_a_state" NEURAL_VIEW_SCAN="$_at_a_scan_empty"
lifecycle_start "assistant terminal: neural-view starts" NEURAL_VIEW_PORT \
    'PATH="$AT_STUB_CODEX:$PATH" CODEX_STUB_MODE=ok python3 "$AT_NV" start --dir "$_at_a_root"'

status_out="$(python3 "$AT_NV" assistant status)"
status_rc=$?
check_rc "assistant status: exits 0" 0 "$status_rc"
check "assistant status: reports the fixture assistant count" "assistants=1" "$status_out"

default_set_out="$(python3 "$AT_NV" assistant default jarvis)"
default_set_rc=$?
check_rc "assistant default <name>: exits 0" 0 "$default_set_rc"
check "assistant default <name>: confirms the name it stored" "jarvis" "$default_set_out"

default_read_out="$(python3 "$AT_NV" assistant default)"
check "assistant default (no name): reads back the stored default" "jarvis" "$default_read_out"

chat_out="$(python3 "$AT_NV" assistant chat "hi")"
chat_rc=$?
check_rc "assistant chat: exits 0" 0 "$chat_rc"
check "assistant chat: prints the real pipeline's reply (via the stub adapter)" "Hello from stub" "$chat_out"

chat_flag_out="$(python3 "$AT_NV" assistant chat --assistant jarvis "hi again")"
check_rc "assistant chat --assistant NAME: exits 0 when the name matches" 0 $?
check "assistant chat --assistant NAME: still round-trips the reply" "Hello from stub" "$chat_flag_out"

hist_body="$(curl -sf "http://127.0.0.1:$NEURAL_VIEW_PORT/assistant/history")"
check "assistant chat: transcript persisted the user message" '"user": "hi"' "$hist_body"
check "assistant chat: transcript persisted the assistant reply" '"assistant": "Hello from stub"' "$hist_body"

unknown_out="$(python3 "$AT_NV" assistant chat --assistant nope "hi" 2>&1)"
unknown_rc=$?
check_rc "assistant chat --assistant <unknown>: exits nonzero" 1 "$unknown_rc"
check "assistant chat --assistant <unknown>: names the discovered candidates" "jarvis" "$unknown_out"
check_absent "assistant chat --assistant <unknown>: no raw traceback" "Traceback" "$unknown_out"

# review r1 LOW 2: a trailing `--assistant` with no NAME after it must be a
# clean usage error, never silently swallowed into the chat message text
# (previously `["chat", "--assistant"]` -> flag stays unset, "--assistant"
# itself becomes (part of) the literal message).
trailing_flag_out="$(python3 "$AT_NV" assistant chat --assistant 2>&1)"
trailing_flag_rc=$?
check_rc "assistant chat --assistant <trailing, no NAME>: exits nonzero (usage error)" 2 "$trailing_flag_rc"
check "assistant chat --assistant <trailing, no NAME>: names the missing NAME, not a traceback" "requires a NAME" "$trailing_flag_out"
check_absent "assistant chat --assistant <trailing, no NAME>: no raw traceback" "Traceback" "$trailing_flag_out"

_at_a_pid="$(cat "$_at_a_state/pid")"
python3 "$AT_NV" stop >/dev/null
for _ in $(seq 1 30); do
    kill -0 "$_at_a_pid" 2>/dev/null || break
    sleep 0.1
done
unset NEURAL_VIEW_STATE NEURAL_VIEW_PORT NEURAL_VIEW_SCAN
rm -rf "$_at_a_root" "$_at_a_state" "$_at_a_scan_empty"

# ----------------------------------------------------- B: resolution error -- no assistants
echo "-- resolution error: no assistants discovered --"
_at_b_root="$(mktemp -d)"
_at_b_state="$(mktemp -d)"
_at_b_scan_empty="$(mktemp -d)"
at_no_assistant_repo "$_at_b_root"

export NEURAL_VIEW_STATE="$_at_b_state" NEURAL_VIEW_SCAN="$_at_b_scan_empty"
lifecycle_start "assistant terminal (no-assistant repo): neural-view starts" NEURAL_VIEW_PORT 'python3 "$AT_NV" start --dir "$_at_b_root"'

noassist_out="$(python3 "$AT_NV" assistant chat "hi" 2>&1)"
noassist_rc=$?
check_rc "assistant chat with no discovered assistants: exits nonzero" 1 "$noassist_rc"
check "assistant chat with no discovered assistants: names the resolution failure" "no assistants discovered" "$noassist_out"
check_absent "assistant chat with no discovered assistants: no raw traceback" "Traceback" "$noassist_out"

status_b_out="$(python3 "$AT_NV" assistant status)"
check "assistant status (no-assistant repo): reports zero assistants" "assistants=0" "$status_b_out"

_at_b_pid="$(cat "$_at_b_state/pid")"
python3 "$AT_NV" stop >/dev/null
for _ in $(seq 1 30); do
    kill -0 "$_at_b_pid" 2>/dev/null || break
    sleep 0.1
done
unset NEURAL_VIEW_STATE NEURAL_VIEW_PORT NEURAL_VIEW_SCAN
rm -rf "$_at_b_root" "$_at_b_state" "$_at_b_scan_empty"

# ----------------------------------------------------- C: coverage gap -- two-candidate resolution
echo "-- coverage gap: two-candidate resolution (§7.6) --"
_at_c_scan="$(mktemp -d)"
_at_c_state="$(mktemp -d)"
mkdir -p "$_at_c_scan/repo-jarvis" "$_at_c_scan/repo-friday"
at_repo "$_at_c_scan/repo-jarvis" jarvis
at_repo "$_at_c_scan/repo-friday" friday

export NEURAL_VIEW_STATE="$_at_c_state"
lifecycle_start "assistant terminal (two candidates): neural-view starts" NEURAL_VIEW_PORT \
    'PATH="$AT_STUB_CODEX:$PATH" CODEX_STUB_MODE=ok python3 "$AT_NV" start --scan "$_at_c_scan"'

status_two_out="$(python3 "$AT_NV" assistant status)"
check "two-candidate: status reports both" "assistants=2" "$status_two_out"

noflag_out="$(python3 "$AT_NV" assistant chat "hi" 2>&1)"
noflag_rc=$?
check_rc "two-candidate, no flag + no stored default: exits nonzero" 1 "$noflag_rc"
check "two-candidate, no flag + no stored default: lists jarvis" "jarvis" "$noflag_out"
check "two-candidate, no flag + no stored default: lists friday" "friday" "$noflag_out"

jarvis_out="$(python3 "$AT_NV" assistant chat --assistant jarvis "hi")"
check_rc "two-candidate: --assistant jarvis resolves" 0 $?
check "two-candidate: --assistant jarvis gets the reply" "Hello from stub" "$jarvis_out"

friday_out="$(python3 "$AT_NV" assistant chat --assistant friday "hi")"
check_rc "two-candidate: --assistant friday resolves" 0 $?
check "two-candidate: --assistant friday gets the reply" "Hello from stub" "$friday_out"

python3 "$AT_NV" assistant default friday >/dev/null
default_pick_out="$(python3 "$AT_NV" assistant chat "hi")"
check_rc "two-candidate: stored default resolves with no flag" 0 $?
check "two-candidate: stored default resolves with no flag" "Hello from stub" "$default_pick_out"

_at_c_pid="$(cat "$_at_c_state/pid")"
python3 "$AT_NV" stop >/dev/null
for _ in $(seq 1 30); do
    kill -0 "$_at_c_pid" 2>/dev/null || break
    sleep 0.1
done
unset NEURAL_VIEW_STATE NEURAL_VIEW_PORT
rm -rf "$_at_c_scan" "$_at_c_state"

# ----------------------------------------------------- D: blocker regression -- concurrent chats, same assistant
# review r1 BLOCKER: engine.py's _chat did load_state -> run_turn ->
# save_state UNLOCKED. Two concurrent chats against the SAME assistant could
# both load turn_count=0, both compute turn_count=1, and whichever saves
# LAST wins -- the other turn's session-state update is silently lost (the
# transcript still has both exchanges, since append_exchange is append-only
# and each write is small enough to land atomically; session-state.json
# does not have that property, it's a read-modify-write). A per-root
# threading.Lock around the whole load->run_turn->save critical section
# (engine.py's `_chat_lock_for`) serializes turns against the SAME
# assistant -- correct per §7.5's one-session-per-assistant model -- while
# turns against DIFFERENT assistants stay independent (a different lock
# instance per canonicalized root).
echo "-- blocker regression: concurrent chats against the same assistant never clobber session-state --"
_at_d_root="$(mktemp -d)"
_at_d_state="$(mktemp -d)"
_at_d_scan_empty="$(mktemp -d)"
at_repo "$_at_d_root" jarvis

export NEURAL_VIEW_STATE="$_at_d_state" NEURAL_VIEW_SCAN="$_at_d_scan_empty"
lifecycle_start "assistant terminal (concurrency fixture): neural-view starts" NEURAL_VIEW_PORT \
    'PATH="$AT_STUB_CODEX:$PATH" CODEX_STUB_MODE=ok CODEX_STUB_SLEEP_SECONDS=1 python3 "$AT_NV" start --dir "$_at_d_root"'

_at_d_resp_a="$(mktemp)"
_at_d_resp_b="$(mktemp)"
_at_d_code_a="$(mktemp)"
_at_d_code_b="$(mktemp)"
(curl -s -o "$_at_d_resp_a" -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
    -d '{"message":"turn-a"}' "http://127.0.0.1:$NEURAL_VIEW_PORT/assistant/chat" >"$_at_d_code_a") &
_at_d_pid_a=$!
(curl -s -o "$_at_d_resp_b" -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
    -d '{"message":"turn-b"}' "http://127.0.0.1:$NEURAL_VIEW_PORT/assistant/chat" >"$_at_d_code_b") &
_at_d_pid_b=$!
wait "$_at_d_pid_a"
wait "$_at_d_pid_b"

check "concurrency: turn A got HTTP 200" "200" "$(cat "$_at_d_code_a")"
check "concurrency: turn B got HTTP 200" "200" "$(cat "$_at_d_code_b")"

# session-state.json lives at the fixed §4 path (store.py's STATE_DIR_REL +
# STATE_FILE_NAME) -- read directly rather than through an HTTP route (none
# exposes it) since the fixture root is a known, controlled temp dir.
_at_d_state_json="$(cat "$_at_d_root/.claude/assistant/session-state.json" 2>/dev/null)"
check "concurrency: session-state.json reflects BOTH turns (turn_count == 2, not clobbered)" '"turn_count": 2' "$_at_d_state_json"
check "concurrency: session-state.json's turns array kept turn-a's text" '"text": "turn-a"' "$_at_d_state_json"
check "concurrency: session-state.json's turns array kept turn-b's text" '"text": "turn-b"' "$_at_d_state_json"

_at_d_pid="$(cat "$_at_d_state/pid")"
python3 "$AT_NV" stop >/dev/null
for _ in $(seq 1 30); do
    kill -0 "$_at_d_pid" 2>/dev/null || break
    sleep 0.1
done
unset NEURAL_VIEW_STATE NEURAL_VIEW_PORT NEURAL_VIEW_SCAN
rm -rf "$_at_d_root" "$_at_d_state" "$_at_d_scan_empty" \
    "$_at_d_resp_a" "$_at_d_resp_b" "$_at_d_code_a" "$_at_d_code_b"

# ----------------------------------------------------- E: no server running
echo "-- headless: no server running --"
_at_e_state="$(mktemp -d)"
export NEURAL_VIEW_STATE="$_at_e_state"

noserver_chat_out="$(python3 "$AT_NV" assistant chat "hi" 2>&1)"
noserver_chat_rc=$?
check_rc "assistant chat with no server running: exits nonzero" 1 "$noserver_chat_rc"
check "assistant chat with no server running: clean message, not a stack trace" "neural-view not running" "$noserver_chat_out"
check_absent "assistant chat with no server running: no raw traceback" "Traceback" "$noserver_chat_out"

noserver_status_out="$(python3 "$AT_NV" assistant status 2>&1)"
noserver_status_rc=$?
check_rc "assistant status with no server running: exits nonzero" 1 "$noserver_status_rc"
check "assistant status with no server running: clean message" "neural-view not running" "$noserver_status_out"

# default is a local file operation (no HTTP round-trip, per AST-016's HOW)
# -- it must keep working even with no server running.
noserver_default_out="$(python3 "$AT_NV" assistant default someone)"
check_rc "assistant default with no server running: still works (local file op)" 0 $?
check "assistant default with no server running: confirms the name it stored" "someone" "$noserver_default_out"

# AST-045 (SPEC-ASSISTANT.md §10.5, issue #331): metrics/trace/events are
# the same "thin HTTP client" posture as chat/status above -- a clean
# not-running message + nonzero exit, no traceback, no server dependency
# bypass.
noserver_metrics_out="$(python3 "$AT_NV" assistant metrics 2>&1)"
noserver_metrics_rc=$?
check_rc "assistant metrics with no server running: exits nonzero" 1 "$noserver_metrics_rc"
check "assistant metrics with no server running: clean message, not a stack trace" "neural-view not running" "$noserver_metrics_out"
check_absent "assistant metrics with no server running: no raw traceback" "Traceback" "$noserver_metrics_out"

noserver_trace_out="$(python3 "$AT_NV" assistant trace last 2>&1)"
noserver_trace_rc=$?
check_rc "assistant trace with no server running: exits nonzero" 1 "$noserver_trace_rc"
check "assistant trace with no server running: clean message, not a stack trace" "neural-view not running" "$noserver_trace_out"
check_absent "assistant trace with no server running: no raw traceback" "Traceback" "$noserver_trace_out"

noserver_events_out="$(python3 "$AT_NV" assistant events --since 5m 2>&1)"
noserver_events_rc=$?
check_rc "assistant events with no server running: exits nonzero" 1 "$noserver_events_rc"
check "assistant events with no server running: clean message, not a stack trace" "neural-view not running" "$noserver_events_out"
check_absent "assistant events with no server running: no raw traceback" "Traceback" "$noserver_events_out"

unset NEURAL_VIEW_STATE
rm -rf "$_at_e_state"

# ----------------------------------------------------- F: metrics/trace/events happy path (AST-045, issue #331)
echo "-- metrics/trace/events: happy path against a live fixture server --"
_at_f_root="$(mktemp -d)"
_at_f_state="$(mktemp -d)"
_at_f_scan_empty="$(mktemp -d)"
at_repo "$_at_f_root" jarvis

export NEURAL_VIEW_STATE="$_at_f_state" NEURAL_VIEW_SCAN="$_at_f_scan_empty"
lifecycle_start "assistant terminal (metrics/trace/events): neural-view starts" NEURAL_VIEW_PORT \
    'PATH="$AT_STUB_CODEX:$PATH" CODEX_STUB_MODE=ok python3 "$AT_NV" start --dir "$_at_f_root"'

python3 "$AT_NV" assistant chat "turn one" >/dev/null
sleep 1
python3 "$AT_NV" assistant chat "turn two" >/dev/null

metrics_out="$(python3 "$AT_NV" assistant metrics)"
metrics_rc=$?
check_rc "assistant metrics: exits 0" 0 "$metrics_rc"
check "assistant metrics: reports the fixture assistant's root label" "jarvis" "$metrics_out"
check "assistant metrics: both turns landed ok" "ok=2" "$metrics_out"
check "assistant metrics: no provider errors" "provider errors: 0" "$metrics_out"
check "assistant metrics: turn duration count matches the number of completed turns" "count=2" "$metrics_out"
check "assistant metrics: renders a p50 latency estimate" "p50=" "$metrics_out"
check "assistant metrics: renders a p95 latency estimate" "p95=" "$metrics_out"

# Pull the two turn ids straight off the raw /assistant/traces feed (seq
# order == chronological order) so `trace last`/`trace <id>` can be
# asserted against real, not guessed, ids.
turn_ids_out="$(curl -sf "http://127.0.0.1:$NEURAL_VIEW_PORT/assistant/traces" | python3 -c '
import json, sys
data = json.load(sys.stdin)
ids = []
for ev in data["events"]:
    if ev.get("kind") == "turn.start" and ev.get("turn_id") not in ids:
        ids.append(ev["turn_id"])
print(ids[0])
print(ids[-1])
')"
_at_f_turn_first="$(sed -n '1p' <<<"$turn_ids_out")"
_at_f_turn_last="$(sed -n '2p' <<<"$turn_ids_out")"

trace_last_out="$(python3 "$AT_NV" assistant trace last)"
check_rc "assistant trace last: exits 0" 0 $?
check "assistant trace last: names the newest turn" "$_at_f_turn_last" "$trace_last_out"
check_absent "assistant trace last: never mixes in the older turn's id" "$_at_f_turn_first" "$trace_last_out"
check "assistant trace last: renders the waterfall's turn.start row" "turn.start" "$trace_last_out"
check "assistant trace last: renders the waterfall's turn.end row" "turn.end" "$trace_last_out"

trace_id_out="$(python3 "$AT_NV" assistant trace "$_at_f_turn_first")"
check_rc "assistant trace <turn-id>: exits 0" 0 $?
check "assistant trace <turn-id>: names the requested (older) turn" "$_at_f_turn_first" "$trace_id_out"
check_absent "assistant trace <turn-id>: never mixes in the other turn's id" "$_at_f_turn_last" "$trace_id_out"

events_wide_out="$(python3 "$AT_NV" assistant events --since 1h)"
check_rc "assistant events --since 1h: exits 0" 0 $?
check "assistant events --since 1h: a wide window includes the first turn" "$_at_f_turn_first" "$events_wide_out"
check "assistant events --since 1h: a wide window includes the last turn" "$_at_f_turn_last" "$events_wide_out"

events_narrow_out="$(python3 "$AT_NV" assistant events --since 0s)"
check_rc "assistant events --since 0s: exits 0 (an empty window is not an error)" 0 $?
check "assistant events --since 0s: an already-past window reports nothing, not stale data" "no events" "$events_narrow_out"

# duration parsing (5m/2h/30s valid; a unit-less/garbage value is a usage error, exit 2)
for _at_f_good_dur in 5m 2h 30s; do
    python3 "$AT_NV" assistant events --since "$_at_f_good_dur" >/dev/null 2>&1
    check_rc "assistant events --since $_at_f_good_dur: valid duration exits 0" 0 $?
done

bad_dur_out="$(python3 "$AT_NV" assistant events --since 5 2>&1)"
bad_dur_rc=$?
check_rc "assistant events --since 5 (no unit): usage error, exits 2" 2 "$bad_dur_rc"
check "assistant events --since 5 (no unit): names the invalid duration" "invalid" "$bad_dur_out"
check_absent "assistant events --since 5 (no unit): no raw traceback" "Traceback" "$bad_dur_out"

trace_toomany_out="$(python3 "$AT_NV" assistant trace last extra-arg 2>&1)"
trace_toomany_rc=$?
check_rc "assistant trace with extra positional args: usage error, exits 2" 2 "$trace_toomany_rc"
check "assistant trace with extra positional args: usage message, not a traceback" "usage:" "$trace_toomany_out"

_at_f_pid="$(cat "$_at_f_state/pid")"
python3 "$AT_NV" stop >/dev/null
for _ in $(seq 1 30); do
    kill -0 "$_at_f_pid" 2>/dev/null || break
    sleep 0.1
done
unset NEURAL_VIEW_STATE NEURAL_VIEW_PORT NEURAL_VIEW_SCAN
rm -rf "$_at_f_root" "$_at_f_state" "$_at_f_scan_empty"

# ----------------------------------------------------- G: --assistant passthrough (two-candidate resolution)
echo "-- coverage: --assistant passthrough resolves trace/events to the NAMED root, not whichever resolves by default --"
_at_g_scan="$(mktemp -d)"
_at_g_state="$(mktemp -d)"
mkdir -p "$_at_g_scan/repo-jarvis" "$_at_g_scan/repo-friday"
at_repo "$_at_g_scan/repo-jarvis" jarvis
at_repo "$_at_g_scan/repo-friday" friday

export NEURAL_VIEW_STATE="$_at_g_state"
lifecycle_start "assistant terminal (--assistant passthrough): neural-view starts" NEURAL_VIEW_PORT \
    'PATH="$AT_STUB_CODEX:$PATH" CODEX_STUB_MODE=ok python3 "$AT_NV" start --scan "$_at_g_scan"'

python3 "$AT_NV" assistant chat --assistant jarvis "hi jarvis" >/dev/null

metrics_two_out="$(python3 "$AT_NV" assistant metrics)"
check "assistant metrics: two-candidate reports jarvis's root" "jarvis" "$metrics_two_out"
check "assistant metrics: two-candidate reports friday's root too (fleet-wide)" "friday" "$metrics_two_out"

jarvis_trace_out="$(python3 "$AT_NV" assistant trace last --assistant jarvis)"
check_rc "assistant trace last --assistant jarvis: exits 0" 0 $?
check "assistant trace last --assistant jarvis: shows jarvis's own turn" "turn.start" "$jarvis_trace_out"

friday_trace_out="$(python3 "$AT_NV" assistant trace last --assistant friday)"
check_rc "assistant trace last --assistant friday: exits 0 (a root with zero turns is not an error)" 0 $?
check "assistant trace last --assistant friday: friday has run no turns of its own, proving --assistant actually scoped the query" "no turns recorded" "$friday_trace_out"

friday_events_out="$(python3 "$AT_NV" assistant events --since 1h --assistant friday)"
check_rc "assistant events --since 1h --assistant friday: exits 0" 0 $?
check "assistant events --assistant friday: friday's own window is empty" "no events" "$friday_events_out"

jarvis_events_out="$(python3 "$AT_NV" assistant events --since 1h --assistant jarvis)"
check_rc "assistant events --since 1h --assistant jarvis: exits 0" 0 $?
check "assistant events --assistant jarvis: jarvis's own window has events" "turn.start" "$jarvis_events_out"

_at_g_pid="$(cat "$_at_g_state/pid")"
python3 "$AT_NV" stop >/dev/null
for _ in $(seq 1 30); do
    kill -0 "$_at_g_pid" 2>/dev/null || break
    sleep 0.1
done
unset NEURAL_VIEW_STATE NEURAL_VIEW_PORT
rm -rf "$_at_g_scan" "$_at_g_state"

# ----------------------------------------------------- H: recency (#393) -- events fetches order=desc + prints a truncation caveat, trace last fetches order=desc
# Bug #393: `events --since`/`trace last` fetched oldest-first (ORDER BY seq
# ASC LIMIT _TERMINAL_TRACES_LIMIT) -- on a root with more than
# _TERMINAL_TRACES_LIMIT events total, that window is stale and silently
# misses everything recent (an empty/stale result is indistinguishable from
# "nothing happened", violating the no-silent-caps rule). Pure unit test
# against the real module (no live server, no 1000+-row fixture needed) --
# `_fetch_traces`/`pid_alive` are monkeypatched, same "import as a module,
# stub the boundary" style section-neural-view-rescan.sh already uses.
echo "-- unit: events --since fetches order=desc and prints a truncation caveat; trace last fetches order=desc --"
h_out="$(python3 - "$AT_NV" <<'PY'
import importlib.util, io, sys, contextlib
from datetime import datetime, timezone, timedelta

spec_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("neural_view", spec_path)
nv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nv)

nv.pid_alive = lambda: True

now = datetime.now(timezone.utc)
recent_ts = (now - timedelta(seconds=10)).isoformat()
old_ts = (now - timedelta(hours=2)).isoformat()

calls = []

def make_fetch(order_requested_holder, events, truncated):
    def _fake_fetch_traces(assistant_flag, turn=None, order=None):
        order_requested_holder.append(order)
        return 200, {"events": events, "truncated": truncated}
    return _fake_fetch_traces

# ---- truncated=True + the oldest fetched event is NEWER than cutoff -> the
# window may extend past the fetch -> caveat expected.
holder1 = []
nv._fetch_traces = make_fetch(holder1, [{"seq": 1, "ts": recent_ts, "kind": "turn.start", "turn_id": "tA", "status": None}], True)
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    rc1 = nv._cmd_assistant_events(["--since", "1h"], None)
print("CAVEAT_RC", rc1)
print("CAVEAT_ORDER_REQUESTED", holder1)
print("CAVEAT_PRINTED", "may be incomplete" in buf.getvalue())
print("CAVEAT_MENTIONS_SINCE_OR_LIMIT", "--since" in buf.getvalue() and "--limit" in buf.getvalue())

# ---- truncated=False -> no caveat, regardless of window size.
holder2 = []
nv._fetch_traces = make_fetch(holder2, [{"seq": 1, "ts": recent_ts, "kind": "turn.start", "turn_id": "tA", "status": None}], False)
buf2 = io.StringIO()
with contextlib.redirect_stdout(buf2):
    rc2 = nv._cmd_assistant_events(["--since", "1h"], None)
print("NOCAVEAT_RC", rc2)
print("NOCAVEAT_PRINTED", "may be incomplete" in buf2.getvalue())

# ---- truncated=True but the oldest fetched event already reaches back past
# cutoff -> the fetched window fully covers --since, no caveat needed even
# though the batch was capped.
holder3 = []
nv._fetch_traces = make_fetch(holder3, [
    {"seq": 1, "ts": old_ts, "kind": "turn.start", "turn_id": "tOld", "status": None},
    {"seq": 2, "ts": recent_ts, "kind": "turn.start", "turn_id": "tNew", "status": None},
], True)
buf3 = io.StringIO()
with contextlib.redirect_stdout(buf3):
    rc3 = nv._cmd_assistant_events(["--since", "1h"], None)
print("COVERED_RC", rc3)
print("COVERED_PRINTED", "may be incomplete" in buf3.getvalue())

# ---- trace last fetches order=desc (correctness on busy roots).
holder4 = []
nv._fetch_traces = make_fetch(holder4, [{"seq": 1, "ts": recent_ts, "kind": "turn.start", "turn_id": "tA", "status": None}], False)
buf4 = io.StringIO()
with contextlib.redirect_stdout(buf4):
    rc4 = nv._cmd_assistant_trace(["last"], None)
print("TRACE_LAST_RC", rc4)
print("TRACE_LAST_ORDER_REQUESTED", holder4)
PY
)"
check_rc "events --since: no exception, exits 0" 0 0
check "events --since: requests order=desc from the server (newest-first window)" "CAVEAT_ORDER_REQUESTED ['desc']" "$h_out"
check "events --since: truncated + incomplete window prints the caveat line" "CAVEAT_PRINTED True" "$h_out"
check "events --since: the caveat names both mitigations (--since / --limit)" "CAVEAT_MENTIONS_SINCE_OR_LIMIT True" "$h_out"
check "events --since: truncated=False never prints the caveat" "NOCAVEAT_PRINTED False" "$h_out"
check "events --since: truncated=True but the window is already fully covered never prints the caveat" "COVERED_PRINTED False" "$h_out"
check "trace last: also requests order=desc (correctness on busy roots)" "TRACE_LAST_ORDER_REQUESTED ['desc']" "$h_out"
if [[ "$h_out" != *"CAVEAT_PRINTED True"* ]]; then echo "$h_out" >&2; fi

# ----------------------------------------------------- G: `assistant prune` -- issue #391 dormant-root escape hatch
echo "-- assistant prune: dormant-root escape hatch (issue #391, no server needed) --"
_at_g_root="$(mktemp -d)"
_at_g_state="$(mktemp -d)"
mkdir -p "$_at_g_root/.claude" "$_at_g_root/.neural-network"
printf '%s\n' '# neural-network' >"$_at_g_root/.neural-network/marker"
printf '%s\n' \
    'schemaVersion: 2' \
    'assistant:' \
    '    version: 1' \
    '    enabled: true' \
    '    names: [jarvis]' \
    '    systemPrompt: |' \
    '        You are jarvis.' \
    '    llm:' \
    '        provider: openai' \
    '        model: gpt-5.6-sol' \
    '    capabilities:' \
    '        codex:' \
    '            enabled: true' \
    '            provisioning:' \
    '                bin: codex' \
    '    observability:' \
    '        traces:' \
    '            sqlite:' \
    '                retainDays: 1' \
    '                maxMB: 500' \
    >"$_at_g_root/.neural-network/project.yaml"

prune_out="$(SCRIPTS_DIR="$PLUGIN/scripts" ROOT="$_at_g_root" STATE="$_at_g_state" python3 - "$AT_NV" <<'PY'
import importlib.util, os, sys, sqlite3
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import observability

spec_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("neural_view", spec_path)
nv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nv)

root = os.environ["ROOT"]
nv.discover_repos = lambda args: [("jarvis", root)]

# seed traces.sqlite with one row far older than the configured retainDays=1,
# so a real prune pass has something to actually remove -- proving this
# verb reaches the resolved root own configured knobs, not just a no-op.
conn, next_seq = observability._open_conn(root)
old_ts = (datetime.now(timezone.utc) - timedelta(days=10)).isoformat()
conn.execute(
    "INSERT INTO events (seq, ts, session_id, turn_id, span_id, parent_span_id, "
    "kind, skill, modality, status, payload) VALUES (?, ?, NULL, NULL, NULL, NULL, "
    "'turn.start', NULL, NULL, NULL, '{}')",
    (next_seq, old_ts),
)
conn.commit()
conn.close()

print("BEFORE_COUNT", len(observability.query(root, limit=10)))

rc = nv._cmd_assistant_prune([], None)
print("PRUNE_RC", rc)
print("AFTER_COUNT", len(observability.query(root, limit=10)))

# --- resolution failure: no assistant discovered -> clean nonzero, no traceback ---
nv.discover_repos = lambda args: []
rc_missing = nv._cmd_assistant_prune([], None)
print("MISSING_RC", rc_missing)

# --- a bad --assistant flag / unknown name: clean nonzero, not a crash ---
nv.discover_repos = lambda args: [("jarvis", root)]
rc_unknown = nv._cmd_assistant_prune([], "nope")
print("UNKNOWN_RC", rc_unknown)

# --- usage error: extra positional args ---
rc_usage = nv._cmd_assistant_prune(["extra"], None)
print("USAGE_RC", rc_usage)
PY
)"
rc=$?
check_rc "assistant prune fixture script exits 0" 0 "$rc"
check "assistant prune: seeded row present before prune" "BEFORE_COUNT 1" "$prune_out"
check "assistant prune: exits 0 against a dormant (no server) fixture" "PRUNE_RC 0" "$prune_out"
check "assistant prune: the stale row (older than retainDays=1) is actually gone after pruning" "AFTER_COUNT 0" "$prune_out"
check "assistant prune: no assistant discovered is a clean nonzero, not a crash" "MISSING_RC 1" "$prune_out"
check "assistant prune: an unmatched --assistant name is a clean nonzero, not a crash" "UNKNOWN_RC 1" "$prune_out"
check "assistant prune: extra positional args are a clean usage error" "USAGE_RC 2" "$prune_out"
check_absent "assistant prune: no raw traceback anywhere in the fixture run" "Traceback" "$prune_out"

# --- the live-writer race: a real EXCLUSIVE lock held on the same
# traces.sqlite (simulating a running neural-view.py serve process own
# writer thread) must make this verb fail LOUD (clean nonzero + explained
# message), never silently succeed or corrupt the db (Sec10.2 single-
# writer discipline; see _cmd_assistant_prune docstring).
race_out="$(SCRIPTS_DIR="$PLUGIN/scripts" ROOT="$_at_g_root" python3 - "$AT_NV" <<'PY'
import importlib.util, os, sys, sqlite3

sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import observability

spec_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("neural_view", spec_path)
nv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nv)

root = os.environ["ROOT"]
nv.discover_repos = lambda args: [("jarvis", root)]

conn0, _ = observability._open_conn(root)
conn0.execute("PRAGMA journal_mode=DELETE")
conn0.close()

db_path = observability._db_path(root)
locker = sqlite3.connect(db_path, isolation_level=None)
locker.execute("PRAGMA busy_timeout=100")
locker.execute("BEGIN EXCLUSIVE")

rc = nv._cmd_assistant_prune([], None)
print("RACE_RC", rc)

locker.execute("ROLLBACK")
locker.close()
PY
)"
race_rc=$?
check_rc "assistant prune race-simulation script exits 0" 0 "$race_rc"
check "assistant prune: a live-writer lock race fails loud (clean nonzero), never a silent no-op" "RACE_RC 1" "$race_out"
check_absent "assistant prune: the live-writer race still never prints a raw traceback" "Traceback" "$race_out"

rm -rf "$_at_g_root" "$_at_g_state"
