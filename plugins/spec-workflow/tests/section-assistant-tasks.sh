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

# at_marker_only <dir> -- an anchored repo (.neural-network marker present,
# same as every other repos_getter()-yielded root) with NO project.yaml at
# all -- discovery.classify_repo(root) resolves this to "no-config", never
# "candidate". Issue #497: repos_getter yields every anchored repo, assistant
# candidate or not, so this is the fixture for "anchored but not an
# assistant" -- the exact shape 8 real repos on the reporting machine had.
at_marker_only() {
    local dir="$1"
    mkdir -p "$dir/.claude"
    printf "%s\n" "# neural-network" >"$dir/.claude/.neural-network"
}

# at_repo_disabled <dir> <main> -- same shape as at_repo, but
# assistant.enabled: false -- discovery.classify_repo(root) resolves this to
# "disabled", never "candidate" (§6.1's assistant: section is the sole
# authority for enabled state). Issue #497 round-1 review MINOR-1: a root
# that WAS a candidate (has a real tasks.sqlite from when it was enabled)
# and has since been disabled/de-candidated must still be skipped by both
# reconciliation sweeps -- classify_repo is the single source of truth, not
# "does a db already exist".
at_repo_disabled() {
    local dir="$1" main="$2"
    mkdir -p "$dir/.claude"
    printf "%s\n" "# neural-network" >"$dir/.claude/.neural-network"
    printf "%s\n" \
        "schemaVersion: 2" \
        "assistant:" \
        "    version: 1" \
        "    enabled: false" \
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
at_worker_reconcile_root="$(mktemp -d)"
at_repo "$at_worker_reconcile_root" jarvis
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - "$at_worker_reconcile_root" <<'PY'
import queue, sys, threading, time
from assistant import tasks

root = sys.argv[1]  # issue #497: must be a real assistant candidate, not a bare tempdir
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
rm -rf "$at_worker_reconcile_root"

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
at_multi_root_a="$(mktemp -d)"
at_multi_root_b="$(mktemp -d)"
at_repo "$at_multi_root_a" jarvis-a
at_repo "$at_multi_root_b" jarvis-b
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - "$at_multi_root_a" "$at_multi_root_b" <<'PY'
import queue, sys, threading, time
from assistant import tasks

root_a, root_b = sys.argv[1], sys.argv[2]  # issue #497: real assistant candidates, not bare tempdirs
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
rm -rf "$at_multi_root_a" "$at_multi_root_b"

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

# ==========================================================================
# AST-070: dispatched harness jobs as a task kind (SPEC-ASSISTANT.md §9.4,
# issue #345, docs/design/ast-E6.md sequence 3). `harness.py` registers the
# FIRST real executor/resolver pair into the `executors`/`resolvers` seams
# this file's own AST-066/067 sections above prove are otherwise empty.
# `$AT_STUB_HARNESS` is a fake agentic-CLI binary (never the real codex/
# claude) providing BOTH a `codex` and a `claude` executable, entirely
# env-driven -- see its own docstring for every $HARNESS_STUB_* knob.
# ==========================================================================
echo "== assistant harness jobs (AST-070: dispatched harness jobs as a task kind, SPEC-ASSISTANT.md §9.4) =="

AT_STUB_HARNESS="$FIX/stub-harness"

echo "-- integration: run_harness_job -- happy path: queued -> started -> progress -> completed, each a trace event, artifact + result populated --"
at_argv_file="$(mktemp)"
out="$(PATH="$AT_STUB_HARNESS:$PATH" HARNESS_STUB_ARGV_FILE="$at_argv_file" PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import queue, tempfile, threading, time
from assistant import tasks, harness, artifacts

root = tempfile.mkdtemp(prefix="at-harness-happy-")
q = queue.Queue()
traces_q = queue.Queue()
stop = threading.Event()

t = threading.Thread(target=tasks.run_worker, args=(q, stop),
                      kwargs={"executors": {harness.KIND: harness.run_harness_job},
                              "resolvers": {harness.KIND: harness.resolve_harness_job},
                              "poll_timeout": 0.1, "traces_queue": traces_q})
t.start()

tid = harness.dispatch(q, root, provider="codex", model="gpt-5.6-sol", prompt="say hi",
                        poll_interval_seconds=0.05, turn_id="turn-harness-1")

deadline = time.monotonic() + 10.0
row = {}
while time.monotonic() < deadline:
    rows = tasks.list_tasks(root)
    if rows and rows[0]["state"] in ("completed", "failed"):
        row = rows[0]
        break
    time.sleep(0.05)
stop.set()
t.join(timeout=3)

print("TASK_ID_RETURNED", isinstance(tid, str) and bool(tid))
print("FINAL_STATE", row.get("state"))
print("ARTIFACT_PATH", row.get("artifact_path"))
print("ARTIFACT_PATH_IS_TASKID_LOG", row.get("artifact_path") == f"{tid}.log")
print("RESULT_HAS_RETURNCODE", isinstance(row.get("result"), dict) and row["result"].get("returncode") == 0)
print("EXTERNAL_JOB_ID_SET", bool(row.get("external_job_id")))
print("EXTERNAL_JOB_ID_STARTS_WITH_TASKID", (row.get("external_job_id") or "").startswith(tid + ":"))
print("ROW_TURN_ID", row.get("turn_id"))

path, size = artifacts.resolve(root, tid)
with open(path) as fh:
    content = fh.read()
print("ARTIFACT_SERVABLE", size > 0)
print("ARTIFACT_CONTENT_HAS_STUB_OUTPUT", "harness job complete" in content)

trace_kinds = []
progress_count = 0
turn_ids = set()
while True:
    try:
        item = traces_q.get_nowait()
    except queue.Empty:
        break
    ev = item["event"]
    trace_kinds.append(ev["kind"])
    turn_ids.add(ev.get("turn_id"))
    if ev["kind"] == "task.progress":
        progress_count += 1
print("HAS_QUEUED", "task.queued" in trace_kinds)
print("HAS_STARTED", "task.started" in trace_kinds)
print("HAS_PROGRESS", progress_count >= 1)
print("HAS_COMPLETED", "task.completed" in trace_kinds)
print("ORDER_OK", trace_kinds[0] == "task.queued" and trace_kinds[1] == "task.started" and trace_kinds[-1] == "task.completed")
print("EVERY_EVENT_SAME_TURN_ID", turn_ids == {"turn-harness-1"})
PY
)"
check "harness happy path: dispatch returns a task id" "TASK_ID_RETURNED True" "$out"
check "harness happy path: reaches completed" "FINAL_STATE completed" "$out"
check "harness happy path: artifact_path is task-id-derived (engine-side, never the job's own claim)" \
    "ARTIFACT_PATH_IS_TASKID_LOG True" "$out"
check "harness happy path: result carries the subprocess returncode" "RESULT_HAS_RETURNCODE True" "$out"
check "harness happy path: external_job_id is populated mid-flight (resumable, §12.4)" "EXTERNAL_JOB_ID_SET True" "$out"
check "harness happy path: external_job_id is task-id-prefixed (resolver-decodable without a separate lookup)" \
    "EXTERNAL_JOB_ID_STARTS_WITH_TASKID True" "$out"
check "harness happy path: the row carries the dispatch-time turn_id" "ROW_TURN_ID turn-harness-1" "$out"
check "harness happy path: the artifact is servable via artifacts.resolve()" "ARTIFACT_SERVABLE True" "$out"
check "harness happy path: the artifact content is the job's own captured transcript" "ARTIFACT_CONTENT_HAS_STUB_OUTPUT True" "$out"
check "harness happy path: emits task.queued" "HAS_QUEUED True" "$out"
check "harness happy path: emits task.started" "HAS_STARTED True" "$out"
check "harness happy path: emits at least one task.progress (report/progress flow, §9.4)" "HAS_PROGRESS True" "$out"
check "harness happy path: emits task.completed" "HAS_COMPLETED True" "$out"
check "harness happy path: events are queued -> started -> ... -> completed, in order" "ORDER_OK True" "$out"
check "harness happy path: every trace event carries the SAME turn_id (conversation resumable mid-job, §9.4)" \
    "EVERY_EVENT_SAME_TURN_ID True" "$out"

argv_contents="$(cat "$at_argv_file")"
check "harness happy path (codex provider): --json is present" "--json" "$argv_contents"
check "harness happy path (codex provider): own sandbox posture -- workspace-write, NOT the turn's read-only" \
    "workspace-write" "$argv_contents"
check_absent "harness happy path (codex provider): never the turn's read-only sandbox (own posture, §9.4)" \
    "read-only" "$argv_contents"
check "harness happy path (codex provider): --ignore-user-config is pinned" "--ignore-user-config" "$argv_contents"
check "harness happy path (codex provider): --ignore-rules is pinned" "--ignore-rules" "$argv_contents"
check "harness happy path (codex provider): --ephemeral is pinned" "--ephemeral" "$argv_contents"
check "harness happy path (codex provider): --skip-git-repo-check is pinned" "--skip-git-repo-check" "$argv_contents"
check "harness happy path (codex provider): -C isolated working root is pinned" "-C" "$argv_contents"
check "harness happy path (codex provider): prompt arrives as one literal argv element" "say hi" "$argv_contents"
rm -f "$at_argv_file"

echo "-- unit: _build_argv -- claude provider: own sandbox posture (tools allowed, unlike a turn) with isolation still pinned --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import harness

argv = harness._build_argv("claude", "sonnet-x", "/tmp/some-isolated-workdir", "do the thing; rm -rf / && echo pwned")
print("ARGV", argv)
print("HAS_SAFE_MODE", "--safe-mode" in argv)
print("HAS_STRICT_MCP", "--strict-mcp-config" in argv)
print("HAS_NO_SESSION_PERSISTENCE", "--no-session-persistence" in argv)
print("HAS_ACCEPT_EDITS", "acceptEdits" in argv)
print("NEVER_DISABLES_ALL_TOOLS", not ("--tools" in argv and "" in argv))
print("PROMPT_IS_ONE_ELEMENT", argv.count("do the thing; rm -rf / && echo pwned") == 1)
print("MODEL_PASSED_VERBATIM", "sonnet-x" in argv)
PY
)"
check "claude harness argv: --safe-mode pinned (no CLAUDE.md/plugins/hooks, same as a turn)" "HAS_SAFE_MODE True" "$out"
check "claude harness argv: --strict-mcp-config pinned" "HAS_STRICT_MCP True" "$out"
check "claude harness argv: --no-session-persistence pinned" "HAS_NO_SESSION_PERSISTENCE True" "$out"
check "claude harness argv: --permission-mode acceptEdits (headless auto-approve, own sandbox posture)" "HAS_ACCEPT_EDITS True" "$out"
check "claude harness argv: never disables all tools (a harness job is a FULL agentic run, unlike a turn)" \
    "NEVER_DISABLES_ALL_TOOLS True" "$out"
check "claude harness argv: an injection-shaped prompt still arrives as exactly one argv element" "PROMPT_IS_ONE_ELEMENT True" "$out"
check "claude harness argv: model passed verbatim" "MODEL_PASSED_VERBATIM True" "$out"

