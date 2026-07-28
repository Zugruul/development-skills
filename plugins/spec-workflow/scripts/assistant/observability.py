"""Observability / traces subsystem (SPEC-ASSISTANT.md Sec5a, Sec10.1, Sec10.2,
Sec10.4, Sec10.6, Sec10.7, E4, AST-040/AST-042, issue #326/#328,
docs/design/ast-E4.md).

Per Sec10.1/Sec17.7 emitting an event is O(1) and NEVER blocks a turn: `emit`
below only puts an item on a `queue.Queue` (drop + stderr on overflow/failure,
the exact posture `engine.py`'s `_enqueue_distill` already uses for the
distiller, Sec9.5). Per Sec5a/Sec10.2 there is exactly ONE writer thread for
ALL assistants' traces -- the engine's existing `traces` worker slot
(AST-010's `WORKER_NAMES` registry) runs `run_writer` below instead of its v1
heartbeat no-op; per-root sqlite connections are opened and held ONLY by that
thread, so sqlite's single-writer discipline is respected without any
cross-thread handle ever existing.

`emit`/`run_writer` deliberately take the queue as an explicit argument
(`emit(q, root, event)`, not a hidden module-global `emit(root, event)`) --
this matches `distill.py`'s own `run_worker(q, stop_event, ...)` convention
(explicit queue in, no module-level engine singleton) and keeps this module
free of process-wide state a test would have to reset between runs. Callers
(engine.py's instrumentation call sites) pass `self.queues["traces"]`.

Schema (`events` table, one per-root `traces.sqlite`): `seq` (INTEGER,
writer-assigned, monotonic per root, seeded from `MAX(seq)` at open --
Sec10.1's "monotonic, not wall-clock-perfect" ordering requirement; emitters
stay lock-free because nothing but the writer thread ever assigns a seq),
`ts` (ISO-8601 UTC, stamped by `emit` at enqueue time -- the moment the event
actually happened, not when the writer got around to it), `session_id`,
`turn_id`, `span_id`, `parent_span_id` (Sec10.6: an error event links to its
turn via `turn_id`, and MAY carry its own `span_id`/`parent_span_id` like any
other event -- there is no separate error table), `kind` (dotted:
`turn.start`/`turn.end`/`recall.summary`/`provider.call`/`provider.error`/
`distill.batch`/...), `skill`, `modality`, `status`, and a `payload` JSON
column for everything that is not one of the indexed first-class columns.
Every first-class column is indexed so `query()`'s filters are always
index-backed -- Sec10.2 explicitly rules out `json_extract` for time-range/
correlation queries.

Durability (Sec10.7): traces are PRUNABLE history (a later AST-041 retention
pass may delete old rows) -- this module never treats `traces.sqlite` as a
must-survive file the way `store.py` treats `session.jsonl`. WAL mode + a
`busy_timeout` pragma on every connection mean a crash loses at most the
queued-not-yet-drained tail (already-committed rows survive); schema
creation is idempotent (`CREATE TABLE/INDEX IF NOT EXISTS`) so opening an
already-initialized `traces.sqlite` a second time is a no-op, never an
error.

`traces.sqlite` lives at `<root>/.claude/assistant/traces.sqlite` -- the SAME
directory `store.py`'s `session.jsonl`/`session-state.json` already use, and
that directory is ALREADY gitignored wholesale (`scripts/local-state.manifest`:
`ignore\t.claude/assistant/`, AST-005/AST-014) -- no new manifest entry is
needed for this file specifically; it falls under the existing directory
entry, and this docstring records that decision so a later reader does not
go looking for a missing per-file line.

Library:
    emit(q, root, event) -> None
        Enqueue-only; NEVER raises into the caller. `event` is a dict with at
        least `"kind"`; `session_id`/`turn_id`/`span_id`/`parent_span_id`/
        `skill`/`modality`/`status`/`payload` are optional (stored as NULL /
        `{}` when absent). `ts` is stamped here if the caller did not supply
        one.
    run_writer(q, stop_event, poll_timeout=..., max_drain=..., retention_config=None,
               prune_every_drains=..., prune_interval_seconds=...) -> None
        The `traces` worker loop body (engine.py's start() binds this into
        the AST-010 `traces` slot). Runs on its own thread only. AST-041:
        also runs the periodic retention prune pass (see `_prune_all`'s
        docstring) on this same thread, every `prune_every_drains` drain
        cycles OR every `prune_interval_seconds` wall-clock seconds,
        whichever comes first.
    query(root, since=None, turn=None, limit=200) -> list[dict]
        Read-only path for endpoints/terminal (AST-043/AST-045 consume
        this). `since` is a `seq` cursor (rows with `seq > since`), not a
        timestamp -- matches "resume after the last seq I've already seen"
        polling, and stays an indexed-integer-column comparison.
    prune(root, retain_days, max_mb) -> None
        AST-041 (SPEC-ASSISTANT.md Sec10.3): standalone retention pass for
        one root -- opens its own short-lived connection (see its
        docstring for why this differs from the writer thread's own
        internal `_prune_conn` call). `retain_days`/`max_mb` of `0` means
        that knob is unlimited (skipped).
    root_metrics(root) -> dict
        AST-043 (SPEC-ASSISTANT.md Sec10.5): one root's computed metrics as
        a JSON-ready dict -- the same numbers `metrics_text` renders in
        Prometheus text format, shaped for `GET /assistant/metrics`
        instead. See the function's own docstring for the exact shape.
    metrics_text(roots) -> str
        AST-042 (SPEC-ASSISTANT.md Sec10.4): Prometheus text-format 0.0.4
        exposition, computed FRESH from `query()` on every call -- never
        cached beyond one call, never a second history store (Sec10.4:
        "SHALL NOT own history"). `roots` is an iterable of `(label, root)`
        pairs (engine.py's `_metrics_roots_provider` supplies the currently
        enabled ones); see the function's own docstring for the exact
        counters/histogram rendered.
    start_metrics_server(host, port, roots_provider) -> (server, thread)
        AST-042: the stdlib-only (`http.server`, no `prometheus_client`)
        exposition server -- binds `(host, port)`, serves `GET /metrics` as
        `metrics_text(roots_provider())` computed per request. `roots_provider`
        is a zero-arg callable (mirrors `AssistantEngine.__init__`'s
        `repos_getter` convention) so the served root set can change across
        the server's lifetime without a restart. Returns the live
        `(server, thread)` pair so a caller can `server.shutdown()` then
        `thread.join(timeout=...)` for a bounded stop, the same posture
        `engine.py.stop()` already uses for every WORKER_NAMES thread.
"""
import http.server
import json
import os
import queue as queue_module
import sqlite3
import sys
import threading
import time
from datetime import datetime, timedelta, timezone

