#!/usr/bin/env bash
# section-assistant-tasks.sh -- AST-066: tasks.sqlite queue + worker +
# states (SPEC-ASSISTANT.md §12.3, issue #341, docs/design/ast-E6.md).
# Sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== assistant tasks (AST-066: tasks.sqlite queue + worker + states, SPEC-ASSISTANT.md §12.3) =="

AT_SCRIPTS="$PLUGIN/scripts"

# at_repo <dir> <main> -- mirrors the house assistant fixture pattern (e.g.
# section-assistant-distill.sh's ad_repo).
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
echo "-- unit: STATES -- the exact six Sec12.3 state names, in transition order --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import tasks
print("STATES", tasks.STATES)
PY
)"
check "tasks: STATES matches Sec12.3 verbatim" \
    "STATES ('queued', 'started', 'progress', 'completed', 'failed', 'orphaned')" "$out"

# ------------------------------------------------------------------------
echo "-- static: tasks.py never opens a second traces.sqlite writer (reuse, not a second writer) --"
# Checks actual CALL syntax, not prose -- the module docstring legitimately
# mentions observability._open_conn/run_writer/traces.sqlite BY NAME for
# context (this section's own file does too, in its echo strings above),
# so a blanket substring ban on the whole file would false-positive on
# documentation. The real invariant: the only observability.* CALL this
# module ever makes is observability.emit(...).
tasks_calls="$(grep -oE 'observability\.[A-Za-z_]+\(' "$AT_SCRIPTS/assistant/tasks.py" | sort -u)"
check "tasks.py: the only observability.* call is emit() -- never its own writer/connection" \
    "observability.emit(" "$tasks_calls"
check "tasks.py: exactly one distinct observability.* call site kind" "1" "$(printf '%s\n' "$tasks_calls" | grep -c .)"

# ------------------------------------------------------------------------
echo "-- unit: enqueue -- returns an id synchronously, never blocks, never raises --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import queue
from assistant import tasks

q = queue.Queue()
tid = tasks.enqueue(q, "/tmp/some-root", "echo", {"x": 1})
print("ID_IS_STRING", isinstance(tid, str))
print("ID_NONEMPTY", bool(tid))
print("QUEUE_SIZE", q.qsize())
item = q.get_nowait()
print("ITEM_ACTION", item.get("action"))
print("ITEM_ID_MATCHES", item.get("id") == tid)
print("ITEM_KIND", item.get("kind"))
PY
)"
check "enqueue: returns a non-empty string id" "ID_IS_STRING True" "$out"
check "enqueue: id is non-empty" "ID_NONEMPTY True" "$out"
check "enqueue: exactly one item lands on the queue" "QUEUE_SIZE 1" "$out"
check "enqueue: the queued item is a create action" "ITEM_ACTION create" "$out"
check "enqueue: the queued item's id matches the returned id" "ITEM_ID_MATCHES True" "$out"
check "enqueue: the queued item carries the requested kind" "ITEM_KIND echo" "$out"

echo "-- unit: enqueue -- a full queue drops the item, never raises, and returns None (round-2: no phantom ids) --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import queue
from assistant import tasks

q = queue.Queue(maxsize=1)
q.put_nowait({"already": "full"})
try:
    tid = tasks.enqueue(q, "/tmp/some-root", "echo", {})
    print("RAISED", False)
    print("RETURNS_NONE", tid is None)
except Exception:
    print("RAISED", True)
PY
)"
check "enqueue (full queue): never raises into the caller" "RAISED False" "$out"
check "enqueue (full queue): returns None -- never a phantom id for a row that will never exist" \
    "RETURNS_NONE True" "$out"

# ------------------------------------------------------------------------
echo "-- integration: run_worker -- a successful task transitions queued -> started -> completed, each also a trace event --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import queue, tempfile, threading, time
from assistant import tasks

root = tempfile.mkdtemp(prefix="at-success-")
q = queue.Queue()
traces_q = queue.Queue()
stop = threading.Event()

def echo_executor(payload, report_progress):
    return {"result": {"echo": payload}, "artifact_path": None}

t = threading.Thread(target=tasks.run_worker, args=(q, stop),
                      kwargs={"executors": {"echo": echo_executor}, "poll_timeout": 0.1, "traces_queue": traces_q})
t.start()

tid = tasks.enqueue(q, root, "echo", {"x": 1}, turn_id="turn-xyz")

deadline = time.monotonic() + 5.0
rows = []
while time.monotonic() < deadline:
    rows = tasks.list_tasks(root)
    if rows and rows[0]["state"] == "completed":
        break
    time.sleep(0.1)

stop.set()
t.join(timeout=3)

print("N_ROWS", len(rows))
row = rows[0] if rows else {}
print("ROW_ID_MATCHES", row.get("id") == tid)
print("FINAL_STATE", row.get("state"))
print("RESULT", row.get("result"))
print("ERROR", row.get("error"))
print("ROW_TURN_ID", row.get("turn_id"))

trace_kinds = []
trace_turn_ids = []
while True:
    try:
        item = traces_q.get_nowait()
    except queue.Empty:
        break
    trace_kinds.append(item["event"]["kind"])
    trace_turn_ids.append(item["event"].get("turn_id"))
print("TRACE_KINDS", trace_kinds)
print("HAS_QUEUED_EVENT", "task.queued" in trace_kinds)
print("HAS_STARTED_EVENT", "task.started" in trace_kinds)
print("HAS_COMPLETED_EVENT", "task.completed" in trace_kinds)
print("EVENTS_IN_ORDER", trace_kinds == ["task.queued", "task.started", "task.completed"])
print("EVERY_EVENT_CARRIES_TURN_ID", trace_turn_ids == ["turn-xyz", "turn-xyz", "turn-xyz"])
PY
)"
check "run_worker (success): exactly one row created" "N_ROWS 1" "$out"
check "run_worker (success): the row's id matches enqueue's returned id" "ROW_ID_MATCHES True" "$out"
check "run_worker (success): final state is completed" "FINAL_STATE completed" "$out"
check "run_worker (success): result is populated with the executor's return value" "RESULT {'echo': {'x': 1}}" "$out"
check "run_worker (success): the row carries the enqueue-time turn_id" "ROW_TURN_ID turn-xyz" "$out"
check "run_worker (success): every trace event carries the SAME turn_id (the #334 one-shared-turn_id pattern)" \
    "EVERY_EVENT_CARRIES_TURN_ID True" "$out"
