# Design — ast/E4: Observability — traces, metrics, inspector
Grounded in: SPEC-ASSISTANT.md §10.1–§10.7 (event stream, traces.sqlite, retention, Prometheus, surfaces, error events, durability classes), §5a (single writer thread per subsystem), §17 invariants 7 (turns never block), 8 (traces never committed to git), 10 (localhost only).

## Components (epic-wide)
- `assistant/observability.py` — grows from stub: event emitter API + the traces writer the engine's existing `traces` worker slot runs. Emit is enqueue-only (O(1), never blocks a turn, §10.1/§17.7); the worker is the SINGLE writer thread (§10.2).
- `traces.sqlite` — per-assistant, under `<root>/.claude/assistant/traces.sqlite` (local state, gitignored via the manifest — never committed, §17.8). Append-only `events` table, WAL mode, busy_timeout; INDEXED first-class columns (seq, ts, session_id, turn_id, span_id, parent_span_id, kind, skill, modality, status) + JSON payload column — time-range/correlation queries never json_extract (§10.2).
- `engine.py` — instrumentation call sites: turn.*, recall.*, prompt.*, provider.*, distill.* events (skill./task./tts./stt. arrive with their epics); AST-024's digest swaps its task source to traces once task events exist (E6) — notes/exchanges may swap earlier if cheap.
- Retention (AST-041): prune by retainDays AND maxMB (0 = unlimited), oldest first, config from assistant.observability.traces (§10.3; defaults 30/500).
- Prometheus (AST-042): exposition endpoint per assistant.observability.metrics config (host/port/enabled) serving COMPUTED histograms/counters; never owns history (§10.4). stdlib-only text exposition — no client library.
- Endpoints (AST-043): /assistant/metrics + /assistant/traces?since=&turn= query sqlite directly (§10.5).
- Voice-panel graphs + waterfall (AST-044), terminal commands (AST-045) — read-only consumers of the same queries.

## Data models
Event: {seq monotonic per assistant (writer-assigned), ts ISO-8601 UTC, session_id, turn_id, span_id, parent_span_id, kind (dotted: turn.start/turn.end/recall.hit/provider.call/provider.error/distill.batch...), skill, modality, status, payload JSON incl. said/heard text where applicable (§10.1)}. Errors are first-class events linked from their turn (§10.6).

## Interfaces / contracts
- `observability.emit(root, event_dict)` → enqueue-only; never raises into the caller (drop + stderr on full/closed queue, same posture as the distiller enqueue).
- `observability.run_writer(queue, stop_event)` — the traces worker loop: opens one connection per root lazily, WAL, single-writer discipline, batched commits (executemany per drain), bounded shutdown drain.
- `observability.query(root, since=None, turn=None, limit=...)` — read path for endpoints/terminal; opens read-only connections; index-backed filters only.
- Durability classes (§10.7): traces = prunable history (retention may delete); embeddings index = rebuildable; tasks.sqlite (E6) = must-survive — retention NEVER touches non-traces files.

## Key sequences
1. Turn: _chat emits turn.start → recall.* → provider.call/provider.error → turn.end (each enqueue-only) → writer drains to sqlite. Latency assertion: turns unaffected with the writer under load (AST-030's pattern).
2. Crash: WAL + per-drain commits mean a crash loses at most the queued-not-yet-drained tail; schema created idempotently on first open.

## Decisions
- **One writer thread for ALL roots** (the AST-010 traces slot), per-root connections held by that thread only — sqlite single-writer discipline without cross-thread handles.
- **seq assigned by the writer** (per-root monotonic counter seeded from MAX(seq) at open) — emitters stay lock-free; ordering is arrival order at the queue, which is §10.1's requirement (monotonic, not wall-clock-perfect).
- **No ORM, no deps** — stdlib sqlite3; schema DDL inline; Prometheus exposition hand-rendered text format.
- **Gitignore via the local-state manifest** (MEM-010 mechanism) in the same PR that first creates the file.
- **Physical retention size with WAL (#510/#534):** size pruning measures the
  main file only after `VACUUM` and a successful `wal_checkpoint(TRUNCATE)` on
  the existing writer connection. VACUUM alone can leave a stale large main
  file or put current growth entirely in WAL. After VACUUM, logical
  `page_count * page_size` describes compact current data, but does not prove
  physical reclamation of main-file/WAL bytes pinned by readers. A successful
  truncate checkpoint makes the main-file measurement current and reclaims
  the WAL; the budget includes schema/index overhead, not transient WAL or SHM.
  The checkpoint uses a temporary zero busy timeout (restored afterward).
  If busy, this size pass returns before deleting another chunk, without
  waiting or retrying; age pruning already committed still applies. Physical
  usage may temporarily exceed the budget until a later writer pass after
  the reader releases its snapshot. No compact-size claim is made on busy or
  measurement failure. Deletes retain the materialized oldest seq boundary,
  and `PRUNE_MAX_SIZE_ITERATIONS` still bounds each pass. Reaching that bound
  can leave the last deletion awaiting compaction on a later pass. Defaults,
  zero-as-unlimited semantics, schema, and the single writer are unchanged;
  retention never touches tasks, artifacts, or transcripts.

## Out of scope for this epic
Task events (E6 emits task.*; the schema accepts them now), tts./stt. (E5), digest task-source swap (E6), any provider/LLM calls.
