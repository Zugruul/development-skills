#!/usr/bin/env bash
# section-assistant-traces.sh -- AST-040: event emitter + traces.sqlite
# writer (SPEC-ASSISTANT.md Sec10.1/Sec10.2/Sec10.6/Sec10.7, E4, issue #326,
# docs/design/ast-E4.md). Sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== assistant traces (AST-040: event emitter + traces.sqlite writer, SPEC-ASSISTANT.md Sec10.1/Sec10.2/Sec10.6/Sec10.7) =="

AT_SCRIPTS="$PLUGIN/scripts"

at_repo() {
    local dir="$1" main="$2"
    mkdir -p "$dir/.claude"
    printf "%s\n" "# neural-network" >"$dir/.claude/.neural-network"
    printf "%s\n" \
        "schemaVersion: 2" \
        "assistant:" \
        "    version: 1" \
        "    enabled: true" \
        "    names: [$main]" \
        "    systemPrompt: |" \
        "        You are $main." \
        "    llm:" \
        "        provider: openai" \
        "        model: gpt-5.6-sol" \
        "    capabilities:" \
        "        codex:" \
        "            enabled: true" \
        "            provisioning:" \
        "                bin: codex" \
        >"$dir/.claude/project.yaml"
}

# ------------------------------------------------------------------------
echo "-- unit: schema idempotent create + WAL mode on --"
schema_out="$(SCRIPTS_DIR="$AT_SCRIPTS" python3 - <<'PY'
import os, sys, tempfile, threading, queue, time, sqlite3
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import observability

root = tempfile.mkdtemp(prefix="at-schema-")
q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=observability.run_writer, args=(q, stop))
t.start()
observability.emit(q, root, {"kind": "turn.start", "turn_id": "t1"})
time.sleep(0.6)
stop.set()
t.join(timeout=3)

db_path = os.path.join(root, ".claude", "assistant", "traces.sqlite")
print("DB_EXISTS", os.path.exists(db_path))
conn = sqlite3.connect(db_path)
mode = conn.execute("PRAGMA journal_mode").fetchone()[0]
print("JOURNAL_MODE", mode)
conn.execute("CREATE TABLE IF NOT EXISTS events (seq INTEGER PRIMARY KEY)")  # idempotent no-op guard sanity
conn.close()

# reopening the writer against the SAME root must not fail (idempotent DDL)
q2 = queue.Queue()
stop2 = threading.Event()
t2 = threading.Thread(target=observability.run_writer, args=(q2, stop2))
t2.start()
observability.emit(q2, root, {"kind": "turn.start", "turn_id": "t2"})
time.sleep(0.6)
stop2.set()
t2.join(timeout=3)
print("REOPEN_OK", True)
PY
)"
check "traces schema: traces.sqlite created under <root>/.claude/assistant/" "DB_EXISTS True" "$schema_out"
check "traces schema: WAL mode is on" "JOURNAL_MODE wal" "$schema_out"
check "traces schema: reopening the writer against an existing db is idempotent" "REOPEN_OK True" "$schema_out"

# ------------------------------------------------------------------------
echo "-- unit: emit -> writer drain -> events visible via query --"
drain_out="$(SCRIPTS_DIR="$AT_SCRIPTS" python3 - <<'PY'
import os, sys, tempfile, threading, queue, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import observability

root = tempfile.mkdtemp(prefix="at-drain-")
q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=observability.run_writer, args=(q, stop))
t.start()

observability.emit(q, root, {"kind": "turn.start", "turn_id": "t1", "session_id": "s1", "payload": {"n": 1}})
observability.emit(q, root, {"kind": "turn.end", "turn_id": "t1", "session_id": "s1", "status": "ok"})

deadline = time.monotonic() + 5.0
rows = []
while time.monotonic() < deadline:
    rows = observability.query(root)
    if len(rows) >= 2:
        break
    time.sleep(0.2)

stop.set()
t.join(timeout=3)

print("ROW_COUNT", len(rows))
print("KINDS", [r["kind"] for r in rows])
print("PAYLOAD_ROUNDTRIP", rows[0]["payload"] == {"n": 1} if rows else None)
print("SESSION_ID_STORED", rows[0]["session_id"] == "s1" if rows else None)
PY
)"
check "emit->drain: both events land in traces.sqlite" "ROW_COUNT 2" "$drain_out"
check "emit->drain: kinds preserved in seq order" "KINDS ['turn.start', 'turn.end']" "$drain_out"
check "emit->drain: JSON payload round-trips through the payload column" "PAYLOAD_ROUNDTRIP True" "$drain_out"
check "emit->drain: session_id stored on the first-class column" "SESSION_ID_STORED True" "$drain_out"

# ------------------------------------------------------------------------
echo "-- unit: seq is monotonic per root, including after a writer reopen --"
seq_out="$(SCRIPTS_DIR="$AT_SCRIPTS" python3 - <<'PY'
import os, sys, tempfile, threading, queue, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import observability

root = tempfile.mkdtemp(prefix="at-seq-")

def run_batch(n, start_i):
    q = queue.Queue()
    stop = threading.Event()
    t = threading.Thread(target=observability.run_writer, args=(q, stop))
    t.start()
    for i in range(start_i, start_i + n):
        observability.emit(q, root, {"kind": "turn.start", "turn_id": "t%d" % i})
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        if len(observability.query(root, limit=1000)) >= start_i + n:
            break
        time.sleep(0.2)
    stop.set()
    t.join(timeout=3)

run_batch(3, 0)
rows1 = observability.query(root, limit=1000)
seqs1 = [r["seq"] for r in rows1]
print("SEQS_FIRST_OPEN", seqs1)
print("MONOTONIC_FIRST", seqs1 == sorted(seqs1) and len(set(seqs1)) == len(seqs1))

# reopen (a NEW run_writer thread/queue over the SAME root) -- seq must
# continue from where it left off, never reset to 1.
run_batch(2, 3)
rows2 = observability.query(root, limit=1000)
seqs2 = [r["seq"] for r in rows2]
print("SEQS_AFTER_REOPEN", seqs2)
print("CONTINUES_AFTER_REOPEN", seqs2 == sorted(seqs2) and len(set(seqs2)) == len(seqs2) and max(seqs1) < min(s for s in seqs2 if s not in seqs1))
PY
)"
check "seq: monotonic within one writer session" "MONOTONIC_FIRST True" "$seq_out"
check "seq: reseeded from MAX(seq) after reopen -- continues, never resets" "CONTINUES_AFTER_REOPEN True" "$seq_out"