check "run_worker (success): error stays None on success" "ERROR None" "$out"
check "run_worker (success): emits a task.queued trace event" "HAS_QUEUED_EVENT True" "$out"
check "run_worker (success): emits a task.started trace event" "HAS_STARTED_EVENT True" "$out"
check "run_worker (success): emits a task.completed trace event" "HAS_COMPLETED_EVENT True" "$out"
check "run_worker (success): transitions happen in the documented order" "EVENTS_IN_ORDER True" "$out"

# ------------------------------------------------------------------------
echo "-- integration: run_worker -- report_progress transitions to 'progress' mid-flight, with its own trace event --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import queue, tempfile, threading, time
from assistant import tasks

root = tempfile.mkdtemp(prefix="at-progress-")
q = queue.Queue()
traces_q = queue.Queue()
stop = threading.Event()
saw_progress_state = {"value": False}

def slow_executor(payload, report_progress):
    report_progress({"pct": 50})
    # poll list_tasks from INSIDE the executor -- proves the progress
    # transition is committed and visible before the executor even returns,
    # not just eventually-consistent after completion.
    rows = tasks.list_tasks(root)
    if rows and rows[0]["state"] == "progress":
        saw_progress_state["value"] = True
    return {"result": "done"}

t = threading.Thread(target=tasks.run_worker, args=(q, stop),
                      kwargs={"executors": {"slow": slow_executor}, "poll_timeout": 0.1, "traces_queue": traces_q})
t.start()
tasks.enqueue(q, root, "slow", {})

deadline = time.monotonic() + 5.0
rows = []
while time.monotonic() < deadline:
    rows = tasks.list_tasks(root)
    if rows and rows[0]["state"] == "completed":
        break
    time.sleep(0.1)
stop.set()
t.join(timeout=3)

print("SAW_PROGRESS_STATE_MID_FLIGHT", saw_progress_state["value"])
print("FINAL_STATE", rows[0]["state"] if rows else None)

trace_kinds = []
while True:
    try:
        item = traces_q.get_nowait()
    except queue.Empty:
        break
    trace_kinds.append(item["event"]["kind"])
print("HAS_PROGRESS_EVENT", "task.progress" in trace_kinds)
PY
)"
check "run_worker (progress): the row is genuinely in 'progress' state while the executor is still running" \
    "SAW_PROGRESS_STATE_MID_FLIGHT True" "$out"
check "run_worker (progress): still reaches completed afterward" "FINAL_STATE completed" "$out"
check "run_worker (progress): emits a task.progress trace event" "HAS_PROGRESS_EVENT True" "$out"

# ------------------------------------------------------------------------
echo "-- integration: run_worker -- an executor exception transitions to 'failed' with a specific error, never crashes the worker --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import queue, tempfile, threading, time
from assistant import tasks

root = tempfile.mkdtemp(prefix="at-fail2-")
q = queue.Queue()
traces_q = queue.Queue()
stop = threading.Event()

def failing_executor(payload, report_progress):
    raise ValueError("simulated failure: disk full")

def echo_executor(payload, report_progress):
    return {"result": "second task ok"}

t = threading.Thread(target=tasks.run_worker, args=(q, stop),
                      kwargs={"executors": {"fail": failing_executor, "echo": echo_executor},
                              "poll_timeout": 0.1, "traces_queue": traces_q})
t.start()
tasks.enqueue(q, root, "fail", {})
tasks.enqueue(q, root, "echo", {})

deadline = time.monotonic() + 5.0
rows = []
while time.monotonic() < deadline:
    rows = tasks.list_tasks(root)
    states_by_kind = {r["kind"]: r["state"] for r in rows}
    if states_by_kind.get("fail") == "failed" and states_by_kind.get("echo") == "completed":
        break
    time.sleep(0.1)

stop.set()
t.join(timeout=3)

by_kind = {r["kind"]: r for r in rows}
print("FAIL_STATE", by_kind.get("fail", {}).get("state"))
print("FAIL_ERROR_NAMES_MESSAGE", "disk full" in (by_kind.get("fail", {}).get("error") or ""))
print("SECOND_TASK_STATE", by_kind.get("echo", {}).get("state"))
print("WORKER_JOINED", not t.is_alive())

trace_kinds = []
while True:
    try:
        item = traces_q.get_nowait()
    except queue.Empty:
        break
    trace_kinds.append(item["event"]["kind"])
print("HAS_FAILED_EVENT", "task.failed" in trace_kinds)
PY
)"
check "run_worker (failure): the failing task's state is failed" "FAIL_STATE failed" "$out"
check "run_worker (failure): the error field names the specific exception message" "FAIL_ERROR_NAMES_MESSAGE True" "$out"
check "run_worker (failure): a SECOND, unrelated task still completes -- the exception never crashed the worker" \
    "SECOND_TASK_STATE completed" "$out"
check "run_worker (failure): the worker thread joins cleanly after stop()" "WORKER_JOINED True" "$out"
check "run_worker (failure): emits a task.failed trace event" "HAS_FAILED_EVENT True" "$out"

# ------------------------------------------------------------------------
echo "-- unit: run_worker -- a kind with no registered executor fails specifically and immediately, never hangs --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import queue, tempfile, threading, time
from assistant import tasks

root = tempfile.mkdtemp(prefix="at-noexec-")
q = queue.Queue()
stop = threading.Event()

t = threading.Thread(target=tasks.run_worker, args=(q, stop),
                      kwargs={"executors": {}, "poll_timeout": 0.1})
t.start()
tasks.enqueue(q, root, "totally-unregistered-kind", {})

deadline = time.monotonic() + 3.0
rows = []
while time.monotonic() < deadline:
    rows = tasks.list_tasks(root)
    if rows and rows[0]["state"] == "failed":
        break
    time.sleep(0.1)
stop.set()
t.join(timeout=3)

row = rows[0] if rows else {}
print("STATE", row.get("state"))
print("ERROR_NAMES_KIND", "totally-unregistered-kind" in (row.get("error") or ""))
print("ERROR_NAMES_REASON", "no executor registered" in (row.get("error") or ""))
PY
)"
check "run_worker (no executor): fails, never hangs" "STATE failed" "$out"
check "run_worker (no executor): error names the offending kind" "ERROR_NAMES_KIND True" "$out"
check "run_worker (no executor): error names the specific reason" "ERROR_NAMES_REASON True" "$out"

# ------------------------------------------------------------------------
echo "-- unit: run_worker -- serial execution model: a second task never starts until the first completes --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import queue, tempfile, threading, time
from assistant import tasks

root = tempfile.mkdtemp(prefix="at-serial-")
q = queue.Queue()
stop = threading.Event()
events = []
lock = threading.Lock()