echo "-- unit: run_harness_job -- argv-array only, never a shell (§17.3) --"
harness_src="$AT_SCRIPTS/assistant/harness.py"
check_absent "harness.py: never uses shell=True" "shell=True" "$(cat "$harness_src")"
check_absent "harness.py: never calls os.system" "os.system" "$(cat "$harness_src")"

echo "-- integration: run_harness_job -- a nonzero exit fails the task with a specific error --"
out="$(PATH="$AT_STUB_HARNESS:$PATH" HARNESS_STUB_EXIT_CODE=7 PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import queue, tempfile, threading, time
from assistant import tasks, harness

root = tempfile.mkdtemp(prefix="at-harness-fail-")
q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=tasks.run_worker, args=(q, stop),
                      kwargs={"executors": {harness.KIND: harness.run_harness_job}, "poll_timeout": 0.1})
t.start()
tid = harness.dispatch(q, root, provider="codex", model="m", prompt="p")

deadline = time.monotonic() + 10.0
row = {}
while time.monotonic() < deadline:
    rows = tasks.list_tasks(root)
    if rows and rows[0]["state"] in ("completed", "failed"):
        row = rows[0]
        break
    time.sleep(0.05)
stop.set()
t.join(timeout=3)
print("STATE", row.get("state"))
print("ERROR_NAMES_EXIT_CODE", "exited 7" in (row.get("error") or ""))
PY
)"
check "harness nonzero exit: task state is failed" "STATE failed" "$out"
check "harness nonzero exit: error names the specific exit code" "ERROR_NAMES_EXIT_CODE True" "$out"

echo "-- integration: run_harness_job -- exceeding the timeout kills the subprocess and fails specifically, never hangs --"
out="$(PATH="$AT_STUB_HARNESS:$PATH" HARNESS_STUB_MODE=hang HARNESS_STUB_HANG_SECONDS=30 PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import queue, tempfile, threading, time
from assistant import tasks, harness

root = tempfile.mkdtemp(prefix="at-harness-timeout-")
q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=tasks.run_worker, args=(q, stop),
                      kwargs={"executors": {harness.KIND: harness.run_harness_job}, "poll_timeout": 0.1})
t.start()
start = time.monotonic()
tid = harness.dispatch(q, root, provider="codex", model="m", prompt="p", timeout_seconds=1, poll_interval_seconds=0.1)

deadline = time.monotonic() + 10.0
row = {}
while time.monotonic() < deadline:
    rows = tasks.list_tasks(root)
    if rows and rows[0]["state"] in ("completed", "failed"):
        row = rows[0]
        break
    time.sleep(0.05)
elapsed = time.monotonic() - start
stop.set()
t.join(timeout=5)
print("STATE", row.get("state"))
print("ERROR_NAMES_TIMEOUT", "timeout" in (row.get("error") or "").lower())
print("BOUNDED", elapsed < 8.0)
print("WORKER_JOINED", not t.is_alive())
PY
)"
check "harness timeout: task state is failed, never hangs forever" "STATE failed" "$out"
check "harness timeout: error names it as a timeout" "ERROR_NAMES_TIMEOUT True" "$out"
check "harness timeout: fails well inside a bounded window (kills the child, doesn't wait out the 30s hang)" "BOUNDED True" "$out"
check "harness timeout: the worker thread still joins cleanly afterward" "WORKER_JOINED True" "$out"

echo "-- SECURITY (OWNER threat-model directive, issue #345): a hostile job trying to smuggle its own artifact_path is ignored/rejected --"
out="$(PATH="$AT_STUB_HARNESS:$PATH" HARNESS_STUB_MODE=hostile PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import queue, tempfile, threading, time
from assistant import tasks, harness, artifacts

root = tempfile.mkdtemp(prefix="at-harness-hostile-")
q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=tasks.run_worker, args=(q, stop),
                      kwargs={"executors": {harness.KIND: harness.run_harness_job}, "poll_timeout": 0.1})
t.start()
tid = harness.dispatch(q, root, provider="claude", model="m", prompt="try to smuggle a path")

deadline = time.monotonic() + 10.0
row = {}
while time.monotonic() < deadline:
    rows = tasks.list_tasks(root)
    if rows and rows[0]["state"] in ("completed", "failed"):
        row = rows[0]
        break
    time.sleep(0.05)
stop.set()
t.join(timeout=3)

print("STATE", row.get("state"))
print("ARTIFACT_PATH", row.get("artifact_path"))
print("ARTIFACT_PATH_IS_TASKID_LOG", row.get("artifact_path") == f"{tid}.log")
print("NEVER_THE_SMUGGLED_PATH", row.get("artifact_path") != "../../../../etc/passwd")
print("NO_TRAVERSAL_SEQUENCE", ".." not in (row.get("artifact_path") or ""))

# artifacts.resolve() is the last line of defence -- must still resolve
# cleanly INSIDE the artifacts root, never escape it.
path, size = artifacts.resolve(root, tid)
artifacts_root = artifacts._artifacts_root(root)
print("RESOLVED_INSIDE_ARTIFACTS_ROOT", artifacts._within(path, artifacts_root))
print("RESOLVED_NEVER_ETC_PASSWD", "etc/passwd" not in path and "etc/shadow" not in path)
PY
)"
check "hostile smuggling: task still completes (the stub CLI itself exits 0)" "STATE completed" "$out"
check "hostile smuggling: artifact_path is STILL the engine-constructed task-id-derived path" \
    "ARTIFACT_PATH_IS_TASKID_LOG True" "$out"
check "hostile smuggling: the injected path string is never adopted" "NEVER_THE_SMUGGLED_PATH True" "$out"
check "hostile smuggling: no traversal sequence ever reaches the stored artifact_path" "NO_TRAVERSAL_SEQUENCE True" "$out"
check "hostile smuggling: artifacts.resolve() (last line of defence) still confines the path inside the artifacts root" \
    "RESOLVED_INSIDE_ARTIFACTS_ROOT True" "$out"
check "hostile smuggling: the resolved path is never anywhere near /etc/passwd or /etc/shadow" \
    "RESOLVED_NEVER_ETC_PASSWD True" "$out"

echo "-- unit: resolve_harness_job -- a completed marker wins outright, never resubmitted --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import tempfile
from assistant import harness

root = tempfile.mkdtemp(prefix="at-harness-resolve-completed-")
harness._write_marker(root, "task-done", {"state": "completed", "result": {"ok": True}})
outcome = harness.resolve_harness_job(harness._encode_external_job_id("task-done", 999999), {"root": root})
print("STATE", outcome.get("state"))
print("ARTIFACT_PATH", outcome.get("artifact_path"))
print("RESULT", outcome.get("result"))
PY
)"
check "resolve (completed marker): reports completed" "STATE completed" "$out"
check "resolve (completed marker): artifact_path is REBUILT from the decoded task id, never read from the marker (round-1 review BLOCKER, issue #345)" \
    "ARTIFACT_PATH task-done.log" "$out"
check "resolve (completed marker): result carries through" "RESULT {'ok': True}" "$out"

echo "-- SECURITY (round-1 review BLOCKER, issue #345): a marker naming a FOREIGN/traversal artifact_path is ignored -- the resolver never trusts stored state for the served path --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import tempfile
from assistant import harness, artifacts

root = tempfile.mkdtemp(prefix="at-harness-resolve-hostile-marker-")
# A legitimate OTHER task real artifact, sitting in the same artifacts
# root -- what a cross-task substitution attack would try to redirect the
# victim task resolver onto.
harness._publish_artifact(root, "secret-other-task.log", "this belongs to a DIFFERENT task")

# The victim task own marker file, TAMPERED (or simply a bug or an old
# marker shape) to name that foreign file instead of its own.
harness._write_marker(root, "victim-task",
                       {"state": "completed", "artifact_path": "secret-other-task.log", "result": {"ok": True}})
outcome = harness.resolve_harness_job(harness._encode_external_job_id("victim-task", 123456), {"root": root})
print("STATE", outcome.get("state"))
print("ARTIFACT_PATH", outcome.get("artifact_path"))
print("NEVER_THE_FOREIGN_PATH", outcome.get("artifact_path") != "secret-other-task.log")
print("IS_TASKID_DERIVED", outcome.get("artifact_path") == "victim-task.log")

# A second flavor: a traversal-shaped value in the marker (never just a
# same-root substitution).
harness._write_marker(root, "victim-task-2",
                       {"state": "completed", "artifact_path": "../../../../etc/passwd", "result": None})
outcome2 = harness.resolve_harness_job(harness._encode_external_job_id("victim-task-2", 123457), {"root": root})
print("ARTIFACT_PATH_2", outcome2.get("artifact_path"))
print("NO_TRAVERSAL_2", ".." not in (outcome2.get("artifact_path") or ""))
PY
)"
check "hostile marker: still reports completed (the marker's state field is legitimate here)" "STATE completed" "$out"
check "hostile marker: artifact_path is the task's OWN rebuilt path, never the foreign one" "NEVER_THE_FOREIGN_PATH True" "$out"
check "hostile marker: artifact_path is exactly <task_id>.log, task-id-derived" "IS_TASKID_DERIVED True" "$out"
check "hostile marker (traversal-shaped): artifact_path is still task-id-derived" "ARTIFACT_PATH_2 victim-task-2.log" "$out"
check "hostile marker (traversal-shaped): no traversal sequence ever reaches the returned path" "NO_TRAVERSAL_2 True" "$out"

echo "-- unit: resolve_harness_job -- a failed marker reports failed with its own error --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import tempfile
from assistant import harness

root = tempfile.mkdtemp(prefix="at-harness-resolve-failed-")
harness._write_marker(root, "task-failed", {"state": "failed", "error": "harness exited 3"})
outcome = harness.resolve_harness_job(harness._encode_external_job_id("task-failed", 999998), {"root": root})
print("STATE", outcome.get("state"))
print("ERROR", outcome.get("error"))
PY
)"
check "resolve (failed marker): reports failed" "STATE failed" "$out"
check "resolve (failed marker): error carries through" "ERROR harness exited 3" "$out"

echo "-- unit: resolve_harness_job -- a genuinely still-running pid (no marker yet) reports in_progress, never resubmitted --"
out="$(PATH="$AT_STUB_HARNESS:$PATH" HARNESS_STUB_MODE=hang HARNESS_STUB_HANG_SECONDS=5 PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import os, subprocess, tempfile
from assistant import harness

root = tempfile.mkdtemp(prefix="at-harness-resolve-running-")
proc = subprocess.Popen(["codex"], cwd=root, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    ext_id = harness._encode_external_job_id("task-running", proc.pid)
    outcome = harness.resolve_harness_job(ext_id, {"root": root})
    print("STATE", outcome.get("state"))
finally:
    proc.kill()
    proc.wait(timeout=5)
PY
)"
check "resolve (still running): reports in_progress -- never resubmitted, genuinely still running" "STATE in_progress" "$out"

echo "-- unit: resolve_harness_job -- a vanished job (dead pid, no marker) reports not_found -> orphaned by the existing reconciliation --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import os, subprocess, sys, tempfile, time
from assistant import harness