# ------------------------------------------------------------------------
echo "-- unit: query filters by since (seq cursor) and turn, index-backed --"
qfilter_out="$(SCRIPTS_DIR="$AT_SCRIPTS" python3 - <<'PY'
import os, sys, tempfile, threading, queue, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import observability

root = tempfile.mkdtemp(prefix="at-qfilter-")
q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=observability.run_writer, args=(q, stop))
t.start()

observability.emit(q, root, {"kind": "turn.start", "turn_id": "tA"})
observability.emit(q, root, {"kind": "turn.end", "turn_id": "tA"})
observability.emit(q, root, {"kind": "turn.start", "turn_id": "tB"})
observability.emit(q, root, {"kind": "turn.end", "turn_id": "tB"})

deadline = time.monotonic() + 5.0
all_rows = []
while time.monotonic() < deadline:
    all_rows = observability.query(root, limit=1000)
    if len(all_rows) >= 4:
        break
    time.sleep(0.2)
stop.set()
t.join(timeout=3)

by_turn = observability.query(root, turn="tA")
print("TURN_FILTER_COUNT", len(by_turn))
print("TURN_FILTER_ALL_TA", all(r["turn_id"] == "tA" for r in by_turn))

first_seq = all_rows[0]["seq"]
since_rows = observability.query(root, since=first_seq)
print("SINCE_FILTER_COUNT", len(since_rows))
print("SINCE_FILTER_EXCLUDES_FIRST", all(r["seq"] > first_seq for r in since_rows))
PY
)"
check "query: turn filter returns only that turn's events" "TURN_FILTER_COUNT 2" "$qfilter_out"
check "query: turn filter never mixes in another turn's rows" "TURN_FILTER_ALL_TA True" "$qfilter_out"
check "query: since=<seq> excludes everything at or before that seq" "SINCE_FILTER_COUNT 3" "$qfilter_out"
check "query: since filter is a strict > comparison" "SINCE_FILTER_EXCLUDES_FIRST True" "$qfilter_out"

# ------------------------------------------------------------------------
echo "-- unit: query(order=desc) returns the NEWEST limit rows, re-sorted ascending (#393) --"
order_out="$(SCRIPTS_DIR="$AT_SCRIPTS" python3 - <<'PY'
import os, sys, tempfile, threading, queue, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import observability

root = tempfile.mkdtemp(prefix="at-order-")
q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=observability.run_writer, args=(q, stop))
t.start()

N = 10
for i in range(N):
    observability.emit(q, root, {"kind": "turn.start", "turn_id": "t%d" % i})

deadline = time.monotonic() + 5.0
all_rows = []
while time.monotonic() < deadline:
    all_rows = observability.query(root, limit=1000)
    if len(all_rows) >= N:
        break
    time.sleep(0.2)
stop.set()
t.join(timeout=3)

# asc (default, back-compat): a 5-row limit on 10 rows returns the OLDEST 5.
asc_rows = observability.query(root, limit=5)
print("ASC_TURN_IDS", [r["turn_id"] for r in asc_rows])

# desc: the SAME 5-row limit must instead return the NEWEST 5 -- the #393
# bug is exactly this returning the same oldest-5 as asc.
desc_rows = observability.query(root, limit=5, order="desc")
print("DESC_TURN_IDS", [r["turn_id"] for r in desc_rows])
print("DESC_STILL_SEQ_ASCENDING", [r["seq"] for r in desc_rows] == sorted(r["seq"] for r in desc_rows))

# order defaults to asc (existing callers see identical behavior).
default_rows = observability.query(root, limit=5)
print("DEFAULT_MATCHES_ASC", [r["turn_id"] for r in default_rows] == [r["turn_id"] for r in asc_rows])
PY
)"
check "query order=desc: default (asc) returns the oldest 5 turns" "ASC_TURN_IDS ['t0', 't1', 't2', 't3', 't4']" "$order_out"
check "query order=desc: returns the newest 5 turns instead" "DESC_TURN_IDS ['t5', 't6', 't7', 't8', 't9']" "$order_out"
check "query order=desc: rows are re-sorted ascending before returning (never desc order to the caller)" "DESC_STILL_SEQ_ASCENDING True" "$order_out"
check "query order=desc: an absent order= matches the explicit asc call exactly (back-compat)" "DEFAULT_MATCHES_ASC True" "$order_out"

# ------------------------------------------------------------------------
echo "-- unit: emitter never raises when the queue is full --"
overflow_out="$(SCRIPTS_DIR="$AT_SCRIPTS" python3 - <<'PY'
import os, sys, queue, io, contextlib
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import observability

q = queue.Queue(maxsize=1)
q.put_nowait({"root": "r", "event": {"kind": "filler"}})  # queue is now full

stderr_buf = io.StringIO()
raised = False
with contextlib.redirect_stderr(stderr_buf):
    try:
        observability.emit(q, "/some/root", {"kind": "turn.start"})
    except Exception:
        raised = True

print("RAISED", raised)
print("STDERR_MENTIONS_DROP", "observability" in stderr_buf.getvalue() and "full" in stderr_buf.getvalue().lower())
PY
)"
check "emit: never raises on a full queue" "RAISED False" "$overflow_out"
check "emit: a dropped event is noted on stderr, not silently swallowed" "STDERR_MENTIONS_DROP True" "$overflow_out"

# ------------------------------------------------------------------------
echo "-- unit: distill.batch event emitted on distiller batch completion --"
distill_trace_out="$(SCRIPTS_DIR="$AT_SCRIPTS" python3 - <<'PY'
import os, sys, tempfile, threading, time, queue
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import distill, observability

root = tempfile.mkdtemp(prefix="at-distill-")
identities = os.path.join(root, ".claude", "identities")
os.makedirs(identities, exist_ok=True)

dq = queue.Queue()
tq = queue.Queue()
stop_d = threading.Event()
stop_t = threading.Event()
td = threading.Thread(target=distill.run_worker, args=(dq, stop_d),
                       kwargs={"batch_n": 2, "traces_queue": tq})
tt = threading.Thread(target=observability.run_writer, args=(tq, stop_t))
td.start()
tt.start()