def slow_first(payload, report_progress):
    with lock:
        events.append("first-start")
    time.sleep(0.5)
    with lock:
        events.append("first-end")
    return {"result": "ok"}

def fast_second(payload, report_progress):
    with lock:
        events.append("second-start")
    return {"result": "ok"}

t = threading.Thread(target=tasks.run_worker, args=(q, stop),
                      kwargs={"executors": {"slow": slow_first, "fast": fast_second}, "poll_timeout": 0.1})
t.start()
tasks.enqueue(q, root, "slow", {})
tasks.enqueue(q, root, "fast", {})

deadline = time.monotonic() + 5.0
while time.monotonic() < deadline:
    rows = tasks.list_tasks(root)
    states = {r["kind"]: r["state"] for r in rows}
    if states.get("slow") == "completed" and states.get("fast") == "completed":
        break
    time.sleep(0.1)
stop.set()
t.join(timeout=3)

print("EVENTS", events)
print("SERIAL_ORDER", events == ["first-start", "first-end", "second-start"])
PY
)"
check "run_worker: tasks run strictly serially -- the second never starts until the first fully completes" \
    "SERIAL_ORDER True" "$out"

# ------------------------------------------------------------------------
echo "-- unit: run_worker -- a malformed queue item is skipped, never crashes the worker --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import queue, tempfile, threading, time
from assistant import tasks

root = tempfile.mkdtemp(prefix="at-malformed-")
q = queue.Queue()
stop = threading.Event()

def echo_executor(payload, report_progress):
    return {"result": "ok"}

t = threading.Thread(target=tasks.run_worker, args=(q, stop),
                      kwargs={"executors": {"echo": echo_executor}, "poll_timeout": 0.1})
t.start()

q.put("not-a-dict")
q.put({"action": "create"})  # missing root/id/kind/payload
q.put({"action": "something-else"})  # unrecognized action
tasks.enqueue(q, root, "echo", {})  # a genuinely valid item afterward

deadline = time.monotonic() + 3.0
rows = []
while time.monotonic() < deadline:
    rows = tasks.list_tasks(root)
    if rows and rows[0]["state"] == "completed":
        break
    time.sleep(0.1)
stop.set()
t.join(timeout=3)

print("N_ROWS", len(rows))
print("STATE", rows[0]["state"] if rows else None)
print("WORKER_JOINED", not t.is_alive())
PY
)"
check "run_worker (malformed items): only the one genuinely valid item creates a row" "N_ROWS 1" "$out"
check "run_worker (malformed items): that row still completes normally" "STATE completed" "$out"
check "run_worker (malformed items): the worker thread joins cleanly (never crashed)" "WORKER_JOINED True" "$out"

echo "-- unit: run_worker -- malformed/unrecognized items are logged, not silently dropped (round-2 ADVISORY 1) --"
err_out="$(PYTHONPATH="$AT_SCRIPTS" python3 - 2>&1 >/dev/null <<'PY'
import queue, threading, time
from assistant import tasks

q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=tasks.run_worker, args=(q, stop), kwargs={"poll_timeout": 0.1})
t.start()

q.put("not-a-dict")
q.put({"action": "create"})  # missing root/id/kind/payload
q.put({"action": "something-else"})
time.sleep(0.5)
stop.set()
t.join(timeout=3)
PY
)"
check "run_worker: a non-dict/unrecognized-action item logs a specific stderr line" \
    "skipping unrecognized queue item" "$err_out"
check "run_worker: a malformed create item (missing fields) logs a specific stderr line" \
    "skipping malformed create item" "$err_out"

# ------------------------------------------------------------------------
echo "-- unit: _insert -- a non-JSON-serializable payload fails BEFORE opening a transaction (round-2 bugfix pin) --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import tempfile
from assistant import tasks

root = tempfile.mkdtemp(prefix="at-insert-bad-payload-")
conn = tasks._open_conn(root)
try:
    tasks._insert(conn, "bad-task", "echo", {"bad": {1, 2, 3}}, None)
    print("RAISED", False)
except TypeError:
    print("RAISED", True)
# the connection must be left CLEAN (no dangling transaction) -- a normal
# insert right after must succeed on the first try.
try:
    tasks._insert(conn, "good-task", "echo", {"ok": 1}, None)
    print("FOLLOWUP_INSERT_OK", True)
except Exception as exc:
    print("FOLLOWUP_INSERT_OK", False, exc)
conn.close()
print("ROW_NEVER_CREATED_FOR_BAD_PAYLOAD", "bad-task" not in {r["id"] for r in tasks.list_tasks(root)})
PY
)"
check "_insert: a non-serializable payload raises (TypeError from json.dumps)" "RAISED True" "$out"
check "_insert: the connection is left clean, never mid-transaction, after that failure" \
    "FOLLOWUP_INSERT_OK True" "$out"
check "_insert: no row is created for a payload that never serialized (nothing to insert)" \
    "ROW_NEVER_CREATED_FOR_BAD_PAYLOAD True" "$out"

echo "-- integration: run_worker -- a failure OUTSIDE the executor (the started transition itself) still reaches 'failed', never a silent exit (round-2 ADVISORY 2) --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import queue, tempfile, threading, time
from assistant import tasks

root = tempfile.mkdtemp(prefix="at-setup-fail-")
q = queue.Queue()
traces_q = queue.Queue()
stop = threading.Event()

def echo_executor(payload, report_progress):
    return {"result": "ok"}

# Monkeypatch _transition to fail EXACTLY once, on the very first call made
# with state=started -- simulates a genuine sqlite error in the
# insert-then-started phase (the row DOES exist, unlike a payload that
# never serializes) without needing to actually break sqlite itself.
real_transition = tasks._transition
calls = {"n": 0}
def flaky_transition(conn, task_id, state, **fields):
    calls["n"] += 1
    if calls["n"] == 1 and state == tasks.STATE_STARTED:
        raise RuntimeError("simulated started-transition failure")
    return real_transition(conn, task_id, state, **fields)
tasks._transition = flaky_transition

try:
    t = threading.Thread(target=tasks.run_worker, args=(q, stop),
                          kwargs={"executors": {"echo": echo_executor}, "poll_timeout": 0.1, "traces_queue": traces_q})
    t.start()

    first_id = tasks.enqueue(q, root, "echo", {"x": 1})   # its started transition will fail
    second_id = tasks.enqueue(q, root, "echo", {"x": 2})  # must still complete normally

    deadline = time.monotonic() + 5.0
    rows = []
    while time.monotonic() < deadline:
        rows = tasks.list_tasks(root)
        by_id = {r["id"]: r for r in rows}
        if (by_id.get(first_id, {}).get("state") == "failed"
                and by_id.get(second_id, {}).get("state") == "completed"):
            break
        time.sleep(0.1)
    stop.set()
    t.join(timeout=3)