TRACES_DIR_REL = os.path.join(".claude", "assistant")  # same dir as store.py's SessionStore
TRACES_FILE_NAME = "traces.sqlite"

# How long run_writer's queue.get() blocks between stop_event checks -- same
# rationale as distill.py's DEFAULT_POLL_TIMEOUT_SECONDS: small enough that
# stop() (5s join timeout, engine.py) always observes the thread exit
# promptly, large enough that an idle writer does not spin.
DEFAULT_POLL_TIMEOUT_SECONDS = 0.5

# Bounds how many additional already-queued items one drain cycle will pull
# via get_nowait() after the first blocking get() succeeds -- batches a
# burst into one commit per root without letting a single drain run forever
# and starve stop_event checks under a truly enormous backlog.
DEFAULT_MAX_DRAIN = 500

# AST-041 (SPEC-ASSISTANT.md Sec10.3): retention defaults applied whenever a
# root's assistant.observability.traces config is absent or omits a knob.
DEFAULT_RETAIN_DAYS = 30
DEFAULT_MAX_MB = 500

# How often (in drain cycles, and in wall-clock seconds -- whichever comes
# first) run_writer's own loop runs a retention prune pass. Both are
# generous: retention is a background-hygiene concern, not a per-event one,
# so it rides the same thread's existing poll cadence instead of adding a
# dedicated timer/thread (Sec5a: single writer thread per subsystem).
DEFAULT_PRUNE_EVERY_DRAINS = 50
DEFAULT_PRUNE_INTERVAL_SECONDS = 300.0

# AST-041 size pass: rows deleted per chunk while trimming toward max_mb, and
# a hard cap on how many chunk-delete+re-measure iterations one prune pass
# will run (guards against spinning forever if max_mb is set below what the
# schema/index overhead alone occupies -- see `_prune_conn`'s docstring).
PRUNE_SIZE_CHUNK = 500
PRUNE_MAX_SIZE_ITERATIONS = 200

# AST-042 (SPEC-ASSISTANT.md Sec10.4, §6 example): defaults applied whenever
# a root's assistant.observability.metrics.prometheus config omits host/port
# -- localhost-only unless config EXPLICITLY says otherwise (§17 invariant
# 10), matching the spec's own worked example (127.0.0.1:9464).
DEFAULT_METRICS_HOST = "127.0.0.1"
DEFAULT_METRICS_PORT = 9464

# metrics_text() reads the WHOLE events table for a root (unlike query()'s
# endpoint-facing default of 200) -- it is computing exact counters/
# histograms, not paging a UI. This is a generous ceiling, not a real cap:
# traces.sqlite is retention-bounded (AST-041, default maxMB=500) so even
# the largest realistic root's event count stays far under it.
METRICS_QUERY_LIMIT = 2_000_000

# AST-042: turn-duration histogram bucket boundaries, in seconds (a "+Inf"
# bucket is always added on top of these, per the Prometheus text format's
# own convention for a histogram's last bucket). Chosen to span "fast text
# turn" through "slow/loaded turn" at a coarse-enough granularity that a
# handful of turns already produces a legible curve, without pretending to
# the precision a client library's runtime-configurable buckets would offer
# (this exposition is hand-rendered, stdlib-only -- see the module
# docstring's "no client library" decision).
LATENCY_BUCKETS_SECONDS = (0.1, 0.5, 1.0, 2.0, 5.0, 10.0, 30.0)

_COLUMNS = (
    "seq", "ts", "session_id", "turn_id", "span_id", "parent_span_id",
    "kind", "skill", "modality", "status", "payload",
)

_SCHEMA_DDL = (
    "CREATE TABLE IF NOT EXISTS events ("
    "seq INTEGER PRIMARY KEY, "
    "ts TEXT, "
    "session_id TEXT, "
    "turn_id TEXT, "
    "span_id TEXT, "
    "parent_span_id TEXT, "
    "kind TEXT, "
    "skill TEXT, "
    "modality TEXT, "
    "status TEXT, "
    "payload TEXT"
    ")"
)