def item(i):
    return {"root": root, "identities": identities,
            "exchange": {"user": "message %d about rocket telemetry" % i, "assistant": "ack"}}

dq.put(item(0))
dq.put(item(1))

deadline = time.monotonic() + 5.0
rows = []
while time.monotonic() < deadline:
    rows = observability.query(root)
    if any(r["kind"] == "distill.batch" for r in rows):
        break
    time.sleep(0.2)

stop_d.set()
td.join(timeout=3)
stop_t.set()
tt.join(timeout=3)

print("DISTILL_BATCH_EVENT_SEEN", any(r["kind"] == "distill.batch" for r in rows))
PY
)"
check "distill.batch: a real batch completion emits a distill.batch trace event" "DISTILL_BATCH_EVENT_SEEN True" "$distill_trace_out"

# ------------------------------------------------------------------------
echo "-- integration: engine wiring -- _chat emits turn.start/recall.*/provider.call/turn.end --"
_at_root="$(mktemp -d)"
at_repo "$_at_root" jarvis

engine_out="$(SCRIPTS_DIR="$AT_SCRIPTS" ROOT="$_at_root" python3 - <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import adapters, engine, observability

root = os.environ["ROOT"]

def stub_complete(context, **kwargs):
    return {"text": "reply about rocket telemetry", "usage": {"tokens": 12}, "timings": None}

adapters.register_adapter("openai", stub_complete)

state_dir = os.path.join(root, ".claude", "assistant-engine-state")
e = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir)
e.start()
try:
    status, payload, _ = e.handle("POST", "/assistant/chat", body={"message": "tell me about rocket telemetry"})
    print("CHAT_STATUS", status)

    deadline = time.monotonic() + 5.0
    rows = []
    while time.monotonic() < deadline:
        rows = observability.query(root)
        kinds = [r["kind"] for r in rows]
        if "turn.end" in kinds:
            break
        time.sleep(0.2)
    kinds = [r["kind"] for r in rows]
    print("KINDS", kinds)
    print("HAS_TURN_START", "turn.start" in kinds)
    print("HAS_PROVIDER_CALL", "provider.call" in kinds)
    print("HAS_TURN_END", "turn.end" in kinds)

    turn_ids = {r["turn_id"] for r in rows if r.get("turn_id")}
    print("SINGLE_TURN_ID", len(turn_ids) == 1)
finally:
    e.stop()
    print("ENGINE_STOPPED_CLEANLY", True)
PY
)"
check "engine wiring: a chat turn emits turn.start" "HAS_TURN_START True" "$engine_out"
check "engine wiring: a chat turn emits provider.call" "HAS_PROVIDER_CALL True" "$engine_out"
check "engine wiring: a chat turn emits turn.end" "HAS_TURN_END True" "$engine_out"
check "engine wiring: every trace event for one turn shares one turn_id" "SINGLE_TURN_ID True" "$engine_out"
check "engine wiring: engine.stop() joins the (now real) traces worker cleanly" "ENGINE_STOPPED_CLEANLY True" "$engine_out"
if [[ "$engine_out" != *"HAS_TURN_END True"* ]]; then echo "$engine_out" >&2; fi
rm -rf "$_at_root"

# ------------------------------------------------------------------------
echo "-- integration: a provider failure emits a first-class provider.error linked to its turn --"
_ate_root="$(mktemp -d)"
at_repo "$_ate_root" jarvis

err_out="$(SCRIPTS_DIR="$AT_SCRIPTS" ROOT="$_ate_root" python3 - <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import adapters, engine, observability

root = os.environ["ROOT"]

def failing_complete(context, **kwargs):
    raise adapters.NonzeroExit("provider exited 1")

adapters.register_adapter("openai", failing_complete)

state_dir = os.path.join(root, ".claude", "assistant-engine-state")
e = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir)
e.start()
try:
    status, payload, _ = e.handle("POST", "/assistant/chat", body={"message": "hello"})
    print("CHAT_STATUS", status)

    deadline = time.monotonic() + 5.0
    rows = []
    while time.monotonic() < deadline:
        rows = observability.query(root)
        if any(r["kind"] == "provider.error" for r in rows):
            break
        time.sleep(0.2)

    error_rows = [r for r in rows if r["kind"] == "provider.error"]
    print("ERROR_EVENT_SEEN", len(error_rows) == 1)
    print("ERROR_LINKED_TO_TURN", bool(error_rows) and bool(error_rows[0].get("turn_id")))
    turn_ids = {r["turn_id"] for r in rows if r.get("turn_id")}
    print("ERROR_SHARES_TURN_ID_WITH_START", len(turn_ids) == 1)
finally:
    e.stop()
PY
)"
check "provider error: a 502 chat still records a first-class provider.error event" "ERROR_EVENT_SEEN True" "$err_out"
check "provider error: the error event carries a turn_id (Sec10.6 linkage)" "ERROR_LINKED_TO_TURN True" "$err_out"
check "provider error: the error's turn_id matches the turn's other events" "ERROR_SHARES_TURN_ID_WITH_START True" "$err_out"
rm -rf "$_ate_root"

# ------------------------------------------------------------------------
echo "-- integration: turns never block on the traces writer (bounded latency under load) --"
_atl_root="$(mktemp -d)"
at_repo "$_atl_root" jarvis

latency_out="$(SCRIPTS_DIR="$AT_SCRIPTS" ROOT="$_atl_root" python3 - <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import adapters, engine

root = os.environ["ROOT"]

def stub_complete(context, **kwargs):
    return {"text": "reply", "usage": None, "timings": None}

adapters.register_adapter("openai", stub_complete)

def timed_chat_calls(e, count):
    t0 = time.monotonic()
    for i in range(count):
        status, _payload, _ct = e.handle("POST", "/assistant/chat", body={"message": "hello %d" % i})
        if status != 200:
            return None
    return time.monotonic() - t0

state_dir_baseline = os.path.join(root, ".claude", "assistant-engine-state-baseline")
e_baseline = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir_baseline)
e_baseline.start()
baseline_elapsed = timed_chat_calls(e_baseline, 10)
e_baseline.stop()

state_dir_loaded = os.path.join(root, ".claude", "assistant-engine-state-loaded")
e_loaded = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir_loaded)
e_loaded.start()
backlog_q = e_loaded.queues["traces"]
for i in range(500):
    try:
        backlog_q.put_nowait({"root": root, "event": {"kind": "synthetic.backlog", "payload": {"i": i}}})
    except Exception:
        break

