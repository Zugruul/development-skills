# Spec seed — Memory scaling (horizontal + vertical) for the identity brains

> **Status: SUPERSEDED by `SPEC-MEMORY.md`** (crafted 2026-07-10 via craft-spec; backlog
> at `docs/BACKLOG-MEM.md`, spec id `mem`, prefix `MEM`). Kept as research provenance —
> full cited report: https://claude.ai/code/artifact/791dd244-e622-4299-9e67-6c5153d9d595.

## Goal

Evolve the per-identity zettel brains (`brain.py`) + neural-view from per-repo,
machine-local, keyword-recall memory into a horizontally scalable (all projects, N
machines, N concurrent sessions) and vertically scalable (retrieval quality that does
NOT degrade as note count grows) memory substrate — the foundation for neural-view
becoming the JARVIS-style workspace. This spec covers the memory layer only; voice,
fleet workers, and capability bus are follow-up specs.

## Decisions already locked (by Leonardo, 2026-07-10)

1. **Substrate: phased dual-write.** Phase 1 keeps files authoritative and dual-writes
   a unified brain-event feed; the Option A (files+sidecar) vs Option B (event-sorc
   backbone) commitment is deferred to the phase where a brain service is actually
   needed. Every Phase-1/2 artifact must carry forward into either.
2. **Spec home: this repo** (brain.py + neural-view live here; event-sorc would be a
   consumed dependency later, never vendored).
3. **Note format: OKF-compatible** (Google Open Knowledge Format — YAML frontmatter +
   markdown, required `type` field). Zettels stay human-readable markdown; all
   intelligence lives in derived layers.
4. Voice (STT/TTS) will run on the Mac as a reproducible setup — out of scope here,
   listed only so the memory spec doesn't accidentally block it.

## Research-derived design rules (see report §5–§6 for citations)

- **Hybrid retrieval**: embedding-kNN seeding + Personalized PageRank over the link
  graph (HippoRAG 2, ICML 2025 — PPR is the principled form of brain.py's existing
  2-hop spreading activation), re-ranked by recency × relevance × strength, budgeted
  injection (existing tiered rendering stays).
- **Anti-degradation is a write-path property** (From Recall to Forgetting, 2026:
  append-only extraction pipelines collapse 40→20 over long horizons): mint-time
  LLM-decided links + retroactive note evolution (A-MEM, NeurIPS 2025), forced
  conflict resolution supersede/retain/annotate (Memanto), bi-temporal invalidation —
  never deletion (Zep/Graphiti).
- **Verifier-gated promotion**: notes/skills only graduate through deterministic
  evidence (recorded gate pass, merged PR) — never model self-judgment (ASG-SI;
  Microsoft agentic-evolution survey).
- **Bounded stores**: keep prune/graduate/retro cadence; top-K everywhere; typed decay.
- **Own the eval**: small recall benchmark over our own brains (ground truth: "which
  lesson should have fired in this PR" from retros); vendor memory benchmarks are
  inflated (Mem0 92.5 self-reported vs 58–66 reproduced).

## Proposed epics

### E-A — Unified brain-event feed (horizontal, phase 1)
Every mint/recall/link-fire/consult/graduate/supersede emitted as a typed event,
dual-written next to the existing file writes (append-only `brain-events.jsonl` per
repo + a merged hub feed). `.activation.jsonl` remains a frozen contract until
neural-view migrates, then deprecates. Neural-view tails the unified feed → cross-repo
activity on one timeline; loop closures visible (feedback → retro → NoteMinted node
appears live).
- Concurrency fix rides along: `links.json` / `consults.json` read-modify-write races
  under parallel sessions are eliminated by folding from append-only events instead.
- Event schema is the Option-A/B-portable artifact — design it as such (event names
  from the report: NoteMinted, LinkFormed, LinkFired, NoteEvolved, NoteSuperseded,
  NoteGraduated, RecallPerformed, FeedbackEmitted, SkillPromoted).

### E-B — Retrieval upgrade (vertical, phase 2)
Embedding sidecar (SQLite; local small model — nomic-class, 0.4GB, runs on the M3 Pro)
rebuilt/updated from note files; recall = embedding seeds + existing glob/keyword
seeds → PPR over links → re-rank → budget. Recall-eval fixture built from retro
ground truth; run in CI.

### E-C — Write-path anti-degradation (vertical, phase 2)
Mint-time: retrieve nearest notes, LLM proposes links (auto-link beyond literal
`[[wikilinks]]`), optional evolution of linked notes' context/tags (A-MEM);
contradiction detection with forced supersede/retain/annotate; `superseded-by`
frontmatter + bi-temporal fields; superseded notes never injected, still render in
neural-view as ghosted synapses/nodes.

### E-D — Feedback-loop hygiene (user-reported gap)
`/feedback` + `/retrospective` structure: the feedback feed is an ever-growing file,
never archived. Redesign as episodic-store lifecycle: feedback entries carry status
(pending → triaged → minted/dismissed); retrospective consumes pending entries and
**archives** them (dated archive files or an `archived/` dir), keeping the active feed
small; archived feedback remains queryable as episodic history (inter-task reflection
per SAMULE needs it). Backfill: archive the current backlog on first run.

### E-E — setup-project gitignore hygiene (user-reported gap)
`/setup-project` (and `sync-project-configs`) should manage `.gitignore` entries for
local-state files the workflow generates that must not be committed — candidates:
`.claude/telemetry.jsonl`, feedback feeds/archives (decide: commit or ignore),
`.activation.jsonl` / brain-event feeds, neural-view state dir, checkpoint flags,
recorded-gate state. Decide per file: committed (shared memory) vs ignored (local
state) vs ignored-but-synced-elsewhere. Idempotent, appends a marked block, never
rewrites user entries.

### E-F — Neural-view on the unified feed
Consume the merged event feed (replacing per-repo `.activation.jsonl` tailing);
render cross-repo constellations from one source; provenance on click (event →
source PR/feedback); ghosted invalidated links; groundwork for machine/capability
constellations (fleet spec, later).

## Invariants (candidate)

- Notes remain plain markdown + YAML frontmatter (OKF-compatible, `type` required);
  no binary or DB-only note state — derived layers must be rebuildable from files.
- Role privacy holds: no cross-role reads except explicit `consult`; events carry
  role ownership.
- Every event append is atomic (single `write()` line); no read-modify-write of
  shared JSON in any concurrent path.
- Recall latency budget: < 100ms end-to-end on the Mac at 10k notes (embed ~10–50ms +
  search ~1–11ms + PPR on cached adjacency).
- Python stdlib only for brain.py itself stays true where feasible; the embedding
  sidecar may add a vetted dependency (document the choice).

## Open questions for the craft-spec interview

1. Hub feed location: `~/Development/.claude/` (scan-base level, matches neural-view
   discovery) vs a dedicated repo? Sync-to-other-machines story for Phase 1 (git vs
   defer to Phase 3)?
2. Feedback archives: committed (shared episodic history) or gitignored (local)?
   Interacts with E-E.
3. Which embedding model/runtime is the pinned default (nomic via MLX? ONNX for
   portability to the Windows box)?
4. Does NoteEvolved mutate the original file in place (git history as the bi-temporal
   record) or append a versioned section?
5. Epic ordering: E-D/E-E are small and independent — ship them first as quick wins,
   or fold into the phased sequence?
