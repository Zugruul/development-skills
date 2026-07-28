"""Task queue subsystem (SPEC-ASSISTANT.md Sec5a, Sec12.3, Sec17, E6,
AST-066, issue #341, docs/design/ast-E6.md).

Per Sec12.3 long-running work (a capability invocation that will not
finish inline) queues in `tasks.sqlite` as `{id, kind, state, payload,
external_job_id, artifact_path, timestamps}`; states are exactly
`queued -> started -> (progress)* -> completed | failed`, plus `orphaned`
(AST-067's restart-reconciliation target, never produced by this module --
see below). Per Sec17 ("turns never block on background work") `enqueue`
below is the SAME enqueue-only, O(1), never-raises-into-the-caller shape
`observability.emit`/`engine._enqueue_distill` already use; the actual
sqlite write happens ONLY on the `tasks` worker thread (engine.py's
`start()` binds `run_worker` into the AST-010 `WORKER_NAMES["tasks"]`
slot, replacing its v1 heartbeat no-op -- the exact "reuse the worker
skeleton verbatim" pattern AST-030/AST-040/AST-061 already used for their
own slots).

Durability (design doc): `tasks.sqlite` is a MUST-SURVIVE store (unlike
`traces.sqlite`, a prunable history) -- this module never deletes a row.
Retention/cleanup of old completed tasks, if ever wanted, is a separate,
future concern this task does not build.

Single writer (Sec10.2's discipline, reused here for a second db):
`run_worker` is the ONLY thread that ever opens a connection to a given
root's `tasks.sqlite`; per-root connections are held for the worker
thread's lifetime, WAL + busy_timeout pragma'd exactly like
`observability._open_conn`. `list_tasks` (the read path) opens its own
short-lived, separate connection per call -- a low-frequency read path,
never held across calls, mirroring `observability.query`.

Transitions AS trace events (Sec12.3's literal wording): every state
change this module makes -- queued/started/progress/completed/failed --
is ALSO emitted via `observability.emit` onto the SAME `traces` worker's
queue (`traces_queue`, optional, `None`-default so every caller/test that
constructs this worker without one keeps working unchanged -- the exact
`distill.run_worker(..., traces_queue=None)` convention). This is
reuse, never a second writer: `run_worker` never opens a `traces.sqlite`
connection itself, it only enqueues onto `traces_queue`, which the
ALREADY-RUNNING `traces` worker (`observability.run_writer`) drains and
writes, same as every other emitter in the codebase.

Execution model (flagged design call, issue #341's report): `run_worker`
is a SINGLE serial thread -- it drains one queue item, runs that task's
registered executor TO COMPLETION (blocking this worker thread, never the
HTTP/chat thread), then moves to the next item. This is deliberately NOT
a thread pool: it matches every other WORKER_NAMES slot (one thread per
subsystem) and already satisfies the actual invariant Sec17 cares about
(turns/chat never block on background work, since this runs on its own
thread entirely) -- a concurrent-task-throughput pool is a future
extension this task does not need to build. `executors` is an injectable
`{kind: callable}` mapping (never a module-level global registry, matching
this codebase's consistent `capability_index.py`-style "injectable seam,
not mutable module state" preference) -- a `kind` with no registered
executor fails specifically and immediately (`"no executor registered for
kind %r"`), never hangs. AST-070 ("dispatched harness jobs as task kind")
is the first task expected to register a REAL executor; this module
builds only the generic queue/state-machine/worker infrastructure, no
specific task kind's business logic (deferred, not hard-coded here).

Schema (flagged addition beyond the design doc's literal Task shape,
issue #341's report): the doc's Data model lists `{id, kind, state,
payload, external_job_id, artifact_path, created_at, updated_at}` with no
field for a failure's diagnostic message or a success's return value.
Added two columns: `error` (TEXT, NULL until `failed`) and `result`
(TEXT/JSON, NULL until `completed` with a non-artifact result) -- a
`failed` state is unactionable without SOME reason string, mirroring
`provisioning.py`'s own "never a bare boolean" precedent for
`unavailable_reason`. Both are minimal, additive, and never populated by
this task for any REAL task kind (no kind ships here) -- exercised only
by this module's own tests via a synthetic executor.

Restart reconciliation (Sec12.4, AST-067, issue #342, docs/design/ast-E6.md
sequence 4): the in-memory queue `q` starts EMPTY on every engine restart --
`tasks.sqlite` is what survives, so any row still `queued`/`started`/
`progress` when the process last stopped is invisible to the normal drain
loop forever unless something looks for it. `run_worker` now does exactly
that ONCE, before entering the drain loop, when given a `repos_getter`
(same live `{repo_name: root}`-pairs callable `capability_index.run_worker`
already takes -- engine.py's `self._repos_getter`): for every currently-
known root, every non-terminal row is re-examined.

Every state a restart can find a row in was already enumerated by the
state machine itself -- sqlite's own transaction atomicity (`_transition`'s
`BEGIN IMMEDIATE` / `COMMIT`) means a crash mid-transition never leaves a
HALF-written state; a row is always exactly one of `STATES`, never
something in between. So reconciliation only ever needs to ask "is this
row's real-world work still happening, or not":
    - `queued` (closure on issue #342's review): never even reached an
      executor -- Sec12.4's own wording is "unreconcilable tasks become
      orphaned", and a purely-queued row genuinely IS unreconcilable: no
      external_job_id, no in-process work, the in-memory queue item that
      would have run it died with the process. Leaving it `queued`
      forever would be the one state in this machine that can never
      progress, and it would still show in the §12.5 queue indicator as
      pending work that will never run. The fix is nearly free: `_insert`
      is followed immediately by `_transition(STARTED)` with no I/O in
      between, so a row only persists as `queued` at rest if the process
      died between those two adjacent statements -- this is a vocabulary/
      correctness fix, not something that reconciles meaningful volume.
      `orphaned` via the same no-`external_job_id` path below, worded for
      what actually happened (never started, not "was running and is now
      gone").
    - no `external_job_id` on a `started`/`progress` row: nothing external
      to ask. The in-process work that was running when the engine stopped
      is simply gone (this worker thread died with the process) --
      unreconcilable, `orphaned`.
    - `external_job_id` present but no resolver registered for that
      `kind`: same shape as `run_worker`'s own "no executor registered for
      kind %r" -- fails specifically, `orphaned`, never silently retried
      or left forever ambiguous.
    - resolver raises, or returns something that is not a dict with a
      recognized `state` (protocol-layer failure enumeration: a resolver
      is someone else's remote system, its response can legitimately be
      unreachable, malformed, or simply wrong) -- `orphaned`, distinct
      error text from the two cases above so `error` always says WHY.
    - resolver reports `"not_found"` (the remote system has no record of
      that job at all -- expired, evicted, or never actually existed) --
      also `orphaned`: this is not the same failure as an unreachable/
      malformed response, so it gets its own recognized outcome and its
      own error text, even though the row-level result (orphaned) is the
      same.
    - resolver reports `"completed"`/`"failed"`: the remote system's real
      state wins outright -- `_transition`ed accordingly (never
      resubmitted, per §12.4's literal wording), same `task.completed`/
      `task.failed` trace events the normal flow emits, `{"reconciled":
      True}` added to the payload so a trace consumer can tell the two
      apart.
    - resolver reports `"in_progress"`: genuinely still running elsewhere;
      no state change (nothing about the row is actually different), but
      a `task.reconcile_checked` trace event still fires so a restart
      leaves SOME record that this row was looked at, even though nothing
      moved.
    One row's reconciliation failing (a bug in a resolver, a query
    exploding) never stops the rest -- same "park-and-continue" posture
    `run_worker`'s own drain loop already has -- and one ROOT's
    reconciliation failing never stops another root's.

    Crash safety is SWEEP idempotence, not per-row atomicity (issue #342's
    review). Each row reconciles in its own transaction, so dying mid-sweep
    leaves some rows resolved and others not -- that is harmless because
    the query that selects candidate rows only ever matches `queued`/
    `started`/`progress`; already-reconciled rows have moved to a terminal
    state and dropped out of the candidate set, so the next restart's sweep
    picks up exactly the remainder, never re-touching what already
    finished. The one residual gap this does NOT close: a crash between a
    row's `_transition` commit and its matching `_emit` trace call commits
    the state change without its trace event -- the database stays
    authoritative and correct (the next sweep will not revisit that row,
    since it is no longer a candidate), only the audit trail has a hole.
    Correctly out of scope: fixing it would need making the state
    transition and the trace emission one atomic unit across two different
    storage systems (sqlite + the traces queue), which is a bigger change
    than this task's reconciliation logic.

    Flagged (issue #342's report): no resolver ships with this task (same
    "generic infrastructure, no specific business logic" posture the
    `executors` seam already established for AST-066 -- AST-070 registers
    the first real one). `resolvers[kind]` is `(external_job_id, payload)
    -> {"state": ..., **fields}`, deliberately the same shape as
    `executors[kind]`'s `(payload, report_progress) -> {...}` outcome dict,
    for the same reason: one convention, not two.

Library:
    STATES -- the exact six state names Sec12.3 lists, in transition
        order. `orphaned` was never produced before AST-067; restart
        reconciliation (below) is what actually produces it now.
    enqueue(q, root, kind, payload=None, turn_id=None) -> task_id | None
        Enqueue-only; generates `task_id` (uuid4 hex) in the CALLING
        thread (cheap, no I/O) so callers get a referenceable id
        synchronously, without waiting on the worker thread to actually
        insert the row -- there is a brief, expected window after
        `enqueue` returns where `list_tasks` will not yet show the row
        (eventual, not synchronous, consistency -- matching every other
        enqueue-only path in this codebase). Never raises into the
        caller. On a full/broken queue (round-2 review, issue #341):
        returns `None`, NEVER a phantom id -- `tasks.sqlite` is
        MUST-SURVIVE, so a caller must be able to tell "this task was
        never even queued" apart from "queued, and its state will show up
        shortly"; a dropped enqueue also has no row to attach a `failed`
        transition to (there is nothing to transition -- the row was
        never created), so `None` is the honest signal, not a synthesized
        failure. `turn_id` (round-2 review, issue #341, the #334
        one-shared-turn_id pattern) is optional and threaded through to
        every trace event this task's lifecycle emits, so a task can be
        correlated back to the turn that spawned it (§12.5: "failures
        surface in-chat with the trace linked").
    run_worker(q, stop_event, executors=None, poll_timeout=...,
        traces_queue=None, repos_getter=None, resolvers=None)
        The `tasks` worker body engine.py's `start()` binds into the
        AST-010 `tasks` slot. See module docstring for the execution
        model, transition-as-trace-event contract, and (AST-067)
        "Restart reconciliation" sections.
    list_tasks(root, state=None, limit=200) -> list[dict]
        Read path for the queue-indicator endpoint
        (`GET /assistant/tasks`). Opens a fresh, short-lived connection
        per call; returns `[]` (never raises) for a root with no
        `tasks.sqlite` yet. Newest-first (`ORDER BY created_at DESC`) --
        a queue indicator cares about what's happening NOW, not the
        oldest historical task.
"""
import json
import os
import queue as queue_module
import sqlite3
import sys
import uuid
from datetime import datetime, timezone