finally:
    tasks._transition = real_transition

by_id = {r["id"]: r for r in rows}
first_row = by_id.get(first_id, {})
print("FIRST_ROW_EXISTS", first_id in by_id)
print("FIRST_STATE", first_row.get("state"))
print("FIRST_ERROR_NAMES_SETUP", "task setup failed" in (first_row.get("error") or ""))
print("SECOND_TASK_SURVIVED", by_id.get(second_id, {}).get("state") == "completed")
print("WORKER_JOINED", not t.is_alive())

trace_kinds = []
while True:
    try:
        item = traces_q.get_nowait()
    except queue.Empty:
        break
    trace_kinds.append((item["event"]["kind"], item["event"]["payload"].get("task_id")))
print("HAS_FAILED_TRACE_FOR_TASK", ("task.failed", first_id) in trace_kinds)
PY
)"
check "run_worker (setup failure): the row that failed on its started transition still exists" \
    "FIRST_ROW_EXISTS True" "$out"
check "run_worker (setup failure): state is failed, never stuck at queued/started" "FIRST_STATE failed" "$out"
check "run_worker (setup failure): error names it as a setup failure (distinct from an executor failure)" \
    "FIRST_ERROR_NAMES_SETUP True" "$out"
check "run_worker (setup failure): a second, unrelated task still completes -- the worker survived" \
    "SECOND_TASK_SURVIVED True" "$out"
check "run_worker (setup failure): the worker thread joins cleanly" "WORKER_JOINED True" "$out"
check "run_worker (setup failure): a task.failed trace event is still emitted for the failed task" \
    "HAS_FAILED_TRACE_FOR_TASK True" "$out"

# ------------------------------------------------------------------------
echo "-- unit: list_tasks -- state filter, limit, newest-first ordering, empty-root degrades to [] --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import os, tempfile, time
from assistant import tasks

root_empty = tempfile.mkdtemp(prefix="at-list-empty-")
print("EMPTY_ROOT", tasks.list_tasks(root_empty))

root = tempfile.mkdtemp(prefix="at-list-")
conn = tasks._open_conn(root)
for i in range(3):
    tasks._insert(conn, f"id-{i}", "kindA", {"n": i}, "turn-abc" if i == 1 else None)
    time.sleep(0.01)
tasks._transition(conn, "id-1", tasks.STATE_COMPLETED)
conn.close()

all_rows = tasks.list_tasks(root)
print("ALL_COUNT", len(all_rows))
print("NEWEST_FIRST", [r["id"] for r in all_rows] == ["id-2", "id-1", "id-0"])
by_id = {r["id"]: r for r in all_rows}
print("TURN_ID_ROUNDTRIPS", by_id["id-1"]["turn_id"] == "turn-abc")
print("TURN_ID_NULL_BY_DEFAULT", by_id["id-0"]["turn_id"] is None)

completed_rows = tasks.list_tasks(root, state=tasks.STATE_COMPLETED)
print("FILTERED_COUNT", len(completed_rows))
print("FILTERED_ID", completed_rows[0]["id"] if completed_rows else None)

limited_rows = tasks.list_tasks(root, limit=1)
print("LIMITED_COUNT", len(limited_rows))
PY
)"
check "list_tasks: a root with no tasks.sqlite yet returns []" "EMPTY_ROOT []" "$out"
check "list_tasks: returns every inserted row" "ALL_COUNT 3" "$out"
check "list_tasks: newest-first ordering" "NEWEST_FIRST True" "$out"
check "list_tasks: turn_id round-trips through the row" "TURN_ID_ROUNDTRIPS True" "$out"
check "list_tasks: turn_id is null when never supplied" "TURN_ID_NULL_BY_DEFAULT True" "$out"
check "list_tasks: state filter returns only matching rows" "FILTERED_COUNT 1" "$out"
check "list_tasks: state filter returns the right row" "FILTERED_ID id-1" "$out"
check "list_tasks: limit is honored" "LIMITED_COUNT 1" "$out"

# ------------------------------------------------------------------------
echo "-- unit: tasks.sqlite -- WAL mode + busy_timeout, matching observability's traces.sqlite discipline --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import tempfile
from assistant import tasks

root = tempfile.mkdtemp(prefix="at-wal-")
conn = tasks._open_conn(root)
mode = conn.execute("PRAGMA journal_mode").fetchone()[0]
print("JOURNAL_MODE", mode)
conn.close()
PY
)"
check "tasks.sqlite: opened in WAL mode" "JOURNAL_MODE wal" "$out"

# ------------------------------------------------------------------------
echo "-- integration: engine wiring -- the tasks worker slot runs the real queue, GET /assistant/tasks serves it --"
_at_root="$(mktemp -d)"
at_repo "$_at_root" jarvis

engine_out="$(SCRIPTS_DIR="$AT_SCRIPTS" ROOT="$_at_root" python3 - <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import engine, tasks

root = os.environ["ROOT"]
state_dir = os.path.join(root, ".claude", "assistant-engine-state")
e = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir)
e.start()
try:
    tid = tasks.enqueue(e.queues["tasks"], root, "totally-unregistered-kind", {"note": "no real executor in this task"})

    deadline = time.monotonic() + 5.0
    payload = None
    while time.monotonic() < deadline:
        status, payload, _ = e.handle("GET", "/assistant/tasks", query={"assistant": ["jarvis"]})
        if payload.get("tasks") and payload["tasks"][0]["state"] == "failed":
            break
        time.sleep(0.2)
    print("STATUS", status)
    print("N_TASKS", len(payload.get("tasks", [])))
    print("TASK_ID_MATCHES", payload["tasks"][0]["id"] == tid if payload.get("tasks") else False)
    print("TASK_STATE", payload["tasks"][0]["state"] if payload.get("tasks") else None)

    status_bad, payload_bad, _ = e.handle("GET", "/assistant/tasks", query={"state": ["not-a-real-state"]})
    print("BAD_STATE_STATUS", status_bad)
    print("BAD_STATE_HAS_ERROR", "error" in payload_bad)

    status_unresolved, payload_unresolved, _ = e.handle(
        "GET", "/assistant/tasks", query={"assistant": ["no-such-assistant"]})
    print("UNRESOLVED_STATUS", status_unresolved)
    print("UNRESOLVED_TASKS_EMPTY", payload_unresolved.get("tasks") == [])
    print("UNRESOLVED_HAS_WARNING", bool(payload_unresolved.get("warnings")))