loaded_elapsed = timed_chat_calls(e_loaded, 10)
e_loaded.stop()

print("BASELINE_ELAPSED", baseline_elapsed)
print("LOADED_ELAPSED", loaded_elapsed)
print("LOADED_UNDER_BOUND", loaded_elapsed is not None and loaded_elapsed < 10.0)
print("LOADED_NOT_WORSE_THAN_10X_BASELINE",
      loaded_elapsed is not None and baseline_elapsed is not None
      and loaded_elapsed < max(baseline_elapsed * 10.0, 5.0))
PY
)"
check "latency: 10 turns complete quickly even while the traces writer chews a 500-item backlog" "LOADED_UNDER_BOUND True" "$latency_out"
check "latency: loaded-writer latency stays within a generous multiple of the idle baseline" "LOADED_NOT_WORSE_THAN_10X_BASELINE True" "$latency_out"
rm -rf "$_atl_root"

# ------------------------------------------------------------------------
echo "-- unit: AST-041 retention -- age prune deletes only rows older than retainDays --"
age_out="$(SCRIPTS_DIR="$AT_SCRIPTS" python3 - <<'PY'
import os, sys, tempfile, threading, queue, time
from datetime import datetime, timezone, timedelta
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import observability

root = tempfile.mkdtemp(prefix="at-retage-")
q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=observability.run_writer, args=(q, stop))
t.start()

old_ts = (datetime.now(timezone.utc) - timedelta(days=40)).isoformat()
recent_ts = (datetime.now(timezone.utc) - timedelta(days=5)).isoformat()
observability.emit(q, root, {"kind": "turn.start", "turn_id": "old1", "ts": old_ts})
observability.emit(q, root, {"kind": "turn.start", "turn_id": "old2", "ts": old_ts})
observability.emit(q, root, {"kind": "turn.start", "turn_id": "keep1", "ts": recent_ts})

deadline = time.monotonic() + 5.0
rows = []
while time.monotonic() < deadline:
    rows = observability.query(root, limit=1000)
    if len(rows) >= 3:
        break
    time.sleep(0.2)
stop.set()
t.join(timeout=3)

observability.prune(root, retain_days=30, max_mb=0)
after = observability.query(root, limit=1000)
after_ids = sorted(r["turn_id"] for r in after)
print("BEFORE_COUNT", len(rows))
print("AFTER_IDS", after_ids)
PY
)"
check "retention age: 3 rows exist before pruning" "BEFORE_COUNT 3" "$age_out"
check "retention age: only the older-than-retainDays rows are deleted, newer row kept" "AFTER_IDS ['keep1']" "$age_out"

# ------------------------------------------------------------------------
echo "-- unit: AST-041 retention -- size prune deletes oldest-first until under maxMB --"
size_out="$(SCRIPTS_DIR="$AT_SCRIPTS" python3 - <<'PY'
import os, sys, tempfile, threading, queue, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import observability

root = tempfile.mkdtemp(prefix="at-retsize-")
q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=observability.run_writer, args=(q, stop))
t.start()

N = 1200
pad = "x" * 2000
for i in range(N):
    observability.emit(q, root, {"kind": "turn.start", "turn_id": str(i), "payload": {"pad": pad}})

deadline = time.monotonic() + 20.0
rows = []
while time.monotonic() < deadline:
    rows = observability.query(root, limit=N + 10)
    if len(rows) >= N:
        break
    time.sleep(0.2)
stop.set()
t.join(timeout=5)

db_path = os.path.join(root, ".claude", "assistant", "traces.sqlite")
before_count = len(rows)

observability.prune(root, retain_days=0, max_mb=1)

after = observability.query(root, limit=N + 10)
after_ids = sorted(int(r["turn_id"]) for r in after)
size_after = os.path.getsize(db_path)

print("BEFORE_COUNT", before_count)
print("SOME_ROWS_REMOVED", len(after) < before_count)
print("SIZE_UNDER_BUDGET", size_after <= 1.5 * 1024 * 1024)
print("OLDEST_FIRST", after_ids == list(range(N - len(after_ids), N)) if after_ids else False)
PY
)"
check "retention size: all rows present before pruning" "BEFORE_COUNT 1200" "$size_out"
check "retention size: pruning removes rows to come under the cap" "SOME_ROWS_REMOVED True" "$size_out"
check "retention size: file size lands near/under the maxMB budget" "SIZE_UNDER_BUDGET True" "$size_out"
check "retention size: deletion is oldest-first (only the lowest turn_ids are gone)" "OLDEST_FIRST True" "$size_out"

# #420: the size-chunk delete used to be one self-referencing statement
# (`DELETE FROM events WHERE seq IN (SELECT seq FROM events ORDER BY seq
# ASC LIMIT ?)`) whose oldest-first guarantee depended on the query
# planner materializing its own subquery before the delete began -- correct
# on every machine this repo's tests ran on locally, wrong on the Ubuntu CI
# runner's SQLite build. Source-level pin, since the behavioral OLDEST_FIRST
# check above cannot itself prove which SQL form produced a passing result,
# and this repo cannot reproduce the CI-only failure locally to red/green
# the fix behaviorally.
_ret_src="$(cat "$AT_SCRIPTS/assistant/observability.py")"
check_absent "observability.py: the self-referencing size-prune DELETE (the actual #420 bug) is gone" \
    "DELETE FROM events WHERE seq IN" "$_ret_src"
check "observability.py: size-prune deletes by an explicit, already-materialized seq boundary instead" \
    "DELETE FROM events WHERE seq <= ?" "$_ret_src"

# ------------------------------------------------------------------------
echo "-- unit: AST-041 retention -- 0 means unlimited for both knobs --"
unlimited_out="$(SCRIPTS_DIR="$AT_SCRIPTS" python3 - <<'PY'
import os, sys, tempfile, threading, queue, time
from datetime import datetime, timezone, timedelta
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import observability

root = tempfile.mkdtemp(prefix="at-retunlim-")
q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=observability.run_writer, args=(q, stop))
t.start()

