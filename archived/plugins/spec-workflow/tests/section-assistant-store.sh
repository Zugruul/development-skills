#!/usr/bin/env bash
# section-assistant-store.sh -- AST-014: session store -- append-safe
# transcript + rolling state, /assistant/history route (SPEC-ASSISTANT.md
# §4, §8.7, issue #312). Sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
# shellcheck disable=SC2016  # lifecycle_start command-strings are single-quoted on
# purpose -- they're expanded when eval'd inside the function, not at call site.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== assistant session store (AST-014: append-safe transcript + rolling state, SPEC-ASSISTANT.md §4/§8.7) =="

AS_SCRIPTS="$PLUGIN/scripts"
NV="$PLUGIN/scripts/neural-view.py"

# as_repo <dir> <name> -- a marker'd repo with a structurally valid, enabled
# assistant: section (mirrors section-assistant-engine.sh's ae_repo).
as_repo() {
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

# --------------------------------------------------------------- unit: append/read round trip
echo "-- unit: append/read round trip --"
_as_root="$(mktemp -d)"
out="$(SCRIPTS_DIR="$AS_SCRIPTS" ROOT="$_as_root" python3 - <<'PY'
import os
import sys

sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant.store import SessionStore

store = SessionStore(os.environ["ROOT"])
r1 = store.append_exchange("hello", "hi there", {"turn": 1})
r2 = store.append_exchange("how are you", "great, thanks", {"turn": 2})
print("R1_KEYS", sorted(r1.keys()))
print("R1_USER", r1["user"])
print("R2_ASSISTANT", r2["assistant"])
print("R2_META", r2["meta"])

result = store.history()
print("EXCHANGE_COUNT", len(result["exchanges"]))
print("WARNINGS_EMPTY", result["warnings"] == [])
print("ORDER_PRESERVED", [e["user"] for e in result["exchanges"]] == ["hello", "how are you"])
PY
)"
rc=$?
check_rc "append/read: script exits 0" 0 "$rc"
check "append/read: record has the documented keys" "R1_KEYS ['assistant', 'meta', 'ts', 'user']" "$out"
check "append/read: user text round-trips" "R1_USER hello" "$out"
check "append/read: assistant text round-trips" "R2_ASSISTANT great, thanks" "$out"
check "append/read: meta round-trips" "R2_META {'turn': 2}" "$out"
check "append/read: history returns both exchanges" "EXCHANGE_COUNT 2" "$out"
check "append/read: no warnings on a clean transcript" "WARNINGS_EMPTY True" "$out"
check "append/read: chronological order preserved" "ORDER_PRESERVED True" "$out"
rm -rf "$_as_root"

# --------------------------------------------------------------- unit: transcript path + gitignore
echo "-- unit: transcript lives under .claude/assistant/, gitignored --"
_as_gi_root="$(mktemp -d)"
( cd "$_as_gi_root" && git init -q . )
as_repo "$_as_gi_root" jarvis
bash "$PLUGIN/scripts/gitignore-sync.sh" "$_as_gi_root/.gitignore" >/dev/null 2>&1
SCRIPTS_DIR="$AS_SCRIPTS" ROOT="$_as_gi_root" python3 - <<'PY' >/dev/null
import os
import sys

sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant.store import SessionStore

SessionStore(os.environ["ROOT"]).append_exchange("hi", "hello", {})
PY
[[ -f "$_as_gi_root/.claude/assistant/session.jsonl" ]] && r=yes || r=no
check "transcript path: session.jsonl exists under .claude/assistant/" "yes" "$r"
if ( cd "$_as_gi_root" && git check-ignore -q .claude/assistant/session.jsonl ); then
    r=ignored
else
    r=NOT-IGNORED
fi
check "transcript path: git check-ignore confirms .claude/assistant/ is gitignored" "ignored" "$r"
rm -rf "$_as_gi_root"

# --------------------------------------------------------------- unit: state atomic save/load
echo "-- unit: rolling state atomic save/load --"
_as_state_root="$(mktemp -d)"
out="$(SCRIPTS_DIR="$AS_SCRIPTS" ROOT="$_as_state_root" python3 - <<'PY'
import glob
import os
import sys

sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant.store import SessionStore

root = os.environ["ROOT"]
store = SessionStore(root)

empty = store.load_state()
print("EMPTY_STATE", empty)

state = {"summary": "prior recap", "turns": [{"role": "user", "text": "hi"}], "turn_count": 3}
store.save_state(state)
loaded = store.load_state()
print("ROUND_TRIP", loaded == state)

leftover = glob.glob(os.path.join(root, ".claude", "assistant", ".assistant-session-state-tmp-*"))
print("NO_TMP_LEFTOVER", leftover == [])

