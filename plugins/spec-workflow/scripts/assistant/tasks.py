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

    AST-070 extension seam (SPEC-ASSISTANT.md §9.4, docs/design/ast-E6.md
    sequence 3): a harness-job executor needs to (a) persist an
    `external_job_id` PARTWAY through its run -- before it blocks on the
    dispatched subprocess, not only at completion, so a restart mid-job has
    something to reconcile against -- and (b) know its OWN task id, so it
    can construct an artifact path deterministically from something the
    engine controls, never from anything the dispatched job's own output
    claims. Neither need changes `executors[kind]`'s fixed two-positional-
    arg call shape (every existing executor fixture in this file's own test
    section keeps working unchanged): `report_progress` (the SAME closure
    every executor already receives) gained an optional `external_job_id=`
    kwarg -- passed, it is written into that transition's `UPDATE` the same
    way `_transition`'s other optional fields are (omitted, the column is
    left untouched, matching `_transition`'s existing "only what's passed
    gets set" behavior) -- and carries its OWN `task_id` as a plain function
    attribute (`report_progress.task_id`), a closure being an ordinary
    Python object that can carry extra, purely-additive state no old caller
    ever reads or is affected by.

Root ownership / heartbeat (§12.4-area, issue #498, AST-067's retro-review
F2): both reconciliation sweeps above assumed they were the only live
engine for a root. On a machine running multiple neural-view engines with
overlapping scan bases, that assumption is false -- a SECOND engine's
startup sweep or periodic live pass would orphan rows a FIRST engine is
actively draining, purely because the second engine has no way to know the
first is alive. Fix: a `task_owner` table -- ONE row, inside the SAME
`tasks.sqlite` (no new file, same single-writer discipline) -- recording
whichever engine last DRAINED this root: `engine_id` (a `uuid4().hex`
generated once per `run_worker` call, i.e. per process, unless a caller
passes its own), `pid`, `host` (`socket.gethostname()`), and `heartbeat_at`.

Claim discipline (deliberately narrow): ONLY `_process_create` -- i.e. this
engine actually draining a queued item for `root` through to an executor --
calls `_claim_ownership`. Neither reconciliation sweep ever claims
ownership of a root it is merely scanning, including a root it finds
something to reconcile in: scanning is not draining, and a scanner that
claimed ownership by the mere act of looking would let a purely-periodic
reconciler falsely present itself as "the live engine" for a root nothing
is actually routing traffic to.

Skip discipline: before either sweep touches a candidate root's rows
(`_reconcile_root`/`_reconcile_live_root`), `_owner_blocks_reconciliation`
reads `task_owner` and returns True (skip this root, this pass) only when
ALL of: a row exists, its `engine_id` is NOT this engine's own, AND its
`heartbeat_at` is within the staleness window. Any other case -- no owner
row (the common case: every #497 test fixture creates none, so absent-
owner must keep behaving exactly like before this task existed), this
engine's OWN id (never blocks itself, regardless of heartbeat age -- an
engine's own in-flight work must never wedge on its own possibly-stale
heartbeat), or a heartbeat older than the staleness window (the owning
engine crashed) -- falls through to the pre-#498 behavior unchanged. This
is what keeps ownership crash-safe: a dead owner's heartbeat simply stops
advancing and ages out on its own; nothing needs to notice the crash or
release a lock.

Staleness window: `owner_stale_seconds`, default `OWNER_STALE_MULTIPLIER`
(3) times the effective live-reconcile interval (the configured
`live_reconcile_interval`, or `DEFAULT_LIVE_RECONCILE_INTERVAL_SECONDS` if
periodic reconciliation is disabled). 3x is chosen the same way a TCP
keepalive or Kubernetes liveness probe threshold is: one missed tick is
ordinary jitter (GC pause, a slow disk fsync under WAL), not evidence of a
crash, so a single miss must never cause a live owner's rows to be
snatched by another engine's sweep; three consecutive misses is no longer
plausibly transient. This also bounds recovery time after a REAL crash to
a small, known multiple of the tick interval (default: 90s), keeping the
"never wedge forever" invariant's actual wait bounded and explainable.

Refresh discipline ("refreshed... each drain/tick"): a claim happens once
per drained item (`_process_create`, unconditionally, best-effort -- a
heartbeat write failing must never fail the task itself). Additionally,
every periodic tick (the SAME `live_reconcile_interval` cadence that
already drives `_reconcile_live_all`) re-stamps the heartbeat for every
root this engine has EVER drained in this process's lifetime
(`owned_roots`, an in-memory set) -- this is what keeps a long-running,
between-drains root (e.g. one dispatched harness job that runs for
several minutes with no new items queued for that root) from going stale
and getting reconciled out from under its own engine by a DIFFERENT
engine's sweep. `owned_roots` is never pruned within a process's lifetime:
an engine that drained a root once keeps asserting ownership of it for as
long as the process lives, which is harmless (this engine's own
reconciliation of that root is always self-permitted regardless) and
correct (only this engine's continued liveness -- not some separate
timeout -- should ever cause ownership to lapse).