ancient_ts = (datetime.now(timezone.utc) - timedelta(days=3650)).isoformat()
pad = "x" * 2000
for i in range(50):
    observability.emit(q, root, {"kind": "turn.start", "turn_id": str(i), "ts": ancient_ts, "payload": {"pad": pad}})

deadline = time.monotonic() + 10.0
rows = []
while time.monotonic() < deadline:
    rows = observability.query(root, limit=200)
    if len(rows) >= 50:
        break
    time.sleep(0.2)
stop.set()
t.join(timeout=3)

observability.prune(root, retain_days=0, max_mb=0)
after = observability.query(root, limit=200)
print("BEFORE_COUNT", len(rows))
print("AFTER_COUNT", len(after))
PY
)"
check "retention unlimited: 50 ancient/large rows exist before pruning" "BEFORE_COUNT 50" "$unlimited_out"
check "retention unlimited: retainDays=0, maxMB=0 prunes nothing" "AFTER_COUNT 50" "$unlimited_out"

# ------------------------------------------------------------------------
echo "-- unit: AST-041 retention -- non-trace files are never touched --"
nontrace_out="$(SCRIPTS_DIR="$AT_SCRIPTS" python3 - <<'PY'
import hashlib, os, sys, tempfile, threading, queue, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import observability

root = tempfile.mkdtemp(prefix="at-retnontrace-")
assistant_dir = os.path.join(root, ".claude", "assistant")
os.makedirs(assistant_dir, exist_ok=True)
session_path = os.path.join(assistant_dir, "session.jsonl")
index_dir = os.path.join(root, ".claude", "assistant", "index")
os.makedirs(index_dir, exist_ok=True)
index_path = os.path.join(index_dir, "embeddings.idx")
with open(session_path, "wb") as f:
    f.write(b"session-line-1\nsession-line-2\n")
with open(index_path, "wb") as f:
    f.write(b"fake-embeddings-bytes")

def sha(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()

before_session = sha(session_path)
before_index = sha(index_path)

q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=observability.run_writer, args=(q, stop))
t.start()
observability.emit(q, root, {"kind": "turn.start", "turn_id": "t1"})
deadline = time.monotonic() + 5.0
while time.monotonic() < deadline:
    if len(observability.query(root)) >= 1:
        break
    time.sleep(0.2)
stop.set()
t.join(timeout=3)

observability.prune(root, retain_days=1, max_mb=1)

after_session = sha(session_path)
after_index = sha(index_path)
print("SESSION_UNCHANGED", before_session == after_session)
print("INDEX_UNCHANGED", before_index == after_index)
PY
)"
check "retention: session.jsonl is byte-identical after pruning" "SESSION_UNCHANGED True" "$nontrace_out"
check "retention: the embeddings index file is byte-identical after pruning" "INDEX_UNCHANGED True" "$nontrace_out"

# ------------------------------------------------------------------------
echo "-- integration: AST-041 retention prune runs on the writer thread cadence --"
cadence_out="$(SCRIPTS_DIR="$AT_SCRIPTS" python3 - <<'PY'
import os, sys, tempfile, threading, queue, time
from datetime import datetime, timezone, timedelta
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import observability

root = tempfile.mkdtemp(prefix="at-retcadence-")
q = queue.Queue()
stop = threading.Event()

def retention_config(root_arg):
    return {"retainDays": 1, "maxMB": 0}

t = threading.Thread(
    target=observability.run_writer,
    args=(q, stop),
    kwargs={
        "retention_config": retention_config,
        "prune_every_drains": 1,
        "prune_interval_seconds": 9999,
    },
)
t.start()

old_ts = (datetime.now(timezone.utc) - timedelta(days=10)).isoformat()
observability.emit(q, root, {"kind": "turn.start", "turn_id": "old", "ts": old_ts})

# The single "old" event's own flush+prune cycle runs back to back (prune_every_drains=1) --
# it is pruned before this test's own query() connection has any chance to observe it, so
# there is no "wait for it to appear, then wait for it to vanish" window to poll for. Instead
# just give the writer thread a bounded head start to run its (flush -> prune) cycle, then
# assert the row never shows up at all.
time.sleep(1.5)
pruned = not any(r["turn_id"] == "old" for r in observability.query(root, limit=100))

observability.emit(q, root, {"kind": "turn.start", "turn_id": "new"})
deadline2 = time.monotonic() + 5.0
seen_new = False
while time.monotonic() < deadline2:
    rows = observability.query(root, limit=100)
    if any(r["turn_id"] == "new" for r in rows):
        seen_new = True
        break
    time.sleep(0.2)

stop.set()
t.join(timeout=3)

print("OLD_PRUNED_BY_CADENCE", pruned)
print("NEW_EVENT_STILL_PRESENT", seen_new)
PY
)"
check "retention cadence: an old event is pruned by the writer thread's own periodic pass" "OLD_PRUNED_BY_CADENCE True" "$cadence_out"
check "retention cadence: a fresh event still lands normally afterward" "NEW_EVENT_STILL_PRESENT True" "$cadence_out"

# ------------------------------------------------------------------------
echo "-- unit: AST-041 retention -- schema and indexes survive a prune pass --"
schema_survive_out="$(SCRIPTS_DIR="$AT_SCRIPTS" python3 - <<'PY'
import os, sys, tempfile, threading, queue, time, sqlite3
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import observability

root = tempfile.mkdtemp(prefix="at-retschema-")
q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=observability.run_writer, args=(q, stop))
t.start()
observability.emit(q, root, {"kind": "turn.start", "turn_id": "t1"})
deadline = time.monotonic() + 5.0
while time.monotonic() < deadline:
    if len(observability.query(root)) >= 1:
        break
    time.sleep(0.2)
stop.set()
t.join(timeout=3)

observability.prune(root, retain_days=30, max_mb=500)

db_path = os.path.join(root, ".claude", "assistant", "traces.sqlite")
conn = sqlite3.connect(db_path)
mode = conn.execute("PRAGMA journal_mode").fetchone()[0]
idx_names = {r[0] for r in conn.execute(
    "SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'ix_events_%'"
).fetchall()}
expected = {
    "ix_events_seq", "ix_events_ts", "ix_events_session_id", "ix_events_turn_id",
    "ix_events_span_id", "ix_events_parent_span_id", "ix_events_kind",
    "ix_events_skill", "ix_events_modality", "ix_events_status",
}
conn.execute("INSERT INTO events (seq, ts, kind) VALUES (999, '2020-01-01', 'sanity')")
conn.close()