state2 = {"summary": "second recap", "turns": [], "turn_count": 5}
store.save_state(state2)
print("OVERWRITE_ROUND_TRIP", store.load_state() == state2)
PY
)"
rc=$?
check_rc "state atomic save/load: script exits 0" 0 "$rc"
check "state: no state file yet returns the documented empty shape" \
    "EMPTY_STATE {'summary': '', 'turns': [], 'turn_count': 0}" "$out"
check "state: save then load round-trips exactly" "ROUND_TRIP True" "$out"
check "state: atomic write leaves no tmp file behind" "NO_TMP_LEFTOVER True" "$out"
check "state: a second save overwrites cleanly" "OVERWRITE_ROUND_TRIP True" "$out"
rm -rf "$_as_state_root"

# --------------------------------------------------------------- unit: torn-line tolerance (hand-truncated)
echo "-- unit: torn last line is tolerated, not a crash --"
_as_torn_root="$(mktemp -d)"
out="$(SCRIPTS_DIR="$AS_SCRIPTS" ROOT="$_as_torn_root" python3 - <<'PY'
import os
import sys

sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant.store import SessionStore, STATE_DIR_REL, TRANSCRIPT_FILE_NAME

root = os.environ["ROOT"]
store = SessionStore(root)
store.append_exchange("one", "reply one", {})
store.append_exchange("two", "reply two", {})

transcript_path = os.path.join(root, STATE_DIR_REL, TRANSCRIPT_FILE_NAME)
with open(transcript_path, "a", encoding="utf-8") as fh:
    fh.write('{"ts": "2026-01-01T00:00:00", "user": "thr')  # deliberately truncated, no closing brace/newline

result = store.history()
print("EXCHANGE_COUNT", len(result["exchanges"]))
print("WARNING_COUNT", len(result["warnings"]))
print("KEPT_ORDER", [e["user"] for e in result["exchanges"]] == ["one", "two"])
PY
)"
rc=$?
check_rc "torn-line tolerance: script exits 0 (never raises)" 0 "$rc"
check "torn-line tolerance: complete exchanges survive" "EXCHANGE_COUNT 2" "$out"
check "torn-line tolerance: exactly one warning for the torn line" "WARNING_COUNT 1" "$out"
check "torn-line tolerance: surviving order preserved" "KEPT_ORDER True" "$out"
rm -rf "$_as_torn_root"

# --------------------------------------------------------------- unit: history n-window edge cases
echo "-- unit: history n-window edge cases --"
_as_n_root="$(mktemp -d)"
out="$(SCRIPTS_DIR="$AS_SCRIPTS" ROOT="$_as_n_root" python3 - <<'PY'
import os
import sys

sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant.store import SessionStore

store = SessionStore(os.environ["ROOT"])
for i in range(1, 6):
    store.append_exchange("u%d" % i, "a%d" % i, {})

print("N_ZERO", len(store.history(0)["exchanges"]))
print("N_ONE", [e["user"] for e in store.history(1)["exchanges"]])
print("N_HUGE", len(store.history(1000000)["exchanges"]))
print("N_NEGATIVE", len(store.history(-3)["exchanges"]))
PY
)"
rc=$?
check_rc "n-window edge cases: script exits 0" 0 "$rc"
check "n-window: n=0 returns no exchanges" "N_ZERO 0" "$out"
check "n-window: n=1 returns only the most recent exchange" "N_ONE ['u5']" "$out"
check "n-window: n larger than the transcript returns everything available" "N_HUGE 5" "$out"
check "n-window: negative n treated as zero" "N_NEGATIVE 0" "$out"
rm -rf "$_as_n_root"

# --------------------------------------------------------------- discrimination: fsync is actually called
echo "-- unit: append_exchange calls os.fsync (discrimination proof) --"
_as_fsync_root="$(mktemp -d)"
out="$(SCRIPTS_DIR="$AS_SCRIPTS" ROOT="$_as_fsync_root" python3 - <<'PY'
import os
import sys

sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import store as store_module

calls = []
real_fsync = os.fsync


def counting_fsync(fd):
    calls.append(fd)
    return real_fsync(fd)


store_module.os.fsync = counting_fsync
try:
    s = store_module.SessionStore(os.environ["ROOT"])
    s.append_exchange("one", "reply one", {})
    s.append_exchange("two", "reply two", {})
    s.append_exchange("three", "reply three", {})
finally:
    store_module.os.fsync = real_fsync

print("FSYNC_CALLS", len(calls))
PY
)"
rc=$?
check_rc "fsync discrimination: script exits 0" 0 "$rc"
check "fsync discrimination: exactly one os.fsync call per append_exchange" "FSYNC_CALLS 3" "$out"
rm -rf "$_as_fsync_root"