root = tempfile.mkdtemp(prefix="at-harness-resolve-vanished-")
proc = subprocess.Popen([sys.executable, "-c", "pass"])
proc.wait(timeout=5)
# proc has genuinely exited and wrote no marker (it never ran through
# run_harness_job at all) -- exactly what a crashed-before-completion job
# looks like to a restart-time resolver.
ext_id = harness._encode_external_job_id("task-vanished", proc.pid)
outcome = harness.resolve_harness_job(ext_id, {"root": root})
print("STATE", outcome.get("state"))
PY
)"
check "resolve (vanished job): reports not_found (no marker, dead pid -- honest 'no record of it')" "STATE not_found" "$out"

echo "-- integration: _reconcile_root -- a harness-job row with a completed marker is reconciled end to end, no subprocess ever spawned (never resubmitted) --"
out="$(PATH="$AT_STUB_HARNESS:$PATH" HARNESS_STUB_CALL_LOG="$(mktemp)" PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import json, os, queue, tempfile
from assistant import tasks, harness

root = tempfile.mkdtemp(prefix="at-harness-reconcile-done-")
conn = tasks._open_conn(root)
tasks._insert(conn, "pre-crash-harness", harness.KIND,
              {"root": root, "provider": "codex", "model": "m", "prompt": "p"}, "turn-precrash")
ext_id = harness._encode_external_job_id("pre-crash-harness", 999996)
tasks._transition(conn, "pre-crash-harness", tasks.STATE_STARTED, external_job_id=ext_id)
harness._write_marker(root, "pre-crash-harness", {"state": "completed", "result": {"ok": True}})

traces_q = queue.Queue()
tasks._reconcile_root(conn, root, {harness.KIND: harness.resolve_harness_job}, traces_q)
conn.close()

row = {r["id"]: r for r in tasks.list_tasks(root)}["pre-crash-harness"]
print("STATE", row["state"])
print("ARTIFACT_PATH", row["artifact_path"])

call_log = os.environ.get("HARNESS_STUB_CALL_LOG")
calls = 0
if call_log and os.path.exists(call_log):
    with open(call_log) as fh:
        calls = sum(1 for _ in fh)
print("SUBPROCESS_NEVER_SPAWNED", calls == 0)

trace_kinds = []
while True:
    try:
        item = traces_q.get_nowait()
    except queue.Empty:
        break
    trace_kinds.append((item["event"]["kind"], item["event"]["payload"].get("reconciled")))
print("HAS_RECONCILED_COMPLETED_EVENT", ("task.completed", True) in trace_kinds)
PY
)"
check "reconcile (harness, completed marker): row transitions to completed" "STATE completed" "$out"
check "reconcile (harness, completed marker): artifact_path is rebuilt from the decoded task id, never read from the marker" \
    "ARTIFACT_PATH pre-crash-harness.log" "$out"
check "reconcile (harness, completed marker): resolving NEVER spawns a new subprocess (never resubmitted, §12.4)" \
    "SUBPROCESS_NEVER_SPAWNED True" "$out"
check "reconcile (harness, completed marker): the trace event is marked reconciled=True" \
    "HAS_RECONCILED_COMPLETED_EVENT True" "$out"

echo "-- integration: engine wiring -- e.start() registers harness.KIND's executor AND resolver into the real tasks worker (AST-070 fills the seams AST-066/067 left empty) --"
_at_harness_root="$(mktemp -d)"
at_repo "$_at_harness_root" jarvis

engine_out="$(SCRIPTS_DIR="$AT_SCRIPTS" ROOT="$_at_harness_root" PATH="$AT_STUB_HARNESS:$PATH" python3 - <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import engine, tasks, harness

root = os.environ["ROOT"]
state_dir = os.path.join(root, ".claude", "assistant-engine-state")
e = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir)
e.start()
try:
    tid = harness.dispatch(e.queues["tasks"], root, provider="codex", model="m", prompt="hi via engine",
                            poll_interval_seconds=0.05)

    deadline = time.monotonic() + 10.0
    payload = None
    while time.monotonic() < deadline:
        status, payload, _ = e.handle("GET", "/assistant/tasks", query={"assistant": ["jarvis"]})
        if payload.get("tasks") and payload["tasks"][0]["state"] in ("completed", "failed"):
            break
        time.sleep(0.1)
    print("STATUS", status)
    task = payload["tasks"][0] if payload.get("tasks") else {}
    print("TASK_STATE", task.get("state"))
    print("TASK_ID_MATCHES", task.get("id") == tid)
    print("ARTIFACT_PATH_SET", bool(task.get("artifact_path")))
finally:
    e.stop()
    print("ENGINE_STOPPED_CLEANLY", True)
PY
)"
check "engine wiring (harness): GET /assistant/tasks returns 200" "STATUS 200" "$engine_out"
check "engine wiring (harness): the real tasks worker executed the harness job end to end via the REAL registered executor" \
    "TASK_STATE completed" "$engine_out"
check "engine wiring (harness): the endpoint's task id matches dispatch's returned id" "TASK_ID_MATCHES True" "$engine_out"
check "engine wiring (harness): an artifact_path is populated" "ARTIFACT_PATH_SET True" "$engine_out"
check "engine wiring (harness): engine.stop() joins the tasks worker cleanly afterward" "ENGINE_STOPPED_CLEANLY True" "$engine_out"
rm -rf "$_at_harness_root"

echo "-- integration: engine wiring -- a real restart reconciles a leftover harness job via the REAL registered resolver (no resubmission) --"
_at_harness_reconcile_root="$(mktemp -d)"
at_repo "$_at_harness_reconcile_root" jarvis

engine_out="$(SCRIPTS_DIR="$AT_SCRIPTS" ROOT="$_at_harness_reconcile_root" HARNESS_STUB_CALL_LOG="$(mktemp)" python3 - <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import engine, tasks, harness

root = os.environ["ROOT"]
state_dir = os.path.join(root, ".claude", "assistant-engine-state")

# Simulate a PRIOR run that crashed mid-job, having already reached actual
# completion and written its durable marker (the "resumable mid-job"
# scenario the AST-070 AC names) -- written directly to tasks.sqlite BEFORE
# this engine ever starts, exactly what a restart finds.
conn = tasks._open_conn(root)
tasks._insert(conn, "precrash-harness-e2e", harness.KIND,
              {"root": root, "provider": "codex", "model": "m", "prompt": "p"}, "turn-precrash-h")
ext_id = harness._encode_external_job_id("precrash-harness-e2e", 999995)
tasks._transition(conn, "precrash-harness-e2e", tasks.STATE_STARTED, external_job_id=ext_id)
conn.close()
harness._write_marker(root, "precrash-harness-e2e", {"state": "completed", "result": {"done": True}})

e = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir)
e.start()
try:
    deadline = time.monotonic() + 5.0
    payload = None
    while time.monotonic() < deadline:
        status, payload, _ = e.handle("GET", "/assistant/tasks", query={"assistant": ["jarvis"], "state": ["completed"]})
        if payload.get("tasks"):
            break
        time.sleep(0.2)
    print("STATUS", status)
    task = payload["tasks"][0] if payload.get("tasks") else {}
    print("TASK_ID_MATCHES", task.get("id") == "precrash-harness-e2e")
    print("ARTIFACT_PATH", task.get("artifact_path"))

    call_log = os.environ.get("HARNESS_STUB_CALL_LOG")
    calls = 0
    if call_log and os.path.exists(call_log):
        with open(call_log) as fh:
            calls = sum(1 for _ in fh)
    print("NEVER_RESUBMITTED", calls == 0)
finally:
    e.stop()
    print("ENGINE_STOPPED_CLEANLY", True)
PY
)"
check "engine wiring (harness restart reconciliation): the completed-at-restart row is found via the endpoint" \
    "STATUS 200" "$engine_out"
check "engine wiring (harness restart reconciliation): it is the SAME pre-crash row" "TASK_ID_MATCHES True" "$engine_out"
check "engine wiring (harness restart reconciliation): artifact_path is rebuilt from the decoded task id, never read from the marker" \
    "ARTIFACT_PATH precrash-harness-e2e.log" "$engine_out"
check "engine wiring (harness restart reconciliation): the real resolver never resubmits (no subprocess spawned)" \
    "NEVER_RESUBMITTED True" "$engine_out"
check "engine wiring (harness restart reconciliation): engine.stop() still joins cleanly" "ENGINE_STOPPED_CLEANLY True" "$engine_out"
rm -rf "$_at_harness_reconcile_root"

# ==========================================================================
# AST-070 round-1 review fixes (issue #345): MAJOR (in_progress reconciliation
# is a dead end after the one-time startup sweep) + MINORS (timeout-path
# artifact loss, timeoutSeconds/pollIntervalSeconds validation,
# external_job_id path-traversal/pid<=0 hardening, honest progress pct).
# ==========================================================================
echo "-- MAJOR (round-1 review, issue #345): a row left in_progress by the one-time startup sweep is NOT a dead end -- the worker periodically re-checks it and picks up completion once the marker lands --"
at_harness_live_root="$(mktemp -d)"
at_repo "$at_harness_live_root" jarvis
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - "$at_harness_live_root" <<'PY'
import queue, subprocess, sys, threading, time
from assistant import tasks, harness

root = sys.argv[1]  # issue #497: must be a real assistant candidate, not a bare tempdir

# A genuinely still-running child -- exactly what a restart into a
# still-executing dispatched job looks like (NOT run through
# run_harness_job at all -- this row is a leftover row + a real,
# independent process, simulating the prior engine having crashed).
proc = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
conn = tasks._open_conn(root)
tasks._insert(conn, "still-going-restart", harness.KIND, {"root": root}, "turn-live")
ext_id = harness._encode_external_job_id("still-going-restart", proc.pid)
tasks._transition(conn, "still-going-restart", tasks.STATE_STARTED, external_job_id=ext_id)
conn.close()

q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=tasks.run_worker, args=(q, stop),
                      kwargs={"resolvers": {harness.KIND: harness.resolve_harness_job},
                              "poll_timeout": 0.05, "repos_getter": lambda: [("jarvis", root)],
                              "live_reconcile_interval": 0.2})
t.start()

# The one-time STARTUP sweep runs first and must leave the row genuinely
# in_progress (state unchanged) -- non-empty control proving the sweep
# actually ran and correctly did NOT orphan a genuinely-live job.
time.sleep(0.4)
rows = {r["id"]: r for r in tasks.list_tasks(root)}
print("AFTER_STARTUP_STATE", rows["still-going-restart"]["state"])

try:
    # NOW the "genuinely live" child actually finishes -- killed here and
    # its completion marker written from OUTSIDE this worker, exactly the
    # way run_harness_job itself would at the end of a real run. Nothing
    # re-enqueues anything (never resubmitted) -- only the PERIODIC
    # re-check (not the one-time startup sweep, which already ran) can
    # ever notice this and move the row.
    proc.kill()
    proc.wait(timeout=5)
    harness._write_marker(root, "still-going-restart", {"state": "completed", "result": {"ok": True}})

    deadline = time.monotonic() + 5.0
    final_row = {}
    while time.monotonic() < deadline:
        rows = {r["id"]: r for r in tasks.list_tasks(root)}
        row = rows.get("still-going-restart")
        if row and row["state"] == "completed":
            final_row = row
            break
        time.sleep(0.1)