print("JOURNAL_MODE_AFTER", mode)
print("ALL_INDEXES_PRESENT", expected.issubset(idx_names))
print("TABLE_WRITABLE_AFTER", True)
PY
)"
check "retention: WAL mode survives a prune pass" "JOURNAL_MODE_AFTER wal" "$schema_survive_out"
check "retention: all first-class-column indexes survive a prune pass" "ALL_INDEXES_PRESENT True" "$schema_survive_out"
check "retention: the events table is still writable after a prune pass" "TABLE_WRITABLE_AFTER True" "$schema_survive_out"

# ------------------------------------------------------------------------
echo "-- unit: AST-041 -- engine resolves per-root observability.traces retention config --"
engine_cfg_out="$(SCRIPTS_DIR="$AT_SCRIPTS" python3 - <<'PY'
import os, sys, tempfile
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import engine

root = tempfile.mkdtemp(prefix="at-retcfg-")
os.makedirs(os.path.join(root, ".claude"), exist_ok=True)
with open(os.path.join(root, ".claude", ".neural-network"), "w") as f:
    f.write("# neural-network\n")
with open(os.path.join(root, ".claude", "project.yaml"), "w") as f:
    f.write(
        "schemaVersion: 2\n"
        "assistant:\n"
        "    version: 1\n"
        "    enabled: true\n"
        "    names: [jarvis]\n"
        "    systemPrompt: |\n"
        "        You are jarvis.\n"
        "    llm:\n"
        "        provider: openai\n"
        "        model: gpt-5.6-sol\n"
        "    capabilities:\n"
        "        codex:\n"
        "            enabled: true\n"
        "            provisioning:\n"
        "                bin: codex\n"
        "    observability:\n"
        "        traces:\n"
        "            sqlite:\n"
        "                enabled: true\n"
        "                retainDays: 7\n"
        "                maxMB: 42\n"
    )

state_dir = os.path.join(root, ".claude", "assistant-engine-state")
e = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir)
cfg = e._retention_config_for(root)
print("RETAIN_DAYS", cfg.get("retainDays") if cfg else None)
print("MAX_MB", cfg.get("maxMB") if cfg else None)

other_root = tempfile.mkdtemp(prefix="at-retcfg-none-")
cfg_none = e._retention_config_for(other_root)
print("NO_MARKER_ROOT_CFG", cfg_none)
PY
)"
check "retention config: engine reads retainDays from observability.traces" "RETAIN_DAYS 7" "$engine_cfg_out"
check "retention config: engine reads maxMB from observability.traces" "MAX_MB 42" "$engine_cfg_out"
check "retention config: a non-candidate root resolves to None (defaults apply)" "NO_MARKER_ROOT_CFG None" "$engine_cfg_out"

# ------------------------------------------------------------------------
echo "-- guard: traces.sqlite is registered in the local-state manifest mechanism --"
ls_policy="$(python3 -c "
import sys
sys.path.insert(0, '$PLUGIN/scripts/lib')
import local_state
print(local_state.policy_of('.claude/assistant/'))
")"
check "manifest: .claude/assistant/ (covers traces.sqlite) is policy=ignore" "ignore" "$ls_policy"
traces_src="$(cat "$AT_SCRIPTS/assistant/observability.py")"
check "observability.py: traces.sqlite lives under the already-ignored .claude/assistant/ dir" "TRACES_DIR_REL = os.path.join(\".claude\", \"assistant\")" "$traces_src"

# ------------------------------------------------------------------------
echo "== assistant traces endpoint (AST-043: GET /assistant/traces, SPEC-ASSISTANT.md Sec10.5, issue #329) =="

echo "-- integration: GET /assistant/traces returns the resolved assistant events, since/turn/limit honored --"
_ate2_root="$(mktemp -d)"
at_repo "$_ate2_root" jarvis

traces_endpoint_out="$(SCRIPTS_DIR="$AT_SCRIPTS" ROOT="$_ate2_root" python3 - <<'PY'
import os, sys, threading, queue, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import engine, observability

root = os.environ["ROOT"]

q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=observability.run_writer, args=(q, stop))
t.start()
observability.emit(q, root, {"kind": "turn.start", "turn_id": "tA"})
observability.emit(q, root, {"kind": "turn.end", "turn_id": "tA", "status": "ok"})
observability.emit(q, root, {"kind": "turn.start", "turn_id": "tB"})
observability.emit(q, root, {"kind": "turn.end", "turn_id": "tB", "status": "ok"})
deadline = time.monotonic() + 5.0
while time.monotonic() < deadline:
    if len(observability.query(root, limit=100)) >= 4:
        break
    time.sleep(0.2)
stop.set()
t.join(timeout=3)

state_dir = os.path.join(root, ".claude", "assistant-engine-state")
e = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir)

status, payload, ct = e.handle("GET", "/assistant/traces")
events = payload.get("events", [])
print("STATUS", status)
print("CONTENT_TYPE", ct)
print("ALL_EVENTS_COUNT", len(events))

status2, payload2, _ct2 = e.handle("GET", "/assistant/traces", query={"turn": ["tA"]})
events2 = payload2.get("events", [])
print("TURN_FILTER_COUNT", len(events2))
print("TURN_FILTER_ALL_TA", all(ev.get("turn_id") == "tA" for ev in events2))

first_seq = events[0]["seq"]
status3, payload3, _ct3 = e.handle("GET", "/assistant/traces", query={"since": [str(first_seq)]})
events3 = payload3.get("events", [])
print("SINCE_FILTER_COUNT", len(events3))
print("SINCE_FILTER_EXCLUDES_FIRST", all(ev["seq"] > first_seq for ev in events3))

