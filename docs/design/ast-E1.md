# Design — ast/E1: Engine core & numeric gates
Grounded in: SPEC-ASSISTANT.md §5/§5a (architecture + structural contract), §7.6 (resolution), §8 (turns), §9.1 (recall in-process), §15 (E1 numeric gates N1–N5), §16 (testing), §17 invariants 1–3, 5, 7, 10.

## Components (epic-wide)
- `plugins/spec-workflow/scripts/assistant/` gains the §5a-mandated engine modules, populated across E1:
  - `engine.py` (AST-010) — route table + lifecycle owner (worker-thread registry, start/stop).
  - `adapters.py` + `codex.py` (AST-011), `claude.py` (AST-012) — `complete(context) -> {text, usage, timings}` contract.
  - `store.py` (AST-014) — session transcript (fsync'd JSONL) + rolling summary.
  - Turn pipeline (AST-013) composes context under budgets; recall via brain.py imported as a library (AST-003) — never subprocess.
  - `distill.py`, `capability_index.py`, `observability.py`, `tasks.py` — E3/E4/E6 fill these; AST-010 creates STUB modules only where the route table/lifecycle needs a name to exist (empty module with docstring), never speculative logic.
- `neural-view.py` — lifecycle + mount ONLY (AST-010): construct the engine, delegate `/assistant/*` requests to it, start/stop its workers with the server. The AC caps the neural-view.py diff at this.
- Gates harness (AST-017) is a SCRIPT + test section, not engine code; embeddings wiring (AST-018) touches recall config only.

## Decisions (AST-010 scope)
**Route table, not an if-chain.** `engine.py` exposes `class AssistantEngine` with `routes() -> {(method, path-prefix): handler}` or a single `handle(method, path, query, body) -> (status, payload, ctype) | None`; neural-view.py's `Handler.do_GET`/`do_POST` call `ENGINE.handle(...)` for any path starting `/assistant/` and fall through untouched otherwise. Exactly ONE dispatch hook lands in the existing if-chain — that plus construction/start/stop is the whole neural-view.py diff.
**Lifecycle.** `AssistantEngine(repos, state_dir)` created in `main()`'s `serve` branch before `serve_forever`; `engine.start()` launches its worker threads (daemon=False, joined on stop with a bounded timeout); `engine.stop()` invoked via `atexit` + on `KeyboardInterrupt`/SIGTERM path. Worker registry: `engine.workers` list of (name, Thread, stop_event) so tests can assert clean start/stop without HTTP. v1 workers in AST-010: a single no-op heartbeat worker per subsystem name {distiller, tasks, traces, index} parked on `stop_event.wait()` — real loops arrive with their tasks (E3/E4/E6); the queue plumbing (`queue.Queue` per subsystem, HTTP threads enqueue-only per §5a) is created now so signatures don't churn.
**/assistant/status** (AST-010's one real route): JSON {engine: "ok", workers: [{name, alive}], assistants: <count of discovered candidates via default_store.discover machinery>, selected: null} — no selection logic (E2), no turn logic (AST-013). Localhost-only is inherited from the server bind (§17.10; invariant N7).
**Isolation.** Engine construction must not import provider CLIs, never spawns subprocesses at status time (§17.1); brain access only via brain.py library imports (§5 key choice), and only under its flock discipline (AST-004).
**Testing (AST-010).** Section-style integration: start the real server on a random port with a fixture scan dir (existing neural-view test patterns — see section-* files touching neural-view), assert /assistant/status shape, assert non-/assistant/ routes byte-identical to pre-change behavior (regression: /graph, / serve), assert stop joins every worker (no leaked threads — enumerate threading.enumerate() before/after), kill -term cleanliness. Unit: route-table dispatch (no server), worker registry start/stop idempotence.

## Constraints for later E1 tasks (binding)
- #523 extends adapters and chat transport with optional streaming; see [the streaming chat design](523-streaming-chat.md). The blocking adapter contract remains available.
- Adapters (011/012): argv-array invocation only (§17.3), pinned isolation flags (§8.4), mandatory timeout (§8.5), stub-binary contract tests (auth unavailable in CI, §16).
- Turn pipeline (013): context budget ≤ ~6k tokens with per-component caps (§8.2); raw message to recall (§8.3); never blocks on distiller/index/tasks (§17.7).
- Store (014): fsync'd JSONL appends; crash loses at most in-flight turn (§8.7).
- Gates harness (017): N1 p95 ≤ 15s is the E2 unblock; run against the real repo brain for N2 (<300ms recall p95 incl. embed hop).

## Out of scope for AST-010
Turn execution, adapters, recall injection, session store, distiller logic, selection/discovery UX (E2), any page/JS changes beyond none (status is JSON-only; the page consumes it in E2), prometheus/traces (E4).