from assistant import observability

TASKS_DIR_REL = os.path.join(".claude", "assistant")  # SAME dir traces.sqlite/
# session.jsonl already use (observability.py's own docstring: this whole
# directory is already gitignored via local-state.manifest's
# `.claude/assistant/` entry -- no new manifest line needed for this file
# specifically, same reasoning that module records for itself).
TASKS_FILE_NAME = "tasks.sqlite"

STATE_QUEUED = "queued"
STATE_STARTED = "started"
STATE_PROGRESS = "progress"
STATE_COMPLETED = "completed"
STATE_FAILED = "failed"
STATE_ORPHANED = "orphaned"
STATES = (STATE_QUEUED, STATE_STARTED, STATE_PROGRESS, STATE_COMPLETED, STATE_FAILED, STATE_ORPHANED)

# AST-067 (§12.4, issue #342): the recognized outcomes a reconciliation
# resolver may report -- see the module docstring's "Restart reconciliation"
# section for what each one means and what it produces.
_RESOLVER_STATE_COMPLETED = "completed"
_RESOLVER_STATE_FAILED = "failed"
_RESOLVER_STATE_IN_PROGRESS = "in_progress"
_RESOLVER_STATE_NOT_FOUND = "not_found"
_RESOLVER_STATES = (_RESOLVER_STATE_COMPLETED, _RESOLVER_STATE_FAILED, _RESOLVER_STATE_IN_PROGRESS, _RESOLVER_STATE_NOT_FOUND)
# rows this old restart-time reconciliation looks at -- includes `queued`
# (closure on issue #342's review): Sec12.4's own wording is "unreconcilable
# tasks become orphaned", and a purely-queued row IS unreconcilable -- no
# external_job_id, no in-process work, the in-memory queue item that would
# have run it died with the process. See the module docstring for why this
# is a vocabulary/correctness fix, not a data-volume one.
_RECONCILE_TARGET_STATES = (STATE_QUEUED, STATE_STARTED, STATE_PROGRESS)

