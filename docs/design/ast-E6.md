# Design — ast/E6: Capabilities, artifacts, tasks

Grounded in: SPEC-ASSISTANT.md §5a (engine structural contract), §11 (capabilities/skills &
roster), §12 (actions, artifacts, async tasks), §17 invariants 2–3, 5.

## Components (epic-wide)
- `assistant/capability_index.py` (AST-060/061/062/065) — capability.yaml schema + version
  negotiation (AST-060), the compiled per-turn index and relevance-filtered roster
  (AST-061), provisioning checks with TTL cache (AST-062), enablement gating end-to-end
  (AST-065). Pure library: no HTTP, no subprocess spawning of its own — provisioning
  checks and invoke both go through `adapters.py`'s existing sandboxed-subprocess path.
- `assistant/adapters.py` — extended (not replaced) with the argv-array invoke primitive
  (AST-063) and an MCP invoke flavor (AST-064); both reuse the isolation/no-tools/timeout
  posture AST-011 already established for provider adapters.
- `assistant/tasks.py` (AST-066/067) — tasks.sqlite queue + worker + state machine
  (AST-066), restart reconciliation of in-flight external jobs (AST-067). Runs on the
  engine's existing `"tasks"` worker slot (`engine.py` `WORKER_NAMES`, currently a
  heartbeat no-op per AST-010) — same replace-the-heartbeat-body pattern AST-030 used for
  `"distiller"`.