finally:
    e.stop()
    print("ENGINE_STOPPED_CLEANLY", True)
PY
)"
check "engine wiring: GET /assistant/tasks returns 200" "STATUS 200" "$engine_out"
check "engine wiring: the enqueued task is visible via the endpoint" "N_TASKS 1" "$engine_out"
check "engine wiring: the endpoint's task id matches enqueue's returned id" "TASK_ID_MATCHES True" "$engine_out"
check "engine wiring: the real tasks worker processed it end to end (state=failed, no executor registered)" \
    "TASK_STATE failed" "$engine_out"
check "engine wiring: an invalid state filter is a clean 400" "BAD_STATE_STATUS 400" "$engine_out"
check "engine wiring: the 400 response carries an error message" "BAD_STATE_HAS_ERROR True" "$engine_out"
check "engine wiring: an unresolvable assistant is a 200, never a crash" "UNRESOLVED_STATUS 200" "$engine_out"
check "engine wiring: an unresolvable assistant returns an empty tasks list" "UNRESOLVED_TASKS_EMPTY True" "$engine_out"
check "engine wiring: an unresolvable assistant explains itself via warnings" "UNRESOLVED_HAS_WARNING True" "$engine_out"
check "engine wiring: engine.stop() joins the (now real) tasks worker cleanly" "ENGINE_STOPPED_CLEANLY True" "$engine_out"
rm -rf "$_at_root"

# ==========================================================================
# AST-067: restart reconciliation (SPEC-ASSISTANT.md §12.4, issue #342,
# docs/design/ast-E6.md sequence 4). The engine restarts with `q` empty --
# any row left `started`/`progress` in tasks.sqlite is invisible to the
# normal drain loop forever unless something looks for it. See
# tasks.py's own module docstring's "Restart reconciliation" section for
# the state-by-state rationale this test file pins.
# ==========================================================================
echo "-- unit: _reconcile_root -- a started/progress row with NO external_job_id is unreconcilable -> orphaned --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import queue, tempfile
from assistant import tasks

root = tempfile.mkdtemp(prefix="at-reconcile-no-jobid-")
conn = tasks._open_conn(root)
tasks._insert(conn, "no-jobid", "echo", {"x": 1}, "turn-1")
tasks._transition(conn, "no-jobid", tasks.STATE_STARTED)

traces_q = queue.Queue()
tasks._reconcile_root(conn, root, {}, traces_q)
conn.close()

rows = {r["id"]: r for r in tasks.list_tasks(root)}
row = rows["no-jobid"]
print("STATE", row["state"])
print("ERROR_NAMES_NO_EXTERNAL_JOBID", "no external_job_id" in (row.get("error") or ""))

trace_kinds = []
while True:
    try:
        item = traces_q.get_nowait()
    except queue.Empty:
        break
    trace_kinds.append((item["event"]["kind"], item["event"].get("turn_id")))
print("HAS_ORPHANED_EVENT", ("task.orphaned", "turn-1") in trace_kinds)
PY
)"
check "reconcile (no external_job_id): row becomes orphaned" "STATE orphaned" "$out"
check "reconcile (no external_job_id): error names the actual reason" "ERROR_NAMES_NO_EXTERNAL_JOBID True" "$out"
check "reconcile (no external_job_id): emits task.orphaned carrying the row's turn_id" "HAS_ORPHANED_EVENT True" "$out"

echo "-- unit: _reconcile_root -- external_job_id present but NO resolver registered for its kind -> orphaned (same shape as run_worker's own no-executor case) --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import queue, tempfile
from assistant import tasks

root = tempfile.mkdtemp(prefix="at-reconcile-no-resolver-")
conn = tasks._open_conn(root)
tasks._insert(conn, "no-resolver", "harness", {}, None)
tasks._transition(conn, "no-resolver", tasks.STATE_STARTED, external_job_id="job-abc")

traces_q = queue.Queue()
tasks._reconcile_root(conn, root, {}, traces_q)  # empty resolvers, matching the real engine.py wiring today
conn.close()

row = {r["id"]: r for r in tasks.list_tasks(root)}["no-resolver"]
print("STATE", row["state"])
print("ERROR_NAMES_KIND", "harness" in (row.get("error") or ""))
PY
)"
check "reconcile (no resolver for kind): row becomes orphaned" "STATE orphaned" "$out"
check "reconcile (no resolver for kind): error names the specific kind" "ERROR_NAMES_KIND True" "$out"

echo "-- unit: _reconcile_root -- resolver raises (protocol-layer failure: the remote system is unreachable) -> orphaned, never crashes the pass --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import queue, tempfile
from assistant import tasks

root = tempfile.mkdtemp(prefix="at-reconcile-raises-")
conn = tasks._open_conn(root)
tasks._insert(conn, "raiser", "harness", {}, None)
tasks._transition(conn, "raiser", tasks.STATE_STARTED, external_job_id="job-xyz")
tasks._insert(conn, "survivor", "harness", {}, None)
tasks._transition(conn, "survivor", tasks.STATE_STARTED, external_job_id="job-ok")

def flaky_resolver(external_job_id, payload):
    if external_job_id == "job-xyz":
        raise ConnectionError("remote host unreachable")
    return {"state": "in_progress"}  # the SECOND row own resolver call must still run normally

traces_q = queue.Queue()
tasks._reconcile_root(conn, root, {"harness": flaky_resolver}, traces_q)
conn.close()

rows = {r["id"]: r for r in tasks.list_tasks(root)}
print("RAISER_STATE", rows["raiser"]["state"])
print("RAISER_ERROR_NAMES_RESOLVER", "resolver raised" in (rows["raiser"].get("error") or ""))
print("SURVIVOR_UNTOUCHED_STATE", rows["survivor"]["state"])  # non-empty control: reconciliation kept running past the raiser
PY
)"
check "reconcile (resolver raises): row becomes orphaned, not stuck/crashed" "RAISER_STATE orphaned" "$out"
check "reconcile (resolver raises): error names it as a resolver failure" "RAISER_ERROR_NAMES_RESOLVER True" "$out"
check "reconcile (resolver raises): a second row in the SAME pass is still reached (park-and-continue)" \
    "SURVIVOR_UNTOUCHED_STATE started" "$out"

echo "-- unit: _reconcile_root -- resolver returns something that is not a usable status dict -> orphaned (validate the declaration, not just a value) --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import queue, tempfile
from assistant import tasks