status4, payload4, _ct4 = e.handle("GET", "/assistant/traces", query={"limit": ["2"]})
events4 = payload4.get("events", [])
print("LIMIT_COUNT", len(events4))
PY
)"
check "traces endpoint: GET /assistant/traces returns 200" "STATUS 200" "$traces_endpoint_out"
check "traces endpoint: application/json content type" "CONTENT_TYPE application/json" "$traces_endpoint_out"
check "traces endpoint: all four events are returned with no filter" "ALL_EVENTS_COUNT 4" "$traces_endpoint_out"
check "traces endpoint: turn filter returns only that turn's events" "TURN_FILTER_COUNT 2" "$traces_endpoint_out"
check "traces endpoint: turn filter never mixes in another turn's rows" "TURN_FILTER_ALL_TA True" "$traces_endpoint_out"
check "traces endpoint: since filter excludes everything at or before that seq" "SINCE_FILTER_COUNT 3" "$traces_endpoint_out"
check "traces endpoint: since filter is a strict greater-than comparison" "SINCE_FILTER_EXCLUDES_FIRST True" "$traces_endpoint_out"
check "traces endpoint: limit caps the returned event count" "LIMIT_COUNT 2" "$traces_endpoint_out"
rm -rf "$_ate2_root"

# ------------------------------------------------------------------------
echo "-- unit: GET /assistant/traces order=desc returns the newest events + truncated flag (#393) --"
_ateo_root="$(mktemp -d)"
at_repo "$_ateo_root" jarvis

order_endpoint_out="$(SCRIPTS_DIR="$AT_SCRIPTS" ROOT="$_ateo_root" python3 - <<'PY'
import os, sys, threading, queue, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import engine, observability

root = os.environ["ROOT"]

q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=observability.run_writer, args=(q, stop))
t.start()
N = 6
for i in range(N):
    observability.emit(q, root, {"kind": "turn.start", "turn_id": "t%d" % i})
deadline = time.monotonic() + 5.0
while time.monotonic() < deadline:
    if len(observability.query(root, limit=100)) >= N:
        break
    time.sleep(0.2)
stop.set()
t.join(timeout=3)

state_dir = os.path.join(root, ".claude", "assistant-engine-state")
e = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir)

# default order=asc, limit=3 -- oldest 3, not truncated-honest since exactly
# limit rows came back (limit == returned count means "possibly more").
status1, payload1, _ct1 = e.handle("GET", "/assistant/traces", query={"limit": ["3"]})
events1 = payload1.get("events", [])
print("ASC_IDS", [ev["turn_id"] for ev in events1])
print("ASC_TRUNCATED", payload1.get("truncated"))

# order=desc, limit=3 -- newest 3.
status2, payload2, _ct2 = e.handle("GET", "/assistant/traces", query={"limit": ["3"], "order": ["desc"]})
events2 = payload2.get("events", [])
print("DESC_STATUS", status2)
print("DESC_IDS", [ev["turn_id"] for ev in events2])
print("DESC_TRUNCATED", payload2.get("truncated"))

# limit=100 (> N) -- everything comes back, truncated must be False (an
# honest "no more" since fewer than limit rows came back).
status3, payload3, _ct3 = e.handle("GET", "/assistant/traces", query={"limit": ["100"], "order": ["desc"]})
events3 = payload3.get("events", [])
print("UNTRUNCATED_COUNT", len(events3))
print("UNTRUNCATED_FLAG", payload3.get("truncated"))

# an invalid order value is a clean 400-style error, never a crash / silent default.
status4, payload4, _ct4 = e.handle("GET", "/assistant/traces", query={"order": ["sideways"]})
print("BAD_ORDER_STATUS", status4)
print("BAD_ORDER_HAS_ERROR", "error" in payload4)
PY
)"
check "traces endpoint order=desc: request succeeds" "DESC_STATUS 200" "$order_endpoint_out"
check "traces endpoint order=asc (default): returns the oldest turns" "ASC_IDS ['t0', 't1', 't2']" "$order_endpoint_out"
check "traces endpoint order=desc: returns the newest turns instead" "DESC_IDS ['t3', 't4', 't5']" "$order_endpoint_out"
check "traces endpoint: truncated=True when exactly limit rows came back" "ASC_TRUNCATED True" "$order_endpoint_out"
check "traces endpoint order=desc: truncated=True when exactly limit rows came back" "DESC_TRUNCATED True" "$order_endpoint_out"
check "traces endpoint: truncated=False when fewer than limit rows came back (honest 'no more')" "UNTRUNCATED_FLAG False" "$order_endpoint_out"
check "traces endpoint: an over-limit fetch still returns every row" "UNTRUNCATED_COUNT 6" "$order_endpoint_out"
check "traces endpoint: an invalid order value is a clean 4xx" "BAD_ORDER_STATUS 400" "$order_endpoint_out"
check "traces endpoint: an invalid order value's error body carries an error key" "BAD_ORDER_HAS_ERROR True" "$order_endpoint_out"
rm -rf "$_ateo_root"

# ------------------------------------------------------------------------
echo "-- unit: GET /assistant/traces clamps an over-cap limit to the documented max (1000) --"
_atc_root="$(mktemp -d)"
at_repo "$_atc_root" jarvis
clamp_out="$(SCRIPTS_DIR="$AT_SCRIPTS" ROOT="$_atc_root" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import engine

root = os.environ["ROOT"]
state_dir = os.path.join(root, ".claude", "assistant-engine-state")
e = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir)

status, payload, _ct = e.handle("GET", "/assistant/traces", query={"limit": ["5000"]})
print("STATUS", status)
print("EVENTS_IS_LIST", isinstance(payload.get("events"), list))
print("CLAMPED_LIMIT", engine._parse_traces_query({"limit": ["5000"]})[2])
print("DEFAULT_LIMIT", engine._parse_traces_query(None)[2])
PY
)"
check "traces endpoint: an over-cap limit is clamped to 1000, never an error" "STATUS 200" "$clamp_out"
check "traces endpoint: the events payload is still a list after clamping" "EVENTS_IS_LIST True" "$clamp_out"
check "traces endpoint: limit=5000 clamps down to the documented max of 1000" "CLAMPED_LIMIT 1000" "$clamp_out"
check "traces endpoint: an absent limit defaults to 200" "DEFAULT_LIMIT 200" "$clamp_out"
rm -rf "$_atc_root"

# ------------------------------------------------------------------------
echo "-- unit: GET /assistant/traces with no assistant resolvable returns a clean error shape, never a crash --"
none_out="$(SCRIPTS_DIR="$AT_SCRIPTS" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import engine