- `engine.py` — E6 tasks replace the `"tasks"` worker body with `tasks.run_worker`
  (mirroring `distill.run_worker`'s wiring), add `/assistant/artifact/<id>` (AST-068), and
  route capability-invocation requests from `turns.py` through the index + adapters.
- neural-view page JS — artifact panels with entrance animations (AST-069), reusing the
  existing 3D/media/video viewer components (§12.1 explicitly says "existing viewers").
- `assistant/observability.py` — every capability invocation, task-queue transition, and
  MCP round trip is a trace event (§10, §12.3); AST-066/070 emit through the existing
  `observability.emit` path, no new trace-writer.

## Data models
- **CapabilityIndexEntry**: `{name, one_liner, keywords, embedding, enabled,
  provisioned_ok, unavailable_reason}` — compiled from every `.claude/skills/<name>/`
  with a `capability.yaml` (§11.1) that is (a) enabled per
  `assistant.capabilities.<name>.enabled` (§11.2, already validated structurally by
  `config.py`) and (b) version-compatible (§11.6). Disabled or version-incompatible
  skills are *never added to the index* — §11.2 "invisible: no roster, no prompt, never
  executed" is stronger than "shown as unavailable"; only *provisioning* failures
  (AST-062) get an unavailable-with-reason index entry, per §11.4's narrower wording.
- **capability.yaml schema** (AST-060): `{version: int, provisioning: {check: argv-array,
  ttlSeconds: int}, permissions: [...], invoke: {exec: argv-array} | {mcp: {...}}}`.
  `version` is checked against `capability_index.SUPPORTED_VERSION_RANGE = (1, 1)` (v1
  ships exactly one supported version; the range shape is future-proofing for §11.6's
  "checked against the engine's supported range" wording, not present multi-version
  support).
- **Task** (tasks.sqlite, §12.3): `{id, kind, state, payload, external_job_id,
  artifact_path, created_at, updated_at}`; `state` ∈
  `{queued, started, progress, completed, failed, orphaned}`.
- **Artifact**: local-state file under the assistant's artifact dir, referenced by
  `artifact_path` on its owning Task; served only via `/assistant/artifact/<id>` (§12.2),
  never `/file`.

## Interfaces / contracts
- `capability_index.load_capability(skill_dir) -> Capability | CapabilityError` — parses
  `capability.yaml`, validates structure, checks `version` against
  `SUPPORTED_VERSION_RANGE`. Out-of-range version ⇒ `CapabilityError(reason=...)`, never
  raises and never executes (AST-060's AC, mirrors `config.validate_assistant`'s
  never-raise/return-errors style).
- `capability_index.compile_index(skills_root, assistant_cfg) -> CapabilityIndex` — one
  pass over installed skills, applying enablement (§11.2) then version negotiation
  (§11.6) then provisioning (§11.4, TTL-cached via AST-062's checker) to produce the
  roster source; recompiled on start and on config change (§11.3), never per-turn.
- `capability_index.roster_for_turn(index, query_embedding, top_n) -> list[Entry]` —
  relevance-filtered, hard-capped top-N; ties/low-confidence return a sentinel the turn
  pipeline (`turns.py`) reads as "ask instead of guess" (§11.3).
- `adapters.invoke_argv(capability, params) -> InvokeResult` — validates `params` against
  the capability's declared schema (type/pattern/allowlist) BEFORE substitution, then
  substitutes only within single argv elements, then `subprocess.run(argv, shell=False,
  ...)` under the same isolation posture as provider adapters (§11.5, §17.3). No skill's
  invoke ever touches a shell — this is a hard invariant, tested with injection-attempt
  fixtures (`; | $() &&` as literal argv text, never interpreted).
- `adapters.invoke_mcp(capability, params) -> InvokeResult` — one MCP round trip per
  `invoke.mcp` config (§11.7); reuses `invoke_argv`'s pre-validation step for params.
- `tasks.enqueue(kind, payload) -> task_id`, `tasks.run_worker(queue, stop_event, ...)` —
  state machine driver; every transition calls `observability.emit` (§12.3). Restart
  reconciliation (AST-067) runs once at worker start: any `started`/`progress` task with
  an `external_job_id` is re-polled against the remote system (never resubmitted);
  no-`external_job_id` in-flight tasks at restart are unreconcilable ⇒ `orphaned`.
- `/assistant/artifact/<id>` (AST-068) — GET only, range-capable (`Range:` header honored,
  reads via chunked file streaming, never loads the whole file into RAM), 404 outside the
  artifact dir (path-traversal closed the same way `/file`'s existing brain-dir scoping
  is).

## Key sequences
1. **Index compile** (AST-060/061/062/065): on engine start and on `assistant:` config
   change, `compile_index` walks installed skills → `load_capability` (version check) →
   enablement filter (§11.2, invisible if disabled) → `provisioning.check` (TTL-cached;
   failure ⇒ unavailable-with-reason entry, §11.4) → `CapabilityIndex` held in engine
   state for `roster_for_turn` to read per-turn (no recompute in the request path, §11.3).
2. **Invocation** (AST-063/064): `turns.py`'s pipeline resolves a capability from the
   turn's roster → validates the model's requested params against the capability's
   schema → `adapters.invoke_argv` or `invoke_mcp` → result (+ any artifact) flows back
   into the turn, and if long-running, becomes a Task instead (sequence 3).
3. **Async task + artifact** (AST-066/067/068/069): capability invocation that won't
   finish inline ⇒ `tasks.enqueue` → `queued` trace event → worker thread drains, marking
   `started`/`progress`/`completed` (or `failed`) with matching trace events → on
   `completed`, `artifact_path` is set and the chat turn that requested it is notified
   (§12.5: chat/voice stay usable throughout; queue indicator reflects live state) →
   client opens `/assistant/artifact/<id>` and the panel renders with its entrance
   animation, TTS-announcing completion if voice is on.
4. **Restart reconciliation** (AST-067): worker start ⇒ query tasks.sqlite for
   `started`/`progress` rows → rows with `external_job_id` are re-polled (their real
   remote state wins, no blind resubmission) → rows without one are marked `orphaned` and
   surfaced (never silently re-run) — this is the concrete mechanism §12.4 requires.
5. **Capability gap** (AST-071): roster/index produce no match for a request ⇒
   `turns.py` returns an in-persona refusal naming the nearest enabled abilities (from the
   index, not a fresh LLM guess) and MAY draft an acquire-offer plan note into the brain
   repo (parking lot, §11.8); nothing installs or enables without a human approving that
   plan out-of-band — this task never flips `assistant.capabilities.*.enabled` itself.

## Decisions
- **Two invisibility tiers, not one.** §11.2 ("disabled ⇒ invisible") and §11.4
  ("unprovisioned-but-enabled ⇒ unavailable-with-reason") are different failure classes
  with different UX: disabled skills never enter the index at all; enabled-but-unprovisioned
  skills DO enter the index, flagged, so the roster can explain *why* something plausible
  isn't usable instead of silently omitting it.
- **Provisioning checks are TTL-cached, not per-turn.** AST-062's cache exists because
  §11.3 forbids recomputing the index per-turn; the cache key is the capability name +
  its provisioning check's argv, invalidated on config change same as the index itself.
- **One argv-validation path, two invoke flavors.** AST-063's schema validation
  (type/pattern/allowlist, pre-substitution) is shared code that AST-064's MCP flavor
  calls too — never two independent parameter-checking implementations that could drift
  out of sync on what counts as safe.
- **Tasks reuse the AST-010 worker skeleton verbatim.** No new worker-registry shape;
  `"tasks"` swaps its heartbeat body for `tasks.run_worker` exactly as `"distiller"` did
  for AST-030 — keeps `engine.py`'s `start()`/`stop()` idempotency guarantees untouched.
- **Artifacts get a dedicated endpoint, never `/file`.** `/file` is brain-dir-scoped and
  whole-file-in-RAM (fine for zettel markdown, wrong for a multi-MB 3D model or video);
  §12.2 is explicit that artifacts need range support, so this is a new route, not a
  `/file` extension.
- **No shell, ever, in the invoke path (§17.3 is load-bearing).** `invoke_argv` builds a
  literal argv list and calls `subprocess.run(..., shell=False)`; the injection-attempt
  fixture set is not optional polish, it's what AST-063's AC actually asks for.

## Out of scope for this epic
Remote compute over SSH (E7 — AST-080/081 build ON TOP of this epic's capability/invoke
contract, e.g. `comfyui-render` is just another `capability.yaml` whose `invoke.exec`
happens to SSH out; E6 does not implement any remote-specific transport). Voice
announcement of task completion (E5 owns TTS itself; E6 only calls the existing
speak-if-voice-on hook per §12.5). Distiller/self-feedback (E3) and observability
dashboards (E4) are consumed here (trace events, brain writes) but not extended.