_INDEX_DDL = [
    "CREATE INDEX IF NOT EXISTS ix_events_seq ON events(seq)",
    "CREATE INDEX IF NOT EXISTS ix_events_ts ON events(ts)",
    "CREATE INDEX IF NOT EXISTS ix_events_session_id ON events(session_id)",
    "CREATE INDEX IF NOT EXISTS ix_events_turn_id ON events(turn_id)",
    "CREATE INDEX IF NOT EXISTS ix_events_span_id ON events(span_id)",
    "CREATE INDEX IF NOT EXISTS ix_events_parent_span_id ON events(parent_span_id)",
    "CREATE INDEX IF NOT EXISTS ix_events_kind ON events(kind)",
    "CREATE INDEX IF NOT EXISTS ix_events_skill ON events(skill)",
    "CREATE INDEX IF NOT EXISTS ix_events_modality ON events(modality)",
    "CREATE INDEX IF NOT EXISTS ix_events_status ON events(status)",
]

_INSERT_SQL = (
    "INSERT INTO events (seq, ts, session_id, turn_id, span_id, "
    "parent_span_id, kind, skill, modality, status, payload) "
    "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
)


def _now_iso():
    return datetime.now(timezone.utc).isoformat()


def _db_path(root):
    return os.path.join(root, TRACES_DIR_REL, TRACES_FILE_NAME)


def emit(q, root, event):
    """Enqueue-only (Sec10.1/Sec17.7): never blocks, never raises into the
    caller. On a full or otherwise unusable queue this drops the event and
    writes a note to stderr -- the exact posture `engine.py`'s
    `_enqueue_distill` already uses for the distiller queue (design doc's
    "same posture as the distiller enqueue")."""
    try:
        ev = dict(event or {})
        ev.setdefault("ts", _now_iso())
        item = {"root": root, "event": ev}
        q.put_nowait(item)
    except queue_module.Full:
        sys.stderr.write(
            "observability: traces queue full, dropping event kind=%r\n"
            % (event or {}).get("kind")
        )
    except Exception as exc:  # never raise into a turn (Sec17.7)
        sys.stderr.write("observability: emit failed: %s\n" % exc)


def _open_conn(root):
    """Opens (and idempotently schema-creates) the ONE connection this
    writer thread will hold for `root`. WAL + busy_timeout so a slow reader
    never blocks this thread and this thread's writes never corrupt a
    concurrent read-only reader (Sec10.2)."""
    path = _db_path(root)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    conn = sqlite3.connect(path, timeout=5.0, isolation_level=None)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=5000")
    conn.execute(_SCHEMA_DDL)
    for ddl in _INDEX_DDL:
        conn.execute(ddl)
    row = conn.execute("SELECT MAX(seq) FROM events").fetchone()
    next_seq = (row[0] or 0) + 1
    return conn, next_seq


def _bucket(buffers, item):
    if not isinstance(item, dict):
        return
    root = item.get("root")
    event = item.get("event")
    if not root or not isinstance(event, dict) or "kind" not in event:
        return
    buffers.setdefault(root, []).append(event)


def _flush(conns, buffers):
    for root, events in buffers.items():
        if not events:
            continue
        try:
            if root not in conns:
                conns[root] = _open_conn(root)
            conn, next_seq = conns[root]
            rows = []
            for ev in events:
                try:
                    payload_json = json.dumps(ev.get("payload") or {}, sort_keys=True)
                except (TypeError, ValueError) as exc:
                    # issue #390: a single non-serializable payload must not
                    # roll back this root's WHOLE drain -- degrade THIS
                    # event to a marker payload (still inserted, still
                    # linked via its own turn_id/span_id/kind) and log once,
                    # rather than letting json.dumps raise out of this
                    # row-building loop and lose every other event in the
                    # same batch (the #390 bug: raising here happens BEFORE
                    # any DB write for this root, so `except Exception`
                    # below caught it and the entire batch -- good events
                    # included -- was silently dropped).
                    sys.stderr.write(
                        "observability writer: unserializable payload for %s "
                        "kind=%r, degrading to a marker event: %s\n"
                        % (root, ev.get("kind"), exc)
                    )
                    payload_json = json.dumps({"_payload_error": str(exc)})
                rows.append((
                    next_seq,
                    ev.get("ts") or _now_iso(),
                    ev.get("session_id"),
                    ev.get("turn_id"),
                    ev.get("span_id"),
                    ev.get("parent_span_id"),
                    ev.get("kind"),
                    ev.get("skill"),
                    ev.get("modality"),
                    ev.get("status"),
                    payload_json,
                ))
                next_seq += 1
            conn.execute("BEGIN IMMEDIATE")
            conn.executemany(_INSERT_SQL, rows)
            conn.execute("COMMIT")
            conns[root] = (conn, next_seq)
        except Exception as exc:  # park-and-continue -- never kill the writer thread
            try:
                conn.execute("ROLLBACK")
            except Exception:
                pass
            sys.stderr.write("observability writer: batch failed for %s: %s\n" % (root, exc))


def _resolve_retention(root, retention_config):
    """Per-root (retain_days, max_mb) pair (SPEC-ASSISTANT.md Sec10.3),
    defaulting to 30/500 whenever `retention_config` is None, raises, or
    returns a mapping missing/mis-typed either key -- "absent/disabled
    config" resolves to the spec's defaults, never to skipping retention
    outright. `retention_config` is a `root -> dict|None` callable (engine.py
    supplies `AssistantEngine._retention_config_for`, reading
    `assistant.observability.traces` off the root's project.yaml); it is
    called defensively since it may re-parse config on every call."""
    cfg = None
    if retention_config is not None:
        try:
            cfg = retention_config(root)
        except Exception:
            cfg = None
    cfg = cfg or {}

    def _int_or_default(value, default):
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            return default
        return value

    retain_days = _int_or_default(cfg.get("retainDays", DEFAULT_RETAIN_DAYS), DEFAULT_RETAIN_DAYS)
    max_mb = _int_or_default(cfg.get("maxMB", DEFAULT_MAX_MB), DEFAULT_MAX_MB)
    return retain_days, max_mb