# --------------------------------------------------------------- kill-test A: clean crash between complete appends
echo "-- kill-test A: SIGKILL between complete appends -- exactly the completed ones survive --"
_as_kill_a_root="$(mktemp -d)"
_as_kill_a_gate="$(mktemp -d)"
_as_kill_a_marker="$_as_kill_a_gate/marker"
_as_writer_a="$FIX/ast014-writer-clean.py"
mkdir -p "$FIX"
cat >"$_as_writer_a" <<'PY'
import os
import sys
import time

sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant.store import SessionStore

root = sys.argv[1]
count = int(sys.argv[2])
marker_path = sys.argv[3]
gate_dir = sys.argv[4]

store = SessionStore(root)
for i in range(1, count + 1):
    store.append_exchange("u%d" % i, "a%d" % i, {"i": i})
    with open(marker_path, "w", encoding="utf-8") as fh:
        fh.write(str(i))
    gate = os.path.join(gate_dir, "go-%d" % (i + 1))
    while not os.path.exists(gate):
        time.sleep(0.01)
PY
# Deterministic barrier: only iterations 1..3 are permitted to proceed (the
# go-4 gate file is never created), so the writer is guaranteed to be parked
# in its gate-wait loop immediately after the 3rd exchange's fsync returns --
# never mid-write of a 4th -- when the kill lands.
touch "$_as_kill_a_gate/go-1" "$_as_kill_a_gate/go-2" "$_as_kill_a_gate/go-3"
SCRIPTS_DIR="$AS_SCRIPTS" python3 "$_as_writer_a" "$_as_kill_a_root" 5 "$_as_kill_a_marker" "$_as_kill_a_gate" &
_as_kill_a_pid=$!
_as_kill_a_seen=""
for _ in $(seq 1 300); do
    if [[ -f "$_as_kill_a_marker" ]]; then
        _as_kill_a_seen="$(cat "$_as_kill_a_marker")"
        [[ "$_as_kill_a_seen" == "3" ]] && break
    fi
    sleep 0.02
done
check "kill-test A: writer reached the barrier at exchange 3" "3" "$_as_kill_a_seen"
kill -9 "$_as_kill_a_pid" 2>/dev/null
wait "$_as_kill_a_pid" 2>/dev/null

out="$(SCRIPTS_DIR="$AS_SCRIPTS" ROOT="$_as_kill_a_root" python3 - <<'PY'
import os
import sys

sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant.store import SessionStore

store = SessionStore(os.environ["ROOT"])
result = store.history()
print("SURVIVOR_COUNT", len(result["exchanges"]))
print("NO_WARNINGS", result["warnings"] == [])
print("ORDER", [e["user"] for e in result["exchanges"]])
PY
)"
check "kill-test A: exactly the 3 completed exchanges survive" "SURVIVOR_COUNT 3" "$out"
check "kill-test A: no torn line -- kill landed strictly between appends" "NO_WARNINGS True" "$out"
check "kill-test A: surviving order preserved" "ORDER ['u1', 'u2', 'u3']" "$out"
rm -rf "$_as_kill_a_root" "$_as_kill_a_gate" "$_as_writer_a"

# --------------------------------------------------------------- kill-test B: crash mid-write (torn trailing line)
echo "-- kill-test B: SIGKILL mid-write -- torn trailing line tolerated, prior exchanges intact --"
_as_kill_b_root="$(mktemp -d)"
_as_kill_b_gate="$(mktemp -d)"
_as_kill_b_marker="$_as_kill_b_gate/marker"
_as_writer_b="$FIX/ast014-writer-torn.py"
cat >"$_as_writer_b" <<'PY'
import json
import os
import sys
import time

sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant.store import SessionStore, STATE_DIR_REL, TRANSCRIPT_FILE_NAME

root = sys.argv[1]
complete_count = int(sys.argv[2])
marker_path = sys.argv[3]
gate_dir = sys.argv[4]

store = SessionStore(root)
for i in range(1, complete_count + 1):
    store.append_exchange("u%d" % i, "a%d" % i, {"i": i})