DEFAULT_POLL_TIMEOUT_SECONDS = 0.5

_SCHEMA_DDL = """
CREATE TABLE IF NOT EXISTS tasks (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    state TEXT NOT NULL,
    payload TEXT NOT NULL,
    external_job_id TEXT,
    artifact_path TEXT,
    result TEXT,
    error TEXT,
    turn_id TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
)
"""
_INDEX_DDL = (
    "CREATE INDEX IF NOT EXISTS idx_tasks_state ON tasks(state)",
    "CREATE INDEX IF NOT EXISTS idx_tasks_created_at ON tasks(created_at)",
    "CREATE INDEX IF NOT EXISTS idx_tasks_turn_id ON tasks(turn_id)",
)

_SELECT_COLUMNS = (
    "id", "kind", "state", "payload", "external_job_id",
    "artifact_path", "result", "error", "turn_id", "created_at", "updated_at",
)


def _now_iso():
    return datetime.now(timezone.utc).isoformat()


def _db_path(root):
    return os.path.join(root, TASKS_DIR_REL, TASKS_FILE_NAME)


def enqueue(q, root, kind, payload=None, turn_id=None):
    """See module docstring's Library entry. Returns `None` (never a
    phantom id -- round-2 review, issue #341) if the item never reached
    the queue."""
    task_id = uuid.uuid4().hex
    try:
        q.put_nowait({
            "action": "create",
            "id": task_id,
            "root": root,
            "kind": kind,
            "payload": payload if payload is not None else {},
            "turn_id": turn_id,
        })
    except queue_module.Full:
        sys.stderr.write("tasks: queue full, dropping task kind=%r\n" % (kind,))
        return None
    except Exception as exc:  # never raise into a turn (Sec17)
        sys.stderr.write("tasks: enqueue failed: %s\n" % exc)
        return None
    return task_id


