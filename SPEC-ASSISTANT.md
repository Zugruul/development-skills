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
- NG2 Persistent warm provider sessions and token-by-token voice output. Stateless
  CLI turns MAY expose genuine incremental assistant text through the chat stream
  defined in §8.8; persistent sessions remain separate work (#539).
- NG3 Note lifecycle beyond mint + strength-bump (merge/retire/aggregate primitives and
  end-of-session retro consolidation are E8).
- NG4 Remote compute beyond the single storm590x/WSL ComfyUI target (E7's scope).
  Native PowerShell targets are excluded.
- NG5 Mobile/remote (non-localhost) access; multi-user; authentication beyond localhost
  trust; encryption at rest.
- NG6 Cloud/API LLM providers, even as a fallback.
- NG7 Marker-scanned external capability repositories (v1 skills are installed in-repo).

## §4 Glossary & domain

- **Assistant repo**: a repository whose `.neural-network/project.yaml` has an `assistant:`
  section with `enabled: true`, anchored by a `.neural-network` marker. Contains the brain
  (`.neural-network/identities/assistant/brain/`), installed skills (`.claude/skills/`), persona
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

`assistant:` section in the assistant repo's `.neural-network/project.yaml` (authoritative):

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
  entries for all assistant local state. WHEN the scaffold is fresh (or
  `assistant.systemPrompt` still equals the bare default) THE SYSTEM SHALL interview the
  human — via the host's structured-input facility — about this project's assistant
  (domain, tone, boundaries, example tasks) and compose a quality persona from the
  answers, applied through a `set-persona` verb that writes the composed text into BOTH
  `assistant.systemPrompt` (via the same snapshot → surgical edit → §6.5 validation →
  revert-on-invalid pattern every other settings verb uses) and a new marker-delimited
  persona block in the root `AGENTS.md`, regenerated in place — hand-written prose
  outside the markers SHALL survive byte-for-byte, and re-running `set-persona` SHALL be
  idempotent and is the supported way to evolve the persona later. Empty/whitespace-only
  persona text, and persona text containing a line matching one of `AGENTS.md`'s own
  reserved generated-block markers, SHALL be rejected (`project.yaml` and `AGENTS.md`
  both left byte-identical); text exceeding the runtime engine's persona-component clip
  (3200 chars by default — `turns.py`'s persona token budget of 800, converted at 4
  chars/token, and itself overridable) SHALL still be accepted and stored in full — never
  silently truncated — with a warning naming the actual clip.
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
  main name in the voice panel header (e.g. "VOICE · JARVIS"). The chat overlay's header
  SHALL additionally render the selected assistant's model id beside its name, muted and
  verbatim (e.g. "MEGABRAIN · claude-sonnet-5"), kept in sync across assistant switches
  and model-only config changes; to support this, each `GET /assistant/status` candidate
  carries a resolved `llm: {provider, model}` sub-mapping (fields degrade to null on a
  malformed section, never an error) so the page resolves the model locally without a
  second round-trip.
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
  any in-flight or queued turn state held for the OUTGOING assistant (if the turn
  pipeline is ever made asynchronous — v1's synchronous per-request pipeline has none to
  flush), load the target assistant's selection state, and keep BOTH assistants'
  background work (task queues, distillers) running throughout, unaffected by the
  switch.
- §7.8 WHEN an assistant becomes active THE SYSTEM SHALL present an activation digest of
  its background activity since last active (completed/failed tasks, minted notes),
  sourced from its trace events (`traces.sqlite`, §10.2) where available, falling back
  to `brain-events.jsonl`/`session.jsonl` for notes/exchanges until the per-assistant
  task trace exists.

## §8 Conversation turns

- §8.1 WHEN a user message arrives THE SYSTEM SHALL execute its initial completion
  as one stateless provider-CLI invocation (`codex exec --json -m <model>` /
  `claude -p --output-format json` or supported `stream-json`) via the adapter
  interface `complete(context) -> {text, usage, timings}`. WHEN a supported adapter
  exposes a streaming callback THE SYSTEM SHALL accept incremental text while
  returning the same authoritative final result. The one same-turn capability
  follow-up permitted by §11.5 SHALL use the same optional streaming interface.
  IF the installed CLI cannot expose incremental text THEN THE SYSTEM SHALL use
  its blocking completion exactly once; THE SYSTEM SHALL NOT simulate streaming
  by splitting a completed answer or retry an already-started completion.
- §8.2 THE SYSTEM SHALL build the turn context as: systemPrompt persona + names + roster
  (§11) + rolling summary + top-k recalled notes + last N turns (N≤6) + user message,
  under a hard total budget (≤ ~6k tokens) with per-component caps; the rolling summary
  SHALL be size-capped and refreshed every K turns; recalled notes SHALL render AFTER
  the rolling summary so a note that contradicts a stale summary wins by prompt-order
  recency (note wins).
- §8.3 THE SYSTEM SHALL pass the RAW user message to recall (hybrid lexical+embeddings,
  §9) and SHALL render which notes fired as recall chips on the reply.
- §8.4 Turns SHALL run answer-only: adapters SHALL pin isolation flags (no user-global
  instruction ingestion; no plugin/skill surface from the dev workflow; harness tool use
  disabled). Agentic work happens via dispatched harness jobs (§9.4), never inside turns.
  EXCEPTION, file production (the workdir publish relay): WHEN the engine resolves a
  sanctioned per-turn `fileOutputDir` the adapter MAY open a write surface scoped to the
  turn's own isolated throwaway workdir (claude: Write-tool flags + pinned cwd; codex:
  `-s workspace-write` + pinned `-C` and cwd) — a turn with no `fileOutputDir` keeps the
  fully read-only posture. Publishing moves only regular files (never symlinks or
  multi-link entries) from that workdir into the sanctioned directory, atomically and
  cross-filesystem-safe.
- §8.5 IF the provider CLI exits nonzero, times out (mandatory timeout), emits
  malformed protocol output, or ends without its authoritative final result THEN
  THE SYSTEM SHALL surface a bounded-time, specific error in the overlay —
  including an auth-expired state instructing `codex login`/`claude auth login`.
  THE SYSTEM SHALL NOT treat partial text as a successful reply. Streaming
  transport SHALL drain both child pipes, bound buffered output and elapsed time,
  terminate and reap owned process groups on failure or cancellation, and clean
  isolated temporary directories while retaining the hardened file publication
  relay. A stalled reader or descendant holding a pipe SHALL NOT defeat those
  bounds.
- §8.6 WHILE a turn is in flight and no public text has arrived THE SYSTEM SHALL
  show an elapsed-time thinking state; chat input SHALL remain open (messages
  queue). WHEN safe public text arrives THE SYSTEM SHALL replace thinking with
  live text in the existing assistant reply row. THE SYSTEM SHALL preserve
  sticky scrolling, final Markdown, recall chips and one voice output per final
  reply. WHEN the selected assistant changes THE SYSTEM SHALL discard outgoing
  stream events and errors without altering the incoming assistant's rows,
  queue, timer or in-flight state.
- §8.7 THE SYSTEM SHALL append each exchange to the session transcript (append-safe
  JSONL, fsync'd) so a crash loses at most the in-flight turn.

- §8.8 WHEN `POST /assistant/chat` receives `Accept: text/event-stream` THE SYSTEM
  SHALL negotiate SSE using typed JSON events: `start` with `turn_id`, `text`
  with completion `phase` and cumulative sanitized `text`, `done` with the
  existing final chat payload, or `error` with a specific error. Content-free
  heartbeats MAY maintain liveness. A successful stream SHALL have one `done`;
  a failed connected stream SHALL have one `error`; EOF without a terminal event
  SHALL be a failure. Requests without stream negotiation and validation errors
  before stream start SHALL retain the existing JSON contract. The browser SHALL
  accept a JSON response from the same request without retrying it.
- §8.9 THE SYSTEM SHALL emit and flush genuine safe provider text before provider
  completion, targeting first visible text within roughly two seconds when the
  provider emits promptly. Deterministic HTTP and browser tests SHALL prove this
  ordering and prompt delivery. Actual CLI startup/reasoning latency SHALL be
  recorded separately without promising the two-second target for every real
  invocation. First-visible timing SHALL start before context composition and
  count only safe public text, separately from completion timing.
- §8.10 THE SYSTEM SHALL retain context budgets, enabled-capability gates,
  per-assistant serialization and durable session/transcript updates for streamed
  turns. Partial failed initial completions SHALL NOT be saved as successful
  exchanges. Streaming SHALL retain subscription authentication and pinned
  isolation; no metered API or persistent session SHALL be introduced.

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
  A capability whose `capability.yaml` declares `longRunning: true` is a second,
  lighter-weight async mechanism: routed through the task queue under its own (more
  generous) bound instead of invoked inline, with the reply directing the user to the
  artifact panel for the result.
- §9.5 Turns SHALL never block on the distiller, index refresh, or any task.
- §9.6 Inactive assistants' queues/distillers SHALL continue running (feeding §7.8's
  digest).

## §10 Observability (event-sourced)

- §10.1 THE SYSTEM SHALL emit an ordered event stream per assistant: turn.*, recall.*,
  prompt.*, provider.*, skill.*, distill.*, task.*, remote.command.*, tts.*, stt.* —
  each event carrying monotonic seq, ts, session_id, turn_id, span_id, parent_span_id,
  kind, skill, modality, status, and a JSON payload (including said/heard text where
  applicable). Managed remote events SHALL carry an engine-generated command ID and
  linked turn/task/span identifiers.
- §10.2 traces.sqlite is the source of truth: append-only events table, WAL,
  busy_timeout, single writer thread; INDEXED first-class columns (seq, ts, session_id,
  turn_id, span_id, parent_span_id, kind, skill, modality, status) so time-range,
  ordering, and correlation queries never depend on json_extract.
- §10.3 Retention SHALL be configurable by age AND size (retainDays, maxMB; 0 =
  unlimited), pruning oldest first; defaults 30/500.
  WHEN enforcing maxMB, THE SYSTEM SHALL measure the compact physical main
  database, including schema and indexes, after making committed WAL changes
  current in that file and reclaiming the WAL. THE SYSTEM SHALL NOT delete
  additional history based on a stale main-file size. Transient WAL and SHM
  storage SHALL NOT be counted as additional retained trace data.
  WHEN a reader prevents the checkpoint required for physical reclamation,
  THE SYSTEM SHALL defer further size-based deletion until a later retention
  pass without waiting or retrying that checkpoint in the current pass. Age
  pruning SHALL still apply. Physical storage MAY temporarily exceed maxMB
  while readers pin history, or while the bounded size-pruning pass has not
  yet converged. THE SYSTEM SHALL NOT report logical compaction alone as
  successful physical shrink.
  Remote audit events SHALL remain prunable under the same age/size policy, including
  reader-held WAL checkpoint deferral. Trace retention SHALL NOT remove or require
  the continued presence of task reconciliation state in tasks.sqlite.
- §10.4 Prometheus exposition (host/port, enabled flag) SHALL serve computed
  histograms/counters and SHALL NOT own history; page/terminal metrics views query
  sqlite directly.
- §10.5 Surfaces: voice-panel metrics expansion (latency percentiles, per-area graphs,
  per-turn trace waterfall inspector with errors inline); `/assistant/metrics`,
  `/assistant/traces?since=&turn=`; terminal `metrics`, `trace [turn|last]`,
  `events --since <dur>`.
- §10.6 Every error (turn, skill, task, remote command) SHALL be a first-class event
  linked from its turn/task.
  Managed remote errors and refusals SHALL use bounded structured reason codes;
  raw exception strings, argv, credentials, configuration and remote stdio SHALL NOT
  enter trace or task persistence through adjacent skill/task error paths.
- §10.7 Durability classes: embeddings index = derived/rebuildable; traces = prunable
  history; tasks.sqlite = must-survive.
  A background remote worker SHALL receive a bounded acknowledgement of the trace
  writer's committed intent before invoking transport. Queue admission or completion
  SHALL NOT constitute that acknowledgement. Acknowledged records SHALL be frozen
  and validated before enqueueing; malformed records SHALL NOT use the best-effort
  serialization marker fallback. Ordinary emit callers SHALL remain nonblocking.
  Audit admission failure SHALL prevent transport; failed terminal acknowledgement
  SHALL surface uncertainty without replay. Late intent commits after timeout SHALL
  NOT authorize delayed effects. Storage loss or a crash between effect and terminal
  persistence MAY leave incomplete history; THE SYSTEM SHALL NOT claim successful
  audit in those windows.

## §11 Capabilities (skills) & roster

- §11.1 A skill is `.claude/skills/<name>/` with SKILL.md and optional capability.yaml
  {version, provisioning.check (TTL-cached), permissions, invoke}; base capabilities
  ship in-plugin with the same shape. v1 discovery: installed-in-repo only (NG7).
  WHEN an operator explicitly installs comfyui-render, THE SYSTEM SHALL copy only
  skill data and bind absolute v1 check/invoke argv to the plugin engine, preserve
  symlink interpreter identity, refuse existing destinations and literal braces in
  binding paths before writes, and never enable the capability automatically.
- §11.2 Enablement: only `assistant.capabilities.<name>.enabled: true` skills load;
  disabled skills SHALL be invisible (no roster, no prompt, never executed);
  project.yaml provisioning overrides localize the skill's defaults.
- §11.3 The engine SHALL compile a capability index {name, one-liner, keywords,
  embedding, enabled, provisioned-ok} on start and on change; the per-turn roster SHALL
  be relevance-filtered top-N with a hard cap; ties/low confidence → the assistant asks
  instead of guessing. A turn whose best-scoring capability has NO relevance signal at
  all (a query unrelated to every installed capability) SHALL yield an empty roster, not
  an ask — the ask-instead-of-guess behavior applies only when at least one capability
  plausibly matched but the choice among matches was ambiguous or too weak to trust.
- §11.4 Unprovisioned-but-enabled skills SHALL appear in the roster as unavailable with
  the reason; THE SYSTEM SHALL never present an unavailable ability as usable.
- §11.5 `invoke.exec` SHALL be an argv ARRAY; placeholder substitution occurs only within
  single argv elements, after validation against the skill's declared parameter schema
  (type/pattern/allowlist); THE SYSTEM SHALL never pass invoke commands through a shell.
  Invocation is reachable from a live turn via a single fenced ```capability JSON
  directive in the model's reply (line-anchored, one per turn, trailing-element rule
  taught via the roster prompt and enforced by the parser), stripped from the visible
  reply engine-side; the result feeds exactly one size-capped same-turn follow-up
  completion, and a follow-up failure degrades to a result-bearing reply rather than
  discarding an executed invocation.
  THE SYSTEM SHALL allow replacement only of declared existing typed literals,
  preserving node classes, links, topology and pre-authored output paths. Before
  POST, THE SYSTEM SHALL inspect native object_info for available nodes, inputs and
  model enum values, reporting bounded actionable dependency identifiers.
  WHEN either completion streams THE SYSTEM SHALL withhold possible line-anchored
  capability-fence prefixes across arbitrary chunk boundaries and hide complete,
  malformed and unterminated directive blocks before public emission. Provider
  message and text-block boundaries SHALL retain line boundaries before filtering,
  including tool cycles allowed by the existing file-output exception. Only main
  assistant text SHALL be public; thinking, signatures, tool/subagent output and
  duplicate snapshots SHALL NOT be emitted. A follow-up phase SHALL replace the
  provisional first reply; the final payload SHALL replace provisional text.
  Disconnect SHALL NOT cause another completion or effect. An already-admitted
  synchronous effect SHALL finish under its own deadline and retain a durable
  result-bearing outcome; cancellation SHALL prevent a not-yet-started follow-up.
- §11.6 capability.yaml `version` SHALL be checked against the engine's supported range;
  unsupported versions are unavailable-with-reason, never best-effort executed.
- §11.7 MCP servers are an invoke flavor (`invoke: {mcp: ...}`).
- §11.8 WHEN a request matches no enabled capability THE SYSTEM SHALL say so in-persona
  and MAY offer to acquire the ability by drafting a plan into the brain repo (parking
  lot); installation/enablement SHALL require human approval.
  The production trigger is an EXPLICIT capability request that fails to resolve by
  name — never a relevance-score threshold, and never plain conversation (which
  invokes no capability machinery at all).
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
  Managed remote tasks SHALL persist only validated nonsecret operation descriptors
  and projected useful results, excluding full manifests/configuration, raw argv/stdio
  and private or unknown fields. Validation and redaction SHALL precede queueing as
  well as SQL persistence, including adjacent skill events. Remote control SHALL
  always use the background task worker regardless of name casing or longRunning.
  Log/catalog text SHALL be bounded and redact known credentials and credential-bearing
  syntax before persistence without discarding useful nonsecret output. Escaped JSON
  credential keys and complete escaped quoted values, including single-quoted mixed
  log assignments, serialized JSON string values and escaped URI separators, SHALL
  NOT bypass redaction. Decoded object keys SHALL be sanitized as well as values;
  sensitive fields SHALL be classified using their original decoded names. Embedded
  JSON objects, arrays and quoted serialized strings in mixed text SHALL receive
  the same sanitization while preserving useful surrounding text. Structured
  sanitization SHALL bound recursion and mixed-text decode attempts, replacing
  content beyond those bounds rather than persisting it unchecked. This SHALL
  NOT change unrelated user-chat persistence or claim universal classification of
  private prose.
  WHEN enabled comfyui-render is requested, THE SYSTEM SHALL queue it independently
  of name casing or longRunning, validate its v1 parameter schema and fixed argv
  binding, and execute through the engine-owned native lifecycle. Only this kind
  SHALL use an opt-in deferred executor result; legacy executor/resolver returns
  SHALL retain their meanings. Periodic context-aware reconciliation SHALL report
  validated progress and recovery updates through the existing task writer.
  THE SYSTEM SHALL refuse credential-bearing values, including decoded known
  credential substrings in nested or embedded JSON strings, before queue/SQL
  persistence and on fresh operation authority checks; generic skill/task events
  SHALL NOT copy workflow/config/argv/stdio/private backend errors. This SHALL NOT
  alter ordinary user-chat persistence or claim universal private-prose detection.
  THE SYSTEM SHALL add optional recovery metadata through an atomic idempotent
  tasks.sqlite migration; legacy rows SHALL remain readable. Recovery SHALL contain
  only engine-generated request UUID, immutable deadline, policy/endpoint digest
  and submission phase; the existing external_job_id SHALL hold validated backend
  prompt identity. THE SYSTEM SHALL commit request identity before POST and backend
  identity before submission acknowledgement. Trace pruning SHALL NOT affect it.
- §12.4 WHEN the engine restarts THE SYSTEM SHALL reconcile the queue: tasks with an
  external_job_id are re-polled against the remote system before any resubmission;
  unreconcilable tasks become orphaned (surfaced, never silently re-run).
  Reconciliation (startup and periodic) SHALL open a root's queue only when the root is
  an assistant candidate AND already has a tasks database on disk — discovery of a repo
  is never a side effect that creates one.
  Reconciliation is additionally guarded by a per-root owner heartbeat (a single-row
  `task_owner` table in the same tasks database: engine id, pid, host, heartbeat ts,
  refreshed by the draining worker via progress reports and a timer backstop): both
  sweeps skip a root whose FOREIGN owner heartbeat is fresh; a stale heartbeat, or a
  same-host owner whose pid is dead, falls through to normal reconciliation, and roots
  skipped for ownership at startup are re-run startup-class once the owner stops
  blocking — crash recovery is bounded, never wedged. Graceful shutdown releases
  ownership; ownership lapses when a root has nothing in flight.
  Remote task IDs, external job IDs, ownership and minimal nonsecret descriptors
  required for reconciliation SHALL survive trace pruning. Restart recovery SHALL
  re-poll known external IDs under a fresh audited status operation, never replay
  the interrupted action based on missing trace history. Unknown IDs or unreconcilable
  jobs SHALL become orphaned. Uncertain failed tasks SHALL retain their IDs for
  inspection and SHALL NOT be silently retried. Existing task rows SHALL remain
  readable; this contract does not retroactively erase legacy persisted data.
  WHEN a response is lost, a process restarts, or terminal audit acknowledgement
  fails, THE SYSTEM SHALL NOT replay submission. Recovery SHALL reread enablement
  and policy, match exact owned request/client identity in bounded queue/history,
  and orphan zero, ambiguous, malformed or policy-rebound matches. Failed/uncertain
  tasks SHALL retain identifiers for operator inspection without automatic retry.
  Completion recovery MAY repeat safe inspection/download, never render submission.
  WHEN the backend prompt ID is known, recovery SHALL inspect bounded native
  `/history/<prompt-id>` independently of the recent-history window, still checking
  exact ownership and conflicting queue/recent-history matches. Malformed or
  oversized responses SHALL be refused. Unknown backend IDs MAY use bounded recent
  history and queue discovery; missing ownership SHALL NOT authorize resubmission.
- §12.5 WHILE tasks run, chat/voice remain fully usable; a queue indicator on the voice
  panel lists running/queued tasks; completion opens the artifact panel and announces
  (TTS when voice on); failures surface in-chat with the trace linked.

## §13 Voice

- §13.1 TTS: assistant replies SHALL be speakable via the existing speechSynthesis
  pipeline (echo-guard interplay preserved).
- §13.2 STT: THE SYSTEM SHALL support BOTH engines, selectable per-session in the
  neural-view voice ⚙ settings panel: `whisper` (whisper.cpp, fully local —
  the DEFAULT) and `web-speech` (the browser's Web Speech API, zero-install; audio
  leaves the machine to the browser vendor). The setting SHALL persist across page loads
  the same way the panel's other voice settings do. WHEN whisper.cpp is selected THE
  SYSTEM SHALL talk to a local whisper sidecar over a documented HTTP contract (a
  capability-provisioned process, out of THIS decision's scope — see the whisper
  capability, E6); WHEN the sidecar is unreachable THE SYSTEM SHALL surface an honest
  "whisper sidecar not available" state naming both the follow-up capability and the
  Web Speech alternative, never a generic/silent failure. Either engine's recognized
  text SHALL enter the SAME downstream text path as typed chat input — the engine API
  stays text-in/text-out regardless of the STT choice.
- §13.3 Voice metrics (STT/TTS spans) join the same trace stream.

## §14 Remote compute (E7 - WSL/ComfyUI)

- §14.1 Control plane: THE SYSTEM SHALL provide `remote-compute-control` for the
  approved WSL target with key-based SSH authentication ONLY, strict pinned host
  keys, and dedicated per-operation-class forced commands, never a blanket shell
  grant. The fixed administrator-selected `inspect` class SHALL permit only
  installed-capability inventory, job status and bounded logs; the fixed `cancel`
  class SHALL permit only identity-checked cancellation of an existing job.
  THE SYSTEM SHALL independently validate bounded versioned ASCII-safe requests
  and exact operation schemas on both client and server, refusing unknown fields,
  versions, operations and cross-class requests before any effect. THE SYSTEM
  SHALL isolate client SSH configuration, credentials, certificate/agent access,
  host trust, stdin, PTY, forwarding and connection reuse, and enforce finite
  subprocess deadlines and output bounds without broader-credential fallback.
  The target dispatcher SHALL run with isolated Python imports and absolute
  administrator-selected code/helper/state paths; code, grants and configuration
  SHALL be administrator-controlled, with no unrestricted alternative grant for
  the dedicated keys. Log access SHALL remain confined to the selected jobs root
  and reject symlinks and nonregular files. This control plane SHALL NOT provide
  arbitrary commands, launch, install, policy mutation, file transfer or tunnels,
  and SHALL NOT claim OS sandboxing of existing recipes.
- §14.2 Job plane: ComfyUI bound to localhost on the WSL target, reached exclusively
  through an SSH tunnel (never LAN-exposed); workflows submitted via its native
  HTTP/WS API; progress streams into trace events + the task queue; artifacts sync
  back over the same SSH.
  THE SYSTEM SHALL access ComfyUI only through its owned isolated OpenSSH local
  loopback forward to the fixed remote loopback port, verify startup/child liveness,
  and bound cleanup on every path. Native HTTP/WebSocket SHALL bypass environment
  proxies, refuse redirects, and bound total reads/frames including slow drip.
  Only owned prompt node/count progress SHALL enter tasks/traces; missing events
  SHALL NOT imply completion or fabricate elapsed-time progress.
  Optional WebSocket connection, handshake or stream failures SHALL retain native
  queue/history polling and SHALL NOT alone orphan an otherwise observable prompt.

  THE DEPLOYMENT SHALL use a dedicated tunnel-only account or separate listener
  with exact permitted destination, local-only TCP forwarding, no stream forwarding,
  no shell/subsystems, PTY, agent, X11, user rc or remote forwarding. MaxSessions 0
  SHALL NOT be applied to a shared existing control/human account or daemon. Local
  checks SHALL NOT claim remote enforcement. The endpoint grant SHALL be documented
  as access to the entire trusted ComfyUI service, not per-route authorization or an
  OS sandbox; ComfyUI SHALL remain loopback-bound and controller loopback protected.

  WHEN cancellation is requested, THE SYSTEM SHALL resolve an existing task within
  the same assistant and delete only a proved owned pending ID. THE SYSTEM SHALL
  never use global interrupt. Running cancellation SHALL remain pending/unsupported;
  an empty delete receipt plus later absence SHALL remain unknown. Expired deadlines
  SHALL attempt bounded safe pending deletion and state that running work may continue;
  closing the tunnel SHALL NOT be reported as remote execution cancellation.
  WHEN owned successful history declares the selected image, THE SYSTEM SHALL stream
  native view over the same owned tunnel, validate resource identifiers, size/type,
  symlinks and containment, and publish exclusively to a local path constructed solely
  from its task ID and trusted PNG type. Backend metadata SHALL never supply a local
  artifact path. Completion SHALL require validated transfer and audit acknowledgement.
  An identical recovered artifact MAY be reused; another task's file SHALL NOT be
  overwritten. Local image fixture proof SHALL NOT claim live GPU or video/3D evidence.
  Existing artifact destinations SHALL be opened without blocking and validated
  through the opened descriptor before reading; nonregular files SHALL fail the
  task without blocking the task worker.
- §14.3 Every engine-managed remote operation SHALL have linked intent and terminal
  trace evidence distinguishing success, refusal, failure, confirmed cancellation,
  pending cancellation and unknown cancellation, subject to §10.3 retention and the
  remote redaction policy. Enablement, validation, provisioning and local admission
  refusals SHALL be linked; pre-worker refusals MAY have an outcome without intent.
  Audit metadata SHALL be bounded explicit operational fields, never raw commands,
  credential paths, workflows, configuration or stdout/stderr. Unknown output SHALL
  NOT select an assistant root, database, audit context or artifact path. The audit
  context SHALL be engine-owned. Direct human diagnostic CLI/library calls and the
  separate human controller SHALL retain compatibility and SHALL NOT be represented
  as assistant trace producers. AST-081 submit/status/cancel/transfer executors SHALL
  bind the reusable audit boundary, preserve external IDs before returning effects,
  and construct artifact destinations engine-side. AST-082's local transfer callback
  verification SHALL NOT claim an actual transfer feature.
  Transfer receipts SHALL require a nonnegative integer byte count and explicit
  state. Only `done` or `completed` SHALL constitute success (including an empty
  completed transfer). `failed` SHALL audit failure; `cancelled` SHALL audit
  cancellation; `unknown`/`lost` SHALL audit unknown; and `queued`, `started`,
  `progress`, `running`, `reserved`, `pending` or `cancelling` SHALL audit pending.
  Non-success receipts SHALL raise sanitized errors after outcome persistence,
  never report task completion or trigger automatic replay. Missing, unrecognized
  or ill-typed states/counts SHALL be malformed receipts and audit failure.
  THE SYSTEM SHALL wrap submit/status/cancel/transfer with acknowledged audit intent
  before effects and terminal outcomes afterward. Ambiguous submission SHALL audit
  unknown, never confirmed success. Audit failure SHALL prevent admission or report
  post-effect uncertainty without replay; crash windows SHALL remain explicit.
- §14.4 Hosts SHALL be explicitly allowlisted in the installed capability manifest's
  `provisioning.hosts` mapping; anything else SHALL be refused. Each approved
  nickname SHALL declare literal host, port, user, absolute pinned known-hosts path,
  and separate dedicated inspect/cancel key paths. The client SHALL reread this
  policy on every invocation. Remote-compute registration and project provisioning
  check/TTL overrides SHALL NOT grant or override this host authority. Explicit
  human installation SHALL copy only skill data into the assistant repository,
  bind the absolute Python interpreter path without dereferencing its symlinks
  (preserving virtual environment identity) and the resolved absolute plugin engine
  path in version-1 check/invoke argv, preserve an existing installation by refusal,
  and never copy engine code or enable the capability. Literal interpreter, engine and target
  manifest binding paths containing either brace SHALL be refused before any
  installer writes; ordinary spaces SHALL remain supported. Generic adapter
  substitution semantics SHALL remain unchanged. Invocation SHALL use the existing
  enablement, schema-validated argv and long-running task mechanisms without relying
  on engine cwd. Local provisioning
  checks SHALL distinguish local prerequisites from live server enforcement.
  THE SYSTEM SHALL read installed host/workflow provisioning for each operation,
  including recovery; project check/TTL overrides and registry membership SHALL NOT
  grant render authority. Each named host SHALL specify literal SSH endpoint/user,
  port, pins, one dedicated tunnel key and a loopback ComfyUI port. Each named workflow
  SHALL pin pre-authored API JSON by SHA-256, a finite timeout, typed scalar bindings
  and one output selection. Unknown fields and model-selected paths, endpoints,
  executables, graphs, timeout overrides and output destinations SHALL be refused.

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
11. A task executor never persists an `artifact_path` it did not itself construct.
    Artifact paths are built engine-side from the task's own id; an executor SHALL
    NEVER accept, parse, or otherwise adopt a path (or path-shaped field) supplied by
    a dispatched job's own output, response, or anything else crossing the process
    boundary.

## §18 Open questions

- OQ1 (owner: human; default: Web Speech behind a config flag, revisit for whisper.cpp)
  — STT provider for E5.
- OQ2 (owner: dev at E1; default: single `assistant` session id per repo) — whether
  sessions ever fork (e.g. per-device) before multi-assistant concurrency.
- OQ3 (owner: human; default: off) — trace payload redaction default once voice lands.
- OQ4 (owner: dev at E6; default: engine-side queue cap 3 concurrent harness jobs) —
  concurrency limits for dispatched jobs.