# simulate a write interrupted mid-line: a raw partial write with no
# trailing newline and no fsync, then park at the gate -- this is the exact
# artifact a real kill-mid-write leaves (bytes on disk that never completed
# the JSON object nor the newline terminator).
full_line = json.dumps({"ts": "2026-01-01T00:00:00", "user": "torn", "assistant": "torn", "meta": {}})
transcript_path = os.path.join(root, STATE_DIR_REL, TRANSCRIPT_FILE_NAME)
with open(transcript_path, "a", encoding="utf-8") as fh:
    fh.write(full_line[: len(full_line) // 2])
    fh.flush()

with open(marker_path, "w", encoding="utf-8") as fh:
    fh.write("torn-written")

gate = os.path.join(gate_dir, "go")
while not os.path.exists(gate):
    time.sleep(0.01)
PY
SCRIPTS_DIR="$AS_SCRIPTS" python3 "$_as_writer_b" "$_as_kill_b_root" 2 "$_as_kill_b_marker" "$_as_kill_b_gate" &
_as_kill_b_pid=$!
_as_kill_b_seen=""
for _ in $(seq 1 300); do
    if [[ -f "$_as_kill_b_marker" ]]; then
        _as_kill_b_seen="$(cat "$_as_kill_b_marker")"
        [[ "$_as_kill_b_seen" == "torn-written" ]] && break
    fi
    sleep 0.02
done
check "kill-test B: writer parked after the torn partial write" "torn-written" "$_as_kill_b_seen"
kill -9 "$_as_kill_b_pid" 2>/dev/null
wait "$_as_kill_b_pid" 2>/dev/null

out="$(SCRIPTS_DIR="$AS_SCRIPTS" ROOT="$_as_kill_b_root" python3 - <<'PY'
import os
import sys

sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant.store import SessionStore

store = SessionStore(os.environ["ROOT"])
result = store.history()
print("SURVIVOR_COUNT", len(result["exchanges"]))
print("WARNING_COUNT", len(result["warnings"]))
print("ORDER", [e["user"] for e in result["exchanges"]])
PY
)"
check "kill-test B: the 2 committed exchanges are intact" "SURVIVOR_COUNT 2" "$out"
check "kill-test B: the torn trailing line is reported as exactly one warning" "WARNING_COUNT 1" "$out"
check "kill-test B: intact-exchange order preserved" "ORDER ['u1', 'u2']" "$out"
rm -rf "$_as_kill_b_root" "$_as_kill_b_gate" "$_as_writer_b"

# --------------------------------------------------------------- engine integration: /assistant/history route
echo "-- integration: /assistant/history on a live server --"
_as_int_root="$(mktemp -d)"
_as_int_state="$(mktemp -d)"
_as_int_scan_empty="$(mktemp -d)"
as_repo "$_as_int_root" friday

export NEURAL_VIEW_STATE="$_as_int_state" NEURAL_VIEW_SCAN="$_as_int_scan_empty"
lifecycle_start "assistant store: neural-view starts" NEURAL_VIEW_PORT 'python3 "$NV" start --dir "$_as_int_root"'

hist_body="$(curl -sf "http://127.0.0.1:$NEURAL_VIEW_PORT/assistant/history")"
check "assistant/history: response has exchanges key" '"exchanges"' "$hist_body"
check "assistant/history: response has warnings key" '"warnings"' "$hist_body"
check "assistant/history: no exchanges yet (no turn route wired in this task)" '"exchanges": []' "$hist_body"

n_code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$NEURAL_VIEW_PORT/assistant/history?n=5")"
check "assistant/history: ?n=5 still returns 200" "200" "$n_code"

_as_int_pid="$(cat "$_as_int_state/pid")"
python3 "$NV" stop >/dev/null
for _ in $(seq 1 30); do
    kill -0 "$_as_int_pid" 2>/dev/null || break
    sleep 0.1
done

unset NEURAL_VIEW_STATE NEURAL_VIEW_PORT NEURAL_VIEW_SCAN
rm -rf "$_as_int_root" "$_as_int_state" "$_as_int_scan_empty"

# --- review r1: an UNREADABLE transcript (chmod 000) degrades to a warning,
# never an uncaught PermissionError (which dropped the HTTP response). ---------
as_d="$(mktemp -d)"
as_r1_out="$(PYTHONPATH="$AS_SCRIPTS" python3 - "$as_d" <<'PY'
import sys, os
from assistant.store import SessionStore
root = sys.argv[1]
s = SessionStore(root)
s.append_exchange("u", "a", {})
os.chmod(s._transcript_path, 0)
try:
    r = s.history(5)
    print("NO_CRASH True")
    print("WARNED", len(r["warnings"]) >= 1)
    print("EMPTY_OK", r["exchanges"] == [])
finally:
    os.chmod(s._transcript_path, 0o644)
PY
)"
as_r1_rc=$?
check_rc "r1: unreadable transcript probe runs" 0 "$as_r1_rc"
check "r1: unreadable transcript never crashes history()" "NO_CRASH True" "$as_r1_out"
check "r1: unreadable transcript surfaces a warning" "WARNED True" "$as_r1_out"
check "r1: unreadable transcript yields empty exchanges honestly" "EMPTY_OK True" "$as_r1_out"
rm -rf "$as_d"