def _prune_conn(conn, root, retain_days, max_mb):
    """Core retention pass (SPEC-ASSISTANT.md Sec10.3) against an ALREADY
    OPEN connection for `root` -- never opens or closes a connection itself,
    so it is safe to call from the writer thread against a connection it
    already holds (Sec10.2 single-writer discipline: no second connection to
    the same file is ever opened while the writer thread is running).

    Age pass (retain_days > 0): one DELETE of every row with `ts` older than
    `now - retain_days` -- cheap, index-backed (`ix_events_ts`), oldest rows
    only.

    Size pass (max_mb > 0): measures ACTUAL on-disk bytes (`os.path.getsize`
    after a `VACUUM`), not `PRAGMA page_count` -- a bare DELETE leaves freed
    pages on sqlite's internal freelist without shrinking the file, so
    page_count alone would never reflect a size reduction. A full `VACUUM`
    per prune pass is acceptable at these sizes (retention runs at most every
    `DEFAULT_PRUNE_INTERVAL_SECONDS`/`DEFAULT_PRUNE_EVERY_DRAINS`, on
    traces.sqlite files that are, by construction, capped at `max_mb`
    megabytes) and keeps the measurement exact rather than approximate. When
    over budget, the oldest `PRUNE_SIZE_CHUNK` rows (by `seq`, index-backed
    via `ix_events_seq`) are deleted -- as a plain ordered SELECT followed
    by a `seq <= boundary` DELETE, deliberately NOT a single self-
    referencing `DELETE ... WHERE seq IN (SELECT ... FROM events ...)`
    statement (#420: that form's oldest-first guarantee depends on the
    query planner materializing its own subquery before the delete begins,
    which is not something every SQLite build makes identically -- it held
    on every machine that ran this locally and broke on CI's) -- and the
    loop re-VACUUMs to re-measure; this repeats until under budget, the
    table is empty (nothing left to delete -- schema/index overhead alone
    may exceed max_mb, which is not an error), or
    `PRUNE_MAX_SIZE_ITERATIONS` is hit as a safety bound.

    Both passes run under `retain_days == 0` / `max_mb == 0` guards (0 =
    unlimited per Sec10.3) so a caller with both knobs at 0 does zero work
    -- not even a VACUUM.
    """
    if retain_days > 0:
        cutoff = (datetime.now(timezone.utc) - timedelta(days=retain_days)).isoformat()
        conn.execute("BEGIN IMMEDIATE")
        conn.execute("DELETE FROM events WHERE ts < ?", (cutoff,))
        conn.execute("COMMIT")

    if max_mb <= 0:
        return

    path = _db_path(root)
    max_bytes = max_mb * 1024 * 1024
    for _ in range(PRUNE_MAX_SIZE_ITERATIONS):
        conn.execute("VACUUM")
        try:
            size = os.path.getsize(path)
        except OSError:
            size = 0
        if size <= max_bytes:
            return
        # #420: this used to be one self-referencing statement -- a DELETE
        # against `events` whose own WHERE clause named a `seq IN (...)`
        # membership test, with the parenthesized subquery itself
        # SELECT-ing `seq` back out of that same `events` table, ordered
        # and limited -- querying and deleting from the SAME table in one
        # statement. SQL semantics require the subquery's own ORDER BY
        # LIMIT to be fully evaluated before the outer DELETE begins, but
        # that materialization is a query-planner choice, not something the
        # language guarantees identically across every SQLite build --
        # this repo's CI runner (Ubuntu, its own libsqlite3) picked a
        # different plan than every machine that ran this test locally
        # (macOS, Homebrew's libsqlite3) and the oldest-first invariant
        # broke there while every other assertion (row count, size budget)
        # still passed. Split into two steps that need no planner
        # cooperation to be correct: read the target seq values as a plain,
        # ordinary SELECT (no self-reference -- nothing is being deleted
        # yet), then delete by an explicit `seq <= boundary` bound computed
        # in Python from that already-materialized result. `seq` values
        # already present are always the exact set >0 rows (possibly with
        # gaps from earlier prune passes), so "every currently-present row
        # with seq <= the fetched chunk's own max" is, by construction,
        # exactly that fetched chunk -- nothing smaller could exist outside
        # it, nothing larger could sneak in under the same bound. Also
        # drops the `cur.rowcount` read after `executemany`-shaped deletes
        # elsewhere in this codebase have already needed workarounds for --
        # Python's sqlite3 module has never guaranteed a specific rowcount
        # value here across versions either; counting the materialized list
        # in Python needs no such guarantee.
        chunk = conn.execute(
            "SELECT seq FROM events ORDER BY seq ASC LIMIT ?", (PRUNE_SIZE_CHUNK,)
        ).fetchall()
        if not chunk:
            return  # table is already empty -- nothing left to trim
        boundary = chunk[-1][0]
        conn.execute("BEGIN IMMEDIATE")
        conn.execute("DELETE FROM events WHERE seq <= ?", (boundary,))
        conn.execute("COMMIT")


