# BACKLOG-ASSISTANT — epics & tasks for SPEC-ASSISTANT.md

Task prefix **AST**. Ranges: E0=001–009, E1=010–019, E2=020–029, E3=030–039, E4=040–049,
E5=050–059, E6=060–079, E7=080–089, E8=090–099. Every task cites the spec §s it
implements; complexity 1–10 (seed-board rubric); priority P1>P2>P3.

## E0 — Foundations (config, identity, brain library) — AST-001..009

- **AST-001** Marker key=value grammar + legacy tolerance. (§6.2) — P1, 3pts
  AC: parser accepts key=value lines, `#` comments, unknown keys; legacy comment-only and
  empty markers valid; unit section covers all fixtures incl. today's shipped marker
  content verbatim.
- **AST-002** `assistant:` project.yaml schema + validate-config. (§6, §6.1, §6.5) — P1, 4pts
  AC: schema validates names (non-empty, first=main), systemPrompt, llm, capabilities,
  observability (retention knobs); provider↔capability consistency enforced with specific
  messages; invalid sections rejected by validate-config with path-precise errors.
- **AST-003** brain.py library extraction: `recall()`/`mint()` structured API. (§5a) — P1, 6pts
  AC: engine-importable functions return structured results; no argparse/stdout coupling;
  CLI delegates to the same functions byte-identically (existing tests green unchanged).
- **AST-004** Atomic brain writes + cross-process flock. (§5a, §17.5) — P1, 5pts
  AC: all brain.py write paths use tmp+rename under a shared flock; concurrent
  CLI-mint × engine-recall stress test shows no torn JSON/lost update; recall link-bumps
  covered.
- **AST-005** `/setup-assistant` skill: bare-brain scaffold + settings editor. (§6.4, §6.7, §11.9) — P1, 5pts
  AC: scaffolds marker, project.yaml assistant section, brain dirs, persona AGENTS.md,
  gitignores for all local state; re-run is idempotent; can flip capabilities/provider/
  model and set the machine-local default (§6.3).
- **AST-006** Preflight assistant checks with enumerated failures. (§6.6) — P2, 3pts
  AC: each negative case (bin missing, unauthenticated, invalid section, provider
  mismatch, legacy marker) produces its specified message; positive path cached.
- **AST-007** Machine-local default assistant store + ambiguity errors. (§6.3, §7.6) — P2, 2pts
  AC: default stored in neural-view local state; duplicate/missing default errors list
  candidates; never written to tracked files.

## E1 — Engine core & gates — AST-010..019

- **AST-010** Engine package skeleton + route table + lifecycle wiring. (§5a) — P1, 5pts
  AC: `scripts/assistant/` package with the mandated modules; neural-view.py diff limited
  to lifecycle+mount; /assistant/status serves; worker threads start/stop cleanly with
  the server.
- **AST-011** Adapter interface + codex adapter (isolation, no-tools, timeout). (§8.1, §8.4, §8.5) — P1, 6pts
  AC: `complete(context)` contract; codex exec --json invoked with pinned isolation and
  answer-only flags; mandatory timeout; nonzero/unparseable/auth-expired mapped to
  specific error states; stub-binary contract tests.
- **AST-012** claude adapter on the same contract. (§8.1, §8.4) — P2, 3pts
  AC: claude -p --output-format json behind the same interface + isolation flags; stub
  contract tests; switching provider is config-only.
- **AST-013** Turn pipeline: context builder + budgets + recall injection. (§8.2, §8.3, §9.1) — P1, 6pts
  AC: persona+roster+notes+summary+turns composed under total & per-component caps
  (asserted); raw message → hybrid recall with query-embed cache; recall chips data in
  the reply payload; summary refresh every K turns, size-capped.
- **AST-014** Session store: append-safe transcript + rolling summary. (§8.7) — P1, 4pts
  AC: fsync'd JSONL appends; crash loses at most in-flight turn (kill-test); history
  endpoint returns last N.
- **AST-015** Harness-contamination isolation test. (§8.4, §16) — P1, 3pts
  AC: merge-gating test dumps a turn's effective injected context and asserts no
  dev-workflow skill/instruction text appears for both adapters.
- **AST-016** Terminal smoke chat + status/default subcommands. (§7.6) — P2, 3pts
  AC: `neural-view assistant chat|status|default` work headless against the engine with
  --assistant resolution order per spec.