root = tempfile.mkdtemp(prefix="at-reconcile-malformed-")
conn = tasks._open_conn(root)
tasks._insert(conn, "not-a-dict", "harness", {}, None)
tasks._transition(conn, "not-a-dict", tasks.STATE_STARTED, external_job_id="job-1")
tasks._insert(conn, "bad-state-value", "harness", {}, None)
tasks._transition(conn, "bad-state-value", tasks.STATE_STARTED, external_job_id="job-2")

def returns_string(external_job_id, payload):
    return "completed"  # not a dict at all

def returns_unknown_state(external_job_id, payload):
    return {"state": "totally-made-up"}

traces_q = queue.Queue()
tasks._reconcile_root(conn, root, {"harness": returns_string}, traces_q)
conn.close()

rows = {r["id"]: r for r in tasks.list_tasks(root)}
print("NOT_A_DICT_STATE", rows["not-a-dict"]["state"])
print("NOT_A_DICT_ERROR_NAMES_UNUSABLE", "unusable status" in (rows["not-a-dict"].get("error") or ""))

conn2 = tasks._open_conn(root)
traces_q2 = queue.Queue()
tasks._reconcile_root(conn2, root, {"harness": returns_unknown_state}, traces_q2)
conn2.close()
rows2 = {r["id"]: r for r in tasks.list_tasks(root)}
print("BAD_STATE_VALUE_STATE", rows2["bad-state-value"]["state"])
PY
)"
check "reconcile (resolver returns a non-dict): row becomes orphaned" "NOT_A_DICT_STATE orphaned" "$out"
check "reconcile (resolver returns a non-dict): error names it as an unusable status" "NOT_A_DICT_ERROR_NAMES_UNUSABLE True" "$out"
check "reconcile (resolver returns an unrecognized state value): row becomes orphaned too" "BAD_STATE_VALUE_STATE orphaned" "$out"

echo "-- unit: _reconcile_root -- resolver reports not_found (remote has no record) -> orphaned, with its OWN distinct reason from a malformed response --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import queue, tempfile
from assistant import tasks

root = tempfile.mkdtemp(prefix="at-reconcile-notfound-")
conn = tasks._open_conn(root)
tasks._insert(conn, "vanished", "harness", {}, None)
tasks._transition(conn, "vanished", tasks.STATE_STARTED, external_job_id="job-gone")

def not_found_resolver(external_job_id, payload):
    return {"state": "not_found"}

traces_q = queue.Queue()
tasks._reconcile_root(conn, root, {"harness": not_found_resolver}, traces_q)
conn.close()

row = {r["id"]: r for r in tasks.list_tasks(root)}["vanished"]
print("STATE", row["state"])
print("ERROR_NAMES_NO_RECORD", "no record" in (row.get("error") or ""))
print("ERROR_NAMES_JOBID", "job-gone" in (row.get("error") or ""))
PY
)"
check "reconcile (not_found): row becomes orphaned" "STATE orphaned" "$out"
check "reconcile (not_found): error names it as the remote having no record (distinct from a malformed-response reason)" \
    "ERROR_NAMES_NO_RECORD True" "$out"
check "reconcile (not_found): error names the specific external_job_id" "ERROR_NAMES_JOBID True" "$out"

echo "-- unit: _reconcile_root -- resolver reports completed/failed -> the remote's real state wins, never resubmitted, same trace events as the normal flow plus reconciled=True --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import queue, tempfile
from assistant import tasks

root = tempfile.mkdtemp(prefix="at-reconcile-definitive-")
conn = tasks._open_conn(root)
tasks._insert(conn, "done-elsewhere", "harness", {}, "turn-done")
tasks._transition(conn, "done-elsewhere", tasks.STATE_PROGRESS, external_job_id="job-done")
tasks._insert(conn, "failed-elsewhere", "harness", {}, "turn-fail")
tasks._transition(conn, "failed-elsewhere", tasks.STATE_STARTED, external_job_id="job-fail")

def resolver(external_job_id, payload):
    if external_job_id == "job-done":
        return {"state": "completed", "artifact_path": "/artifacts/x.glb", "result": {"ok": True}}
    return {"state": "failed", "error": "harness exited 1"}

traces_q = queue.Queue()
tasks._reconcile_root(conn, root, {"harness": resolver}, traces_q)
conn.close()

rows = {r["id"]: r for r in tasks.list_tasks(root)}
print("DONE_STATE", rows["done-elsewhere"]["state"])
print("DONE_ARTIFACT", rows["done-elsewhere"]["artifact_path"])
print("DONE_RESULT", rows["done-elsewhere"]["result"])
print("FAILED_STATE", rows["failed-elsewhere"]["state"])
print("FAILED_ERROR", rows["failed-elsewhere"]["error"])

trace_items = []
while True:
    try:
        item = traces_q.get_nowait()
    except queue.Empty:
        break
    trace_items.append(item["event"])
completed_ev = next((e for e in trace_items if e["kind"] == "task.completed"), None)
failed_ev = next((e for e in trace_items if e["kind"] == "task.failed"), None)
print("COMPLETED_EVENT_RECONCILED", bool(completed_ev and completed_ev["payload"].get("reconciled") is True))
print("COMPLETED_EVENT_TURN_ID", completed_ev.get("turn_id") if completed_ev else None)
print("FAILED_EVENT_RECONCILED", bool(failed_ev and failed_ev["payload"].get("reconciled") is True))
PY
)"
check "reconcile (resolver says completed): row transitions to completed, never resubmitted" "DONE_STATE completed" "$out"
check "reconcile (resolver says completed): artifact_path carries through" "DONE_ARTIFACT /artifacts/x.glb" "$out"
check "reconcile (resolver says completed): result carries through" "DONE_RESULT {'ok': True}" "$out"
check "reconcile (resolver says failed): row transitions to failed" "FAILED_STATE failed" "$out"
check "reconcile (resolver says failed): error carries through from the resolver" "FAILED_ERROR harness exited 1" "$out"
check "reconcile (definitive outcomes): the task.completed trace event is marked reconciled=True" "COMPLETED_EVENT_RECONCILED True" "$out"
check "reconcile (definitive outcomes): the trace event still carries the row's own turn_id" "COMPLETED_EVENT_TURN_ID turn-done" "$out"
check "reconcile (definitive outcomes): the task.failed trace event is marked reconciled=True too" "FAILED_EVENT_RECONCILED True" "$out"

echo "-- unit: _reconcile_root -- resolver reports in_progress -> genuinely still running, NO state change, but a reconcile_checked trace event still fires --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import queue, tempfile
from assistant import tasks