finally:
    stop.set()
    t.join(timeout=3)

print("FINAL_STATE", final_row.get("state"))
print("ARTIFACT_PATH", final_row.get("artifact_path"))
PY
)"
check "live reconciliation: the startup sweep leaves a genuinely-live job in_progress (state unchanged)" \
    "AFTER_STARTUP_STATE started" "$out"
check "live reconciliation: the PERIODIC re-check later finds the completion and transitions the row" \
    "FINAL_STATE completed" "$out"
check "live reconciliation: artifact_path is rebuilt from the task id (same BLOCKER-fix path)" \
    "ARTIFACT_PATH still-going-restart.log" "$out"
rm -rf "$at_harness_live_root"

echo "-- unit: run_worker -- live_reconcile_interval OMITTED default / repos_getter absent -> no periodic re-check ever runs (opt-in, existing callers unaffected) --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import queue, tempfile, threading, time
from assistant import tasks

root = tempfile.mkdtemp(prefix="at-live-reconcile-noop-")
conn = tasks._open_conn(root)
tasks._insert(conn, "leftover3", "harness-job", {}, None)
tasks._transition(conn, "leftover3", tasks.STATE_STARTED, external_job_id="leftover3:1")
conn.close()

q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=tasks.run_worker, args=(q, stop), kwargs={"poll_timeout": 0.05})
t.start()
time.sleep(0.5)
stop.set()
t.join(timeout=3)

row = {r["id"]: r for r in tasks.list_tasks(root)}["leftover3"]
print("STATE_UNCHANGED", row["state"])
PY
)"
check "run_worker (no repos_getter): the periodic live re-check never runs either -- purely opt-in" \
    "STATE_UNCHANGED started" "$out"

echo "-- MINOR (a): a timeout still publishes the captured transcript BEFORE the workdir is wiped, not just at the end of a clean run --"
out="$(PATH="$AT_STUB_HARNESS:$PATH" HARNESS_STUB_MODE=hang HARNESS_STUB_HANG_SECONDS=30 HARNESS_STUB_OUTPUT="partial transcript before the kill" PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import queue, tempfile, threading, time
from assistant import tasks, harness

root = tempfile.mkdtemp(prefix="at-harness-timeout-publish-")
q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=tasks.run_worker, args=(q, stop),
                      kwargs={"executors": {harness.KIND: harness.run_harness_job}, "poll_timeout": 0.1})
t.start()
tid = harness.dispatch(q, root, provider="codex", model="m", prompt="p", timeout_seconds=1, poll_interval_seconds=0.1)

deadline = time.monotonic() + 10.0
row = {}
while time.monotonic() < deadline:
    rows = tasks.list_tasks(root)
    if rows and rows[0]["state"] == "failed":
        row = rows[0]
        break
    time.sleep(0.05)
stop.set()
t.join(timeout=5)

print("STATE", row.get("state"))
artifact_path = harness._artifact_rel_path(tid)
import os
on_disk = os.path.join(root, "").rstrip("/")
full_path = os.path.join(root, ".claude", "assistant", "artifacts", artifact_path)
print("PUBLISHED_TO_DISK", os.path.isfile(full_path))
if os.path.isfile(full_path):
    with open(full_path) as fh:
        content = fh.read()
    print("HAS_PARTIAL_TRANSCRIPT", "partial transcript before the kill" in content)
else:
    print("HAS_PARTIAL_TRANSCRIPT", False)
PY
)"
check "timeout publish: task still fails (unchanged behavior)" "STATE failed" "$out"
check "timeout publish: the captured transcript IS written to disk before the workdir is wiped (round-1 MINOR a)" \
    "PUBLISHED_TO_DISK True" "$out"
check "timeout publish: the transcript content is the partial output captured before the kill" \
    "HAS_PARTIAL_TRANSCRIPT True" "$out"

echo "-- MINOR (c): timeoutSeconds/pollIntervalSeconds are type/bounds-validated -- a bad value fails specifically, never spawns a subprocess, never crashes with a raw TypeError --"
out="$(PATH="$AT_STUB_HARNESS:$PATH" HARNESS_STUB_CALL_LOG="$(mktemp)" PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import os, tempfile
from assistant import harness

root = tempfile.mkdtemp(prefix="at-harness-badtimeout-")

def report_progress(payload=None, external_job_id=None):
    raise AssertionError("must never be called -- validation must precede any spawn")
report_progress.task_id = "would-be-task"

cases = [
    ("not-a-number", {"root": root, "provider": "codex", "model": "m", "prompt": "p", "timeoutSeconds": "soon"}),
    ("negative", {"root": root, "provider": "codex", "model": "m", "prompt": "p", "timeoutSeconds": -5}),
    ("too-large", {"root": root, "provider": "codex", "model": "m", "prompt": "p", "timeoutSeconds": 999999}),
    ("bool-not-number", {"root": root, "provider": "codex", "model": "m", "prompt": "p", "timeoutSeconds": True}),
    ("poll-exceeds-timeout", {"root": root, "provider": "codex", "model": "m", "prompt": "p",
                               "timeoutSeconds": 5, "pollIntervalSeconds": 50}),
]
results = {}
for name, payload in cases:
    try:
        harness.run_harness_job(payload, report_progress)
        results[name] = "NO_ERROR_RAISED"
    except harness.HarnessJobError as exc:
        results[name] = "HarnessJobError: " + str(exc)
    except Exception as exc:
        results[name] = "WRONG_EXCEPTION: " + type(exc).__name__

for name, outcome in results.items():
    print(name.upper(), outcome)

call_log = os.environ.get("HARNESS_STUB_CALL_LOG")
calls = 0
if call_log and os.path.exists(call_log):
    with open(call_log) as fh:
        calls = sum(1 for _ in fh)
print("NEVER_SPAWNED_ANYTHING", calls == 0)
PY
)"
check "bad timeoutSeconds (non-number): raises HarnessJobError, never a raw exception" "NOT-A-NUMBER HarnessJobError" "$out"
check "bad timeoutSeconds (negative): raises HarnessJobError" "NEGATIVE HarnessJobError" "$out"
check "bad timeoutSeconds (over the max bound): raises HarnessJobError" "TOO-LARGE HarnessJobError" "$out"
check "bad timeoutSeconds (bool, not a real number -- bool-before-int-guard): raises HarnessJobError" "BOOL-NOT-NUMBER HarnessJobError" "$out"
check "pollIntervalSeconds exceeding timeoutSeconds: raises HarnessJobError" "POLL-EXCEEDS-TIMEOUT HarnessJobError" "$out"
check "bad timeout/poll values: validation precedes any spawn -- the stub CLI is never invoked" \
    "NEVER_SPAWNED_ANYTHING True" "$out"

echo "-- MINOR (d): _decode_external_job_id rejects a path-traversal-shaped task id and a non-positive pid, never used to build an on-disk path --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import harness

cases = [
    ("traversal_task_id", "../../etc/passwd:1234"),
    ("slash_task_id", "some/nested/path:1234"),
    ("pid_zero", "task-abc:0"),
    ("pid_negative", "task-abc:-5"),
    ("pid_not_numeric", "task-abc:not-a-pid"),
    ("no_colon", "task-abc-no-colon"),
]
for name, ext_id in cases:
    try:
        harness._decode_external_job_id(ext_id)
        print(name.upper(), "NO_ERROR_RAISED")
    except ValueError:
        print(name.upper(), "VALUE_ERROR")

# resolve_harness_job must degrade cleanly (not_found), never raise, for
# every one of these -- a resolver must never trust its input.
for name, ext_id in cases:
    outcome = harness.resolve_harness_job(ext_id, {"root": "/tmp/does-not-matter"})
    print(name.upper() + "_RESOLVE_STATE", outcome.get("state"))

# a VALID id still round-trips normally.
task_id, pid = harness._decode_external_job_id("task_ABC-123:4567")
print("VALID_TASK_ID", task_id)
print("VALID_PID", pid)
PY
)"
check "decode: rejects a traversal-shaped task id" "TRAVERSAL_TASK_ID VALUE_ERROR" "$out"
check "decode: rejects a slash-containing task id" "SLASH_TASK_ID VALUE_ERROR" "$out"
check "decode: rejects pid=0 (meaningless/dangerous with os.kill)" "PID_ZERO VALUE_ERROR" "$out"
check "decode: rejects a negative pid" "PID_NEGATIVE VALUE_ERROR" "$out"
check "decode: rejects a non-numeric pid" "PID_NOT_NUMERIC VALUE_ERROR" "$out"
check "decode: rejects an id with no colon separator at all" "NO_COLON VALUE_ERROR" "$out"
check "resolve_harness_job never raises for any of these -- degrades to not_found" \
    "TRAVERSAL_TASK_ID_RESOLVE_STATE not_found" "$out"
check "resolve_harness_job (slash task id): not_found, never touches the filesystem with it" \
    "SLASH_TASK_ID_RESOLVE_STATE not_found" "$out"
check "resolve_harness_job (pid=0): not_found" "PID_ZERO_RESOLVE_STATE not_found" "$out"
check "decode: a well-formed id still round-trips its task id" "VALID_TASK_ID task_ABC-123" "$out"
check "decode: a well-formed id still round-trips its pid" "VALID_PID 4567" "$out"

echo "-- MINOR (e): progress events carry an honest, timeout-derived pct so a progress ring has something to render --"
at_pct_argv="$(mktemp)"
out="$(PATH="$AT_STUB_HARNESS:$PATH" PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import queue, tempfile, threading, time
from assistant import tasks, harness

root = tempfile.mkdtemp(prefix="at-harness-pct-")
q = queue.Queue()
traces_q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=tasks.run_worker, args=(q, stop),
                      kwargs={"executors": {harness.KIND: harness.run_harness_job},
                              "poll_timeout": 0.1, "traces_queue": traces_q})
t.start()
harness.dispatch(q, root, provider="codex", model="m", prompt="p", poll_interval_seconds=0.05)

deadline = time.monotonic() + 10.0
while time.monotonic() < deadline:
    rows = tasks.list_tasks(root)
    if rows and rows[0]["state"] in ("completed", "failed"):
        break
    time.sleep(0.05)
stop.set()
t.join(timeout=3)

pct_values = []
while True:
    try:
        item = traces_q.get_nowait()
    except queue.Empty:
        break
    ev = item["event"]
    if ev["kind"] == "task.progress":
        progress = (ev.get("payload") or {}).get("progress") or {}
        if "pct" in progress:
            pct_values.append(progress["pct"])