def _open_conn(root):
    """Opens (and idempotently schema-creates) the ONE connection this
    worker thread holds for `root`'s tasks.sqlite -- mirrors
    `observability._open_conn` exactly (WAL + busy_timeout, `CREATE ...
    IF NOT EXISTS` schema)."""
    path = _db_path(root)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    conn = sqlite3.connect(path, timeout=5.0, isolation_level=None)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=5000")
    conn.execute(_SCHEMA_DDL)
    for ddl in _INDEX_DDL:
        conn.execute(ddl)
    return conn


def _insert(conn, task_id, kind, payload, turn_id):
    """Round-2 review (issue #341) bugfix, caught by this round's own new
    ADVISORY-2 test: `payload` is serialized to JSON text BEFORE `BEGIN
    IMMEDIATE` runs, not inside the transaction. A `payload` that passes
    the `isinstance(dict)` guard but contains a non-JSON-serializable
    value (e.g. a `set`) used to raise INSIDE the transaction, leaving the
    connection stuck mid-transaction ("cannot start a transaction within
    a transaction" on the very next `BEGIN IMMEDIATE` -- including the
    recovery `_transition_safe` call `_process_create`'s except branch
    makes). Serializing first means a bad payload fails BEFORE any
    transaction ever opens, so the connection is always left clean for
    whatever recovery comes next."""
    payload_json = json.dumps(payload, sort_keys=True)
    now = _now_iso()
    conn.execute("BEGIN IMMEDIATE")
    conn.execute(
        "INSERT INTO tasks (id, kind, state, payload, external_job_id, artifact_path, "
        "result, error, turn_id, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, NULL, NULL, NULL, NULL, ?, ?, ?)",
        (task_id, kind, STATE_QUEUED, payload_json, turn_id, now, now),
    )
    conn.execute("COMMIT")