def _prune_all(conns, retention_config):
    """Runs `_prune_conn` for every root the writer thread currently holds a
    connection open for (`conns`, `run_writer`'s own dict). Deliberately
    scoped to already-open connections rather than discovering every root
    with a traces.sqlite on disk -- this keeps the writer thread decoupled
    from repo enumeration (that is the engine's job, e.g. `_status`'s
    `discovery.scan`) and only ever touches a root it has already opened at
    least once via a real emitted event, matching the "one writer thread,
    per-root connections held by that thread only" decision (design doc).
    Never lets one root's prune failure stop another's (park-and-continue,
    matching `_flush`'s own posture)."""
    for root, (conn, _next_seq) in list(conns.items()):
        try:
            retain_days, max_mb = _resolve_retention(root, retention_config)
            if retain_days == 0 and max_mb == 0:
                continue
            _prune_conn(conn, root, retain_days, max_mb)
        except Exception as exc:  # park-and-continue -- never kill the writer thread
            try:
                conn.execute("ROLLBACK")
            except Exception:
                pass
            sys.stderr.write("observability writer: prune failed for %s: %s\n" % (root, exc))


def prune(root, retain_days, max_mb):
    """Public/standalone entry point (AST-041's `prune(root, retain_days,
    max_mb)` contract): opens its OWN short-lived connection for `root` via
    `_open_conn` (idempotent schema create, same as the writer), runs
    `_prune_conn`, and closes it. Intended for callers OTHER than the
    writer thread itself -- tests, and any offline/administrative caller --
    since it is only safe to open a connection to `root` this way when the
    writer thread is not concurrently holding its own connection open for
    the same root (Sec10.2 single-writer discipline). `run_writer`'s own
    periodic pass calls `_prune_conn` directly against the connection it
    already holds instead of calling this function, for exactly that
    reason."""
    if retain_days <= 0 and max_mb <= 0:
        return
    conn, _next_seq = _open_conn(root)
    try:
        _prune_conn(conn, root, retain_days, max_mb)
    finally:
        conn.close()


def run_writer(q, stop_event, poll_timeout=DEFAULT_POLL_TIMEOUT_SECONDS,
                max_drain=DEFAULT_MAX_DRAIN, retention_config=None,
                prune_every_drains=DEFAULT_PRUNE_EVERY_DRAINS,
                prune_interval_seconds=DEFAULT_PRUNE_INTERVAL_SECONDS):
    """The `traces` worker body engine.py's `start()` binds into the
    AST-010 `traces` slot, replacing the v1 heartbeat no-op. Drains `q` for
    items shaped `{"root": str, "event": dict}` (this module's `emit`),
    buffers PER ROOT within one drain cycle, and commits once per root per
    cycle (`executemany` -- Sec5a "batched commits").

    Runs entirely on ITS OWN thread: the per-root sqlite connections this
    function opens are NEVER touched by any other thread (Sec10.2's single-
    writer discipline). `q.get(timeout=poll_timeout)` bounds how long the
    loop can go without checking `stop_event`, so `engine.stop()`'s bounded
    join always succeeds promptly.

    Shutdown (bounded drain): once `stop_event` is set and the loop exits,
    whatever is STILL queued (never blocking -- `get_nowait` only) is
    drained and flushed once more before every held connection is closed --
    a crash loses at most the never-drained tail; an orderly stop() loses
    nothing already enqueued.

    Retention (AST-041, Sec10.3): after every drain+flush cycle, once
    `prune_every_drains` cycles have passed OR `prune_interval_seconds` of
    wall-clock time has elapsed (whichever comes first), this SAME thread
    runs `_prune_all(conns, retention_config)` -- a prune pass is just
    another thing this single writer thread does between polls, never a
    separate thread/timer. `retention_config` is a `root -> dict|None`
    callable (engine.py wires `AssistantEngine._retention_config_for`); see
    `_resolve_retention` for the absent/disabled-config default (30/500).
    """
    conns = {}
    drains_since_prune = 0
    last_prune = time.monotonic()
    try:
        while not stop_event.is_set():
            try:
                item = q.get(timeout=poll_timeout)
            except queue_module.Empty:
                continue
            buffers = {}
            _bucket(buffers, item)
            q.task_done()
            for _ in range(max_drain - 1):
                try:
                    item = q.get_nowait()
                except queue_module.Empty:
                    break
                _bucket(buffers, item)
                q.task_done()
            _flush(conns, buffers)
            drains_since_prune += 1
            now = time.monotonic()
            if (drains_since_prune >= prune_every_drains
                    or (now - last_prune) >= prune_interval_seconds):
                _prune_all(conns, retention_config)
                drains_since_prune = 0
                last_prune = now
    finally:
        drained = {}
        while True:
            try:
                item = q.get_nowait()
            except queue_module.Empty:
                break
            _bucket(drained, item)
            q.task_done()
        if drained:
            _flush(conns, drained)
        for conn, _next_seq in conns.values():
            try:
                conn.close()
            except Exception:
                pass


