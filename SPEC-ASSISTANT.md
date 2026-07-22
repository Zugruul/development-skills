# SPEC-ASSISTANT — persistent LLM-agnostic assistant on the neural network

Status: draft v1 (crafted 2026-07-22, two agent review rounds folded; plan lineage in
session notes). Task prefix: **AST**. Backlog: `docs/BACKLOG-ASSISTANT.md`.

## §1 Overview

A persistent, personal, LLM-agnostic assistant whose knowledge source is a zettel brain.
The **assistant repository is a bare brain** — configuration, notes, skills, and local
state; never engine code. The **engine lives in this repository** (the spec-workflow
plugin's neural-view server) and drives conversation turns, recall, self-feedback,
observability, and capabilities. Users talk to it through neural-view (a game-chat
overlay and, later, voice) and a terminal command. All LLM access goes through
**subscription-authenticated CLIs** (`codex` via ChatGPT sign-in, `claude` via Claude
Pro/Max login) — never metered APIs.

Why now: the zettel brain, its 3D visualization, live recall events, media viewers, and
the voice panel already exist here; the assistant composes them into a daily-use tool and
makes the brain the durable memory ("resume yesterday's travel plan instantly").

## §2 Goals

- G1 Chat with a named assistant from neural-view (T-key overlay) and the terminal, with
  persona, memory, and recall transparency.
- G2 Fast topic resume: a vague reference to a prior topic surfaces the right notes via
  hybrid (lexical + embeddings) recall injected into the turn.
- G3 Background self-feedback: a distiller continuously mints/strengthens notes from
  conversation without ever blocking a reply.
- G4 LLM-agnostic turns: provider adapters behind one interface; switching provider/model
  is config, not code.
- G5 Full observability: every turn is an event-sourced trace (sqlite) with metrics
  exposition (prometheus) and page + terminal surfaces.
- G6 Capabilities as installable skills with a compiled roster — the assistant knows
  precisely what it can and cannot do, and can act while talking (artifacts, async tasks).
- G7 Zero pay-per-use: subscription CLIs only.

## §3 Non-goals (v1)

- NG1 Concurrent multi-assistant serving (one ACTIVE assistant at a time; design must not
  preclude concurrency later).
- NG2 Streaming token-by-token replies (turns are one-shot CLI invocations; an elapsed-time
  thinking state is the v1 UX).
- NG3 Note lifecycle beyond mint + strength-bump (merge/retire/aggregate primitives and
  end-of-session retro consolidation are E8).
- NG4 Remote compute beyond the single Windows/ComfyUI target (E7's scope).
- NG5 Mobile/remote (non-localhost) access; multi-user; authentication beyond localhost
  trust; encryption at rest.
- NG6 Cloud/API LLM providers, even as a fallback.
- NG7 Marker-scanned external capability repositories (v1 skills are installed in-repo).

## §4 Glossary & domain

- **Assistant repo**: a repository whose `.claude/project.yaml` has an `assistant:`
  section with `enabled: true`, anchored by a `.neural-network` marker. Contains the brain
  (`.claude/identities/assistant/brain/`), installed skills (`.claude/skills/`), persona
  docs, and gitignored local state (`.claude/assistant/`: session, traces.sqlite,
  tasks.sqlite, artifacts/).
- **Engine**: the assistant runtime inside the neural-view server process
  (`plugins/spec-workflow/scripts/assistant/` package) — routes `/assistant/*`, owns
  turns, recall, distiller, queues, observability.
- **Active assistant**: the single assistant currently owning chat/voice/turn traffic.
  Inactive assistants keep their background work running (§9.6).
- **Turn**: one user message → one assistant reply, executed as a stateless provider-CLI
  invocation with engine-owned context.
- **Capability / skill**: one unit — a directory `.claude/skills/<name>/` with `SKILL.md`
  (teaches) and optional `capability.yaml` (provisioning, permissions, invoke). Base
  capabilities (`codex`, `claude-code`) ship in-plugin with the same shape.
- **Roster**: the compiled, availability-annotated list of enabled capabilities injected
  into every turn.
- **Distiller**: the background self-feedback worker minting/bumping notes from
  transcript batches.
- **Harness job**: a dispatched, full agentic run of a provider CLI (its own sandbox
  posture), queued as an async task — distinct from a turn (§9.4).
- **Trace**: the ordered set of events for one turn/task, projected from the event store.

## §5 Architecture

```
neural-view page (:4748)                     neural-view server process
┌────────────────────────────┐              ┌────────────────────────────────────────┐
│ T-key chat overlay         │  same-origin │ scripts/assistant/ package (engine)    │
│ voice panel (name header,  │──/assistant/*│  engine.py  route table + lifecycle    │
│  gating, metrics, queue)   │              │  adapters.py codex.py claude.py        │
│ artifact panels (3D/image/ │              │  store.py (session, sqlite owners)     │
│  video viewers, entrance   │              │  capability_index.py                   │
│  animations)               │              │  distill.py · tasks.py                 │
└────────────────────────────┘              │  observability.py (events→sqlite,      │
   terminal: neural-view assistant …        │   prometheus exposition)               │
   (same endpoints)                         └───────┬────────────────────────────────┘
                                                    ▼
                       assistant repo: brain/ (via brain.py imported as a library,
                       single-writer + flock), .claude/skills/, local state
```

Key choices (each with the WHY):
- **In-process engine, package-structured** (§5a): one lifecycle with neural-view, no
  CORS, no port contract; the mandated package layout + route-table keep neural-view.py
  from absorbing thousands of lines. Extraction to a supervised child is a contingency,
  not v1.
- **brain.py as an imported library** — never vendored, never subprocessed: preserves
  ranking (outcomes, decay, spread), preserves `brain-events.jsonl` emission (recalls
  light up in 3D), avoids schema drift, and is the only way to meet recall latency.
- **Stateless per-turn CLI calls** with engine-owned context: restartable, provider-
  agnostic, subscription-safe.
- **Event-sourced observability** with sqlite as source of truth and prometheus as
  exposition-only.

## §5a Engine structural contract

- THE SYSTEM SHALL implement the engine as the package
  `plugins/spec-workflow/scripts/assistant/` with module boundaries {engine, adapters,
  store, distill, capability_index, observability, tasks}; `neural-view.py` SHALL contain
  only lifecycle wiring and route-table mounting for `/assistant/*`.
- THE SYSTEM SHALL run one owned worker thread per subsystem (distiller, task queue,
  traces writer, index refresh), with cross-thread communication via queues; HTTP request
  threads only enqueue work and execute turns.
- THE SYSTEM SHALL provide `recall()`/`mint()` as importable library functions in
  brain.py returning structured results (no argparse/stdout coupling); the existing CLI
  SHALL delegate to the same functions.
- THE SYSTEM SHALL serialize every brain write through the engine's writer queue AND
  guard all brain.py write paths with a cross-process file lock (flock) shared by CLI
  invocations, writing files atomically (temp + rename). (Recall's own link-bump writes
  included.)

## §6 Configuration & identity

`assistant:` section in the assistant repo's `.claude/project.yaml` (authoritative):

```yaml
assistant:
  version: 1
  enabled: true
  names: [jarvis, j]          # first = main name; rest = aliases
  systemPrompt: |             # persona; names + roster appended mechanically
    ...
  llm: {provider: openai, model: gpt-5.6-sol}
  capabilities:
    codex:       {enabled: true,  provisioning: {bin: codex}}
    claude-code: {enabled: false, provisioning: {bin: claude}}
  observability:
    metrics: {prometheus: {enabled: true, host: 127.0.0.1, port: 9464}}
    traces:  {sqlite: {enabled: true, retainDays: 30, maxMB: 500}}
```

- §6.1 THE SYSTEM SHALL treat the `assistant:` section as the sole authority for
  assistant identity/enabled state; the `.neural-network` marker SHALL carry no assistant
  flags (pure discovery anchor).
- §6.2 THE SYSTEM SHALL parse `.neural-network` as key=value lines with `#` comments,
  ignoring unknown keys, and SHALL accept legacy comment-only/empty marker content.
- §6.3 THE SYSTEM SHALL store the machine-local default assistant in neural-view's local
  state (never in a tracked file); IF the stored default is ambiguous or missing among
  discovered assistants THEN THE SYSTEM SHALL fail the resolution with a message listing
  candidates.
- §6.4 WHEN `/setup-assistant` runs THE SYSTEM SHALL scaffold: marker, project.yaml with
  assistant section, empty brain directories, persona-scoped AGENTS.md, and gitignore
  entries for all assistant local state.
- §6.5 THE SYSTEM SHALL validate: provider↔capability consistency (`openai` requires
  `codex` enabled; `claude` requires `claude-code` enabled); model string passed verbatim
  to the adapter.
- §6.6 The development-skills preflight SHALL verify, for each discovered assistant:
  config parses/validates, and each enabled capability's `bin` resolves and is
  authenticated — with an enumerated, specific message per failure mode.
- §6.7 The assistant repo SHALL contain no engine code and no dev-loop agent instruction
  files; its AGENTS.md/CLAUDE.md are persona documents.

## §7 Discovery, selection, gating

- §7.1 WHEN the discovery scan runs THE SYSTEM SHALL identify assistant repos by marker
  presence + valid `assistant.enabled: true` config.
- §7.2 WHEN exactly one assistant exists THE SYSTEM SHALL select it silently and show its
  main name in the voice panel header (e.g. "VOICE · JARVIS").
- §7.3 WHEN multiple assistants exist THE SYSTEM SHALL present a startup picker (main
  name + aliases) with a Skip option; WHEN Skip is chosen THE SYSTEM SHALL disable voice
  and chat for the session.
- §7.4 WHEN no assistant exists THE SYSTEM SHALL show a red overlay on the voice panel
  ("set up an assistant") whose hover explains /setup-assistant; voice and chat SHALL be
  hard-gated off.
- §7.5 THE SYSTEM SHALL remember the selection server-side (page, tabs, terminal agree);
  a page setting SHALL toggle "ask again on load" vs "remember"; the voice ⚙ panel SHALL
  offer an assistant switcher.
- §7.6 Terminal: `neural-view assistant <chat|metrics|trace|events|status|default>
  [--assistant NAME]`; resolution order: flag → sole assistant → local default → error
  listing candidates. NAME matches any name/alias.
- §7.7 (one-active model) WHEN the active assistant is switched THE SYSTEM SHALL flush
  in-flight turn state, load the target assistant, and keep BOTH assistants' background
  work (task queues, distillers) running throughout.
- §7.8 WHEN an assistant becomes active THE SYSTEM SHALL present an activation digest of
  its background activity since last active (completed/failed tasks, minted notes),
  sourced from its trace events.

## §8 Conversation turns

- §8.1 WHEN a user message arrives THE SYSTEM SHALL execute the turn as one stateless
  provider-CLI invocation (`codex exec --json -m <model>` / `claude -p --output-format
  json`) via the adapter interface `complete(context) -> {text, usage, timings}`.
- §8.2 THE SYSTEM SHALL build the turn context as: systemPrompt persona + names + roster
  (§11) + top-k recalled notes + rolling summary + last N turns (N≤6) + user message,
  under a hard total budget (≤ ~6k tokens) with per-component caps; the rolling summary
  SHALL be size-capped and refreshed every K turns.
- §8.3 THE SYSTEM SHALL pass the RAW user message to recall (hybrid lexical+embeddings,
  §9) and SHALL render which notes fired as recall chips on the reply.
- §8.4 Turns SHALL run answer-only: adapters SHALL pin isolation flags (no user-global
  instruction ingestion; no plugin/skill surface from the dev workflow; harness tool use
  disabled). Agentic work happens via dispatched harness jobs (§9.4), never inside turns.
- §8.5 IF the provider CLI exits nonzero, times out (mandatory timeout), or emits
  unparseable output THEN THE SYSTEM SHALL surface a bounded-time, specific error in the
  overlay — including an auth-expired state instructing `codex login`/`claude login`.
- §8.6 WHILE a turn is in flight THE SYSTEM SHALL show an elapsed-time thinking state;
  chat input SHALL remain open (messages queue).
- §8.7 THE SYSTEM SHALL append each exchange to the session transcript (append-safe
  JSONL, fsync'd) so a crash loses at most the in-flight turn.

## §9 Memory, self-feedback, background work

- §9.1 Recall SHALL run in-process with a query-embedding cache; the p95 recall budget
  INCLUDES the embedding hop (§15 gates).
- §9.2 The distiller SHALL batch every N exchanges (never per-exchange), minting new
  notes and bumping touched ones; v1 SHALL NOT merge/retire/aggregate (NG3).
- §9.3 WHEN the distiller mints THE SYSTEM SHALL refresh the embeddings index so new
  notes are recallable within one batch cycle.
- §9.4 Harness jobs: THE SYSTEM SHALL support dispatching full agentic CLI runs as async
  tasks (own sandbox posture, full tracing); the assistant SHALL keep conversing while
  jobs run, report progress, and announce results, resuming the topic on completion.
- §9.5 Turns SHALL never block on the distiller, index refresh, or any task.
- §9.6 Inactive assistants' queues/distillers SHALL continue running (feeding §7.8's
  digest).

## §10 Observability (event-sourced)

- §10.1 THE SYSTEM SHALL emit an ordered event stream per assistant: turn.*, recall.*,
  prompt.*, provider.*, skill.*, distill.*, task.*, tts.*, stt.* — each event carrying
  monotonic seq, ts, session_id, turn_id, span_id, parent_span_id, kind, skill, modality,
  status, and a JSON payload (including said/heard text where applicable).
- §10.2 traces.sqlite is the source of truth: append-only events table, WAL,
  busy_timeout, single writer thread; INDEXED first-class columns (seq, ts, session_id,
  turn_id, span_id, parent_span_id, kind, skill, modality, status) so time-range,
  ordering, and correlation queries never depend on json_extract.
- §10.3 Retention SHALL be configurable by age AND size (retainDays, maxMB; 0 =
  unlimited), pruning oldest first; defaults 30/500.
- §10.4 Prometheus exposition (host/port, enabled flag) SHALL serve computed
  histograms/counters and SHALL NOT own history; page/terminal metrics views query
  sqlite directly.
- §10.5 Surfaces: voice-panel metrics expansion (latency percentiles, per-area graphs,
  per-turn trace waterfall inspector with errors inline); `/assistant/metrics`,
  `/assistant/traces?since=&turn=`; terminal `metrics`, `trace [turn|last]`,
  `events --since <dur>`.
- §10.6 Every error (turn, skill, task, remote command) SHALL be a first-class event
  linked from its turn/task.
- §10.7 Durability classes: embeddings index = derived/rebuildable; traces = prunable
  history; tasks.sqlite = must-survive.

## §11 Capabilities (skills) & roster

- §11.1 A skill is `.claude/skills/<name>/` with SKILL.md and optional capability.yaml
  {version, provisioning.check (TTL-cached), permissions, invoke}; base capabilities
  ship in-plugin with the same shape. v1 discovery: installed-in-repo only (NG7).
- §11.2 Enablement: only `assistant.capabilities.<name>.enabled: true` skills load;
  disabled skills SHALL be invisible (no roster, no prompt, never executed);
  project.yaml provisioning overrides localize the skill's defaults.
- §11.3 The engine SHALL compile a capability index {name, one-liner, keywords,
  embedding, enabled, provisioned-ok} on start and on change; the per-turn roster SHALL
  be relevance-filtered top-N with a hard cap; ties/low confidence → the assistant asks
  instead of guessing.
- §11.4 Unprovisioned-but-enabled skills SHALL appear in the roster as unavailable with
  the reason; THE SYSTEM SHALL never present an unavailable ability as usable.
- §11.5 `invoke.exec` SHALL be an argv ARRAY; placeholder substitution occurs only within
  single argv elements, after validation against the skill's declared parameter schema
  (type/pattern/allowlist); THE SYSTEM SHALL never pass invoke commands through a shell.
- §11.6 capability.yaml `version` SHALL be checked against the engine's supported range;
  unsupported versions are unavailable-with-reason, never best-effort executed.
- §11.7 MCP servers are an invoke flavor (`invoke: {mcp: ...}`).
- §11.8 WHEN a request matches no enabled capability THE SYSTEM SHALL say so in-persona
  and MAY offer to acquire the ability by drafting a plan into the brain repo (parking
  lot); installation/enablement SHALL require human approval.
- §11.9 For codex turns, /setup-assistant SHALL maintain a generated persona-scoped
  AGENTS.md section listing enabled skills (codex has no native skills dir).

## §12 Actions, artifacts, async tasks

- §12.1 WHEN a capability invocation produces an artifact THE SYSTEM SHALL open it in a
  detached panel using the existing viewers (3D models → live viewer; images → media
  viewer; video → player) with an entrance animation (panel scales in; 3D model rises/
  fades in with auto-rotation catching).
- §12.2 Artifacts SHALL live in assistant local state and be served by a dedicated
  streamed, range-capable `/assistant/artifact/<id>` endpoint (NOT `/file`, which is
  brain-dir-scoped and whole-file-in-RAM).
- §12.3 Long-running work SHALL queue in tasks.sqlite {id, kind, state, payload,
  external_job_id, artifact_path, timestamps}; states queued/started/progress/completed/
  failed/orphaned; every transition is a trace event.
- §12.4 WHEN the engine restarts THE SYSTEM SHALL reconcile the queue: tasks with an
  external_job_id are re-polled against the remote system before any resubmission;
  unreconcilable tasks become orphaned (surfaced, never silently re-run).
- §12.5 WHILE tasks run, chat/voice remain fully usable; a queue indicator on the voice
  panel lists running/queued tasks; completion opens the artifact panel and announces
  (TTS when voice on); failures surface in-chat with the trace linked.

## §13 Voice

- §13.1 TTS: assistant replies SHALL be speakable via the existing speechSynthesis
  pipeline (echo-guard interplay preserved).
- §13.2 STT: E5 decides Web Speech (zero-install; audio leaves the machine) vs
  whisper.cpp sidecar (local); the engine API stays text-in/text-out either way. The
  choice SHALL be recorded as a spec delta before implementation.
- §13.3 Voice metrics (STT/TTS spans) join the same trace stream.

## §14 Remote compute (E7 — Windows/ComfyUI)

- §14.1 Control plane: SSH to the Windows box with key-based auth ONLY, pinned host keys
  (StrictHostKeyChecking=yes with a pinned known_hosts), and per-operation-class forced
  commands/restricted scopes — never a blanket interactive shell grant.
- §14.2 Job plane: ComfyUI bound to localhost on the Windows box, reached exclusively
  through an SSH tunnel (never LAN-exposed); workflows submitted via its native HTTP/WS
  API; progress streams into trace events + the task queue; artifacts sync back over the
  same SSH.
- §14.3 Every remote command SHALL be a trace event (full audit), subject to §10.3
  retention/redaction.
- §14.4 Hosts SHALL be allowlisted in capability provisioning; anything else is refused.

## §15 Non-functional & E1 gates (blocking)

- N1 Scripted 20-turn session records turn p50/p95, variance, and harness tool-use rate;
  **p95 ≤ 15s or E2 is blocked** and the fallback decision (persistent session /
  streaming investigation) is taken explicitly.
- N2 Recall p95 including the embedding hop < 300ms (with cache) on the real brain.
- N3 Page-serving isolation: a turn in flight + /graph rebuild concurrently SHALL NOT
  measurably degrade page polling.
- N4 kill -9 mid-turn → restart: session resumes; links.json and all sqlites uncorrupted.
- N5 Logged-out provider → bounded-time, specific failure in the overlay (timeouts
  mandatory on all subprocess calls).
- N6 E1→E2 exit criterion: multi-day real dogfood with recorded error-rate/latency within
  thresholds.
- N7 All engine HTTP surface localhost-only; all assistant local state gitignored.

## §16 Testing strategy

- Unit: config/marker parsing (incl. legacy tolerance), schema validation, roster
  compilation, invoke argv substitution + injection attempts, retention pruning, task
  state machine + reconcile logic — in the plugin's run-tests.sh section style;
  merge-gating.
- Integration: engine endpoints against a fixture assistant repo (turn with a stub
  adapter, trace assertions, crash-recovery, lock contention CLI-vs-engine) —
  merge-gating.
- Adapter contract tests run against stub binaries in CI; against real CLIs only in
  dogfood (auth unavailable in CI).
- E2E (manual/dogfood): §15 gates, overlay UX, artifact panels.
- The isolation test (§8.4) asserting a turn's injected context contains no dev-workflow
  instructions is merge-gating.

## §17 Invariants

1. LLM invocations occur only through locally authenticated subscription CLIs enabled as
   capabilities; no metered API is ever called.
2. A disabled capability is never invoked by the engine, and harness subprocesses always
   run with pinned isolation and sandbox flags — the pair constitutes the boundary.
3. Capability invocation is argv-array with schema-validated parameters; no invoke string
   is ever interpreted by a shell.
4. The assistant repository contains no engine code and no dev-loop agent instructions.
5. All brain writes are atomic and serialized (engine writer queue + cross-process flock
   in brain.py write paths).
6. The assistant brain remains fully zettel-schema-compatible, including
   brain-events.jsonl emission.
7. Conversation turns never block on the distiller, index refresh, or task queue.
8. Transcripts, traces, tasks, and artifacts are never committed to git.
9. Voice and chat are hard-gated off when no enabled assistant is selected.
10. The engine's HTTP surface binds localhost only.

## §18 Open questions

- OQ1 (owner: human; default: Web Speech behind a config flag, revisit for whisper.cpp)
  — STT provider for E5.
- OQ2 (owner: dev at E1; default: single `assistant` session id per repo) — whether
  sessions ever fork (e.g. per-device) before multi-assistant concurrency.
- OQ3 (owner: human; default: off) — trace payload redaction default once voice lands.
- OQ4 (owner: dev at E6; default: engine-side queue cap 3 concurrent harness jobs) —
  concurrency limits for dispatched jobs.