Failure honesty (OWNER directive: never orphan blind): if reading
`task_owner` itself raises (locked, corrupt, mid-migration), the root is
SKIPPED for this pass -- fail closed, exactly as if a live foreign owner
were found -- and a `task.ownership_check_failed` trace event plus a
stderr line record why, so a silent skip that could otherwise look
indistinguishable from "root has nothing to reconcile" always leaves a
trail.

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
        traces_queue=None, repos_getter=None, resolvers=None,
        live_reconcile_interval=..., engine_id=None, owner_stale_seconds=None)
        The `tasks` worker body engine.py's `start()` binds into the
        AST-010 `tasks` slot. See module docstring for the execution
        model, transition-as-trace-event contract, (AST-067) "Restart
        reconciliation", and (#498) "Root ownership / heartbeat" sections.
        `engine_id` defaults to a fresh `uuid4().hex` per call (i.e. per
        process) when omitted; `owner_stale_seconds` defaults to
        `OWNER_STALE_MULTIPLIER * live_reconcile_interval` (see #498
        section for the 3x justification). Both are backward-compatible:
        every existing caller/test that constructs this worker without
        them keeps working unchanged (they only matter once more than one
        engine's sweep can see the same root).
    list_tasks(root, state=None, limit=200) -> list[dict]
        Read path for the queue-indicator endpoint
        (`GET /assistant/tasks`). Opens a fresh, short-lived connection
        per call; returns `[]` (never raises) for a root with no
        `tasks.sqlite` yet. Newest-first (`ORDER BY created_at DESC`) --
        a queue indicator cares about what's happening NOW, not the
        oldest historical task.
    get_task(root, task_id) -> dict | None
        Single-row read path (AST-068, issue #343: `/assistant/artifact/
        <task-id>` needs to look up ONE task's `state`/`artifact_path` by
        its id, not a bounded/filtered list). Same short-lived-connection,
        never-raises-for-a-missing-db shape as `list_tasks`; returns
        `None` for a missing db, a missing row, OR a malformed table --
        every "nothing usable here" case collapses to the SAME `None`
        result, since a caller resolving an artifact treats all three
        identically (see `artifacts.py`'s `ArtifactError`, which
        deliberately never distinguishes them either).
"""
import json
import os
import queue as queue_module
import socket
import sqlite3
import sys
import threading
import time
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

# AST-070 round-1 review MAJOR (issue #345): the startup sweep above runs
# exactly ONCE, before the drain loop starts -- a row it leaves `in_progress`
# (genuinely still running elsewhere at that moment) has NOTHING that will
# ever look at it again, since reconciliation never enqueues anything onto
# `q` and the drain loop only ever pulls from `q`. That row would sit
# `started`/`progress` FOREVER even after the external job actually
# finishes -- a dead end that directly contradicts "conversation resumable
# mid-job" (AST-070's own AC). `_reconcile_live_root`/`_reconcile_live_all`
# (see `run_worker`'s periodic call below) are the fix: a periodic re-poll,
# reusing `_reconcile_row`'s exact per-outcome logic (never resubmits), but
# over a NARROWER row set than the startup sweep -- ONLY `started`/
# `progress` rows that already carry an `external_job_id`. A bare `queued`
# row is deliberately EXCLUDED here (unlike the startup sweep): during
# NORMAL operation a `queued` row can be a legitimate, imminent item
# already sitting in the in-memory queue `q`, about to be drained -- the
# startup sweep's "queued at restart is unreconcilable" reasoning is true
# only at the one moment nothing could legitimately still be pending
# in-process; treating a live `queued` row that way mid-loop would
# incorrectly orphan work that is about to run normally.
_LIVE_RECONCILE_TARGET_STATES = (STATE_STARTED, STATE_PROGRESS)

DEFAULT_POLL_TIMEOUT_SECONDS = 0.5
DEFAULT_LIVE_RECONCILE_INTERVAL_SECONDS = 30.0

# #498 (module docstring's "Root ownership / heartbeat" section): 3 missed
# heartbeat ticks before a foreign owner is treated as crashed -- see that
# section for the keepalive-style justification.
OWNER_STALE_MULTIPLIER = 3

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

# #498: ONE row (id=1, enforced by the CHECK constraint), inside the SAME
# tasks.sqlite -- see module docstring's "Root ownership / heartbeat"
# section for the full claim/skip/refresh/failure contract.
_OWNER_TABLE_DDL = """
CREATE TABLE IF NOT EXISTS task_owner (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    engine_id TEXT NOT NULL,
    pid INTEGER NOT NULL,
    host TEXT NOT NULL,
    heartbeat_at TEXT NOT NULL
)
"""

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
    conn.execute(_OWNER_TABLE_DDL)  # #498: same db, same connection, no new file
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


def _pid_alive(pid):
    """#498 round-1 review MAJOR-2(a): mirrors `harness._pid_alive` exactly
    (duplicated, not imported -- `harness.py` imports `tasks`, so the
    reverse import would be circular). See that module's own docstring for
    the OS-signal-0 rationale; used here only for a same-host owner pid,
    never across hosts."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True  # exists, just not ours -- still "alive" from here
    except OSError:
        return False
    return True


class _OwnedRoots:
    """#498 round-1 review MAJOR-1(b): the set of roots THIS engine process
    has ever drained, guarded by a lock. Before this round, only the main
    worker thread ever touched this set; now a background heartbeat-timer
    thread (`_run_heartbeat_timer`) also reads it on its own schedule,
    concurrently with the main thread's `add`/`discard` calls -- a bare
    `set()` is not safe for that without a lock (both iteration-during-
    mutation and lost updates are real risks here, not theoretical)."""

    def __init__(self):
        self._roots = set()
        self._lock = threading.Lock()

    def add(self, root):
        with self._lock:
            self._roots.add(root)

    def discard(self, root):
        with self._lock:
            self._roots.discard(root)

    def snapshot(self):
        with self._lock:
            return list(self._roots)


def _claim_ownership(conn, engine_id):
    """#498: stamps THIS process as `root`'s current owner (upsert -- the
    table always holds exactly one row, `id=1`). Called from several
    places now (round-1 review MAJOR-1): `_process_create`'s drain claim,
    its `report_progress`-triggered refresh, the main loop's periodic-tick
    refresh, and the background heartbeat-timer thread's own refresh.
    Blindly overwrites whatever was there: whichever caller is actually
    reaching this IS, by definition, either draining the root right now or
    refreshing on behalf of a root this SAME engine already drained.

    Round-1 review MINOR-2: defensively rolls back FIRST (mirrors
    `_transition_safe`) -- a PRIOR failed call (or any other failed
    transaction on this connection) may have left `conn` mid-transaction;
    a fresh `BEGIN IMMEDIATE` on a connection already mid-transaction
    raises ("cannot start a transaction within a transaction"), which used
    to poison every subsequent `_insert`/`_transition` on this root too.
    Also rolls back on ITS OWN failure, then re-raises -- every call site
    already wraps this in a best-effort try/except (a heartbeat write
    failing must never fail the actual task), so re-raising here just
    hands the caller back a clean connection to recover with."""
    try:
        conn.execute("ROLLBACK")
    except Exception:
        pass  # nothing to roll back -- not an error
    now = _now_iso()
    conn.execute("BEGIN IMMEDIATE")
    try:
        conn.execute(
            "INSERT INTO task_owner (id, engine_id, pid, host, heartbeat_at) VALUES (1, ?, ?, ?, ?) "
            "ON CONFLICT(id) DO UPDATE SET engine_id = excluded.engine_id, pid = excluded.pid, "
            "host = excluded.host, heartbeat_at = excluded.heartbeat_at",
            (engine_id, os.getpid(), socket.gethostname(), now),
        )
        conn.execute("COMMIT")
    except Exception:
        try:
            conn.execute("ROLLBACK")
        except Exception:
            pass
        raise


def _read_owner(conn):
    """#498: the current owner row, or `None` if this root has never been
    drained by any engine. Raises on a genuinely broken read (locked/
    corrupt db) -- callers (`_owner_blocks_reconciliation`) decide what
    "raised" means; this function itself never swallows anything, so a
    test can reliably patch it to simulate a read failure."""
    row = conn.execute(
        "SELECT engine_id, pid, host, heartbeat_at FROM task_owner WHERE id = 1"
    ).fetchone()
    if row is None:
        return None
    return {"engine_id": row[0], "pid": row[1], "host": row[2], "heartbeat_at": row[3]}


def _refresh_owned_heartbeats(conns, owned, engine_id):
    """#498: the cheap half of the refresh contract -- called from the main
    loop's own periodic tick, re-stamping every root THIS engine has ever
    drained using its ALREADY-OPEN connection (never a fresh one just for
    this). This is the common-case path: most of the time the main loop
    is free to reach its own tick (between drains, waiting on `q.get`).
    See `_run_heartbeat_timer` for the round-1 review MAJOR-1(b) backstop
    that covers the case this alone does NOT: the main thread blocked
    inside a single long-running executor call, where this tick never
    fires at all."""
    for root in owned.snapshot():
        conn = conns.get(root)
        if conn is None:
            continue
        try:
            _claim_ownership(conn, engine_id)
        except Exception as exc:  # a heartbeat write hiccup must never stop the tick loop
            sys.stderr.write("tasks worker: heartbeat refresh failed for root %s: %s\n" % (root, exc))


def _run_heartbeat_timer(stop_event, owned, engine_id, interval_seconds):
    """#498 round-1 review MAJOR-1(b): a lightweight background thread,
    started once per `run_worker` call (only when reconciliation is
    active), that refreshes every root THIS engine currently owns on its
    own schedule -- independent of whether the main worker thread is free
    to reach its own tick. This is what keeps an owned root's heartbeat
    from freezing for the ENTIRE duration of an executor call that runs
    longer than the staleness window: `_process_create` calls the
    executor SYNCHRONOUSLY on the main thread, which cannot service its
    own periodic tick (or drain anything else) until that call returns --
    reviewer-confirmed: at production defaults, a 300s harness job was
    stale ~70% of its life against the 90s window before this fix.

    Uses its OWN short-lived connection per root per wake -- NEVER the
    long-lived `conns[root]` the main worker thread owns (Sec10.2's
    single-writer-PER-THREAD discipline: a `sqlite3.Connection` object
    must never be touched from a thread other than the one that created
    it). This mirrors `list_tasks`'s own "opens its own short-lived,
    separate connection per call" precedent, just for a write instead of
    a read -- WAL + `busy_timeout` (already pragma'd by `_open_conn`)
    serializes it against the main thread's own writes the same way it
    already serializes concurrent ENGINE PROCESSES writing `task_owner`
    (see module docstring's wall-clock/writers note).

    `stop_event.wait(interval_seconds)` (rather than `time.sleep`) doubles
    as both the sleep and the shutdown signal -- returns `True` (loop
    exits promptly) the instant the caller's `stop_event.set()` fires,
    `False` after a normal timeout."""
    while not stop_event.wait(interval_seconds):
        for root in owned.snapshot():
            try:
                conn = _open_conn(root)
                try:
                    _claim_ownership(conn, engine_id)
                finally:
                    conn.close()
            except Exception as exc:  # never let one root's refresh failure kill the timer
                sys.stderr.write("tasks worker: heartbeat timer refresh failed for root %s: %s\n" % (root, exc))


def _maybe_prune_owned_root(conn, root, owned):
    """#498 round-1 review advisory (a): once a root has no in-flight
    (`queued`/`started`/`progress`) rows left, THIS engine stops asserting
    ownership of it. Without this, an engine that drained a root exactly
    once would keep refreshing its heartbeat forever (both refresh paths
    iterate `owned` indefinitely) -- blocking every OTHER engine's
    reconciliation of that root for as long as this process merely stays
    alive, even with nothing left to protect. Compounds MAJOR-2's wedge
    risk the same way a never-expiring lock would.

    Ownership is reclaimed automatically the next time this engine
    actually drains something for the root (`_process_create`'s claim).
    Until then, the on-disk `task_owner` row is left exactly as it last
    was -- no explicit release here, no second write -- and simply ages
    out of the staleness window on its own, indistinguishable from a
    crashed owner's to any other engine checking it. (Compare
    `run_worker`'s shutdown-time deletion, advisory (b): THAT is an
    explicit release for a clean process exit; this is an implicit one
    for a merely-idle-but-still-alive engine, which must not look
    "departed" to anyone -- it may drain this same root again any
    moment.)"""
    try:
        placeholders = ", ".join("?" for _ in _RECONCILE_TARGET_STATES)
        count = conn.execute(
            "SELECT COUNT(*) FROM tasks WHERE state IN (" + placeholders + ")",
            _RECONCILE_TARGET_STATES,
        ).fetchone()[0]
        if count == 0:
            owned.discard(root)
    except Exception as exc:  # a failed prune check must never fail the task that just finished
        sys.stderr.write("tasks worker: owned-root prune check failed for root %s: %s\n" % (root, exc))


def _owner_blocks_reconciliation(conn, root, engine_id, owner_stale_seconds, traces_queue):
    """#498: True means "skip `root` this pass" -- see module docstring's
    "Root ownership / heartbeat" section for the full decision table. Fails
    CLOSED (also returns True) on a read failure: never risk orphaning a
    root this engine cannot even confirm is unowned, and never silently --
    always a trace event plus a stderr line."""
    try:
        owner = _read_owner(conn)
    except Exception as exc:
        sys.stderr.write("tasks worker: ownership read failed for root %s: %s\n" % (root, exc))
        if traces_queue is not None:
            observability.emit(traces_queue, root, {
                "kind": "task.ownership_check_failed",
                "payload": {"root": root, "error": str(exc)},
            })
        return True

    if owner is None or owner["engine_id"] == engine_id:
        return False  # no live foreign owner known -- proceed exactly as before #498

    # #498 round-1 review MAJOR-2(a): pid/host were written but never READ.
    # A fast restart on the SAME host inherits a predecessor's heartbeat
    # that is still timestamp-fresh (the predecessor only just died) --
    # without this check, that fresh-looking row would wedge the root
    # until the staleness window elapses on its own (or, for a
    # startup-class-only row -- see MAJOR-2(b) -- effectively forever). A
    # dead pid on THIS host is unambiguous, immediate evidence the owner
    # is gone -- checked before, and regardless of, heartbeat age. A
    # foreign host's pid is never checked this way (no portable, safe way
    # to ask a DIFFERENT machine "is this pid alive"): only the age-based
    # staleness window governs cross-host recovery.
    if owner["host"] == socket.gethostname() and not _pid_alive(owner["pid"]):
        return False

    try:
        heartbeat_dt = datetime.fromisoformat(owner["heartbeat_at"])
        age_seconds = (datetime.now(timezone.utc) - heartbeat_dt).total_seconds()
    except (TypeError, ValueError):
        # #498 round-1 review MINOR-1: the age SUBTRACTION (not just the
        # parse) must be inside this try too -- a naive (tzinfo-less)
        # `heartbeat_at` parses successfully but then raises TypeError
        # subtracting it from an aware `datetime.now(timezone.utc)`. That
        # used to escape uncaught here, propagate past this function
        # entirely, and get swallowed by the CALLER's generic per-root
        # except handler as an unrelated "reconciliation failed" -- an
        # untraced fail-CLOSED (root silently skipped), the exact OPPOSITE
        # of this documented fail-OPEN contract for an unusable timestamp.
        return False

    is_blocked = age_seconds < owner_stale_seconds
    if is_blocked and traces_queue is not None:
        # #498 round-1 review advisory (c): only the FAILURE path traced
        # before this -- a normal, working skip (the common case, not a
        # bug) had no visibility at all. Distinct kind from
        # task.ownership_check_failed: this is "working as designed",
        # that is "something is broken".
        observability.emit(traces_queue, root, {
            "kind": "task.ownership_skip",
            "payload": {"root": root, "owner_engine_id": owner["engine_id"], "heartbeat_at": owner["heartbeat_at"]},
        })
    return is_blocked


def _process_create(item, conns, executors, traces_queue, engine_id, owned, owner_stale_seconds):
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

    # #498 round-1 review MAJOR-1(a): the minimum gap between two
    # report_progress-triggered heartbeat refreshes for THIS task -- "~
    # window/3" (an executor that calls report_progress at least this
    # often keeps the heartbeat comfortably inside the staleness window
    # without hammering sqlite on every call, e.g. harness.py's ~2s
    # cadence). `nonlocal`-mutated by `report_progress` below.
    heartbeat_refresh_min_interval = owner_stale_seconds / OWNER_STALE_MULTIPLIER
    last_progress_heartbeat_mono = 0.0

    try:
        if root not in conns:
            conns[root] = _open_conn(root)
        conn = conns[root]

        # #498: THIS is a real drain -- the one and only place ownership is
        # claimed (never by a reconciliation sweep merely scanning `root`).
        # Isolated try/except: a heartbeat write hiccup must never fail the
        # task itself, which is real work, not bookkeeping.
        try:
            _claim_ownership(conn, engine_id)
            owned.add(root)
        except Exception as exc:
            sys.stderr.write("tasks worker: ownership claim failed for root %s: %s\n" % (root, exc))

        _insert(conn, task_id, kind, payload, turn_id)
        _emit(traces_queue, root, "task.queued", task_id, kind, STATE_QUEUED, turn_id=turn_id)

        _transition(conn, task_id, STATE_STARTED)
        _emit(traces_queue, root, "task.started", task_id, kind, STATE_STARTED, turn_id=turn_id)
    except Exception as exc:  # never crash the worker thread; never a silent exit either
        error = "task setup failed: %s" % exc
        if root in conns:
            _transition_safe(conns[root], task_id, STATE_FAILED, error=error)
            _maybe_prune_owned_root(conns[root], root, owned)  # #498 advisory (a)
        _emit(traces_queue, root, "task.failed", task_id, kind, STATE_FAILED, {"error": error}, turn_id=turn_id)
        return

    executor = executors.get(kind)
    if executor is None:
        error = "no executor registered for kind %r" % (kind,)
        _transition_safe(conn, task_id, STATE_FAILED, error=error)
        _emit(traces_queue, root, "task.failed", task_id, kind, STATE_FAILED, {"error": error}, turn_id=turn_id)
        _maybe_prune_owned_root(conn, root, owned)  # #498 advisory (a)
        return

    def report_progress(progress_payload=None, external_job_id=None):
        nonlocal last_progress_heartbeat_mono
        # AST-070 (see module docstring's "AST-070 extension seam"):
        # external_job_id is OPTIONAL and omitted by every pre-existing
        # caller -- only written into the transition when a caller (a
        # harness-job executor) actually supplies one, so a plain
        # `report_progress()`/`report_progress({...})` call never clobbers
        # the column back to NULL.
        fields = {}
        if external_job_id is not None:
            fields["external_job_id"] = external_job_id
        _transition(conn, task_id, STATE_PROGRESS, **fields)
        extra = {"progress": progress_payload} if progress_payload is not None else None
        _emit(traces_queue, root, "task.progress", task_id, kind, STATE_PROGRESS, extra, turn_id=turn_id)

        # #498 round-1 review MAJOR-1(a): rate-limited heartbeat refresh --
        # an executor that reports progress (harness.py: every ~2s) is the
        # CHEAPEST possible signal "this root's owner is still genuinely
        # alive and working", available on the SAME thread/connection this
        # closure already holds, no extra thread or connection needed.
        now_mono = time.monotonic()
        if now_mono - last_progress_heartbeat_mono >= heartbeat_refresh_min_interval:
            try:
                _claim_ownership(conn, engine_id)
                owned.add(root)
                last_progress_heartbeat_mono = now_mono
            except Exception as exc:
                sys.stderr.write("tasks worker: progress-triggered heartbeat refresh failed for root %s: %s\n" % (root, exc))

    # AST-070: a task-scoped executor (e.g. harness.run_harness_job) reads
    # this to construct an artifact path deterministically from the task's
    # OWN id -- never from anything crossing the process boundary. Plain
    # attribute on the closure; no old executor reads or is affected by it.
    report_progress.task_id = task_id

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

    _maybe_prune_owned_root(conn, root, owned)  # #498 advisory (a): covers both the completed and failed outcomes above


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


def _is_reconcile_candidate(root):
    """Issue #497 (AST-067's retro-review): `repos_getter()` yields EVERY
    `.neural-network`-anchored repo, not just assistant candidates -- but
    `_open_conn` `os.makedirs`'s `.claude/assistant/` and CREATEs
    `tasks.sqlite` as a side effect, so a reconciliation sweep opening a
    connection unconditionally for every yielded root was silently
    creating that directory/db for non-assistant repos too (§17.8
    exposure: those dirs are frequently un-gitignored). Both sweeps below
    now gate on this exactly the way `capability_index.run_worker` already
    gates its own `repos_getter()` walk: `discovery.classify_repo(root)`,
    skip anything that is not `"candidate"`.

    A candidate with no `tasks.sqlite` on disk yet is ALSO skipped here --
    it has nothing to reconcile (no rows exist), so opening a connection
    for it would itself be the exact bug this is fixing, just for a
    legitimate assistant repo instead of a non-assistant one. This check
    only ever gates OPENING a fresh connection (see both call sites: it is
    skipped entirely once `root` is already in `conns`) -- the normal
    enqueue/worker path for a root actively receiving tasks legitimately
    creates the db via its own `_open_conn` call in `_process_create`,
    completely unaffected by this function.

    Round-1 review (issue #497): the on-disk `tasks.sqlite` check runs
    FIRST, `classify_repo` (a project.yaml parse) second -- semantics-
    identical (both must hold either way), but the vast majority of
    `repos_getter()`'s roots have never queued a task, so the cheap
    filesystem stat short-circuits before paying for a YAML parse on
    every anchored repo on every periodic tick.

    Local import (mirrors `capability_index.run_worker`'s own `from
    assistant import discovery`): avoids a hard import-time coupling from
    this pure queue/worker module to the discovery/marker/config stack for
    callers that only need the queue machinery."""
    if not os.path.exists(_db_path(root)):
        return False
    from assistant import discovery
    try:
        classification = discovery.classify_repo(root)
    except Exception:
        return False
    return classification.kind == "candidate"


def _reconcile_all(repos_getter, conns, resolvers, traces_queue, engine_id, owner_stale_seconds,
                    pending_startup_reconcile):
    """Called once, before `run_worker`'s drain loop starts. `conns` is
    `run_worker`'s OWN dict (passed in, not created here) so a connection
    reconciliation opens for a root is the SAME connection the drain loop
    reuses afterward -- single writer per root, never a second connection
    opened just for this pass.

    #498: `_owner_blocks_reconciliation` runs AFTER the connection is open
    (the owner row lives inside the same db #497 already gates opening a
    connection for) but BEFORE `_reconcile_root` touches any task row --
    this sweep never claims ownership itself (see module docstring), it
    only ever reads it to decide whether to skip.

    Round-1 review MAJOR-2(b): this ONE-TIME sweep is the ONLY code path
    that ever reconciles a bare `queued` row or a started-without-
    external_job_id row (`_reconcile_root`'s full `_RECONCILE_TARGET_STATES`
    set -- the periodic live pass only ever looks at a narrower,
    external_job_id-only subset). A root skipped here because a foreign
    owner's heartbeat was fresh AT THIS ONE MOMENT would otherwise never
    get another chance for the rest of this process's life -- `queued`/
    no-external_job_id rows would wedge until restart even after the
    foreign owner crashes. Every root skipped for ownership (not for
    #497's own candidate-scoping, which has nothing to defer) is recorded
    into `pending_startup_reconcile` -- `run_worker`'s periodic tick
    (`_retry_pending_startup_reconcile`) retries exactly this pass on
    those roots once ownership stops blocking."""
    try:
        repo_pairs = list(repos_getter())
    except Exception as exc:  # a broken repos_getter must not prevent the worker from starting at all
        sys.stderr.write("tasks worker: reconciliation could not list roots: %s\n" % exc)
        return
    for _repo_name, root in repo_pairs:
        try:
            if root not in conns:
                if not _is_reconcile_candidate(root):  # issue #497: never CREATE a db just to reconcile it
                    continue
                conns[root] = _open_conn(root)
            if _owner_blocks_reconciliation(conns[root], root, engine_id, owner_stale_seconds, traces_queue):
                pending_startup_reconcile.add(root)  # #498 MAJOR-2(b): retry once ownership stops blocking
                continue  # #498: a different engine's heartbeat is still fresh -- not ours to touch this pass
            _reconcile_root(conns[root], root, resolvers, traces_queue)
        except Exception as exc:  # one root's reconciliation failing must not block another root's
            sys.stderr.write("tasks worker: reconciliation failed for root %s: %s\n" % (root, exc))


def _retry_pending_startup_reconcile(conns, resolvers, traces_queue, engine_id, owner_stale_seconds,
                                      pending_startup_reconcile):
    """#498 round-1 review MAJOR-2(b): the periodic-tick counterpart to
    `_reconcile_all`'s deferral above. For every root the one-time startup
    sweep skipped for ownership, re-check ownership on each tick; once it
    no longer blocks (the foreign owner went stale, or MAJOR-2(a)'s
    same-host-dead-pid check fires), run the FULL startup-class
    `_reconcile_root` on it -- exactly the pass it missed at boot -- and
    stop retrying it. Still blocked -> left in the set, tried again next
    tick. This is deliberately `_reconcile_root`, never
    `_reconcile_live_root`: the whole point is recovering the WIDER
    startup-class row set the periodic pass alone never covers.

    Round-2 review, advisory (a) (trace dedup): every root ever added here
    came from `_reconcile_all`'s own pass over the SAME `repos_getter()`
    list `_reconcile_live_all` walks every tick -- so a still-candidate
    root in this set is, by construction, ALSO re-checked by
    `_reconcile_live_all` on this exact same tick, which already emits its
    own `task.ownership_skip` if still blocked. Passing `traces_queue=None`
    here avoids a redundant second trace event for the identical skip
    decision on the identical root in the identical tick -- this function's
    own value is the RECONCILE it performs once unblocked, not a second
    copy of a trace another call site already emits."""
    for root in list(pending_startup_reconcile):
        conn = conns.get(root)
        if conn is None:
            pending_startup_reconcile.discard(root)  # should not happen -- defensive, never re-tried blind
            continue
        try:
            if _owner_blocks_reconciliation(conn, root, engine_id, owner_stale_seconds, None):
                continue  # still blocked -- retry next tick
            _reconcile_root(conn, root, resolvers, traces_queue)
            pending_startup_reconcile.discard(root)
        except Exception as exc:  # one root's deferred reconciliation failing must not block another's
            sys.stderr.write("tasks worker: deferred startup reconciliation failed for root %s: %s\n" % (root, exc))


def _reconcile_live_root(conn, root, resolvers, traces_queue):
    """AST-070 round-1 review MAJOR (issue #345): the PERIODIC twin of
    `_reconcile_root`, called repeatedly from `run_worker`'s drain loop
    instead of once at startup. See `_LIVE_RECONCILE_TARGET_STATES`'s own
    comment for why this selects a narrower row set (never a bare
    `queued` row) and reuses `_reconcile_row`'s exact per-outcome logic
    unchanged -- same never-resubmit guarantee, same trace events, just a
    different, safe-for-mid-loop candidate set."""
    placeholders = ", ".join("?" for _ in _LIVE_RECONCILE_TARGET_STATES)
    rows = conn.execute(
        "SELECT " + ", ".join(_SELECT_COLUMNS) + " FROM tasks WHERE state IN (" + placeholders + ") "
        "AND external_job_id IS NOT NULL",
        _LIVE_RECONCILE_TARGET_STATES,
    ).fetchall()
    for raw_row in rows:
        row = dict(zip(_SELECT_COLUMNS, raw_row))
        try:
            _reconcile_row(conn, root, row, resolvers, traces_queue)
        except Exception as exc:  # never let one row's reconciliation kill the pass
            sys.stderr.write("tasks worker: live reconciliation failed for task %s: %s\n" % (row.get("id"), exc))


def _reconcile_live_all(repos_getter, conns, resolvers, traces_queue, engine_id, owner_stale_seconds):
    """Periodic twin of `_reconcile_all` -- same broken-repos_getter and
    per-root failure isolation posture, called repeatedly instead of once.
    Same #498 ownership gate as `_reconcile_all` (see its docstring):
    never claims ownership itself, only reads it to decide whether to
    skip a root this tick."""
    try:
        repo_pairs = list(repos_getter())
    except Exception as exc:  # a broken repos_getter must not prevent the worker from continuing
        sys.stderr.write("tasks worker: live reconciliation could not list roots: %s\n" % exc)
        return
    for _repo_name, root in repo_pairs:
        try:
            if root not in conns:
                if not _is_reconcile_candidate(root):  # issue #497: never CREATE a db just to reconcile it
                    continue
                conns[root] = _open_conn(root)
            if _owner_blocks_reconciliation(conns[root], root, engine_id, owner_stale_seconds, traces_queue):
                continue  # #498: a different engine's heartbeat is still fresh -- not ours to touch this tick
            _reconcile_live_root(conns[root], root, resolvers, traces_queue)
        except Exception as exc:  # one root's reconciliation failing must not block another root's
            sys.stderr.write("tasks worker: live reconciliation failed for root %s: %s\n" % (root, exc))


def run_worker(q, stop_event, executors=None, poll_timeout=DEFAULT_POLL_TIMEOUT_SECONDS, traces_queue=None,
                repos_getter=None, resolvers=None, live_reconcile_interval=DEFAULT_LIVE_RECONCILE_INTERVAL_SECONDS,
                engine_id=None, owner_stale_seconds=None):
    """See module docstring's Library entry, "Execution model",
    "Restart reconciliation", and (#498) "Root ownership / heartbeat"
    sections. `repos_getter`/`resolvers` are both optional (default
    `None`/`{}`) so every existing caller/test that constructs this worker
    without them keeps working unchanged -- the same convention
    `traces_queue=None` already established. `repos_getter` omitted means
    reconciliation simply does not run (there is no way to know which
    roots to check without it) -- this also disables the periodic live
    re-check below, for the identical reason.

    `live_reconcile_interval` (AST-070 round-1 review MAJOR, issue #345):
    seconds between periodic `_reconcile_live_all` passes, checked once per
    drain-loop iteration (cheap: a monotonic-clock subtraction) so it never
    adds a second sleep/timer thread. `None` or `<= 0` disables it (same
    "falsy/absent means off" convention `repos_getter=None` already uses
    for the startup sweep) -- opt-in, existing callers that construct this
    worker without passing it keep the DEFAULT interval, but since
    `repos_getter` also defaults to `None`, no existing caller's behavior
    changes unless it ALREADY opted into `repos_getter` too.

    `engine_id` (#498): this process's identity for ownership claims --
    defaults to a fresh `uuid4().hex` (one per `run_worker` call, i.e. per
    process) when omitted, so two independent engines never collide on a
    shared id by accident. `owner_stale_seconds` defaults to
    `OWNER_STALE_MULTIPLIER * <effective live-reconcile interval>` (using
    `DEFAULT_LIVE_RECONCILE_INTERVAL_SECONDS` when periodic reconciliation
    is disabled, so the staleness window is always well-defined even then)
    -- see module docstring for the 3x justification. Both are ordinary
    keyword args, not `None`-means-"feature off" like `repos_getter`:
    ownership gating is always active once `repos_getter` is given, using
    whatever `engine_id` this call ends up with.

    Round-1 review MAJOR-1(b): while `repos_getter` is given, a background
    heartbeat-timer thread (`_run_heartbeat_timer`) runs for this call's
    entire lifetime, refreshing every currently-owned root on its own
    schedule -- independent of the main loop's own tick, which cannot fire
    while this thread is blocked inside a single long-running executor
    call. Joined (bounded) in `finally`, before this engine's owner rows
    are released below, so no refresh can race the handoff."""
    executors = executors or {}
    resolvers = resolvers or {}
    conns = {}
    owned = _OwnedRoots()
    if engine_id is None:
        engine_id = uuid.uuid4().hex
    effective_interval = (
        live_reconcile_interval if live_reconcile_interval and live_reconcile_interval > 0
        else DEFAULT_LIVE_RECONCILE_INTERVAL_SECONDS
    )
    if owner_stale_seconds is None:
        owner_stale_seconds = OWNER_STALE_MULTIPLIER * effective_interval
    pending_startup_reconcile = set()  # #498 MAJOR-2(b): roots the startup sweep deferred, see _reconcile_all
    heartbeat_timer_thread = None
    if repos_getter is not None:
        _reconcile_all(repos_getter, conns, resolvers, traces_queue, engine_id, owner_stale_seconds,
                        pending_startup_reconcile)
        heartbeat_timer_thread = threading.Thread(
            target=_run_heartbeat_timer,
            args=(stop_event, owned, engine_id, effective_interval),
            name="assistant-tasks-heartbeat-timer",
            daemon=True,
        )
        heartbeat_timer_thread.start()
    last_live_reconcile = time.monotonic()
    try:
        while not stop_event.is_set():
            try:
                item = q.get(timeout=poll_timeout)
            except queue_module.Empty:
                item = None
            if item is not None:
                try:
                    if isinstance(item, dict) and item.get("action") == "create":
                        _process_create(item, conns, executors, traces_queue, engine_id, owned, owner_stale_seconds)
                    else:
                        # ADVISORY 1 (round-2 review, issue #341): a non-dict
                        # item or an unrecognized action used to be silently
                        # dropped here with no trace at all -- symmetry with
                        # every other drop path in this module.
                        sys.stderr.write("tasks worker: skipping unrecognized queue item: %r\n" % (item,))
                except Exception as exc:  # park-and-continue -- never kill the worker thread
                    sys.stderr.write("tasks worker: item failed: %s\n" % exc)
            if repos_getter is not None and live_reconcile_interval and live_reconcile_interval > 0:
                now = time.monotonic()
                if now - last_live_reconcile >= live_reconcile_interval:
                    # #498: refresh THIS engine's already-owned roots' heartbeats
                    # before reconciling -- keeps an idle-but-owned root (no new
                    # drains, but still legitimately ours) from going stale.
                    # Cheap/common-case path; _run_heartbeat_timer above is the
                    # backstop for when this tick itself cannot fire (MAJOR-1b).
                    _refresh_owned_heartbeats(conns, owned, engine_id)
                    _reconcile_live_all(repos_getter, conns, resolvers, traces_queue, engine_id, owner_stale_seconds)
                    # #498 MAJOR-2(b): give any root the startup sweep deferred
                    # another chance now that ownership may have stopped blocking.
                    _retry_pending_startup_reconcile(conns, resolvers, traces_queue, engine_id, owner_stale_seconds,
                                                      pending_startup_reconcile)
                    last_live_reconcile = now
    finally:
        if heartbeat_timer_thread is not None:
            # #498 round-2 review: a bounded join alone is a genuine race --
            # a single in-flight _claim_ownership can legitimately block up
            # to `busy_timeout` (5s, `_open_conn`'s own pragma) waiting for
            # a lock, longer than a short bounded join would wait. If the
            # bounded join times out while that write is still in flight,
            # the timer thread can land it AFTER the owner-row deletion
            # below, resurrecting this engine's own row right after this
            # engine just tried to hand it off -- the opposite of advisory
            # (b)'s intent. The bounded join is still tried FIRST (the
            # overwhelmingly common case: nothing contended, exits fast);
            # the unconditional fallback below is what actually GUARANTEES
            # no write can ever land after the delete, not a probability --
            # sqlite's own busy_timeout bounds how long any single claim can
            # possibly block, so this can never hang forever either.
            heartbeat_timer_thread.join(timeout=3)
            if heartbeat_timer_thread.is_alive():
                heartbeat_timer_thread.join()
        for root, conn in conns.items():
            # #498 round-1 review advisory (b): a graceful shutdown releases
            # THIS engine's ownership immediately -- a departing engine's
            # heartbeat would otherwise sit "fresh" for the rest of the
            # staleness window, needlessly blocking a legitimate successor
            # (e.g. the same repo now routed to a different engine) even
            # though nobody crashed. `engine_id = ?` guards against ever
            # deleting a DIFFERENT engine's already-reclaimed row.
            try:
                conn.execute("BEGIN IMMEDIATE")
                conn.execute("DELETE FROM task_owner WHERE id = 1 AND engine_id = ?", (engine_id,))
                conn.execute("COMMIT")
            except Exception as exc:
                try:
                    conn.execute("ROLLBACK")
                except Exception:
                    pass
                sys.stderr.write("tasks worker: could not release ownership for root %s: %s\n" % (root, exc))
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


def get_task(root, task_id):
    """See module docstring's Library entry (AST-068, issue #343)."""
    path = _db_path(root)
    if not os.path.exists(path):
        return None
    conn = sqlite3.connect(path, timeout=5.0)
    try:
        conn.execute("PRAGMA busy_timeout=5000")
        sql = "SELECT " + ", ".join(_SELECT_COLUMNS) + " FROM tasks WHERE id = ?"
        try:
            row = conn.execute(sql, (task_id,)).fetchone()
        except sqlite3.OperationalError:
            return None  # same "no such table" degrade as list_tasks
    finally:
        conn.close()
    return _row_to_dict(row) if row is not None else None