def _transition(conn, task_id, state, **fields):
    """Updates `state` (+ `updated_at`, always) and any of
    `artifact_path`/`result`/`error` passed as kwargs. A single-row
    UPDATE, committed immediately -- tasks transition one at a time (this
    worker's serial execution model), never batched the way
    `observability._flush` batches trace events, so there is no
    "buffer, then commit" step to mirror here."""
    now = _now_iso()
    set_clauses = ["state = ?", "updated_at = ?"]
    values = [state, now]
    for key, value in fields.items():
        set_clauses.append(f"{key} = ?")
        values.append(value)
    values.append(task_id)
    conn.execute("BEGIN IMMEDIATE")
    conn.execute(f"UPDATE tasks SET {', '.join(set_clauses)} WHERE id = ?", values)
    conn.execute("COMMIT")


def _emit(traces_queue, root, kind, task_id, task_kind, state, extra=None, turn_id=None):
    if traces_queue is None:
        return
    payload = {"task_id": task_id, "kind": task_kind, "state": state}
    if extra:
        payload.update(extra)
    observability.emit(traces_queue, root, {"kind": kind, "turn_id": turn_id, "payload": payload})


def _transition_safe(conn, task_id, state, **fields):
    """Best-effort `_transition` for a FAILURE-recording call site (round-2
    review, issue #341, ADVISORY 2): a failing `_transition` here must
    never raise back out -- there is no further fallback state to record
    a failure of recording a failure into, so this just logs to stderr
    and gives up on the row (the trace event, which never touches sqlite,
    still gets emitted by the caller regardless).

    Defensively rolls back FIRST: whatever failure this is recovering
    from may have left `conn` mid-transaction (a `BEGIN IMMEDIATE` that
    never reached its `COMMIT`) -- a fresh `BEGIN IMMEDIATE` on a
    connection already mid-transaction raises "cannot start a transaction
    within a transaction", which would make THIS recovery attempt fail
    too. `_insert` avoiding that specific case (serializing JSON before
    opening its transaction) is not a guarantee every future failure mode
    will -- this rollback is the general safety net, not a duplicate of
    that fix."""
    try:
        conn.execute("ROLLBACK")
    except Exception:
        pass  # nothing to roll back (no open transaction) -- not an error
    try:
        _transition(conn, task_id, state, **fields)
    except Exception as exc:
        sys.stderr.write("tasks worker: could not record %s transition for %s: %s\n" % (state, task_id, exc))


