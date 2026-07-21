# SPEC-GRAPHIFY — Graphify-inspired improvements to the skillset

Status: **APPROVED 2026-07-20** — human validated; §16 defaults accepted (Q1: C1–C3 merge, C4 deferred; Q2: graphify vocabulary verbatim; Q3: report opens retro; Q4: impact-first epic order). Registered in `.claude/project.yaml` as spec `gl`, seeded to the board.

## §1 Overview

We studied [Graphify-Labs/graphify](https://github.com/Graphify-Labs/graphify) — a knowledge-graph builder for code with a working self-learning loop — to find ideas worth adopting into the spec-workflow plugin's brain/recall/feedback/neural-view stack, and to prune our own skill surface. This spec records the findings (§5), enumerates skill-consolidation candidates for approval (§6), and specifies the improvements, rated from greater to lower positive impact (§7–§11, ranking table in §12).

**Guiding principle (from the human, verbatim intent):** learn from graphify while keeping the essence of how we work today — zettel brains as the knowledge substrate, scripts-decide-model-obeys, orchestrator-mediated brain privacy, bash 3.2 + stdlib-only Python. We adopt graphify's *mechanisms as ideas*; we never adopt graphify as a dependency.

## §2 Goals

- G1: Close the self-learning loop with ground truth — recall outcomes (did the recalled note actually help?) feed back into ranking, today they don't.
- G2: Make recalled knowledge trustworthy — every injected note carries confidence and staleness signals the consumer can act on.
- G3: Make the brain graph *queryable*, not only *recallable* — explain/path style interrogation.
- G4: Reduce skill-surface maintenance cost by consolidating overlapping skills (human-approved list only).
- G5: Make neural-view show structure (communities, contested knowledge), not just raw nodes.
- G6: Do all of this without breaking a single existing consumer repo (byte-identical degradation when new data is absent, like the MEM-032 embedding sidecar precedent).

## §3 Non-goals

- **No graphify dependency** — no `pip install graphifyy`, no tree-sitter, no Leiden library, no vector store requirement. Ideas only.
- **No replacement of zettels** — we do not auto-extract a code graph and call it the brain. Notes stay human/agent-authored atomic lessons.
- **No embeddings requirement** — everything specified here works with the keyword+glob+link baseline; the `index.sqlite3` sidecar stays opt-in.
- **No new always-on hooks** for automatic per-tool-call retrieval — injection stays orchestrator-mediated (briefs), per the brain privacy model.
- **No multi-platform install matrix** (graphify ships 20+ per-assistant installers; we deliberately stay Claude Code + the existing codex-compat track).
- **No breaking change to `.activation.jsonl`** — it is a frozen contract neural-view parses.

## §4 Glossary

- **Outcome** — post-task verdict on a recalled note: `useful` | `dead_end` | `corrected` (vocabulary borrowed from graphify `save-result`).
- **Contested note** — a note whose recent outcomes disagree (both `useful` and `corrected`/`dead_end` in the window).
- **Stale note** — a note whose `paths` globs match files that changed in git after the note's `created` (or last re-mint) date.
- **Confidence tag** — provenance label on a note: `direct` (minted from an explicit feedback item / incident) vs `inferred` (generalized by the orchestrator). Analog of graphify's `EXTRACTED`/`INFERRED`.
- **Community** — a cluster of densely-linked notes, computed by stdlib label propagation (our no-dependency stand-in for graphify's Leiden step).

## §5 Findings from the graphify study

### §5.1 What graphify does well (the ideas we adopt)

1. **Outcome-tracked work memory** — `graphify save-result --outcome useful|dead_end|corrected` records how each Q&A turned out; `graphify reflect` aggregates outcomes into `LESSONS.md` and a per-node overlay tagging nodes `preferred`/`tentative`/`contested`, recency-weighted with provenance. This is the piece our loop is missing: we record that a link *fired* (`fires`, `last` in `links.json`) but never whether the recall *helped*.
2. **Staleness flagging** — the learning overlay marks a lesson "code changed — re-verify" when the source moved on. We have `paths` globs on every note and full git history; we can compute this deterministically.
3. **Confidence tagging with a discrete rubric** — every edge is `EXTRACTED` (1.0) / `INFERRED` (0.55–0.95 rubric) / `AMBIGUOUS`; the report surfaces ambiguity for human review instead of hiding it.
4. **Graph interrogation verbs** — `query` (budgeted traversal), `path A B`, `explain X` (why is this node connected, who are its neighbors). Our recall is inject-only; there is no way to ask *why* a note surfaced.
5. **Cheap idempotent reflection** — `reflect --if-stale` no-ops when the lessons doc is newer than every input, so it is safe to run every session. Our retrospective is a heavyweight prose protocol that silently doesn't run (the feedback skill itself records "two live repos silently accumulated dozens of task-closes with zero brain notes").
6. **Community detection as structure** — Leiden clustering turns a node soup into named subsystems; the report highlights god nodes and surprising connections. Neural-view currently renders per-role clusters only.
7. **Deterministic-first economics** — the expensive LLM pass is reserved for what genuinely needs it; everything derivable mechanically is derived mechanically, cached by content hash. Matches our scripts-decide invariant; a benchmark discipline (their `worked/` corpora + spend ledgers) is worth imitating for recall-quality regressions.

### §5.2 What graphify does poorly (feedback the human asked us to collect)

From the issue tracker (2000-series, July 2026) and docs:

1. **Incremental update is its weakest subsystem** — `--update` has silently replaced a merged doc+code graph with a code-only rebuild (-74% edges, #2053), silently evicts semantic nodes when a change set contains an unextractable file (#2056), preserves stale nodes for deleted files "as authoritative" (#2051), and its ghost-node pruning can no-op on a path-representation mismatch (#2012). **Lesson for us:** every brain-mutating command must have a shrink guard — refuse or warn loudly when an operation would remove disproportionate knowledge; never let a maintenance path silently discard notes/links.
2. **Silent failure as a pattern** — persisted excludes ignored (#2027), update runbook re-extracting the whole corpus semantically (#2033), manifest stamping making `--update` skip new docs (#2015). **Lesson:** degradation must be loud (we already do this in places — `emit_event` warns on failure — keep it a rule).
3. **Deliberate blind spots presented as features** — dotted/member calls are never resolved "by design" (#2041), nested containment edges never represented (#2040). **Lesson:** when we punt (e.g., recency not used in ranking), the punt belongs in the spec as an open item, not as silent behavior.
4. **Per-language long tail** — a dozen open Scala-extraction gaps show the cost of owning a 40-language extraction matrix. Validates our non-goal §3: don't build/own a code-graph extractor.
5. **Workspace-pollution footgun** — graphify writes `graph.json`/`graphify-out/` into the workspace and invalidates the assistant's prompt cache unless the user hand-edits `.claudeignore`. **Lesson:** all new artifacts in this spec live under already-gitignored local-state paths or the committed `.claude/` locations the workflow already owns.
6. **Modest absolute numbers, self-run benchmarks** — recall@10 0.497 / LOCOMO QA 45.3% are the best *of the systems they tested on their own harness*; still, they publish judge-validation stats and spend ledgers most memory vendors don't. Adopt the honesty, keep skepticism about the absolutes.

## §6 Skill consolidation (ENUMERATED — human must approve each row)

Inventory: 29 spec-workflow skills + peer-review + scaffold-project. None are dead (all referenced from CDX maintenance tasks / deep links), so this is consolidation, not deletion of unused code. Recommendations:

| # | Candidate | Recommendation | Rationale |
|---|---|---|---|
| C1 | `pr-review-model` → fold into `auto-merge` | **Merge** | 22-line wrapper on the same `merge-mode.sh`; only meaningful when auto-merge is on. Becomes `auto-merge model <...>`. |
| C2 | `find-task` → fold into `create-inbound` | **Merge** | `find-task` is exactly the search half of `create-inbound`'s dup-gate (`similar.py`). Becomes `create-inbound --search-only` (keep `/find-task` as an alias line in the description if discoverability matters). |
| C3 | `ask-brain` + `ask-identity` → one `ask` skill | **Merge** | Same mechanism (`brain.sh`), differ only in scope; `ask <question>` = all roles, `ask <role> <question>` = one role. Neural-view "Talk" deep links updated in the same PR. |
| C4 | `concurrency` + `ui-mode` + `checkpoint` → one `mode` skill | **Merge (weaker conviction)** | Three near-identical show/set-one-value wrappers (21–26 lines). `mode concurrency 2`, `mode ui off`, `mode pause`. Cost: three slash-commands become one; keep if per-command discoverability is judged worth 3 extra SKILL.md files. |
| C5 | `queue` vs `next-task` | **Keep both** | Read-only preview vs committing pick are genuinely different verbs with different safety profiles. |
| C6 | `ui-options` vs `refine-task-ui` | **Keep both for now** | `refine-task-ui` is a superset workflow but the two are invoked at different lifecycle points (pre-decision vs post-merge refine). Revisit after C1–C4 land. |
| C7 | `dev-up`, `changelog-generate`, `handoff`, `sync-project-configs`, `agent-identities` | **Keep** | Distinct verbs, no shared backing script with anything else. |

Every merge keeps the backing script and its tests untouched in the same PR that removes the SKILL.md (scripts are the behavior; skills are the interface).

## §7 Self-learning loop: outcome-tracked recall (functional area, impact #1)

The missing feedback edge: recall → task → outcome → ranking. All data lands in the per-role brain dir (orchestrator-mediated, same privacy model).

- **R7.1** WHEN the orchestrator closes a task for which a brief contained recalled notes, THE SYSTEM SHALL support recording one outcome per recalled note via `brain.sh outcome <role> <slug> useful|dead_end|corrected [--task <ref>]`, appended to `<brain>/outcomes.jsonl` (new file; append-only; atomic single-write like `emit_event`).
- **R7.2** WHEN an outcome is recorded, THE SYSTEM SHALL emit a `RecallOutcome` event to `.claude/brain-events.jsonl` (never load-bearing, warn-on-failure).
- **R7.3** WHEN `corrected` is recorded, THE SYSTEM SHALL require a `--note "<what was wrong>"` payload so the retro has material to re-mint from.
- **R7.4** WHEN recall ranks candidates, THE SYSTEM SHALL apply an outcome multiplier to seed activation: notes whose recent outcomes are net-positive rank up, net-negative rank down; a note with zero outcomes is unchanged (byte-identical ranking to today — G6).
- **R7.5** WHILE a note is contested (≥1 `useful` AND ≥1 `corrected`/`dead_end` within the last N retros, N default 3), THE SYSTEM SHALL render it in recall output with a `⚠ contested` marker instead of silently ranking it.
- **R7.6** WHEN `retrospective` runs, THE SYSTEM SHALL surface per-note outcome tallies (`brain.sh status` extension) so mint/prune/graduate decisions can use them; notes that are repeatedly `dead_end` and never `useful` become prune candidates alongside the existing link-age rule.
- **R7.7** IF `outcomes.jsonl` is absent or malformed THEN THE SYSTEM SHALL behave exactly as today (no outcome weighting, no markers) and warn once.

## §8 Recall ranking: recency + staleness + confidence (impact #2–#4)

- **R8.1** WHEN recall ranks candidates, THE SYSTEM SHALL apply a recency decay derived from the retro clock (`retros.log`), not wall-time: a note untouched (no re-mint, no fired link, no `useful` outcome) for K retros decays by a configured factor; K and factor live in `methodology.*` with defaults that keep current top-1 results stable on the existing corpora (regression-tested).
- **R8.2** WHEN a note is rendered in recall output, THE SYSTEM SHALL flag it `⟳ stale — re-verify` IF any of its `paths` globs match files with git commits after the note's `created` (or latest re-mint) date. Computation is on-demand at recall time, cached per (note, HEAD) — never a background daemon.
- **R8.3** WHEN a note is minted, THE SYSTEM SHALL accept an optional `--confidence direct|inferred` (default `inferred`); the retrospective protocol sets `direct` for notes minted verbatim from an incident/feedback item. Stored in frontmatter; existing notes without the field are treated as `inferred`.
- **R8.4** WHEN recall renders a full-body tier note, THE SYSTEM SHALL include its confidence tag and outcome tally in the one-line header (e.g. `[direct · 3× useful]`), so the consuming subagent can weigh it.
- **R8.5** IF staleness computation fails (no git, shallow clone) THEN THE SYSTEM SHALL omit the flag silently and never fail the recall.

## §9 Graph interrogation: explain and path (impact #5)

- **R9.1** THE SYSTEM SHALL provide `brain.sh explain <role> <slug>`: the note's body, confidence, outcome tally, staleness, communities (§10), inbound/outbound links with weights and last-fired, and the top co-activated notes — a human/agent-readable "why does this note matter" card.
- **R9.2** THE SYSTEM SHALL provide `brain.sh path <role> <slug-a> <slug-b>`: shortest link path between two notes (BFS over `links.json`, stdlib), or "no path".
- **R9.3** WHERE ask-brain/ask-identity (or merged `ask`, per C3) answer a question, THE SYSTEM SHALL ground answers with `explain` output for the notes it cites, replacing ad-hoc note pasting.

## §10 Neural-view: communities and a knowledge report (impact #6)

- **R10.1** THE SYSTEM SHALL compute note communities per brain via stdlib label propagation over `links.json` (deterministic seed ordering so runs are reproducible), exposed in the `/graph` payload as a `community` attribute per node. No new dependencies; absent/tiny graphs degrade to one community.
- **R10.2** WHEN neural-view renders the graph, THE SYSTEM SHALL color/cluster by community and show community labels (top-tags heuristic) in hover and the sidebar.
- **R10.3** WHEN a `RecallOutcome` event arrives on the event feed, THE SYSTEM SHALL render contested notes visually distinct (matching the §7.5 marker).
- **R10.4** THE SYSTEM SHALL provide `brain.sh report [role]` emitting a `BRAIN_REPORT.md`-style digest to stdout (graphify's `GRAPH_REPORT.md` analog): god notes (highest degree), contested notes, stale notes, orphan notes (no links), community summary. Read-only; never written into the repo automatically.

## §11 Feedback loop: cheap idempotent reflection (impact #7)

- **R11.1** THE SYSTEM SHALL provide `feedback.py <root> pending --quiet` (or equivalent) as a zero-cost staleness check, and the retrospective skill SHALL open with it: WHEN nothing is pending and no outcomes were recorded since the last retro-mark, the retro SHALL no-op in one command (graphify `reflect --if-stale` analog).
- **R11.2** WHEN a build-next iteration closes a PR and pending feedback exists, THE SYSTEM SHALL keep today's behavior (retro step 7) — this section lowers the cost of running retros, it does not add new automation that bypasses the orchestrator.

## §12 Impact ranking (greater → lower positive impact)

| Rank | Item | Spec § | Why this rank |
|---|---|---|---|
| 1 | Outcome-tracked recall (close the learning loop) | §7 | The loop currently learns from *emission* (minting) but never from *consumption results*; this is the single structural gap graphify's design exposes. Everything else compounds on it. |
| 2 | Recency decay in ranking | §8.1 | Known punt (SPEC-MEMORY lists forgetting as future); stale strong notes currently outrank fresh correct ones forever. |
| 3 | Staleness re-verify flags | §8.2 | Cheap (git + globs we already have), directly prevents confidently-wrong injections. |
| 4 | Confidence tags | §8.3–8.4 | Small change, makes every injection self-describing; prerequisite polish for 1–3 to be consumable. |
| 5 | explain / path interrogation | §9 | Turns the brain from write-mostly into a debuggable system; also powers ask-* grounding. |
| 6 | Skill consolidation | §6 | Real but bounded maintenance win (~4 fewer SKILL.md surfaces, CDX matrix shrinks); zero user-visible capability change. |
| 7 | Neural-view communities + report | §10 | High delight, moderate insight value; depends on nothing above but consumes 1, 3. |
| 8 | If-stale cheap retro | §11 | Removes friction that causes silent retro-skipping; small code, behavioral win depends on adoption. |

## §13 Invariants

- Brains remain orchestrator-mediated: no role reads another role's brain directory; subagents receive knowledge only as pasted brief text.
- Scripts are bash 3.2-compatible with `set -uo pipefail` and pass shellcheck -x; Python is stdlib-only (PyYAML sole permitted dependency). No graphify, tree-sitter, embedding, or graph-library dependency is introduced.
- Every new data file (`outcomes.jsonl`) degrades byte-identically: its absence reproduces today's behavior exactly.
- `.activation.jsonl` and `brain-events.jsonl` schemas are append-extended only (new event types allowed, existing fields never repurposed).
- Every brain-mutating command refuses or loudly warns when an operation would remove more than a configured fraction of notes or links in one invocation (shrink guard; lesson from graphify #2053/#2056).
- No new artifact is written into prompt-cache-visible workspace paths; all new outputs live in existing `.claude/` locations or stdout.
- Red-first TDD; the gate is green before In review; docs updated in the same PR as behavior.

## §14 Non-functional

- Recall latency budget: outcome weighting + staleness + decay must add <200ms to `brain.sh recall` on a 200-note brain (staleness git query batched, one subprocess).
- Determinism: identical inputs (notes, links, outcomes, HEAD) produce identical recall ranking and identical community assignments.
- All new commands covered by the existing bats-style test suite; shellcheck + `claude plugin validate` stay green (the recorded gate).

## §15 Testing strategy

Unit tests per script function (existing pattern: one test file per module under `plugins/spec-workflow/tests/`); ranking-regression fixtures: a frozen corpus of notes/links/outcomes with golden recall output, asserting both the new behavior and the G6 byte-identical-degradation path; shrink-guard tests that simulate a destructive prune. Merge-gating: the standard recorded gate. Advisory: a manual before/after recall-quality comparison on this repo's three live brains, recorded in the PR description.

## §16 Open questions (owner: the human; defaults apply if unanswered)

| Q | Question | Default if unanswered |
|---|---|---|
| Q1 | Approve which consolidation rows in §6? | C1–C3 merge, C4 deferred, C5–C7 keep. |
| Q2 | Outcome vocabulary: adopt graphify's `useful/dead_end/corrected` verbatim or rename? | Adopt verbatim (cross-referenceable with their docs). |
| Q3 | Should `brain.sh report` also run inside `retrospective` automatically? | Yes, read-only, as the retro's opening context. |
| Q4 | Epic order: impact-first (E1 learning loop before E0 consolidation) or quick-win-first? | Impact-first; consolidation is E4. |