root = tempfile.mkdtemp(prefix="at-reconcile-inprogress-")
conn = tasks._open_conn(root)
tasks._insert(conn, "still-going", "harness", {}, None)
tasks._transition(conn, "still-going", tasks.STATE_PROGRESS, external_job_id="job-live")

def resolver(external_job_id, payload):
    return {"state": "in_progress"}

before = {r["id"]: r for r in tasks.list_tasks(root)}["still-going"]

traces_q = queue.Queue()
tasks._reconcile_root(conn, root, {"harness": resolver}, traces_q)
conn.close()

after = {r["id"]: r for r in tasks.list_tasks(root)}["still-going"]
print("STATE_UNCHANGED", after["state"] == "progress" == before["state"])
print("UPDATED_AT_UNCHANGED", after["updated_at"] == before["updated_at"])  # no write at all for a genuine no-op

trace_kinds = []
while True:
    try:
        item = traces_q.get_nowait()
    except queue.Empty:
        break
    trace_kinds.append(item["event"]["kind"])
print("HAS_RECONCILE_CHECKED_EVENT", "task.reconcile_checked" in trace_kinds)
print("NO_COMPLETED_OR_FAILED_EVENT", "task.completed" not in trace_kinds and "task.failed" not in trace_kinds)
PY
)"
check "reconcile (in_progress): the row's state genuinely does not change" "STATE_UNCHANGED True" "$out"
check "reconcile (in_progress): no write happens at all for a real no-op (updated_at untouched)" "UPDATED_AT_UNCHANGED True" "$out"
check "reconcile (in_progress): still emits a task.reconcile_checked trace event (a restart leaves SOME record)" "HAS_RECONCILE_CHECKED_EVENT True" "$out"
check "reconcile (in_progress): does not ALSO emit a completed/failed event" "NO_COMPLETED_OR_FAILED_EVENT True" "$out"

echo "-- unit: _reconcile_root -- a queued-but-never-started row IS reconciled (closure, issue #342 review: Sec12.4 'unreconcilable -> orphaned' applies to it too); terminal rows are never re-touched --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import queue, tempfile
from assistant import tasks

root = tempfile.mkdtemp(prefix="at-reconcile-scope-")
conn = tasks._open_conn(root)
tasks._insert(conn, "never-started", "harness", {}, "turn-never")  # stays queued -- default state _insert leaves it in
tasks._insert(conn, "already-done", "harness", {}, None)
tasks._transition(conn, "already-done", tasks.STATE_COMPLETED, result='"pre-existing"')
tasks._insert(conn, "already-orphaned", "harness", {}, None)
tasks._transition(conn, "already-orphaned", tasks.STATE_ORPHANED, error="orphaned on a previous restart")
tasks._insert(conn, "in-flight", "harness", {}, None)
tasks._transition(conn, "in-flight", tasks.STATE_STARTED, external_job_id="job-real")  # non-empty control: reconciliation DOES run this pass

def resolver(external_job_id, payload):
    return {"state": "completed", "result": "reconciled"}

traces_q = queue.Queue()
tasks._reconcile_root(conn, root, {"harness": resolver}, traces_q)
conn.close()

rows = {r["id"]: r for r in tasks.list_tasks(root)}
print("NEVER_STARTED_STATE", rows["never-started"]["state"])
print("NEVER_STARTED_ERROR_NAMES_NEVER_STARTED", "never started" in (rows["never-started"].get("error") or ""))
print("ALREADY_DONE_UNTOUCHED", rows["already-done"]["state"], rows["already-done"]["result"])
print("ALREADY_ORPHANED_UNTOUCHED", rows["already-orphaned"]["state"], rows["already-orphaned"]["error"])
print("IN_FLIGHT_WAS_ACTUALLY_RECONCILED", rows["in-flight"]["state"])  # proves the pass genuinely ran, not a no-op fixture

trace_kinds = []
while True:
    try:
        item = traces_q.get_nowait()
    except queue.Empty:
        break
    trace_kinds.append((item["event"]["kind"], item["event"].get("turn_id")))
print("HAS_ORPHANED_EVENT_FOR_NEVER_STARTED", ("task.orphaned", "turn-never") in trace_kinds)
PY
)"
check "reconcile (scope, closure): a queued-but-never-started row is orphaned too, not left stuck forever" \
    "NEVER_STARTED_STATE orphaned" "$out"
check "reconcile (scope, closure): its error names why (never started, not 'was running and vanished')" \
    "NEVER_STARTED_ERROR_NAMES_NEVER_STARTED True" "$out"
check "reconcile (scope, closure): still emits task.orphaned carrying its own turn_id, same as any other orphaning" \
    "HAS_ORPHANED_EVENT_FOR_NEVER_STARTED True" "$out"
check "reconcile (scope): an already-completed row is never re-touched" "ALREADY_DONE_UNTOUCHED completed pre-existing" "$out"
check "reconcile (scope): an already-orphaned row (from a PRIOR restart) is never re-touched either" \
    "ALREADY_ORPHANED_UNTOUCHED orphaned orphaned on a previous restart" "$out"
check "reconcile (scope): the one genuinely in-flight row in the same pass WAS reconciled (non-empty control -- the pass really ran)" \
    "IN_FLIGHT_WAS_ACTUALLY_RECONCILED completed" "$out"

echo "-- integration: run_worker -- repos_getter given, reconciliation runs ONCE at startup, before any queue item is even processed --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import queue, tempfile, threading, time
from assistant import tasks

root = tempfile.mkdtemp(prefix="at-worker-reconcile-")
conn = tasks._open_conn(root)
tasks._insert(conn, "leftover", "harness", {}, None)
tasks._transition(conn, "leftover", tasks.STATE_STARTED, external_job_id="job-leftover")
conn.close()

q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=tasks.run_worker, args=(q, stop),
                      kwargs={"poll_timeout": 0.1, "repos_getter": lambda: [("jarvis", root)]})
t.start()

deadline = time.monotonic() + 5.0
row = {}
while time.monotonic() < deadline:
    rows = {r["id"]: r for r in tasks.list_tasks(root)}
    row = rows.get("leftover", {})
    if row.get("state") == "orphaned":
        break
    time.sleep(0.1)
stop.set()
t.join(timeout=3)

print("RECONCILED_AT_STARTUP", row.get("state"))
print("WORKER_JOINED", not t.is_alive())
PY
)"
check "run_worker (repos_getter given): a leftover started row is reconciled at startup, no resolver registered -> orphaned" \
    "RECONCILED_AT_STARTUP orphaned" "$out"