def _process_create(item, conns, executors, traces_queue):
    """Handles one `{"action": "create", ...}` queue item end to end:
    insert (queued) -> started -> executor -> completed|failed, each
    transition also emitted as a trace event. Never lets an executor's
    exception escape -- caught, recorded as `error`, state -> failed --
    matching `distill.run_worker`'s "an exception processing one item
    never crashes the thread" posture.

    Round-2 review (issue #341) ADVISORY 2: a failure OUTSIDE the
    executor -- e.g. a sqlite error on the insert/started transition --
    used to leave the task stuck in whatever state it last reached (or
    never created at all), with no `failed` transition and no trace
    event: a silent exit from the state machine. The insert+started
    phase is now its own try/except, recording a best-effort `failed`
    transition (`_transition_safe`, guarded against recursing if EVEN
    THAT fails) and always emitting the `task.failed` trace event
    (enqueue-only, never touches sqlite, so it cannot itself fail this
    way)."""
    root = item.get("root")
    task_id = item.get("id")
    kind = item.get("kind")
    payload = item.get("payload")
    turn_id = item.get("turn_id")
    if not root or not task_id or not kind or not isinstance(payload, dict):
        # ADVISORY 1 (round-2 review, issue #341): symmetry with every
        # other drop path in this module (enqueue's full/broken queue,
        # run_worker's unrecognized-action skip below) -- a malformed
        # item is silently SKIPPED (never crashes the worker), but never
        # silently, with no trace at all.
        sys.stderr.write("tasks worker: skipping malformed create item: %r\n" % (item,))
        return

    try:
        if root not in conns:
            conns[root] = _open_conn(root)
        conn = conns[root]

        _insert(conn, task_id, kind, payload, turn_id)
        _emit(traces_queue, root, "task.queued", task_id, kind, STATE_QUEUED, turn_id=turn_id)

        _transition(conn, task_id, STATE_STARTED)
        _emit(traces_queue, root, "task.started", task_id, kind, STATE_STARTED, turn_id=turn_id)
    except Exception as exc:  # never crash the worker thread; never a silent exit either
        error = "task setup failed: %s" % exc
        if root in conns:
            _transition_safe(conns[root], task_id, STATE_FAILED, error=error)
        _emit(traces_queue, root, "task.failed", task_id, kind, STATE_FAILED, {"error": error}, turn_id=turn_id)
        return

    executor = executors.get(kind)
    if executor is None:
        error = "no executor registered for kind %r" % (kind,)
        _transition_safe(conn, task_id, STATE_FAILED, error=error)
        _emit(traces_queue, root, "task.failed", task_id, kind, STATE_FAILED, {"error": error}, turn_id=turn_id)
        return

    def report_progress(progress_payload=None):
        _transition(conn, task_id, STATE_PROGRESS)
        extra = {"progress": progress_payload} if progress_payload is not None else None
        _emit(traces_queue, root, "task.progress", task_id, kind, STATE_PROGRESS, extra, turn_id=turn_id)

    try:
        outcome = executor(payload, report_progress)
        outcome = outcome if isinstance(outcome, dict) else {}
        artifact_path = outcome.get("artifact_path")
        result = outcome.get("result")
        _transition(
            conn, task_id, STATE_COMPLETED,
            artifact_path=artifact_path,
            result=json.dumps(result, sort_keys=True) if result is not None else None,
        )
        extra = {"artifact_path": artifact_path} if artifact_path else None
        _emit(traces_queue, root, "task.completed", task_id, kind, STATE_COMPLETED, extra, turn_id=turn_id)
    except Exception as exc:  # never crash the worker thread over one task's failure
        error = str(exc)
        _transition_safe(conn, task_id, STATE_FAILED, error=error)
        _emit(traces_queue, root, "task.failed", task_id, kind, STATE_FAILED, {"error": error}, turn_id=turn_id)


def _orphan_row(conn, root, row, reason, traces_queue):
    """One row -> `orphaned`, `error=reason`, `task.orphaned` trace event.
    Every unreconcilable path in `_reconcile_row` funnels through here so
    the state machine's actual "give up, surface it" step is written once.
    `_transition_safe` (never `_transition`) -- a reconciliation failure
    recording ITS OWN failure must not raise back out of the reconciliation
    pass (same posture `_process_create`'s except-branches already use)."""
    _transition_safe(conn, row["id"], STATE_ORPHANED, error=reason)
    _emit(traces_queue, root, "task.orphaned", row["id"], row["kind"], STATE_ORPHANED,
          {"error": reason, "reconciled": True}, turn_id=row.get("turn_id"))