- **AST-017** E1 numeric gates harness. (§15 N1–N5) — P1, 5pts
  AC: scripted 20-turn run records p50/p95/variance/tool-use-rate; recall p95 incl. embed
  hop; page-isolation concurrent test; kill -9 mid-turn recovery; logged-out bounded
  failure — all automated, results recorded; N1 threshold check is the E2 unblock.
- **AST-018** Embeddings-on-by-default recall wiring + index refresh hook. (§9.1, §9.3) — P1, 4pts
  AC: fixture brain with embeddings answers a vague-topic query that lexical-only misses;
  refresh after mint makes a new note recallable within one batch cycle.

## E2 — Selection UX & chat overlay — AST-020..029

- **AST-020** Discovery of assistant repos (config-authoritative). (§7.1) — P1, 3pts
  AC: scan flags repos with valid enabled assistant sections; disabled/invalid counts as
  none; unit fixtures for all §7 table rows.
- **AST-021** Startup selection: silent single, picker w/ Skip, none-overlay. (§7.2–§7.4) — P1, 5pts
  AC: all four table behaviors; red overlay + hover explainer; skip disables voice+chat;
  header shows main name.
- **AST-022** Server-side selection memory + ask-again setting + ⚙ switcher. (§7.5) — P2, 4pts
  AC: selection consistent across tabs/terminal; page setting toggles ask-on-load;
  switcher in voice ⚙.
- **AST-023** T-key chat overlay (full UX). (§8.6, §5-surfaces) — P1, 6pts
  AC: T opens bottom-center dialog (outside inputs), Esc closes; last-X toggle 1–3;
  Enter sends; queued input while thinking; elapsed-time state; recall chips rendered;
  offline/gated/auth states; HUD styling.
- **AST-024** Switch flow: flush, reload, activation digest. (§7.7, §7.8) — P2, 4pts
  AC: switching preserves both assistants' background work; digest summarizes tasks/notes
  since last active from trace events.

## E3 — Distiller & self-feedback — AST-030..039

- **AST-030** Distiller worker: batched mint+bump. (§9.2, §9.5) — P1, 5pts
  AC: batches every N exchanges; mints/bumps via library API through the writer queue;
  never blocks turns (latency assertion under active distilling); v1 performs no
  merge/retire.
- **AST-031** Index refresh cycle post-mint. (§9.3) — P2, 2pts
  AC: new notes recallable within one batch cycle (integration fixture).
- **AST-032** Rolling summary maintenance. (§8.2) — P2, 3pts
  AC: refresh every K turns, capped size, stale-summary regression fixture (summary never
  contradicts a fresher note in-prompt: note wins ordering documented).
- **AST-033** Background continuation for inactive assistants. (§9.6) — P2, 3pts
  AC: inactive assistant's distiller/task workers keep running; digest source events
  recorded.

## E4 — Observability — AST-040..049

- **AST-040** Event emitter + traces.sqlite writer (schema, WAL, single writer). (§10.1, §10.2) — P1, 6pts
  AC: all event kinds emitted with first-class columns; concurrent emission stress shows
  ordered seq, no SQLITE_BUSY loss; correlation query fixtures (turns×skills×text) use
  indexes (EXPLAIN checked).
- **AST-041** Retention pruning (age+size knobs). (§10.3) — P2, 3pts
  AC: retainDays/maxMB enforced prune-oldest; 0=unlimited; config-driven.
- **AST-042** Prometheus exposition endpoint. (§10.4) — P2, 3pts
  AC: host/port serve histograms/counters; disabled flag = no listener; sqlite remains
  authoritative for views.
- **AST-043** /assistant/metrics + /assistant/traces endpoints. (§10.5) — P1, 3pts
  AC: since/turn filters; page+terminal share them.
- **AST-044** Voice-panel metrics expansion: graphs + trace waterfall inspector. (§10.5) — P1, 6pts
  AC: percentile/per-area graphs; pick a turn → span waterfall + event timeline with
  errors inline; HUD styling.
- **AST-045** Terminal metrics/trace/events commands. (§10.5) — P2, 3pts
  AC: metrics tables/sparklines; trace waterfall text; events --since tail; --assistant
  resolution honored.

## E5 — Voice — AST-050..059

- **AST-050** TTS wiring: replies speakable, echo-guard preserved. (§13.1) — P1, 4pts
  AC: reply → speechSynthesis when voice on; echo guard ducks inbound during speech;
  spans traced.
- **AST-051** STT decision spec-delta + implementation. (§13.2, OQ1) — P1, 6pts
  AC: recorded decision delta; chosen path implemented; mic → text → turn round trip;
  spans traced.