check "run_worker (repos_getter given): the worker thread still joins cleanly afterward" "WORKER_JOINED True" "$out"

echo "-- integration: run_worker -- repos_getter OMITTED (the default) -> reconciliation does NOT run at all, existing callers/tests are unaffected --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import queue, tempfile, threading, time
from assistant import tasks

root = tempfile.mkdtemp(prefix="at-worker-noreconcile-")
conn = tasks._open_conn(root)
tasks._insert(conn, "leftover2", "harness", {}, None)
tasks._transition(conn, "leftover2", tasks.STATE_STARTED, external_job_id="job-leftover2")
conn.close()

q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=tasks.run_worker, args=(q, stop), kwargs={"poll_timeout": 0.1})
t.start()
time.sleep(0.5)  # give a real (buggy) reconciliation pass every chance to have run if it were going to
stop.set()
t.join(timeout=3)

row = {r["id"]: r for r in tasks.list_tasks(root)}["leftover2"]
print("STATE_UNCHANGED_NO_REPOS_GETTER", row["state"])
PY
)"
check "run_worker (no repos_getter): a leftover started row is left completely untouched -- opt-in, not automatic" \
    "STATE_UNCHANGED_NO_REPOS_GETTER started" "$out"

echo "-- integration: run_worker -- repos_getter returns MULTIPLE roots, every one gets reconciled, not just the first --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import queue, tempfile, threading, time
from assistant import tasks

root_a = tempfile.mkdtemp(prefix="at-multi-a-")
root_b = tempfile.mkdtemp(prefix="at-multi-b-")
for root in (root_a, root_b):
    conn = tasks._open_conn(root)
    tasks._insert(conn, "orphan-me", "no-such-kind", {}, None)
    tasks._transition(conn, "orphan-me", tasks.STATE_STARTED, external_job_id="job-1")
    conn.close()

q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=tasks.run_worker, args=(q, stop),
                      kwargs={"poll_timeout": 0.1, "repos_getter": lambda: [("a", root_a), ("b", root_b)]})
t.start()

deadline = time.monotonic() + 5.0
state_a = state_b = None
while time.monotonic() < deadline:
    state_a = tasks.list_tasks(root_a)[0]["state"] if tasks.list_tasks(root_a) else None
    state_b = tasks.list_tasks(root_b)[0]["state"] if tasks.list_tasks(root_b) else None
    if state_a == "orphaned" and state_b == "orphaned":
        break
    time.sleep(0.1)
stop.set()
t.join(timeout=3)

print("ROOT_A_STATE", state_a)
print("ROOT_B_STATE", state_b)
PY
)"
check "run_worker (multiple roots): the FIRST root's leftover row is reconciled" "ROOT_A_STATE orphaned" "$out"
check "run_worker (multiple roots): the SECOND root's leftover row is reconciled too, not skipped" "ROOT_B_STATE orphaned" "$out"

echo "-- integration: run_worker -- a broken repos_getter never prevents the worker from starting or draining the live queue --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import queue, tempfile, threading, time
from assistant import tasks

root = tempfile.mkdtemp(prefix="at-broken-reposgetter-")

def broken_repos_getter():
    raise RuntimeError("config totally unreadable")

def echo_executor(payload, report_progress):
    return {"result": "still works"}

q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=tasks.run_worker, args=(q, stop),
                      kwargs={"executors": {"echo": echo_executor}, "poll_timeout": 0.1,
                              "repos_getter": broken_repos_getter})
t.start()
tid = tasks.enqueue(q, root, "echo", {})

deadline = time.monotonic() + 5.0
rows = []
while time.monotonic() < deadline:
    rows = tasks.list_tasks(root)
    if rows and rows[0]["state"] == "completed":
        break
    time.sleep(0.1)
stop.set()
t.join(timeout=3)

print("WORKER_STILL_PROCESSED_LIVE_QUEUE", bool(rows) and rows[0]["state"] == "completed")
print("WORKER_JOINED", not t.is_alive())
PY
)"
check "run_worker (broken repos_getter): the worker still starts and drains the live queue normally" \
    "WORKER_STILL_PROCESSED_LIVE_QUEUE True" "$out"
check "run_worker (broken repos_getter): the worker thread still joins cleanly" "WORKER_JOINED True" "$out"

# ------------------------------------------------------------------------
echo "-- integration: engine wiring -- a real restart (fresh engine.start()) reconciles a leftover in-flight row end to end --"
_at_reconcile_root="$(mktemp -d)"
at_repo "$_at_reconcile_root" jarvis

engine_out="$(SCRIPTS_DIR="$AT_SCRIPTS" ROOT="$_at_reconcile_root" python3 - <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import engine, tasks

root = os.environ["ROOT"]
state_dir = os.path.join(root, ".claude", "assistant-engine-state")

# Simulate a PRIOR run that crashed mid-task: a started row with an
# external_job_id, written directly to tasks.sqlite BEFORE this engine
# ever starts -- exactly what a restart finds.
conn = tasks._open_conn(root)
tasks._insert(conn, "pre-crash-task", "harness", {}, "turn-precrash")
tasks._transition(conn, "pre-crash-task", tasks.STATE_STARTED, external_job_id="job-precrash")
conn.close()

e = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir)
e.start()
try:
    deadline = time.monotonic() + 5.0
    payload = None
    while time.monotonic() < deadline:
        status, payload, _ = e.handle("GET", "/assistant/tasks", query={"assistant": ["jarvis"], "state": ["orphaned"]})
        if payload.get("tasks"):
            break
        time.sleep(0.2)
    print("STATUS", status)
    print("N_ORPHANED", len(payload.get("tasks", [])))
    print("ORPHANED_TASK_ID_MATCHES", payload["tasks"][0]["id"] == "pre-crash-task" if payload.get("tasks") else False)
finally:
    e.stop()
    print("ENGINE_STOPPED_CLEANLY", True)
PY
)"
check "engine wiring (restart reconciliation, real e.start()): the endpoint's state=orphaned filter finds it" "STATUS 200" "$engine_out"
check "engine wiring (restart reconciliation): exactly the one pre-crash row is orphaned" "N_ORPHANED 1" "$engine_out"
check "engine wiring (restart reconciliation): it is genuinely the SAME row that existed before the engine ever started" \
    "ORPHANED_TASK_ID_MATCHES True" "$engine_out"
check "engine wiring (restart reconciliation): engine.stop() still joins cleanly afterward" "ENGINE_STOPPED_CLEANLY True" "$engine_out"
rm -rf "$_at_reconcile_root"