def query(root, since=None, turn=None, limit=200, order="asc"):
    """Read path for endpoints/terminal (AST-043/AST-045). Opens a fresh
    read-only connection per call (this is a low-frequency, low-volume read
    path -- unlike the writer, no connection is held across calls). Returns
    `[]` (never raises) when `root` has no `traces.sqlite` yet -- a fresh
    assistant with no turns run is not an error.

    `since` filters to `seq > since` (a resume cursor, NOT a timestamp --
    see the module docstring); `turn` filters to `turn_id == turn`. Both
    filters, and the default ordering, are backed by the `seq`/`turn_id`
    indexes `_open_conn` creates -- never a `json_extract` scan (Sec10.2).

    `order` is `"asc"` (default, back-compat: every caller that predates
    #393 gets the exact same oldest-first rows it always did) or `"desc"`.
    `"desc"` runs the SQL query itself as `ORDER BY seq DESC LIMIT ?` --
    still index-backed -- so a `LIMIT` actually caps at the NEWEST `limit`
    rows rather than the oldest (the #393 bug: an oldest-first LIMIT on a
    root with more than `limit` events silently drops everything recent).
    The rows are then re-sorted ascending in Python before being returned,
    so every consumer of this function's return value keeps seeing
    seq-ascending order regardless of which direction was actually queried
    -- `order` only changes WHICH `limit` rows come back, never the shape
    callers see them in."""
    path = _db_path(root)
    if not os.path.exists(path):
        return []

    uri = "file:%s?mode=ro" % path.replace("?", "%3F").replace("#", "%23")
    conn = sqlite3.connect(uri, uri=True, timeout=5.0)
    try:
        conn.execute("PRAGMA busy_timeout=5000")
        clauses = []
        params = []
        if since is not None:
            clauses.append("seq > ?")
            params.append(since)
        if turn is not None:
            clauses.append("turn_id = ?")
            params.append(turn)
        where = ("WHERE " + " AND ".join(clauses)) if clauses else ""
        sql_order = "DESC" if order == "desc" else "ASC"
        sql = (
            "SELECT %s FROM events %s ORDER BY seq %s LIMIT ?"
            % (", ".join(_COLUMNS), where, sql_order)
        )
        params.append(limit)
        try:
            rows = conn.execute(sql, params).fetchall()
        except sqlite3.OperationalError as exc:
            # The writer's `sqlite3.connect(path)` creates the file's header
            # on disk before its own schema DDL runs (a real, if narrow,
            # window) -- a reader that opens in that window sees a file
            # that EXISTS but has no `events` table yet. That is exactly
            # equivalent to "no events for this root yet" from a caller's
            # perspective, not an error -- never raise, return no rows.
            if "no such table" not in str(exc):
                raise
            rows = []
    finally:
        conn.close()

    if order == "desc":
        # The SQL above fetched the NEWEST `limit` rows (DESC LIMIT) --
        # re-sort ascending here so every caller of `query()` keeps seeing
        # seq-ascending order regardless of `order` (see this function's
        # own docstring for why: `order` only changes which window of rows
        # is selected, never the shape callers iterate).
        rows = sorted(rows, key=lambda row: row[0])

    out = []
    for row in rows:
        rec = dict(zip(_COLUMNS, row))
        try:
            rec["payload"] = json.loads(rec["payload"]) if rec["payload"] else {}
        except ValueError:
            rec["payload"] = {}
        out.append(rec)
    return out


def _family(kind):
    """The dotted kind's first segment ("turn.end" -> "turn"), or
    "unknown" for a falsy/malformed kind -- `events_total`'s label
    (Sec10.1's "kind (dotted: ...)" convention, generalized to a coarse
    per-subsystem count rather than one time series per exact kind
    string)."""
    return (kind or "").split(".", 1)[0] or "unknown"


def _parse_ts(ts):
    """Parses one of THIS module's own `ts` strings (always
    `datetime.now(timezone.utc).isoformat()`-shaped, see `_now_iso`) back
    into a `datetime`. Never raises into `_compute_root_metrics` --
    returns `None` on anything malformed (a hand-edited/foreign row),
    which that caller treats as "this turn's duration is unknown", not a
    crash."""
    try:
        return datetime.fromisoformat(ts)
    except (TypeError, ValueError):
        return None


def _compute_root_metrics(root):
    """One root's raw counters/durations, read fresh off `query()` --
    Sec10.4's "SHALL NOT own history": every number here is derived from
    `traces.sqlite` at call time, nothing is retained across calls.

    `turn_starts` only ever holds a `turn_id` from `turn.start` up until
    ITS OWN matching `turn.end` is seen (each is popped on match) --
    `query()`'s rows are already `seq`-ordered (arrival order, Sec10.1),
    so a `turn.end` always finds its `turn.start` already buffered when
    the pair completed cleanly. A `turn.end` with no matching start
    (buffer expired... which cannot happen here since nothing is ever
    dropped from `turn_starts` except by a match) or a `turn.start` that
    never gets a `turn.end` (an in-flight or abandoned turn at scrape
    time) simply contributes no duration sample -- never a crash, never a
    fabricated number.
    """
    events = query(root, limit=METRICS_QUERY_LIMIT)
    turns_by_status = {}
    provider_errors = 0
    events_total = {}
    distill_batches = 0
    notes_minted = 0
    turn_starts = {}
    durations = []

    for ev in events:
        kind = ev.get("kind") or ""
        events_total[_family(kind)] = events_total.get(_family(kind), 0) + 1

        if kind == "turn.start":
            turn_id = ev.get("turn_id")
            if turn_id:
                turn_starts[turn_id] = ev.get("ts")
        elif kind == "turn.end":
            status = ev.get("status") or "unknown"
            turns_by_status[status] = turns_by_status.get(status, 0) + 1
            turn_id = ev.get("turn_id")
            start_ts = turn_starts.pop(turn_id, None) if turn_id else None
            if start_ts is not None:
                start = _parse_ts(start_ts)
                end = _parse_ts(ev.get("ts"))
                if start is not None and end is not None:
                    duration = (end - start).total_seconds()
                    if duration >= 0:
                        durations.append(duration)
        elif kind == "provider.error":
            provider_errors += 1
        elif kind == "distill.batch":
            distill_batches += 1
            minted = (ev.get("payload") or {}).get("minted") or []
            notes_minted += len(minted)

    return {
        "turns_by_status": turns_by_status,
        "provider_errors": provider_errors,
        "events_total": events_total,
        "distill_batches": distill_batches,
        "notes_minted": notes_minted,
        "durations": durations,
    }


