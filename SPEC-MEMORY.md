# memory-scaling — identity-brain memory spec (v1)

> Research provenance: deep-research report at
> https://claude.ai/code/artifact/791dd244-e622-4299-9e67-6c5153d9d595 (cited studies:
> A-MEM/NeurIPS 2025, HippoRAG 2/ICML 2025, Zep/Graphiti, Memanto, Reflexion line,
> ASG-SI, Microsoft agentic-evolution survey, From-Recall-to-Forgetting).
> Seed: `docs/design/memory-scaling-spec-seed.md` (superseded by this document).

## §1 Overview

The per-identity zettel brains (`brain.py`) and neural-view are today per-repo,
machine-local, keyword-recall-only, and append-forever. This spec scales them
**horizontally** (all projects on one timeline, N concurrent sessions without races,
groundwork for N machines) and **vertically** (retrieval quality that does not degrade
as notes accumulate), while keeping markdown files the human-readable source of truth.
Everything is **additive-only**: each mechanism is opt-in, defaults preserve current
behavior, and no existing flow breaks when a new component is absent.

## §2 Goals

- **G1** — Feedback episodic store stays bounded: routed feedback is archived, the
  active feed is O(pending). (§6)
- **G2** — Every consumer repo gets a correct, canonical local-state `.gitignore`
  managed idempotently. (§7)
- **G3** — Every memory operation is observable as a typed event on a per-repo
  append-only feed; cross-repo activity merges at read time. (§8)
- **G4** — Recall combines embedding similarity with graph traversal (PPR) and meets
  the §13 latency budget at 10k notes. (§9)
- **G5** — The write path prevents degradation: new notes link/evolve/supersede
  existing ones instead of silently accumulating near-duplicates and contradictions. (§10)
- **G6** — Neural-view renders the unified feed live: cross-repo constellations,
  ghosted superseded synapses, provenance on click. (§11)

## §3 Non-goals (v1)

Named follow-up specs — deferred, not dropped:

- **Voice** — Mac-hosted STT/TTS reproducible setup (separate spec).
- **Fleet / capability bus** — processing-power workers on other machines, job
  queues, machine constellations in neural-view (separate spec; §9's sidecar install
  pattern is its seed).
- **External AI provider capabilities** — ChatGPT/OpenAI integration (image
  generation, complementary-model workflows) belongs to the capability-bus spec.
- **Event-sorc substrate commitment** — no Mongo/event-store dependency in v1; the
  §8 feed is designed to migrate INTO one later (Option B) without rework.
- **Off-the-shelf memory products** (Letta/Zep/Mem0) — patterns borrowed, products
  not adopted.
- **Cross-role brain reads** — role privacy model is unchanged; `consult` remains the
  only cross-role path.

## §4 Glossary

- **Brain** — `.claude/identities/<role>/brain/`: `notes/*.md` zettels + `links.json`
  + `.activation.jsonl`.
- **Episodic / semantic / procedural memory** — raw timestamped history (feeds,
  events) / distilled notes+links / skills & rules. The self-improvement loop is
  episodic → (retro) → semantic → (graduation) → procedural.
- **Brain-event feed** — per-repo `.claude/brain-events.jsonl`, append-only typed
  events (§8.2), the episodic record of memory operations.
- **PPR** — Personalized PageRank seeded from matched notes, run over the link graph;
  the principled generalization of the current 2-hop × 0.5-decay spread.
- **Supersede** — bi-temporal invalidation: a note/link marked obsolete by a
  successor is kept, never injected, never deleted.
- **OKF** — Google's Open Knowledge Format: markdown + YAML frontmatter with a
  required `type` field. Notes are OKF-compatible.
- **Sidecar** — the optional embedding capability: isolated venv + ONNX runtime +
  SQLite index. First instance of the modular capability-install pattern.
- **Managed block** — a marker-delimited region of `.gitignore` owned by the plugin.

## §5 Architecture

- **Files are canon.** Notes, `links.json`, feedback feed: authoritative, committed
  (§7.3), git history is the audit trail. Every derived layer (embedding index, PPR
  adjacency, event folds) is rebuildable from files + feed alone.
- **Dual-write, not migrate.** `brain.py`/`feedback.py` keep their file writes
  byte-identical to today and additionally append events (§8). The feed is
  observability + episodic history + a future migration format; it is never load-bearing
  for current behavior unless a documented opt-in flag says so.
- **Merge at read.** Cross-repo views (neural-view, future cross-repo recall) merge
  per-repo feeds at read time using byte-offset cursors — the mechanism
  `neural-view.py` already uses for `.activation.jsonl`. No hub file, no second writer.
- **Capability modules.** Optional components (the §9 sidecar) install into
  `.claude/capabilities/<name>/` (self-contained venv + manifest), are detected at
  runtime, and degrade gracefully when absent. Core scripts stay stdlib-only.