print("SAW_PCT_VALUES", len(pct_values) > 0)
print("ALL_PCT_ARE_NUMBERS", all(isinstance(v, (int, float)) for v in pct_values))
print("ALL_PCT_IN_RANGE", all(0 <= v <= 100 for v in pct_values))
PY
)"
check "progress pct: at least one progress event carries a pct field" "SAW_PCT_VALUES True" "$out"
check "progress pct: every pct value is numeric" "ALL_PCT_ARE_NUMBERS True" "$out"
check "progress pct: every pct value is in the sane 0-100 range" "ALL_PCT_IN_RANGE True" "$out"
rm -f "$at_pct_argv"

# ==========================================================================
# BUG #497 (AST-067's retro-review): repos_getter() yields EVERY
# .neural-network-anchored repo, not just assistant candidates -- but both
# reconciliation sweeps (`_reconcile_all`/startup and
# `_reconcile_live_all`/periodic, via `run_worker`) call `_open_conn(root)`
# unconditionally for every root repos_getter() hands them, and `_open_conn`
# `os.makedirs`s `.claude/assistant/` and CREATEs `tasks.sqlite` as a side
# effect -- even for a non-assistant repo, and even for an assistant
# candidate that has never had a task queued (no tasks.sqlite yet, nothing
# to reconcile). capability_index.run_worker already solved this exact
# problem (filters with discovery.classify_repo(root), skips non-
# candidates) -- both sweeps here must do the same, PLUS skip a candidate
# with no tasks.sqlite on disk yet (nothing to reconcile -- opening one
# would itself be the bug).
# ==========================================================================
echo "-- BUG #497: startup sweep must not create .claude/assistant/tasks.sqlite for a non-assistant anchored repo --"
at497_a="$(mktemp -d)"
at_marker_only "$at497_a"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - "$at497_a" <<'PY'
import os, queue, sys, threading, time
from assistant import tasks

root = sys.argv[1]

q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=tasks.run_worker, args=(q, stop),
                      kwargs={"poll_timeout": 0.05, "repos_getter": lambda: [("not-jarvis", root)],
                              "live_reconcile_interval": 0.15})
t.start()

time.sleep(0.05)  # the one-time startup sweep has already run by now
print("STARTUP_DIR_EXISTS", os.path.isdir(os.path.join(root, ".claude", "assistant")))

time.sleep(0.6)  # several periodic live-reconcile ticks have had a chance to run
print("LIVE_DIR_EXISTS", os.path.isdir(os.path.join(root, ".claude", "assistant")))

stop.set()
t.join(timeout=3)
print("WORKER_JOINED", not t.is_alive())
PY
)"
check "#497 non-assistant repo: startup sweep creates no .claude/assistant dir" "STARTUP_DIR_EXISTS False" "$out"
check "#497 non-assistant repo: periodic live pass creates no .claude/assistant dir either" "LIVE_DIR_EXISTS False" "$out"
check "#497 non-assistant repo: worker still joins cleanly" "WORKER_JOINED True" "$out"
rm -rf "$at497_a"

echo "-- BUG #497: sweeps must not create tasks.sqlite for an assistant CANDIDATE that has no existing db (nothing to reconcile) --"
at497_b="$(mktemp -d)"
at_repo "$at497_b" jarvis
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - "$at497_b" <<'PY'
import os, queue, sys, threading, time
from assistant import tasks

root = sys.argv[1]
db_path = os.path.join(root, ".claude", "assistant", "tasks.sqlite")

q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=tasks.run_worker, args=(q, stop),
                      kwargs={"poll_timeout": 0.05, "repos_getter": lambda: [("jarvis", root)],
                              "live_reconcile_interval": 0.15})
t.start()

time.sleep(0.05)
print("STARTUP_DB_EXISTS", os.path.exists(db_path))

time.sleep(0.6)
print("LIVE_DB_EXISTS", os.path.exists(db_path))

stop.set()
t.join(timeout=3)
print("WORKER_JOINED", not t.is_alive())
PY
)"
check "#497 fresh candidate (no db yet): startup sweep alone creates no tasks.sqlite" "STARTUP_DB_EXISTS False" "$out"
check "#497 fresh candidate (no db yet): periodic live pass alone creates no tasks.sqlite either" "LIVE_DB_EXISTS False" "$out"
check "#497 fresh candidate (no db yet): worker still joins cleanly" "WORKER_JOINED True" "$out"
rm -rf "$at497_b"

echo "-- BUG #497 regression control: an assistant candidate WITH an existing db is still reconciled by the startup sweep, exactly as before --"
at497_c="$(mktemp -d)"
at_repo "$at497_c" jarvis
PYTHONPATH="$AT_SCRIPTS" python3 - "$at497_c" <<'PY'
import sys
from assistant import tasks

root = sys.argv[1]
conn = tasks._open_conn(root)
tasks._insert(conn, "leftover-497c", "harness", {}, None)
tasks._transition(conn, "leftover-497c", tasks.STATE_STARTED)  # no external_job_id -> unreconcilable
conn.close()
PY
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - "$at497_c" <<'PY'
import queue, sys, threading, time
from assistant import tasks

root = sys.argv[1]

q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=tasks.run_worker, args=(q, stop),
                      kwargs={"poll_timeout": 0.1, "repos_getter": lambda: [("jarvis", root)]})
t.start()

deadline = time.monotonic() + 5.0
row = {}
while time.monotonic() < deadline:
    rows = {r["id"]: r for r in tasks.list_tasks(root)}
    row = rows.get("leftover-497c", {})
    if row.get("state") == "orphaned":
        break
    time.sleep(0.1)
stop.set()
t.join(timeout=3)

print("RECONCILED_STATE", row.get("state"))
PY
)"
check "#497 regression (startup): an existing-db candidate's leftover row is still reconciled -> orphaned" \
    "RECONCILED_STATE orphaned" "$out"
rm -rf "$at497_c"

echo "-- BUG #497 regression control: an assistant candidate WITH an existing db is still visited by the PERIODIC live reconciliation pass, exactly as before --"
at497_d="$(mktemp -d)"
at_repo "$at497_d" jarvis
PYTHONPATH="$AT_SCRIPTS" python3 - "$at497_d" <<'PY'
import sys
from assistant import tasks

root = sys.argv[1]
conn = tasks._open_conn(root)
tasks._insert(conn, "live-497d", "harness", {}, None)
tasks._transition(conn, "live-497d", tasks.STATE_STARTED, external_job_id="job-497d")
conn.close()
PY
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - "$at497_d" <<'PY'
import queue, sys, threading, time
from assistant import tasks

root = sys.argv[1]

def still_running_resolver(external_job_id, payload):
    return {"state": "in_progress"}

traces_q = queue.Queue()
q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=tasks.run_worker, args=(q, stop),
                      kwargs={"resolvers": {"harness": still_running_resolver},
                              "poll_timeout": 0.05, "repos_getter": lambda: [("jarvis", root)],
                              "live_reconcile_interval": 0.15, "traces_queue": traces_q})
t.start()
time.sleep(0.6)  # let the startup sweep AND at least one periodic tick run
stop.set()
t.join(timeout=3)

saw_reconcile_checked = False
while True:
    try:
        item = traces_q.get_nowait()
    except queue.Empty:
        break
    ev = item["event"]
    payload = ev.get("payload") or {}
    if ev["kind"] == "task.reconcile_checked" and payload.get("task_id") == "live-497d":
        saw_reconcile_checked = True

print("SAW_RECONCILE_CHECKED", saw_reconcile_checked)
PY
)"
check "#497 regression (periodic): an existing-db candidate's live row is still visited by the periodic pass" \
    "SAW_RECONCILE_CHECKED True" "$out"
rm -rf "$at497_d"

echo "-- BUG #497 round-1 review MINOR-1: a DISABLED (de-candidated) root with an EXISTING tasks.sqlite is skipped by both sweeps -- classify_repo is the single source of truth, not 'does a db already exist' --"
at497_e="$(mktemp -d)"
at_repo_disabled "$at497_e" jarvis
PYTHONPATH="$AT_SCRIPTS" python3 - "$at497_e" <<'PY'
import sys
from assistant import tasks

root = sys.argv[1]
conn = tasks._open_conn(root)
tasks._insert(conn, "leftover-497e", "harness", {}, None)
tasks._transition(conn, "leftover-497e", tasks.STATE_STARTED)  # no external_job_id
conn.close()
conn2 = tasks._open_conn(root)
tasks._insert(conn2, "live-497e", "harness", {}, None)
tasks._transition(conn2, "live-497e", tasks.STATE_STARTED, external_job_id="job-497e")
conn2.close()
PY
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - "$at497_e" <<'PY'
import queue, sys, threading, time
from assistant import tasks

root = sys.argv[1]

def completed_resolver(external_job_id, payload):
    # a resolver that WOULD flip the row to completed if this root got
    # reconciled at all -- state staying "started" is the only honest
    # signal that the root (both leftover-497e, the no-external-job-id
    # startup-path row, and live-497e, the external_job_id row) was truly
    # skipped, since an in_progress response would be a state-invariant
    # no-op either way and could not distinguish skipped from reconciled.
    return {"state": "completed", "result": {"ok": True}}

q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=tasks.run_worker, args=(q, stop),
                      kwargs={"resolvers": {"harness": completed_resolver},
                              "poll_timeout": 0.05, "repos_getter": lambda: [("jarvis", root)],
                              "live_reconcile_interval": 0.15})
t.start()
time.sleep(0.6)  # startup sweep AND at least one periodic tick have had a chance to run
stop.set()
t.join(timeout=3)

rows = {r["id"]: r for r in tasks.list_tasks(root)}
print("STARTUP_ROW_STATE", rows.get("leftover-497e", {}).get("state"))
print("LIVE_ROW_STATE", rows.get("live-497e", {}).get("state"))
PY
)"
check "#497 MINOR-1: a disabled root's queued-startup-candidate row is left completely untouched, not orphaned" \
    "STARTUP_ROW_STATE started" "$out"
check "#497 MINOR-1: a disabled root's live-reconcile-candidate row is left completely untouched, not re-checked" \
    "LIVE_ROW_STATE started" "$out"
rm -rf "$at497_e"

# ==========================================================================
# #498 (AST-067's retro-review F2): reconciliation assumed it was the only
# live engine for a root. On this machine multiple neural-view engines
# routinely run with scan bases covering the same repos -- a second engine's
# startup sweep or periodic live pass would orphan rows a FIRST engine is
# actively working. Fix: a per-root owner heartbeat (`task_owner`, one row,
# inside the SAME tasks.sqlite -- no new files) that the worker claims/
# refreshes only when it actually DRAINS a root (never merely by scanning
# it for reconciliation); both sweeps skip a root whose owner heartbeat is
# foreign AND fresh (bounded staleness window, engine_id/owner_stale_seconds
# below are the new run_worker kwargs this task adds). A stale or self-owned
# or absent heartbeat falls through to today's behavior -- every #497 test
# above creates no task_owner row at all, so this must regress none of them.
# ==========================================================================
echo "== assistant tasks ownership (#498: heartbeat-guarded reconciliation, AST-067 retro-review F2) =="

echo "-- #498: a fresh FOREIGN engine heartbeat is skipped by the STARTUP sweep (never orphans another engine's live root) --"
at498_a="$(mktemp -d)"
at_repo "$at498_a" jarvis
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - "$at498_a" <<'PY'
import queue, sys, threading, time
from assistant import tasks