def _histogram(durations):
    """Cumulative bucket counts (Prometheus's own histogram convention --
    each `le` bucket counts every sample <= that boundary, so buckets are
    non-decreasing as `le` grows) over `LATENCY_BUCKETS_SECONDS`, plus the
    overall sum and count `_sum`/`_count` samples require. Returns
    `(buckets_dict, total_sum, count)`; `buckets_dict` does NOT include the
    "+Inf" bucket -- callers append it themselves as `count` (every sample
    is <= +Inf by definition, so it is always exactly the total)."""
    buckets = {b: 0 for b in LATENCY_BUCKETS_SECONDS}
    total = 0.0
    count = 0
    for d in durations:
        total += d
        count += 1
        for b in LATENCY_BUCKETS_SECONDS:
            if d <= b:
                buckets[b] += 1
    return buckets, total, count


def _escape_label_value(value):
    """Prometheus text-format 0.0.4 label-value escaping: backslash, then
    double-quote, then newline (backslash MUST go first or a value
    containing a literal backslash would have its own escaping doubled up
    again by the later replacements)."""
    value = str(value)
    value = value.replace("\\", "\\\\")
    value = value.replace('"', '\\"')
    value = value.replace("\n", "\\n")
    return value


def _fmt_num(n):
    """Renders a counter/bucket/sum value the way Prometheus's text format
    expects: plain integers stay bare ("5", not "5.0"); floats print
    without a trailing ".0" for whole numbers and without noisy float
    artifacts otherwise (`repr`'s round-trippable digits, trimmed of
    trailing zeros then a trailing dot)."""
    if isinstance(n, bool):
        return "1" if n else "0"
    if isinstance(n, int):
        return str(n)
    if n == int(n):
        return str(int(n))
    text = repr(float(n))
    if "e" in text or "E" in text:
        return text
    return text.rstrip("0").rstrip(".")


def root_metrics(root):
    """AST-043 (SPEC-ASSISTANT.md Sec10.5, issue #329): one root's computed
    metrics as a JSON-ready dict -- `GET /assistant/metrics`'s per-root
    value, and the page/terminal's read surface for the exact same numbers
    `metrics_text` renders in Prometheus text format (same
    `_compute_root_metrics`/`_histogram` computation, just shaped as JSON
    instead of exposition lines). Computed FRESH from `query()` on every
    call, same as `metrics_text` -- Sec10.4's "SHALL NOT own history"
    applies here too. A root with no `traces.sqlite` yet returns all-zero
    counters (never an error): `_compute_root_metrics` already returns
    empty dicts/an empty duration list for a root `query()` finds nothing
    for.

    Shape: `{turnsByStatus, providerErrors, eventsTotal, distillBatches,
    notesMinted, turnDuration: {count, sum, buckets}}` -- `buckets` maps
    each `LATENCY_BUCKETS_SECONDS` boundary (stringified, plus "+Inf") to
    its cumulative sample count, mirroring the histogram's Prometheus
    rendering without the text-format's own bucket-per-line shape.
    """
    stats = _compute_root_metrics(root)
    buckets, total, count = _histogram(stats["durations"])
    bucket_map = {_fmt_num(b): buckets[b] for b in LATENCY_BUCKETS_SECONDS}
    bucket_map["+Inf"] = count
    return {
        "turnsByStatus": dict(stats["turns_by_status"]),
        "providerErrors": stats["provider_errors"],
        "eventsTotal": dict(stats["events_total"]),
        "distillBatches": stats["distill_batches"],
        "notesMinted": stats["notes_minted"],
        "turnDuration": {"count": count, "sum": total, "buckets": bucket_map},
    }