- **AST-052** Voice-driven turn UX (speak → reply spoken + overlay sync). (§13) — P2, 4pts
  AC: full voice loop with visualizer active; chat overlay mirrors the exchange.

## E6 — Capabilities, artifacts, tasks — AST-060..079

- **AST-060** capability.yaml schema + version negotiation. (§11.1, §11.6) — P1, 4pts
  AC: schema validated; unsupported version = unavailable-with-reason, never executed.
- **AST-061** Capability index + bounded relevance-filtered roster. (§11.3) — P1, 5pts
  AC: compiled on start/change; roster top-N hard cap; tie/low-confidence yields
  ask-instead-of-guess behavior in the turn contract.
- **AST-062** Provisioning checks (TTL cache) + unavailable-with-reason. (§11.4) — P2, 3pts
  AC: failing check marks unavailable + reason in roster; cache TTL honored.
- **AST-063** Argv-array invoke with schema-validated params. (§11.5, §17.3) — P1, 5pts
  AC: no shell anywhere in the invoke path; injection-attempt fixtures (`; | $() &&`)
  land as literal argv text; type/pattern/allowlist validation errors are specific.
- **AST-064** MCP invoke flavor. (§11.7) — P2, 4pts
  AC: a capability can reference an MCP server; one round-trip invocation fixture.
- **AST-065** Enablement gating end-to-end. (§11.2, §17.2) — P1, 3pts
  AC: disabled skill absent from roster/prompt/index; execution attempt refused; enabled
  provisioning overrides localize defaults.
- **AST-066** tasks.sqlite queue + worker + states. (§12.3) — P1, 5pts
  AC: full state machine w/ transitions as trace events; queue indicator data endpoint.
- **AST-067** Restart reconciliation (external_job_id re-poll, orphans). (§12.4) — P1, 4pts
  AC: restart with in-flight external job does NOT resubmit (re-polls); unreconcilable
  → orphaned + surfaced.
- **AST-068** /assistant/artifact streamed range endpoint. (§12.2) — P1, 4pts
  AC: range requests streamed (no whole-file-in-RAM), scoped to artifacts dir; video
  seek fixture.
- **AST-069** Artifact panels with entrance animations. (§12.1) — P2, 5pts
  AC: 3D/image/video open in existing viewers with entrance animation; progress state
  fed by trace events; chat turn links artifact+trace.
- **AST-070** Dispatched harness jobs as task kind. (§9.4) — P1, 5pts
  AC: agentic CLI run queued with own sandbox posture; progress/report/announce flow;
  conversation resumable mid-job; full tracing.
- **AST-071** Capability-gap flow (honest + acquire offer, parking lot). (§11.8) — P2, 4pts
  AC: unmatched request → in-persona refusal naming nearest abilities; acquire offer
  drafts plan notes; nothing installs/enables without human approval.

## E7 — Remote compute (Windows/ComfyUI) — AST-080..089

- **AST-080** remote-windows capability: scoped SSH control plane. (§14.1, §14.4) — P1, 6pts
  AC: key-only auth, pinned host keys, per-operation-class forced commands (no blanket
  shell); allowlisted hosts; refusal paths tested with fixtures.
- **AST-081** comfyui-render capability over SSH tunnel. (§14.2) — P1, 6pts
  AC: ComfyUI reached only via tunnel (never LAN); workflow submit + progress → trace
  events + task queue; artifact sync back over SSH.
- **AST-082** Remote command audit + retention interplay. (§14.3) — P2, 2pts
  AC: every remote command an event; redaction/retention applied.
- **AST-083** E2E: "generate a 3d model of a duck" → panel. (§12, §14) — P2, 4pts
  AC: chat request → queued job → progress → artifact panel entrance with the generated
  model; failure path surfaces trace.

## E8 — Later: note lifecycle & retro — AST-090..099

- **AST-090** Merge/retire/aggregate primitives in brain library. (NG3 lift) — P2, 6pts
- **AST-091** Distiller lifecycle use of the primitives (guarded). — P2, 4pts
- **AST-092** End-of-session retro consolidation pass. — P2, 4pts

Dependency guards: E1 blockedBy E0; E2 blockedBy E1 (N1 gate); E3 blockedBy E1;
E4 blockedBy E1; E5 blockedBy E2; E6 blockedBy E2; E7 blockedBy E6; E8 blockedBy E3.
