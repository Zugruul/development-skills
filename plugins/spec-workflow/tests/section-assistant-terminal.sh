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
    mkdir -p "$dir/.claude"
    printf '%s\n' '# neural-network' >"$dir/.claude/.neural-network"
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
        >"$dir/.claude/project.yaml"
}

# at_no_assistant_repo <dir> -- marker'd but no assistant: section, i.e.
# not a candidate (mirrors ae_repo_b in section-assistant-engine.sh).
at_no_assistant_repo() {
    local dir="$1"
    mkdir -p "$dir/.claude"
    printf '%s\n' '# neural-network' >"$dir/.claude/.neural-network"
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

unset NEURAL_VIEW_STATE
rm -rf "$_at_e_state"