root = sys.argv[1]
conn = tasks._open_conn(root)
tasks._claim_ownership(conn, "engine-foreign")
tasks._insert(conn, "leftover-498a", "harness", {}, None)
tasks._transition(conn, "leftover-498a", tasks.STATE_STARTED)  # no external_job_id -> would normally orphan
conn.close()

q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=tasks.run_worker, args=(q, stop),
                      kwargs={"poll_timeout": 0.05, "repos_getter": lambda: [("jarvis", root)],
                              "engine_id": "engine-self"})
t.start()
time.sleep(0.3)  # the one-time startup sweep has already run by now
stop.set()
t.join(timeout=3)

rows = {r["id"]: r for r in tasks.list_tasks(root)}
print("ROW_STATE", rows.get("leftover-498a", {}).get("state"))
print("WORKER_JOINED", not t.is_alive())
PY
)"
check "#498 startup sweep: a foreign engine's fresh-heartbeat root is left completely untouched, not orphaned" \
    "ROW_STATE started" "$out"
check "#498 startup sweep: worker still joins cleanly" "WORKER_JOINED True" "$out"
rm -rf "$at498_a"

echo "-- #498: a fresh FOREIGN engine heartbeat is skipped by the PERIODIC live sweep too --"
at498_b="$(mktemp -d)"
at_repo "$at498_b" jarvis
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - "$at498_b" <<'PY'
import queue, sys, threading, time
from assistant import tasks

root = sys.argv[1]
conn = tasks._open_conn(root)
tasks._claim_ownership(conn, "engine-foreign")
conn.close()

def completed_resolver(external_job_id, payload):
    # would flip the row to completed if this root got reconciled at all --
    # only a periodic pass incorrectly ignoring ownership could do that,
    # since the row below is inserted AFTER the one-time startup sweep runs.
    return {"state": "completed", "result": {"ok": True}}

q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=tasks.run_worker, args=(q, stop),
                      kwargs={"resolvers": {"harness": completed_resolver},
                              "poll_timeout": 0.05, "repos_getter": lambda: [("jarvis", root)],
                              "live_reconcile_interval": 0.15, "engine_id": "engine-self",
                              # a real foreign engine would keep refreshing its own
                              # heartbeat; this test stamps it once and never again,
                              # so owner_stale_seconds must outlast the whole test's
                              # wall-clock window (independent of the SHORT tick
                              # interval used above to drive this engine's own cadence).
                              "owner_stale_seconds": 60})
t.start()
time.sleep(0.3)  # let the startup sweep finish -- nothing to reconcile yet

conn2 = tasks._open_conn(root)
tasks._insert(conn2, "live-498b", "harness", {}, None)
tasks._transition(conn2, "live-498b", tasks.STATE_STARTED, external_job_id="job-498b")
conn2.close()

time.sleep(0.6)  # several periodic ticks have had a chance to run
stop.set()
t.join(timeout=3)

rows = {r["id"]: r for r in tasks.list_tasks(root)}
print("ROW_STATE", rows.get("live-498b", {}).get("state"))
PY
)"
check "#498 periodic sweep: a foreign engine's fresh-heartbeat root is left completely untouched, not reconciled" \
    "ROW_STATE started" "$out"
rm -rf "$at498_b"

echo "-- #498: a heartbeat owned by THIS SAME engine id never blocks its own reconciliation --"
at498_c="$(mktemp -d)"
at_repo "$at498_c" jarvis
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - "$at498_c" <<'PY'
import queue, sys, threading, time
from assistant import tasks

root = sys.argv[1]
conn = tasks._open_conn(root)
tasks._claim_ownership(conn, "engine-self")
tasks._insert(conn, "leftover-498c", "harness", {}, None)
tasks._transition(conn, "leftover-498c", tasks.STATE_STARTED)  # no external_job_id -> unreconcilable
conn.close()

q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=tasks.run_worker, args=(q, stop),
                      kwargs={"poll_timeout": 0.1, "repos_getter": lambda: [("jarvis", root)],
                              "engine_id": "engine-self"})
t.start()

deadline = time.monotonic() + 5.0
row = {}
while time.monotonic() < deadline:
    rows = {r["id"]: r for r in tasks.list_tasks(root)}
    row = rows.get("leftover-498c", {})
    if row.get("state") == "orphaned":
        break
    time.sleep(0.1)
stop.set()
t.join(timeout=3)

print("ROW_STATE", row.get("state"))
PY
)"
check "#498 self-ownership: the SAME engine id's own root still reconciles normally -> orphaned" \
    "ROW_STATE orphaned" "$out"
rm -rf "$at498_c"

echo "-- #498: a STALE foreign heartbeat (crashed owner) falls through to normal reconciliation -- crash recovery preserved --"
at498_d="$(mktemp -d)"
at_repo "$at498_d" jarvis
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - "$at498_d" <<'PY'
import queue, sqlite3, sys, threading, time
from datetime import datetime, timedelta, timezone
from assistant import tasks

root = sys.argv[1]
conn = tasks._open_conn(root)
stale_heartbeat = (datetime.now(timezone.utc) - timedelta(seconds=1000)).isoformat()
conn.execute(
    "INSERT INTO task_owner (id, engine_id, pid, host, heartbeat_at) VALUES (1, ?, ?, ?, ?)",
    ("engine-crashed", 999999, "some-other-host", stale_heartbeat),
)
tasks._insert(conn, "leftover-498d", "harness", {}, None)
tasks._transition(conn, "leftover-498d", tasks.STATE_STARTED)  # no external_job_id -> unreconcilable
conn.close()

q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=tasks.run_worker, args=(q, stop),
                      kwargs={"poll_timeout": 0.1, "repos_getter": lambda: [("jarvis", root)],
                              "engine_id": "engine-self", "owner_stale_seconds": 5})
t.start()

deadline = time.monotonic() + 5.0
row = {}
while time.monotonic() < deadline:
    rows = {r["id"]: r for r in tasks.list_tasks(root)}
    row = rows.get("leftover-498d", {})
    if row.get("state") == "orphaned":
        break
    time.sleep(0.1)
stop.set()
t.join(timeout=3)

print("ROW_STATE", row.get("state"))
PY
)"
check "#498 stale heartbeat: a long-dead owner's root falls through to normal reconciliation -> orphaned (never wedged forever)" \
    "ROW_STATE orphaned" "$out"
rm -rf "$at498_d"

echo "-- #498: heartbeat refresh happens on DRAIN -- claiming a root writes engine_id/pid/host/heartbeat_at --"
at498_e="$(mktemp -d)"
at_repo "$at498_e" jarvis
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - "$at498_e" <<'PY'
import os, queue, socket, sqlite3, sys, threading, time
from datetime import datetime, timezone
from assistant import tasks

root = sys.argv[1]

def echo_executor(payload, report_progress):
    return {"result": "ok"}

q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=tasks.run_worker, args=(q, stop),
                      kwargs={"executors": {"echo": echo_executor}, "poll_timeout": 0.1,
                              "engine_id": "engine-drain-test"})
t.start()
tasks.enqueue(q, root, "echo", {})

deadline = time.monotonic() + 5.0
rows = []
while time.monotonic() < deadline:
    rows = tasks.list_tasks(root)
    if rows and rows[0]["state"] == "completed":
        break
    time.sleep(0.1)

# Read the owner row WHILE the worker is still alive -- round-1 review
# advisory (b) makes a graceful shutdown DELETE it (tested separately,
# below), so reading only after stop.set()/join() would no longer prove
# the claim ever happened.
conn = sqlite3.connect(tasks._db_path(root))
owner_row = conn.execute("SELECT engine_id, pid, host, heartbeat_at FROM task_owner WHERE id = 1").fetchone()
conn.close()

print("OWNER_ROW_EXISTS", owner_row is not None)
if owner_row:
    engine_id, pid, host, heartbeat_at = owner_row
    print("ENGINE_ID", engine_id)
    print("PID_MATCHES_THIS_PROCESS", pid == os.getpid())
    print("HOST_MATCHES", host == socket.gethostname())
    age = (datetime.now(timezone.utc) - datetime.fromisoformat(heartbeat_at)).total_seconds()
    print("HEARTBEAT_RECENT", age < 10)

stop.set()
t.join(timeout=3)

# advisory (b): a graceful shutdown releases ownership immediately.
conn2 = sqlite3.connect(tasks._db_path(root))
owner_row_after_stop = conn2.execute("SELECT 1 FROM task_owner WHERE id = 1").fetchone()
conn2.close()
print("OWNER_ROW_GONE_AFTER_GRACEFUL_STOP", owner_row_after_stop is None)
PY
)"
check "#498 drain claims ownership: a task_owner row exists after draining one item" "OWNER_ROW_EXISTS True" "$out"
check "#498 drain claims ownership: engine_id matches the draining worker's id" "ENGINE_ID engine-drain-test" "$out"
check "#498 drain claims ownership: pid is this (thread's) process pid" "PID_MATCHES_THIS_PROCESS True" "$out"
check "#498 drain claims ownership: host is this machine's hostname" "HOST_MATCHES True" "$out"
check "#498 drain claims ownership: heartbeat_at is recent" "HEARTBEAT_RECENT True" "$out"
check "#498 round-1 review advisory (b): a graceful stop() deletes this engine's owner row (instant handoff, never wait out the staleness window)" \
    "OWNER_ROW_GONE_AFTER_GRACEFUL_STOP True" "$out"
rm -rf "$at498_e"

echo "-- #498 round-1 review advisory (a): an engine that drained a root but has NOTHING in-flight for it anymore stops refreshing its heartbeat (must not block every other engine's reconciliation of that root forever just by staying alive) --"
at498_f="$(mktemp -d)"
at_repo "$at498_f" jarvis
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - "$at498_f" <<'PY'
import queue, sqlite3, sys, threading, time
from assistant import tasks

root = sys.argv[1]

def echo_executor(payload, report_progress):
    return {"result": "ok"}

q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=tasks.run_worker, args=(q, stop),
                      kwargs={"executors": {"echo": echo_executor}, "poll_timeout": 0.05,
                              "repos_getter": lambda: [("jarvis", root)],
                              "live_reconcile_interval": 0.15, "engine_id": "engine-tick-test"})
t.start()
tasks.enqueue(q, root, "echo", {})

deadline = time.monotonic() + 5.0
rows = []
while time.monotonic() < deadline:
    rows = tasks.list_tasks(root)
    if rows and rows[0]["state"] == "completed":
        break
    time.sleep(0.05)

def read_heartbeat():
    conn = sqlite3.connect(tasks._db_path(root))
    row = conn.execute("SELECT heartbeat_at FROM task_owner WHERE id = 1").fetchone()
    conn.close()
    return row[0] if row else None

# The one and only task for this root has already completed by now -- no
# in-flight rows remain, so _maybe_prune_owned_root should have dropped
# this root from `owned` the moment it finished.
heartbeat_after_drain = read_heartbeat()
time.sleep(0.6)  # several idle periodic ticks AND heartbeat-timer wakes have had a chance to run
heartbeat_after_ticks = read_heartbeat()