def _reconcile_row(conn, root, row, resolvers, traces_queue):
    """One `queued`/`started`/`progress` row found at restart -> re-polled
    (never resubmitted, §12.4's literal wording) or `orphaned`. See the
    module docstring's "Restart reconciliation" section for the full
    state-by-state rationale; this is that section's implementation."""
    task_id = row["id"]
    kind = row["kind"]
    external_job_id = row.get("external_job_id")
    turn_id = row.get("turn_id")
    old_state = row["state"]

    if old_state == STATE_QUEUED:
        # closure on issue #342's review: a queued row never even reached
        # an executor, so it can never carry an external_job_id either --
        # unreconcilable for the same reason a bare no-external_job_id
        # started/progress row is, just phrased for what actually happened
        # (never started, not "was running and is now gone").
        _orphan_row(conn, root, row,
                    "queued at restart, never started -- the in-memory queue item that would have run it is gone",
                    traces_queue)
        return

    if not external_job_id:
        _orphan_row(conn, root, row, (
            "no external_job_id at restart -- the in-process work that was "
            "%s when the engine stopped is gone, nothing to re-poll" % old_state
        ), traces_queue)
        return

    resolver = resolvers.get(kind)
    if resolver is None:
        _orphan_row(conn, root, row, "no reconciliation resolver registered for kind %r" % (kind,), traces_queue)
        return

    try:
        payload = json.loads(row.get("payload") or "{}")
        if not isinstance(payload, dict):
            payload = {}
    except (TypeError, ValueError):
        payload = {}

    try:
        outcome = resolver(external_job_id, payload)
    except Exception as exc:  # protocol-layer failure: the remote system is someone else's -- never trust it, never crash on it
        _orphan_row(conn, root, row, "reconciliation resolver raised: %s" % exc, traces_queue)
        return

    if not isinstance(outcome, dict) or outcome.get("state") not in _RESOLVER_STATES:
        # validate the DECLARATION (a dict with a recognized `state` key),
        # not just some value inside it -- an unparseable/malformed
        # response from a remote system is exactly the kind of thing that
        # must never be silently trusted into a definitive transition.
        _orphan_row(conn, root, row, "reconciliation resolver returned an unusable status: %r" % (outcome,), traces_queue)
        return

    resolver_state = outcome["state"]
    if resolver_state == _RESOLVER_STATE_NOT_FOUND:
        _orphan_row(conn, root, row, "remote system has no record of external_job_id %r" % (external_job_id,), traces_queue)
        return

    if resolver_state == _RESOLVER_STATE_IN_PROGRESS:
        # genuinely still running elsewhere -- nothing about the row
        # changed, so no _transition (no write for a no-op), but the
        # restart still gets a record that this row was checked at all.
        _emit(traces_queue, root, "task.reconcile_checked", task_id, kind, old_state,
              {"reconciled": True, "still_running": True}, turn_id=turn_id)
        return

    if resolver_state == _RESOLVER_STATE_COMPLETED:
        artifact_path = outcome.get("artifact_path")
        result = outcome.get("result")
        _transition(
            conn, task_id, STATE_COMPLETED,
            artifact_path=artifact_path,
            result=json.dumps(result, sort_keys=True) if result is not None else None,
        )
        extra = {"reconciled": True}
        if artifact_path:
            extra["artifact_path"] = artifact_path
        _emit(traces_queue, root, "task.completed", task_id, kind, STATE_COMPLETED, extra, turn_id=turn_id)
        return

    # resolver_state == _RESOLVER_STATE_FAILED
    error = outcome.get("error") or "remote job reported failure (reconciled at restart)"
    _transition(conn, task_id, STATE_FAILED, error=error)
    _emit(traces_queue, root, "task.failed", task_id, kind, STATE_FAILED, {"error": error, "reconciled": True}, turn_id=turn_id)


def _reconcile_root(conn, root, resolvers, traces_queue):
    """Every `started`/`progress` row in ONE root's tasks.sqlite, each
    handled independently -- one row's reconciliation blowing up (a bug in
    a resolver, a row this function did not anticipate) never stops the
    rest, same park-and-continue posture `run_worker`'s own drain loop
    already has for queue items."""
    placeholders = ", ".join("?" for _ in _RECONCILE_TARGET_STATES)
    rows = conn.execute(
        "SELECT " + ", ".join(_SELECT_COLUMNS) + " FROM tasks WHERE state IN (" + placeholders + ")",
        _RECONCILE_TARGET_STATES,
    ).fetchall()
    for raw_row in rows:
        row = dict(zip(_SELECT_COLUMNS, raw_row))
        try:
            _reconcile_row(conn, root, row, resolvers, traces_queue)
        except Exception as exc:  # never let one row's reconciliation kill the pass
            sys.stderr.write("tasks worker: reconciliation failed for task %s: %s\n" % (row.get("id"), exc))