- **Substrate deferral.** Option A (files+sidecar forever) vs Option B (event-sorc
  backbone) is decided no earlier than multi-machine work; §8 events are the
  Option-B migration payload, so nothing built here is throwaway.

## §6 Feedback lifecycle (E0)

- **§6.1 archive subcommand** — WHEN `feedback.py <root> archive` is invoked THE
  SYSTEM SHALL move every feed document whose items ALL have a `routing.action` to
  `.claude/feedbacks/archive/<YYYY-MM>.yaml` (month = the document's `ts`), preserving
  document content byte-for-byte, and SHALL leave documents with ≥1 unrouted item in
  the feed untouched.
  - **§6.1.1** — WHEN `archive` runs THE SYSTEM SHALL write atomically (temp file +
    rename per touched file) and SHALL be idempotent (second run = no-op, exit 0).
  - **§6.1.2** — IF the feed contains a document that fails to parse THEN THE SYSTEM
    SHALL abort without modifying any file and print the offending byte offset.
- **§6.2 pending unchanged** — WHILE archives exist `feedback.py pending` SHALL
  return exactly what it returns today for the active feed (archives are not scanned).
- **§6.3 archive query** — WHEN `feedback.py <root> archived [--since YYYY-MM]` is
  invoked THE SYSTEM SHALL list archived documents (same rendering as `pending`)
  across archive files, filtered by month when given.
- **§6.4 retrospective integration** — WHEN the retrospective protocol completes
  routing THE SYSTEM SHALL run `archive` as its final feed step and commit feed +
  archives together (retrospective + build-next docs updated accordingly).
- **§6.5 commit policy** — Feedback feed and archives are tracked by default. THE
  SYSTEM SHALL NOT gitignore `.claude/feedbacks/`; this repo's `.gitignore` line
  ignoring it is removed and the feed/archives committed (migration task).
- **§6.6 emit/route untouched** — `emit` and `route` behavior/formats are unchanged
  (additive-only).

## §7 Local-state gitignore management (E1)

- **§7.1 canonical manifest** — THE SYSTEM SHALL define ONE machine-readable manifest
  in the plugin (`scripts/local-state.manifest`, shell-and-python readable) listing
  every path the plugin writes at runtime with a policy: `ignore` (local state) or
  `track` (shared memory). Initial policies: ignore `.claude/CHECKPOINT`,
  `.claude/ITERATIVE_UI_OFF`, `.claude/ui-hub/`, `.claude/gate-pass`,
  `.claude/telemetry.jsonl`, `.claude/lessons.jsonl`, `.claude/board-queue.jsonl`,
  `.claude/board-cache.json`, `.claude/neural-view/`, `.claude/merge-requirements.json`,
  `.claude/.flush*`, `.claude/worktrees/`; track `.claude/feedbacks/`,
  `.claude/identities/`, `.claude/brain-events.jsonl`, `.claude/.neural-network`,
  `.claude/project.yaml`.
- **§7.2 managed block** — WHEN setup-project (or the new `gitignore-sync` script)
  runs THE SYSTEM SHALL write the `ignore`-policy paths into `.gitignore` between
  `# >>> spec-workflow managed` / `# <<< spec-workflow managed` markers, replacing
  only that block, appending it if absent, and SHALL NOT modify any line outside the
  markers.
  - **§7.2.1** — IF a `track`-policy path is ignored by the repo's own rules THEN THE
    SYSTEM SHALL warn (path + matching rule) and SHALL NOT edit non-managed lines.
- **§7.3 sync rule** — WHEN `sync-project-configs` runs against an anchored repo THE
  SYSTEM SHALL reconcile the managed block to the current manifest (versioned sync
  rule, dry-run first, per that skill's conventions).
- **§7.4 single source** — setup-project's Phase-5 inline list is replaced by reads
  of §7.1's manifest; no second copy of the path list may exist in skills or scripts.

## §8 Unified brain-event feed (E2)

- **§8.1 emitter** — WHEN any brain.py command (mint, recall, consult, graduate,
  prune --apply, and §10's evolve/supersede) or feedback.py `emit` completes a state
  change THE SYSTEM SHALL append exactly one JSON line per semantic event to
  `<root>/.claude/brain-events.jsonl` via a single `write()` of a `\n`-terminated
  line opened in append mode.
  - **§8.1.1** — IF the feed append fails THEN THE SYSTEM SHALL complete the file
    operation normally and print a warning (feed is never load-bearing).
- **§8.2 schema** — Event lines carry `{v:1, ts, repo, role, type, ...payload}` with
  `type` ∈ {NoteMinted, NoteEvolved, NoteSuperseded, NoteGraduated, LinkFormed,
  LinkFired, LinkPruned, RecallPerformed, ConsultPerformed, FeedbackEmitted,
  FeedbackRouted, FeedbackArchived}. Payloads identify slugs/link keys/counts, never
  full note bodies. Schema documented in the plugin README; unknown fields are
  ignored by consumers (forward-compatible).
- **§8.3 activation contract frozen** — WHILE E5 has not shipped THE SYSTEM SHALL
  keep `.activation.jsonl` writes byte-identical to today; the new feed is strictly
  additional.
- **§8.4 fold verification** — WHEN `brain.py <root> verify-feed <role>` is invoked
  THE SYSTEM SHALL fold LinkFormed/LinkFired/LinkPruned events and report any
  divergence from `links.json` (fires/weights/keys), exit 1 on divergence.
- **§8.5 opt-in fold mode** — WHERE `brain.events.authoritative: true` is set in
  `project.yaml` THE SYSTEM SHALL derive `links.json` as a fold of the feed (written
  as a cache), eliminating the read-modify-write path. Default remains `false`
  (§12 additive-only); flipping the default requires verify-feed green across ≥3
  retros (recorded in an OQ resolution).

## §9 Retrieval upgrade (E3)

- **§9.1 capability install** — WHEN `capability.sh install embeddings` is invoked
  THE SYSTEM SHALL create `.claude/capabilities/embeddings/` (or `~/.claude/...`
  shared — OQ-2) containing a self-contained venv with pinned `onnxruntime` +
  tokenizer deps, a pinned ONNX-exported small embedding model (bge-small-class,
  384-dim), and a `manifest.json` (name, version, entrypoint, healthcheck).
  - **§9.1.1** — WHERE the capability is absent or its healthcheck fails THE SYSTEM
    SHALL run recall exactly as today (keyword/glob seeding only), printing one
    notice line at most.
- **§9.2 index** — WHEN `brain.py <root> index <role>` runs (and incrementally after
  mint/evolve) THE SYSTEM SHALL upsert embeddings for changed notes into
  `.claude/identities/<role>/brain/index.sqlite3` keyed by (slug, content-hash);
  the index is a derived layer, rebuildable at any time, and gitignored (add to
  §7.1 manifest as `ignore`).
- **§9.3 hybrid recall** — WHERE the sidecar is available `recall` SHALL seed with
  the union of (a) today's glob/keyword matches and (b) top-K embedding neighbors of
  the query text (K default 8, flag-tunable), then rank as today.
- **§9.4 PPR** — WHERE `brain.recall.ppr: true` (default false until eval green,
  OQ-3) recall SHALL replace the 2-hop spread with Personalized PageRank over
  `links.json` (damping 0.85, personalization = seed activations, convergence 1e-6
  or 50 iterations, stdlib implementation), preserving the existing budget/tier
  rendering unchanged.
- **§9.5 recall eval** — THE SYSTEM SHALL ship a hermetic eval fixture (frozen brain
  + query→expected-notes pairs derived from real retro ground truth) and a
  `recall-eval` script reporting hit@K and MRR for keyword-only vs hybrid vs
  hybrid+PPR; run in CI as advisory (non-gating), gating only on crashes.

## §10 Write-path anti-degradation (E4)

- **§10.1 neighbor surfacing** — WHEN `mint` runs with the sidecar available THE
  SYSTEM SHALL print the top-5 embedding-nearest existing notes (slug + first line +
  similarity) so the orchestrator can link/evolve/supersede instead of duplicating.
  (Model-in-the-loop: the orchestrator decides; brain.py only surfaces.)
- **§10.2 near-duplicate guard** — IF a minted note's embedding similarity to an
  existing note exceeds 0.90 (flag-tunable) THEN THE SYSTEM SHALL require
  `--supersedes <slug>`, `--evolves <slug>`, or `--force` (recorded in the event),
  and SHALL refuse the plain mint otherwise.
- **§10.3 supersede** — WHEN `brain.py <root> supersede <role> <old> <new>` runs THE
  SYSTEM SHALL stamp the old note's frontmatter `superseded-by: <new>` +
  `superseded-at: <date>` and the new note's `supersedes: <old>`; superseded notes
  SHALL never be injected by recall (any tier) but remain on disk, in links, and in
  neural-view (ghosted, §11.2). Graduated behavior is unchanged.
- **§10.4 evolve** — WHEN `brain.py <root> evolve <role> <slug>` runs (body on
  stdin) THE SYSTEM SHALL update the note in place, bump `strength`, stamp
  `evolved-at`, re-extract wikilinks (never resetting existing link metadata), and
  emit NoteEvolved. Git history is the temporal record (no versioned copies).
- **§10.5 retro protocol** — The retrospective/brains protocol docs SHALL instruct
  the orchestrator to consult §10.1's neighbors and choose evolve/supersede over
  fresh mints when a neighbor covers the same lesson.

## §11 Neural-view on the unified feed (E5)

- **§11.1 feed consumption** — WHEN brain-event feeds exist THE SYSTEM SHALL extend
  the `/events?since=` cursor to cover `brain-events.jsonl` per repo alongside
  `.activation.jsonl`, delivering typed events to the page with the same
  skip-backlog semantics; repos without feeds behave exactly as today.
- **§11.2 ghosting** — WHERE a note has `superseded-by` THE SYSTEM SHALL render it
  and its links ghosted (reduced opacity, excluded from recall highlights), with the
  supersession chain shown on inspect.
- **§11.3 provenance** — WHEN a note or synapse is clicked THE SYSTEM SHALL show its
  originating events (minted/evolved/superseded/last-fired, with `source` from
  frontmatter) from the feed, read on demand — not preloaded.
- **§11.4 loop closure** — WHEN a FeedbackRouted(brain-note) event is followed by its
  NoteMinted event THE SYSTEM SHALL animate the new node's appearance (the visible
  self-improvement loop).
- **§11.5 activation sunset** — WHEN §11.1 has shipped and a deprecation window of
  ≥2 plugin releases has passed THE SYSTEM MAY stop writing `.activation.jsonl`
  behind an opt-in flag; removal of the writer requires a major version note.

## §12 Invariants

- Notes are plain markdown + YAML frontmatter, OKF-compatible (`type` field present
  going forward); no note content lives only in a database.
- Every derived layer (embedding index, folds, adjacency caches) is rebuildable from
  committed files + feeds alone.
- Feed appends are atomic single-line `write()`s; no shared JSON file is
  read-modify-written on any concurrent path unless it is a derived cache.
- Role privacy holds: no role reads another role's brain; `consult` is the only
  cross-role path and is orchestrator-mediated.
- Superseded notes are never deleted and never injected.
- Core scripts remain stdlib-only (PyYAML exception stands); capability modules own
  their dependencies in isolated venvs and their absence degrades features, never
  breaks flows.
- Graduation and skill promotion remain verifier-gated (recorded gate pass / merged
  PR / human), never model self-judgment.
- Additive-only: every new mechanism is opt-in, defaults preserve current behavior,
  and no existing flow breaks when a new component is absent or disabled.

## §13 Non-functional

- Recall end-to-end < 100ms at 10k notes/role on an M3 Pro (embed ≤ 50ms, search
  ≤ 11ms, PPR ≤ 20ms on cached adjacency).
- Feed append overhead < 5ms per operation.
- Neural-view poll delta < 50ms at 10k accumulated events per repo.
- Sidecar install fully offline-capable after first model download; pinned versions.
- All new scripts: bash 3.2-compatible / Python stdlib rules per repo invariants.

## §14 Testing strategy

- Hermetic fixtures (house style): frozen brain dirs, feed files, feedback feeds
  under `tests/fixtures/`; no network, no live board.
- Merge-gating: unit/integration suites for §6 archive semantics, §7 managed block
  idempotency, §8 emitter atomicity + verify-feed, §10 supersede/evolve/guard logic,
  §11 cursor extension.
- Advisory: §9.5 recall-eval metrics (tracked, non-gating); §13 latency smoke checks.
- Concurrency: a stress test spawning N parallel mint/recall processes asserting no
  lost feed lines and unchanged file semantics.

## §15 Open questions

| id | question | owner | default if unanswered | status |
|---|---|---|---|---|
| OQ-1 | Multi-machine feed sync (git-only vs syncthing vs Option B) | Leonardo | git via committed tracked files; revisit at fleet spec | open |
| OQ-2 | Sidecar install location: per-repo `.claude/capabilities/` vs shared `~/.claude/capabilities/` | Leonardo | shared `~/.claude/capabilities/` (one venv/model for all repos) | open |
| OQ-3 | When do §8.5 fold-mode and §9.4 PPR flip default-on | Leonardo | after verify-feed green across 3 retros / recall-eval shows ≥ parity | open |
| OQ-4 | Embedding model pin (bge-small-en-v1.5 vs nomic-embed-text-v1.5 ONNX) | dev (benchmark in MEM-030) | bge-small-en-v1.5 (384-dim, smallest, well-supported ONNX export) | MEM-030: pinned bge-small-en-v1.5 (Xenova ONNX export, commit `ea104da`); installs + embeds correctly, single-embed latency ~15ms median warm (well under the §13 ≤50ms budget). Full quality benchmark vs nomic deferred to MEM-034's recall-eval fixture — pin stands until then. |
| OQ-5 | Does `brain-events.jsonl` rotate (size cap) in v1 | Leonardo | no rotation in v1; revisit if >10MB observed | open |