stop.set()
t.join(timeout=3)

print("HEARTBEAT_AFTER_DRAIN", heartbeat_after_drain)
print("HEARTBEAT_NEVER_ADVANCED_AFTER_IDLE", heartbeat_after_ticks == heartbeat_after_drain)
PY
)"
check "#498 advisory (a): once the root has nothing in-flight, its heartbeat stops advancing -- ownership is pruned, not held forever" \
    "HEARTBEAT_NEVER_ADVANCED_AFTER_IDLE True" "$out"
rm -rf "$at498_f"

echo "-- #498: ownership READ failure (locked/corrupt) skips the root this pass -- never orphans blind, always traced --"
at498_g="$(mktemp -d)"
at_repo "$at498_g" jarvis
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - "$at498_g" <<'PY'
import queue, sys, threading, time
from unittest import mock
from assistant import tasks

root = sys.argv[1]
conn = tasks._open_conn(root)
tasks._insert(conn, "leftover-498g", "harness", {}, None)
tasks._transition(conn, "leftover-498g", tasks.STATE_STARTED)  # no external_job_id -> would normally orphan
conn.close()

traces_q = queue.Queue()
q = queue.Queue()
stop = threading.Event()
with mock.patch.object(tasks, "_read_owner", side_effect=RuntimeError("database is locked")):
    t = threading.Thread(target=tasks.run_worker, args=(q, stop),
                          kwargs={"poll_timeout": 0.05, "repos_getter": lambda: [("jarvis", root)],
                                  "engine_id": "engine-self", "traces_queue": traces_q})
    t.start()
    time.sleep(0.3)  # the one-time startup sweep has already run by now
    stop.set()
    t.join(timeout=3)

rows = {r["id"]: r for r in tasks.list_tasks(root)}
print("ROW_STATE", rows.get("leftover-498g", {}).get("state"))

saw_failure_trace = False
while True:
    try:
        item = traces_q.get_nowait()
    except queue.Empty:
        break
    ev = item["event"]
    if ev["kind"] == "task.ownership_check_failed":
        payload = ev.get("payload") or {}
        if "database is locked" in str(payload.get("error", "")):
            saw_failure_trace = True
print("SAW_FAILURE_TRACE", saw_failure_trace)
PY
)"
check "#498 ownership read failure: the root is skipped this pass, never orphaned blind" "ROW_STATE started" "$out"
check "#498 ownership read failure: a trace-level note is emitted with the error text" "SAW_FAILURE_TRACE True" "$out"
rm -rf "$at498_g"

# #497's own scoping (candidates-with-a-db only) is regression-guarded by
# every #497 test above continuing to pass unchanged: none of them ever
# create a task_owner row, so absent-owner must keep behaving exactly like
# "no live foreign owner" -- proceed with reconciliation, same as before
# this task existed.

# ==========================================================================
# #498 round-1 review: two CONFIRMED majors (heartbeat freezes for an
# executor's entire duration; the one-time startup sweep can wedge a root
# forever on a fast restart) plus two minors (a naive timestamp escapes
# fail-open as an untraced fail-closed; a failed claim can poison the
# connection for the next _insert) plus advisories (idle-owner pruning,
# instant shutdown handoff -- both already tested above inline; a normal
# ownership skip was previously untraced).
# ==========================================================================
echo "== assistant tasks ownership round-1 review (#498) =="

echo "-- #498 round-1 review MAJOR-1: an executor that OUTLIVES the staleness window -- a foreign engine's sweep must skip the whole time, never just at the start --"
at498r1_a="$(mktemp -d)"
at_repo "$at498r1_a" jarvis
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - "$at498r1_a" <<'PY'
import queue, sys, threading, time
from assistant import tasks

root = sys.argv[1]

def slow_executor(payload, report_progress):
    report_progress(external_job_id="ext-major1")  # makes this row live-reconcile-visible
    time.sleep(1.0)  # >> owner_stale_seconds (0.3s) -- the whole point of this test
    return {"result": "done-by-A"}

def hostile_resolver(external_job_id, payload):
    # a resolver B would NEVER legitimately see run for a row A still owns
    # -- a distinctive, un-mistakable outcome if ownership gating fails.
    return {"state": "failed", "error": "WRONGLY-RECONCILED-BY-FOREIGN-ENGINE-B"}

q_a = queue.Queue()
stop_a = threading.Event()
engine_a = threading.Thread(target=tasks.run_worker, args=(q_a, stop_a),
                             kwargs={"executors": {"slow": slow_executor}, "poll_timeout": 0.05,
                                     "repos_getter": lambda: [("jarvis", root)],
                                     "live_reconcile_interval": 0.1, "owner_stale_seconds": 0.3,
                                     "engine_id": "engine-A"})
engine_a.start()
tasks.enqueue(q_a, root, "slow", {})
time.sleep(0.2)  # let A claim ownership and enter the slow executor call

q_b = queue.Queue()
stop_b = threading.Event()
engine_b = threading.Thread(target=tasks.run_worker, args=(q_b, stop_b),
                             kwargs={"resolvers": {"slow": hostile_resolver}, "poll_timeout": 0.05,
                                     "repos_getter": lambda: [("jarvis", root)],
                                     "live_reconcile_interval": 0.1, "owner_stale_seconds": 0.3,
                                     "engine_id": "engine-B"})
engine_b.start()

samples = []
deadline = time.monotonic() + 1.3  # spans the whole 1.0s executor sleep, well past 0.3s staleness window
while time.monotonic() < deadline:
    rows = tasks.list_tasks(root)
    samples.append(rows[0]["state"] if rows else None)
    time.sleep(0.1)

stop_a.set()
stop_b.set()
engine_a.join(timeout=3)
engine_b.join(timeout=3)

final_rows = tasks.list_tasks(root)
print("EVER_WRONGLY_RECONCILED", "failed" in samples)
print("FINAL_STATE", final_rows[0]["state"] if final_rows else None)
PY
)"
check "#498 MAJOR-1: engine B's sweep never touches A's row at ANY sampled point during the whole executor run" \
    "EVER_WRONGLY_RECONCILED False" "$out"
check "#498 MAJOR-1: the row completes normally via A's own flow once the executor returns" "FINAL_STATE completed" "$out"
rm -rf "$at498r1_a"

echo "-- #498 round-1 review MAJOR-1(b): the fallback for an executor that NEVER calls report_progress (e.g. #508's capability-invoke executor) -- a background timer keeps the heartbeat fresh regardless --"
at498r1_b="$(mktemp -d)"
at_repo "$at498r1_b" jarvis
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - "$at498r1_b" <<'PY'
import queue, sqlite3, sys, threading, time
from datetime import datetime, timezone
from assistant import tasks

root = sys.argv[1]

def silent_executor(payload, report_progress):
    time.sleep(0.8)  # never calls report_progress -- MUST rely on the timer thread alone
    return {"result": "done"}

q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=tasks.run_worker, args=(q, stop),
                      kwargs={"executors": {"silent": silent_executor}, "poll_timeout": 0.05,
                              "repos_getter": lambda: [("jarvis", root)],
                              "live_reconcile_interval": 0.1, "owner_stale_seconds": 0.3,
                              "engine_id": "engine-daemon-only"})
t.start()
tasks.enqueue(q, root, "silent", {})

def heartbeat_age():
    conn = sqlite3.connect(tasks._db_path(root))
    row = conn.execute("SELECT heartbeat_at FROM task_owner WHERE id = 1").fetchone()
    conn.close()
    if row is None:
        return None
    return (datetime.now(timezone.utc) - datetime.fromisoformat(row[0])).total_seconds()

time.sleep(0.15)  # let the drain claim ownership once
samples = []
deadline = time.monotonic() + 0.55  # sampled WHILE the 0.8s silent executor is still sleeping
while time.monotonic() < deadline:
    age = heartbeat_age()
    if age is not None:
        samples.append(age)
    time.sleep(0.1)

stop.set()
t.join(timeout=3)

print("ENOUGH_SAMPLES", len(samples) >= 3)
print("NEVER_WENT_STALE", all(age < 0.3 for age in samples))
PY
)"
check "#498 MAJOR-1(b): several heartbeat samples were taken during the silent executor's run" "ENOUGH_SAMPLES True" "$out"
check "#498 MAJOR-1(b): the heartbeat never once exceeded the staleness window, though report_progress was never called" \
    "NEVER_WENT_STALE True" "$out"
rm -rf "$at498r1_b"

echo "-- #498 round-2 review: report_progress-triggered refresh (MAJOR-1(a)) keeps the heartbeat fresh even with the background timer thread DISABLED -- proves that half of the fix independently, not merely alongside the timer --"
at498r1_h="$(mktemp -d)"
at_repo "$at498r1_h" jarvis
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - "$at498r1_h" <<'PY'
import queue, sqlite3, sys, threading, time
from datetime import datetime, timezone
from unittest import mock
from assistant import tasks

root = sys.argv[1]

def chatty_executor(payload, report_progress):
    # reports progress well inside window/OWNER_STALE_MULTIPLIER (~0.67s)
    # -- if this path were deleted, ONLY the (disabled, below) timer
    # thread could keep the heartbeat warm, and this test would fail.
    deadline = time.monotonic() + 2.5  # spans past the 2.0s staleness window
    while time.monotonic() < deadline:
        report_progress()
        time.sleep(0.3)
    return {"result": "done"}

def heartbeat_age():
    conn = sqlite3.connect(tasks._db_path(root))
    row = conn.execute("SELECT heartbeat_at FROM task_owner WHERE id = 1").fetchone()
    conn.close()
    if row is None:
        return None
    return (datetime.now(timezone.utc) - datetime.fromisoformat(row[0])).total_seconds()

q = queue.Queue()
stop = threading.Event()
# the background timer thread (MAJOR-1(b)) is a no-op here -- ONLY
# report_progress-triggered refresh (MAJOR-1(a)) can keep this root warm.
with mock.patch.object(tasks, "_run_heartbeat_timer", lambda *a, **kw: None):
    t = threading.Thread(target=tasks.run_worker, args=(q, stop),
                          kwargs={"executors": {"chatty": chatty_executor}, "poll_timeout": 0.05,
                                  "repos_getter": lambda: [("jarvis", root)],
                                  "live_reconcile_interval": 0.2, "owner_stale_seconds": 2.0,
                                  "engine_id": "engine-progress-only"})
    t.start()
    tasks.enqueue(q, root, "chatty", {})

    time.sleep(0.2)  # let the drain claim ownership once
    samples = []
    deadline = time.monotonic() + 2.2  # sampled WHILE the chatty executor is still running
    while time.monotonic() < deadline:
        age = heartbeat_age()
        if age is not None:
            samples.append(age)
        time.sleep(0.2)

    stop.set()
    t.join(timeout=5)

print("ENOUGH_SAMPLES", len(samples) >= 5)
print("NEVER_WENT_STALE", all(age < 2.0 for age in samples))
PY
)"
check "#498 round-2 review: report_progress refresh alone (timer disabled) -- enough samples were taken" \
    "ENOUGH_SAMPLES True" "$out"