def _reconcile_all(repos_getter, conns, resolvers, traces_queue):
    """Called once, before `run_worker`'s drain loop starts. `conns` is
    `run_worker`'s OWN dict (passed in, not created here) so a connection
    reconciliation opens for a root is the SAME connection the drain loop
    reuses afterward -- single writer per root, never a second connection
    opened just for this pass."""
    try:
        repo_pairs = list(repos_getter())
    except Exception as exc:  # a broken repos_getter must not prevent the worker from starting at all
        sys.stderr.write("tasks worker: reconciliation could not list roots: %s\n" % exc)
        return
    for _repo_name, root in repo_pairs:
        try:
            if root not in conns:
                conns[root] = _open_conn(root)
            _reconcile_root(conns[root], root, resolvers, traces_queue)
        except Exception as exc:  # one root's reconciliation failing must not block another root's
            sys.stderr.write("tasks worker: reconciliation failed for root %s: %s\n" % (root, exc))


def run_worker(q, stop_event, executors=None, poll_timeout=DEFAULT_POLL_TIMEOUT_SECONDS, traces_queue=None, repos_getter=None, resolvers=None):
    """See module docstring's Library entry, "Execution model", and
    "Restart reconciliation" sections. `repos_getter`/`resolvers` are both
    optional (default `None`/`{}`) so every existing caller/test that
    constructs this worker without them keeps working unchanged -- the
    same convention `traces_queue=None` already established. `repos_getter`
    omitted means reconciliation simply does not run (there is no way to
    know which roots to check without it)."""
    executors = executors or {}
    resolvers = resolvers or {}
    conns = {}
    if repos_getter is not None:
        _reconcile_all(repos_getter, conns, resolvers, traces_queue)
    try:
        while not stop_event.is_set():
            try:
                item = q.get(timeout=poll_timeout)
            except queue_module.Empty:
                continue
            try:
                if isinstance(item, dict) and item.get("action") == "create":
                    _process_create(item, conns, executors, traces_queue)
                else:
                    # ADVISORY 1 (round-2 review, issue #341): a non-dict
                    # item or an unrecognized action used to be silently
                    # dropped here with no trace at all -- symmetry with
                    # every other drop path in this module.
                    sys.stderr.write("tasks worker: skipping unrecognized queue item: %r\n" % (item,))
            except Exception as exc:  # park-and-continue -- never kill the worker thread
                sys.stderr.write("tasks worker: item failed: %s\n" % exc)
    finally:
        for conn in conns.values():
            try:
                conn.close()
            except Exception:
                pass


def _row_to_dict(row):
    values = dict(zip(_SELECT_COLUMNS, row))
    for key in ("payload", "result"):
        text = values.get(key)
        if text is None:
            continue
        try:
            values[key] = json.loads(text)
        except (TypeError, ValueError):
            values[key] = None
    return values


def list_tasks(root, state=None, limit=200):
    """See module docstring's Library entry."""
    path = _db_path(root)
    if not os.path.exists(path):
        return []
    conn = sqlite3.connect(path, timeout=5.0)
    try:
        conn.execute("PRAGMA busy_timeout=5000")
        sql = "SELECT " + ", ".join(_SELECT_COLUMNS) + " FROM tasks"
        args = []
        if state is not None:
            sql += " WHERE state = ?"
            args.append(state)
        sql += " ORDER BY created_at DESC LIMIT ?"
        try:
            limit = max(0, int(limit))
        except (TypeError, ValueError):
            limit = 200
        args.append(limit)
        try:
            rows = conn.execute(sql, args).fetchall()
        except sqlite3.OperationalError:
            # "no such table" (shouldn't happen in practice since
            # _open_conn always creates the schema, but never crash a
            # read path over it) degrades to empty, same as
            # observability.query's own posture for a missing table.
            return []
    finally:
        conn.close()
    return [_row_to_dict(row) for row in rows]
