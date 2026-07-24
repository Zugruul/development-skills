# Design — ast/E3: Distiller & self-feedback
Grounded in: SPEC-ASSISTANT.md §5a (worker threads/queues, writer queue), §8.2 (rolling summary), §9.1–§9.6 (memory & background work), §17 invariants 5 (atomic serialized brain writes), 7 (turns never block on distiller/index/tasks).

## Components (epic-wide)
- `assistant/distill.py` — grows from stub to the real distiller: batch detector + note synthesis + mint/bump through brain.py's library API. Owns NO thread itself; it is the logic the engine's existing `distiller` worker slot runs.
- `engine.py` — wires the AST-010 distiller worker slot (thread + stop_event + `queue.Queue`) to distill logic: `_chat` enqueues an exchange-ref after each turn (enqueue-only per §5a; never synchronous distilling on the request thread).
- Writer discipline: ALL brain writes go through `brain.py` library calls (mint/bump), which already hold the cross-process flock (AST-004) — the distiller worker is the engine's single writer thread for brain mutations (§5a writer queue == this worker's serial execution).
- `assistant/store.py` — rolling summary maintenance (AST-032) extends SessionStore; summary regeneration every K turns, size-capped.

## Data models
- Distiller batch: every N exchanges (default N=8, config-overridable later — hard-code the default now, additive knob when config grows a `distiller:` section) the worker synthesizes candidate notes from the batch transcript slice.
- v1 synthesis is DETERMINISTIC-extractive, not LLM: no metered/provider calls from a background worker (§17.1 posture; a provider-CLI distiller is a later, explicitly-gated evolution). Notes derive from exchange content markers (keyword extraction / repeated-entity heuristics); modest quality is acceptable and honest — the pipeline shape is the deliverable.
- Bump: an exchange that recalls an existing note (recall chips already flow through the turn) bumps that note via re-mint (strength+1, existing brain.py semantics).

## Interfaces / contracts
- `distill.process_batch(identities_dir, root, exchanges, role="assistant") -> {minted: [slug], bumped: [slug]}` — pure logic, testable without threads.
- Engine: `_chat` post-turn enqueues `{root, exchange}` to the distiller queue (non-blocking put); worker drains, buffers per-root, triggers `process_batch` at N. Worker exceptions are caught + logged to stderr, never kill the thread (park-and-continue).
- `brain-events.jsonl` emission comes free via brain.py mint — which AST-024's digest already consumes (digest's notesMinted will light up from distilled notes; no new wiring).
- AST-031: after a batch mints, worker calls the existing embeddings index refresh (brain.py index) for the role — recallable within one cycle.
- AST-033: workers are engine-wide and already run regardless of the active selection; the deliverable is TESTS proving an inactive (non-selected) assistant's exchanges still distill + events record (digest source), not new mechanism.

## Key sequences
1. Turn completes → `_chat` enqueues exchange-ref (O(1), never blocks) → worker buffers → at N: process_batch → mint/bump via brain.py (flock'd, atomic) → index refresh (AST-031) → brain-events emitted.
2. Latency invariant test (AST-030 AC): drive turns while the worker is mid-batch on a large synthetic backlog; assert turn latency unaffected (bounded delta vs idle-worker baseline; generous threshold — this is an ordering/blocking assertion, not a perf benchmark).

## Decisions
- **No LLM in the distiller (v1)** — deterministic extraction only; background provider calls would need their own enablement/gating design (parking-lot for E8/later).
- **Distiller worker == writer queue** — one serial consumer thread satisfies §5a's writer-queue mandate for engine-originated brain writes; CLI writes stay safe via the flock.
- **Per-root buffers in the worker** — multiple assistants distill independently; batches never mix roots (role privacy + digest correctness).
- **Failure posture** — a failing batch logs and drops (transcript is the durable source; a batch can be re-derived later); never retries in a tight loop, never crashes the thread.

## Out of scope for this epic
Merge/retire/aggregate (E8, NG3); provider-CLI note synthesis; traces.sqlite (E4); task queue (E6); any UI beyond what AST-024's digest already renders.