check "#498 round-2 review: report_progress refresh alone (timer disabled) -- the heartbeat never once went stale" \
    "NEVER_WENT_STALE True" "$out"
rm -rf "$at498r1_h"

echo "-- #498 round-1 review MAJOR-2(a): a dead pid on THIS SAME host recovers INSTANTLY at the startup sweep, regardless of how fresh the heartbeat timestamp still looks --"
at498r1_c="$(mktemp -d)"
at_repo "$at498r1_c" jarvis
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - "$at498r1_c" <<'PY'
import queue, socket, subprocess, sys, threading, time
from datetime import datetime, timezone
from assistant import tasks

root = sys.argv[1]

# A genuinely dead pid on THIS host.
proc = subprocess.Popen([sys.executable, "-c", "pass"])
proc.wait()
dead_pid = proc.pid

conn = tasks._open_conn(root)
fresh_ts = datetime.now(timezone.utc).isoformat()  # deliberately FRESH by timestamp
conn.execute(
    "INSERT INTO task_owner (id, engine_id, pid, host, heartbeat_at) VALUES (1, ?, ?, ?, ?)",
    ("engine-dead-samehost", dead_pid, socket.gethostname(), fresh_ts),
)
tasks._insert(conn, "leftover-major2a", "harness", {}, None)
tasks._transition(conn, "leftover-major2a", tasks.STATE_STARTED)  # no external_job_id -- startup-class-only
conn.close()

q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=tasks.run_worker, args=(q, stop),
                      kwargs={"poll_timeout": 0.05, "repos_getter": lambda: [("jarvis", root)],
                              "engine_id": "engine-self",
                              # deliberately HUGE -- if recovery happens anyway, it cannot be
                              # timestamp-staleness explaining it, only the dead-pid check.
                              "owner_stale_seconds": 999})
t.start()
time.sleep(0.3)  # only the ONE-TIME startup sweep needs to have run
stop.set()
t.join(timeout=3)

rows = {r["id"]: r for r in tasks.list_tasks(root)}
print("ROW_STATE", rows.get("leftover-major2a", {}).get("state"))
PY
)"
check "#498 MAJOR-2(a): a same-host dead-pid owner is recovered from INSTANTLY, not after waiting out a (huge) staleness window" \
    "ROW_STATE orphaned" "$out"
rm -rf "$at498r1_c"

echo "-- #498 round-1 review MAJOR-2(b): a root the ONE-TIME startup sweep deferred for ownership must NOT wedge forever -- the periodic tick retries it, recovering BOTH startup-class-only row shapes once the foreign owner goes stale --"
at498r1_d="$(mktemp -d)"
at_repo "$at498r1_d" jarvis
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - "$at498r1_d" <<'PY'
import queue, sys, threading, time
from datetime import datetime, timezone
from assistant import tasks

root = sys.argv[1]

conn = tasks._open_conn(root)
fresh_ts = datetime.now(timezone.utc).isoformat()
conn.execute(
    "INSERT INTO task_owner (id, engine_id, pid, host, heartbeat_at) VALUES (1, ?, ?, ?, ?)",
    # a REMOTE host -- the MAJOR-2(a) same-host dead-pid shortcut must NOT
    # apply here; this test is specifically about the age-based retry path.
    ("engine-dead-remote", 424242, "some-other-host-not-this-machine", fresh_ts),
)
tasks._insert(conn, "queued-major2b", "harness", {}, None)  # left QUEUED -- only _reconcile_root ever touches this
tasks._insert(conn, "started-major2b", "harness", {}, None)
tasks._transition(conn, "started-major2b", tasks.STATE_STARTED)  # no external_job_id -- also startup-class-only
conn.close()

q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=tasks.run_worker, args=(q, stop),
                      kwargs={"poll_timeout": 0.05, "repos_getter": lambda: [("jarvis", root)],
                              "engine_id": "engine-self", "live_reconcile_interval": 0.1,
                              "owner_stale_seconds": 0.3})
t.start()

time.sleep(0.15)  # only the startup sweep has run -- the foreign heartbeat still looks fresh
rows = {r["id"]: r for r in tasks.list_tasks(root)}
print("AT_BOOT_QUEUED_STATE", rows.get("queued-major2b", {}).get("state"))
print("AT_BOOT_STARTED_STATE", rows.get("started-major2b", {}).get("state"))

deadline = time.monotonic() + 5.0
rows = {}
while time.monotonic() < deadline:
    rows = {r["id"]: r for r in tasks.list_tasks(root)}
    if (rows.get("queued-major2b", {}).get("state") == "orphaned"
            and rows.get("started-major2b", {}).get("state") == "orphaned"):
        break
    time.sleep(0.1)
stop.set()
t.join(timeout=3)

print("EVENTUAL_QUEUED_STATE", rows.get("queued-major2b", {}).get("state"))
print("EVENTUAL_STARTED_STATE", rows.get("started-major2b", {}).get("state"))
PY
)"
check "#498 MAJOR-2(b): at boot, the deferred queued row is correctly left untouched (not orphaned prematurely)" \
    "AT_BOOT_QUEUED_STATE queued" "$out"
check "#498 MAJOR-2(b): at boot, the deferred started row is correctly left untouched (not orphaned prematurely)" \
    "AT_BOOT_STARTED_STATE started" "$out"
check "#498 MAJOR-2(b): once the foreign owner goes stale, the deferred queued row IS eventually reconciled -> orphaned (never wedged for this process's life)" \
    "EVENTUAL_QUEUED_STATE orphaned" "$out"
check "#498 MAJOR-2(b): the deferred started (no external_job_id) row is reconciled too" \
    "EVENTUAL_STARTED_STATE orphaned" "$out"
rm -rf "$at498r1_d"

echo "-- #498 round-1 review MINOR-1: a NAIVE (tzinfo-less) heartbeat timestamp must fail OPEN (normal reconciliation), not escape as an untraced fail-closed skip --"
at498r1_e="$(mktemp -d)"
at_repo "$at498r1_e" jarvis
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - "$at498r1_e" <<'PY'
import queue, sys, threading, time
from assistant import tasks

root = sys.argv[1]
conn = tasks._open_conn(root)
naive_heartbeat = "2020-01-01T00:00:00"  # NO tzinfo -- raises TypeError subtracting from an aware datetime
conn.execute(
    "INSERT INTO task_owner (id, engine_id, pid, host, heartbeat_at) VALUES (1, ?, ?, ?, ?)",
    ("engine-naive-ts", 1, "some-host", naive_heartbeat),
)
tasks._insert(conn, "leftover-minor1", "harness", {}, None)
tasks._transition(conn, "leftover-minor1", tasks.STATE_STARTED)  # no external_job_id -- unreconcilable if reached
conn.close()

q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=tasks.run_worker, args=(q, stop),
                      kwargs={"poll_timeout": 0.05, "repos_getter": lambda: [("jarvis", root)],
                              "engine_id": "engine-self"})
t.start()
time.sleep(0.3)
stop.set()
t.join(timeout=3)

rows = {r["id"]: r for r in tasks.list_tasks(root)}
print("ROW_STATE", rows.get("leftover-minor1", {}).get("state"))
print("WORKER_JOINED", not t.is_alive())
PY
)"
check "#498 MINOR-1: a naive heartbeat timestamp fails OPEN -- the root reconciles normally, never silently skipped" \
    "ROW_STATE orphaned" "$out"
check "#498 MINOR-1: the worker never crashes or hangs over the naive timestamp" "WORKER_JOINED True" "$out"
rm -rf "$at498r1_e"

echo "-- #498 round-1 review MINOR-2: a failed ownership claim must never leave the connection mid-transaction -- the NEXT _insert on it must still succeed --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import sqlite3, tempfile
from assistant import tasks

root = tempfile.mkdtemp(prefix="at-minor2-")
real_conn = tasks._open_conn(root)

class FlakyConn:
    """Proxies a real sqlite3.Connection, raising exactly once on the
    task_owner upsert -- everything else (including the ROLLBACK/BEGIN
    IMMEDIATE _claim_ownership itself issues) passes through untouched."""
    def __init__(self, real):
        self._real = real
        self.armed = True
    def execute(self, sql, params=()):
        if self.armed and "INSERT INTO task_owner" in sql:
            self.armed = False
            raise sqlite3.OperationalError("simulated failure mid-claim")
        return self._real.execute(sql, params)
    def __getattr__(self, name):
        return getattr(self._real, name)

flaky = FlakyConn(real_conn)
claim_raised = False
try:
    tasks._claim_ownership(flaky, "engine-x")
except Exception:
    claim_raised = True
print("CLAIM_RAISED", claim_raised)

insert_raised = False
insert_error = ""
try:
    tasks._insert(real_conn, "after-flaky-claim", "harness", {}, None)
except Exception as exc:
    insert_raised = True
    insert_error = str(exc)
print("INSERT_AFTER_FLAKY_CLAIM_RAISED", insert_raised)
print("INSERT_ERROR", insert_error)
real_conn.close()
PY
)"
check "#498 MINOR-2: the flaky claim itself raises, as designed (propagates to its caller's own try/except)" \
    "CLAIM_RAISED True" "$out"
check "#498 MINOR-2: a SUBSEQUENT _insert on the same connection succeeds -- never poisoned by the failed claim's dangling transaction" \
    "INSERT_AFTER_FLAKY_CLAIM_RAISED False" "$out"
check_absent "#498 MINOR-2: no 'cannot start a transaction within a transaction' error leaks through" \
    "cannot start a transaction" "$out"

echo "-- #498 round-1 review advisory (c): a NORMAL ownership skip (working as designed, not a failure) now emits its own trace event -- distinct from the failure-path task.ownership_check_failed --"
at498r1_g="$(mktemp -d)"
at_repo "$at498r1_g" jarvis
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - "$at498r1_g" <<'PY'
import queue, sys, threading, time
from assistant import tasks

root = sys.argv[1]
conn = tasks._open_conn(root)
tasks._claim_ownership(conn, "engine-foreign-c")
conn.close()

traces_q = queue.Queue()
q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=tasks.run_worker, args=(q, stop),
                      kwargs={"poll_timeout": 0.05, "repos_getter": lambda: [("jarvis", root)],
                              "engine_id": "engine-self", "traces_queue": traces_q})
t.start()
time.sleep(0.3)
stop.set()
t.join(timeout=3)

saw_skip_trace = False
while True:
    try:
        item = traces_q.get_nowait()
    except queue.Empty:
        break
    ev = item["event"]
    if ev["kind"] == "task.ownership_skip":
        payload = ev.get("payload") or {}
        if payload.get("owner_engine_id") == "engine-foreign-c" and payload.get("root") == root:
            saw_skip_trace = True
print("SAW_SKIP_TRACE", saw_skip_trace)
PY
)"
check "#498 advisory (c): a normal (non-failure) ownership skip emits its own task.ownership_skip trace event" \
    "SAW_SKIP_TRACE True" "$out"
rm -rf "$at498r1_g"