def metrics_text(roots):
    """AST-042 (SPEC-ASSISTANT.md Sec10.4, docs/design/ast-E4.md): Prometheus
    text-format 0.0.4 exposition, hand-rendered (stdlib only, no
    `prometheus_client`) and computed FRESH from each root's traces.sqlite
    on every call via `query()`/`_compute_root_metrics` -- pure and
    deterministic given the db's current contents; nothing here is a
    second history store (Sec10.4: "SHALL NOT own history"), so calling
    this twice with new events written in between simply reflects them,
    with no caching/staleness window of any kind.

    `roots` is an iterable of `(label, root)` pairs -- AST-042's v1
    multi-root decision (design doc) is that every currently-enabled root
    shares ONE exposition server (bound on the first-configured root's
    host/port), so every sample below carries a `root="<label>"` label to
    disambiguate which assistant it belongs to on a shared scrape. A
    single-root caller just passes a one-element list. `label` is
    whatever the caller chooses (engine.py uses the assistant's main
    name); this function only escapes and renders it, never resolves it.

    Metrics emitted, each with its own `# HELP`/`# TYPE` pair (the
    Prometheus text-format lint AST-042's tests check for) rendered ONCE
    per metric name ahead of every root's samples for it, per the format's
    own convention that a metric name is declared once, not once per
    label combination:

      assistant_turns_total{root,status}            counter
      assistant_provider_errors_total{root}          counter
      assistant_events_total{root,kind}              counter (kind = the
          dotted event kind's first segment, e.g. "turn", "recall",
          "provider", "distill" -- see `_family`)
      assistant_distill_batches_total{root}          counter
      assistant_notes_minted_total{root}             counter
      assistant_turn_duration_seconds{root,le}       histogram (turn.start
          -> turn.end pairs, bucketed per `LATENCY_BUCKETS_SECONDS`)
    """
    root_list = list(roots)
    per_root = [(label, _compute_root_metrics(root)) for label, root in root_list]
    lines = []

    lines.append("# HELP assistant_turns_total Total number of completed turns, by status.")
    lines.append("# TYPE assistant_turns_total counter")
    for label, stats in per_root:
        for status, n in sorted(stats["turns_by_status"].items()):
            lines.append(
                'assistant_turns_total{root="%s",status="%s"} %s'
                % (_escape_label_value(label), _escape_label_value(status), _fmt_num(n))
            )

    lines.append("# HELP assistant_provider_errors_total Total number of provider errors.")
    lines.append("# TYPE assistant_provider_errors_total counter")
    for label, stats in per_root:
        lines.append(
            'assistant_provider_errors_total{root="%s"} %s'
            % (_escape_label_value(label), _fmt_num(stats["provider_errors"]))
        )

    lines.append("# HELP assistant_events_total Total number of trace events, by kind family.")
    lines.append("# TYPE assistant_events_total counter")
    for label, stats in per_root:
        for kind, n in sorted(stats["events_total"].items()):
            lines.append(
                'assistant_events_total{root="%s",kind="%s"} %s'
                % (_escape_label_value(label), _escape_label_value(kind), _fmt_num(n))
            )

    lines.append("# HELP assistant_distill_batches_total Total number of distiller batches processed.")
    lines.append("# TYPE assistant_distill_batches_total counter")
    for label, stats in per_root:
        lines.append(
            'assistant_distill_batches_total{root="%s"} %s'
            % (_escape_label_value(label), _fmt_num(stats["distill_batches"]))
        )

    lines.append("# HELP assistant_notes_minted_total Total number of notes minted by the distiller.")
    lines.append("# TYPE assistant_notes_minted_total counter")
    for label, stats in per_root:
        lines.append(
            'assistant_notes_minted_total{root="%s"} %s'
            % (_escape_label_value(label), _fmt_num(stats["notes_minted"]))
        )

    lines.append("# HELP assistant_turn_duration_seconds Turn duration in seconds (turn.start to turn.end).")
    lines.append("# TYPE assistant_turn_duration_seconds histogram")
    for label, stats in per_root:
        buckets, total, count = _histogram(stats["durations"])
        for b in LATENCY_BUCKETS_SECONDS:
            lines.append(
                'assistant_turn_duration_seconds_bucket{root="%s",le="%s"} %s'
                % (_escape_label_value(label), _fmt_num(b), _fmt_num(buckets[b]))
            )
        lines.append(
            'assistant_turn_duration_seconds_bucket{root="%s",le="+Inf"} %s'
            % (_escape_label_value(label), _fmt_num(count))
        )
        lines.append(
            'assistant_turn_duration_seconds_sum{root="%s"} %s'
            % (_escape_label_value(label), _fmt_num(total))
        )
        lines.append(
            'assistant_turn_duration_seconds_count{root="%s"} %s'
            % (_escape_label_value(label), _fmt_num(count))
        )

    return "\n".join(lines) + "\n"


class _MetricsHandler(http.server.BaseHTTPRequestHandler):
    """AST-042: the exposition server's only route, `GET /metrics`. Kept
    minimal on purpose -- this is not a general-purpose HTTP surface, it is
    one computed text blob per request."""

    def log_message(self, format, *args):  # noqa: A002 (stdlib's own param name)
        # Silence BaseHTTPRequestHandler's default per-request stderr
        # logging -- a scrape loop hitting this every few seconds would
        # otherwise spam every assistant process's stderr, unlike every
        # other worker thread in this module (writer/prune), which is
        # already silent on the happy path.
        pass

    def do_GET(self):
        if self.path != "/metrics":
            self.send_response(404)
            self.end_headers()
            return
        body = metrics_text(self.server.roots_provider()).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class _MetricsHTTPServer(http.server.HTTPServer):
    """`allow_reuse_address` so a just-stopped server's port is immediately
    rebindable (matters for tests cycling start/stop against the same
    port far more than for a real long-lived process, but costs nothing
    either way)."""
    allow_reuse_address = True


def start_metrics_server(host, port, roots_provider):
    """AST-042 (SPEC-ASSISTANT.md Sec10.4): starts the shared Prometheus
    exposition server bound to `(host, port)` -- a bare `socket.bind` (via
    `http.server.HTTPServer`) is what enforces the "localhost by default"
    invariant in practice: this function does not itself default or
    validate `host`/`port` (that is engine.py's `_metrics_config_for`/
    `_discover_metrics_configs`' job, mirroring the
    `_resolve_retention`/`_retention_config_for` split in this same
    module), it just binds exactly what it is given -- a non-loopback
    `host` reaching here is the caller's/config's explicit choice, not
    something this function decides.

    Runs `serve_forever()` on its OWN daemon-free thread (matching every
    other WORKER_NAMES thread's `daemon=False` -- an explicit `stop()` is
    always required, never relying on process-exit cleanup) so an
    in-flight scrape is never torn down mid-response.

    Returns `(server, thread)`. To stop: `server.shutdown()` (unblocks
    `serve_forever`'s loop) then `thread.join(timeout=...)` then, once
    joined, `server.server_close()` to release the listening socket --
    the exact three-step sequence `engine.py.stop()` performs for this
    slot, the HTTP-server analogue of every other worker's
    `stop_event.set()` + bounded `join()`.
    """
    server = _MetricsHTTPServer((host, port), _MetricsHandler)
    server.roots_provider = roots_provider
    thread = threading.Thread(
        target=server.serve_forever,
        name="assistant-metrics",
        daemon=False,
    )
    thread.start()
    return server, thread