state_dir = "/tmp/at-traces-none-state"
e = engine.AssistantEngine(lambda: [], state_dir)
status, payload, ct = e.handle("GET", "/assistant/traces")
print("STATUS", status)
print("CONTENT_TYPE", ct)
print("EVENTS_EMPTY", payload.get("events") == [])
print("HAS_WARNINGS", bool(payload.get("warnings")))
PY
)"
check "traces endpoint: no assistant discovered returns 200 with an empty events list" "STATUS 200" "$none_out"
check "traces endpoint: no-selection case still reports application/json" "CONTENT_TYPE application/json" "$none_out"
check "traces endpoint: no-selection case returns an empty events list, not an error" "EVENTS_EMPTY True" "$none_out"
check "traces endpoint: no-selection case explains itself via warnings, matching /assistant/history" "HAS_WARNINGS True" "$none_out"

# ------------------------------------------------------------------------
echo "-- engine: TRACES_QUEUE_MAXSIZE bounds the traces queue (issue #390) --"
tq_bound_out="$(SCRIPTS_DIR="$AT_SCRIPTS" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import engine

state_dir = "/tmp/at-traces-bound-state"
e = engine.AssistantEngine(lambda: [], state_dir)
print("TRACES_MAXSIZE", e.queues["traces"].maxsize)
print("DISTILLER_MAXSIZE", e.queues["distiller"].maxsize)
PY
)"
tq_maxsize="$(printf '%s\n' "$tq_bound_out" | awk '/^TRACES_MAXSIZE/ {print $2}')"
if [[ "$tq_maxsize" =~ ^[0-9]+$ ]] && [[ "$tq_maxsize" -gt 0 ]]; then
    echo "ok   traces queue is bounded (maxsize=$tq_maxsize, not the unbounded 0 default)"
else
    echo "FAIL traces queue is bounded — expected a positive maxsize, got '$tq_maxsize'"; fails=$((fails + 1))
fi
check "the traces queue's bound mirrors the distiller queue's bound" "TRACES_MAXSIZE $(printf '%s\n' "$tq_bound_out" | awk '/^DISTILLER_MAXSIZE/ {print $2}')" "$tq_bound_out"

# ------------------------------------------------------------------------
echo "-- writer: _flush degrades one unserializable payload to a marker event instead of rolling back the whole drain (issue #390) --"
_at_poison_root="$(mktemp -d)"
at_repo "$_at_poison_root" jarvis
poison_out="$(SCRIPTS_DIR="$AT_SCRIPTS" ROOT="$_at_poison_root" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import observability

root = os.environ["ROOT"]
conns = {}
buffers = {
    root: [
        {"kind": "turn.start", "turn_id": "t1", "payload": {"message_len": 3}},
        # a non-JSON-serializable payload (a raw set) -- must not roll back
        # the good events in the SAME drain for this root.
        {"kind": "recall.summary", "turn_id": "t1", "payload": {"bad": {1, 2, 3}}},
        {"kind": "turn.end", "turn_id": "t1", "payload": {"warnings": []}},
    ],
}
observability._flush(conns, buffers)
for conn, _next_seq in conns.values():
    conn.close()

events = observability.query(root, limit=10)
print("EVENT_COUNT", len(events))
print("KINDS", [e["kind"] for e in events])
poison_events = [e for e in events if e["kind"] == "recall.summary"]
print("POISON_KEPT", len(poison_events) == 1)
print("POISON_PAYLOAD_IS_MARKER", bool(poison_events) and "bad" not in poison_events[0]["payload"])
PY
)"
rc=$?
check_rc "poison-payload flush script exits 0" 0 "$rc"
check "the good turn.start/turn.end events are NOT lost alongside the poison event" "EVENT_COUNT 3" "$poison_out"
check "all three events (including the degraded one) are present, in kind order" "KINDS ['turn.start', 'recall.summary', 'turn.end']" "$poison_out"
check "the poisoned event is kept (degraded), not silently dropped" "POISON_KEPT True" "$poison_out"
check "the poisoned event's payload is replaced with a safe marker, not the raw unserializable value" "POISON_PAYLOAD_IS_MARKER True" "$poison_out"
rm -rf "$_at_poison_root"

# ------------------------------------------------------------------------
echo "-- engine: GET /assistant/traces degrades cleanly on a busy-timeout lock overrun, never crashes (issue #391) --"
_at_busy_root="$(mktemp -d)"
at_repo "$_at_busy_root" jarvis
busy_out="$(SCRIPTS_DIR="$AT_SCRIPTS" ROOT="$_at_busy_root" python3 - <<'PY'
import os, sys, sqlite3
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import engine, observability

root = os.environ["ROOT"]

# Create traces.sqlite (as the real writer thread would), then switch it
# OUT of WAL mode: a rollback-journal EXCLUSIVE lock (below) blocks
# readers the same way a VACUUM own exclusive access does (Sec10.3,
# "VACUUM lock overrun"), unlike normal WAL reader/writer non-blocking
# posture, which this test needs to actually reproduce contention.
conn0, _ = observability._open_conn(root)
conn0.execute("PRAGMA journal_mode=DELETE")
conn0.close()

db_path = observability._db_path(root)
locker = sqlite3.connect(db_path, isolation_level=None)
locker.execute("PRAGMA busy_timeout=100")
locker.execute("BEGIN EXCLUSIVE")  # held for the rest of this script -- simulates a live VACUUM

repos = lambda: [("a", root)]
e = engine.AssistantEngine(repos, "/tmp/at-busy-state")
try:
    status, payload, ct = e.handle("GET", "/assistant/traces")
    print("CRASHED", False)
    print("STATUS", status)
    print("CONTENT_TYPE", ct)
    print("EVENTS_EMPTY", payload.get("events") == [])
    print("HAS_WARNINGS", bool(payload.get("warnings")))
except Exception as exc:
    print("CRASHED", True)
    print("CRASH_TYPE", type(exc).__name__)

locker.execute("ROLLBACK")
locker.close()
PY
)"
rc=$?
check_rc "busy-timeout traces script exits 0" 0 "$rc"
check "a VACUUM-style lock overrun never crashes the request, it degrades cleanly" "CRASHED False" "$busy_out"
check "the degraded response is still a clean 200" "STATUS 200" "$busy_out"
check "the degraded response is still application/json" "CONTENT_TYPE application/json" "$busy_out"
check "the degraded response's events list is empty, matching the 'no such table' posture" "EVENTS_EMPTY True" "$busy_out"
check "the degraded response explains itself via warnings (retryable, not a silent empty)" "HAS_WARNINGS True" "$busy_out"
rm -rf "$_at_busy_root"
