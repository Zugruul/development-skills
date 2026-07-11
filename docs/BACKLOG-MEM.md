# Backlog — spec MEM (SPEC-MEMORY.md)

Task ids: `MEM-<number>`. Ranges: E0 = 001–009, E1 = 010–019, E2 = 020–029, E3 = 030–039, E4 = 040–049, E5 = 050–059. Points ≈ complexity (1–10 rubric, seed-board skill). Every task cites its SPEC-MEMORY.md §s; acceptance criteria are the merge bar. Build order: E0 → E1 → E2 → E3 → E4 (blockedBy E3) → E5 (blockedBy E2). Everything is additive-only (§12): defaults preserve current behavior.

## E0 — Feedback lifecycle (§6)

### MEM-001 · `feedback.py archive` subcommand — P0 · 4 pts · §6.1 §6.1.1 §6.1.2
Move fully-routed feed documents (every item has `routing.action`) into `.claude/feedbacks/archive/<YYYY-MM>.yaml` by document `ts`; partially-routed and unrouted documents stay. Byte-identical document preservation; temp-file + rename atomicity on both feed and archive files; idempotent re-run; parse failure aborts untouched with byte offset.
**Acceptance:** hermetic tests cover mixed feed (routed/partial/unrouted), month bucketing, idempotent second run, corrupt-doc abort, atomicity (no partial writes on injected failure); `emit`/`route`/`pending` behavior byte-identical to before (regression fixtures); `pending` never scans archives (§6.2).
**DoD:** suite green, shellcheck/stdlib rules hold, feedback.py docstring updated.

### MEM-002 · `feedback.py archived` query — P1 · 2 pts · §6.3
List archived documents with the same rendering as `pending`, `--since YYYY-MM` filter, across all archive files.
**Acceptance:** tests for empty archive dir, multi-month, `--since` boundary; output format matches `pending`'s item rendering.
**DoD:** suite green; README feedback section mentions the lifecycle.

### MEM-003 · Retrospective + build-next protocol: archive at close — P1 · 2 pts · §6.4
Retrospective skill (and the build-next retro step) run `archive` as the final feed action and commit feed+archives together as the orchestrator identity.
**Acceptance:** both SKILL.md protocols updated (exact command, ordering after route/mint/retro-mark); docs[] entries updated; eval/fixture for the protocol text if one exists for these skills.
**DoD:** docs updated in same PR; no script changes beyond skill text.

### MEM-004 · Commit-policy reconciliation — P1 · 2 pts · §6.5
Remove `.claude/feedbacks/` from this repo's `.gitignore`; commit the existing feed (+ new archives); align feedback SKILL.md / SPEC §8.5 wording so tracked-by-default is stated once and consistently.
**Acceptance:** `git check-ignore .claude/feedbacks/feed.yaml` returns nothing; existing feed committed; docs state the policy and the opt-out (repo-local ignore) explicitly.
**DoD:** repo state matches docs; CI green.

## E1 — Local-state gitignore management (§7)

### MEM-010 · Canonical local-state manifest — P0 · 3 pts · §7.1 §7.4
One machine-readable manifest (`scripts/local-state.manifest`) of plugin-written paths with `ignore`/`track` policy, readable from bash 3.2 and python stdlib; includes every path in §7.1 (plus `index.sqlite3` from §9.2 as ignore). All existing inline path lists (setup-project Phase 5 printf) replaced by manifest reads.
**Acceptance:** manifest parse helpers with tests; grep proves no second copy of the path list exists in skills/scripts; policy table rendered into the plugin README from the manifest (or verified in sync by test).
**DoD:** suite green; shellcheck clean.

### MEM-011 · `gitignore-sync.sh` managed block — P0 · 4 pts · §7.2 §7.2.1
Script writing the managed block (`# >>> spec-workflow managed` … `# <<< spec-workflow managed`) with all `ignore` paths; replaces only the block, appends if absent, never touches other lines; warns (path + rule) when a `track` path is ignored by non-managed rules; `--dry-run` prints the diff.
**Acceptance:** tests: fresh repo (no .gitignore), existing .gitignore without block (append), stale block (replace), user lines above/below preserved byte-identically, track-path warning fires on this repo's current feedbacks rule, dry-run makes no writes, idempotent second run.
**DoD:** suite green; shellcheck -x clean; bash 3.2 compatible.

### MEM-012 · setup-project integration — P1 · 2 pts · §7.2 §7.4
setup-project Phase 5 calls `gitignore-sync.sh` instead of its inline printf list.
**Acceptance:** SKILL.md updated; the printf list is gone; a consumer-repo fixture run produces the managed block; docs[] updated.
**DoD:** suite green.

### MEM-013 · sync-project-configs rule — P1 · 3 pts · §7.3
Versioned sync rule reconciling anchored repos' managed blocks to the current manifest (dry-run default, per skill conventions).
**Acceptance:** rule registered with a version; dry-run shows per-repo diff; apply updates only managed blocks; test fixture with two divergent repos.
**DoD:** suite green; skill docs updated.

## E2 — Unified brain-event feed (§8)

### MEM-020 · Event schema + emitter — P0 · 4 pts · §8.1 §8.1.1 §8.2
`brain.py` gains an internal `emit_event(root, obj)` appending one `\n`-terminated JSON line (single `write()`, append mode, O_APPEND) to `.claude/brain-events.jsonl`; schema v1 with the §8.2 type enum documented in the README; emit failure warns and never blocks the file operation.
**Acceptance:** unit tests for line atomicity contract (single write call), schema fields (v, ts, repo, role, type), warning-not-error on unwritable dir; concurrency stress test — N parallel processes, zero interleaved/lost lines.
**DoD:** suite green; README schema section added.

### MEM-021 · Emit from all brain.py commands — P0 · 4 pts · §8.1 §8.3
mint → NoteMinted (+LinkFormed per new wikilink), recall → RecallPerformed (+LinkFired per traversed link), consult → ConsultPerformed, graduate → NoteGraduated, prune --apply → LinkPruned. `.activation.jsonl` writes stay byte-identical (frozen contract, §8.3).
**Acceptance:** per-command fixture tests asserting emitted event sequence AND byte-identical legacy outputs (golden files for .activation.jsonl and links.json); no event on read-only failures.
**DoD:** suite green; no behavior change without the feed present (deleting the feed file mid-run breaks nothing).

### MEM-022 · feedback.py events — P1 · 2 pts · §8.1 §8.2
`emit` → FeedbackEmitted, `route` → FeedbackRouted, `archive` → FeedbackArchived (one per document), same emitter contract.
**Acceptance:** fixture tests per subcommand; event payloads carry ts+idx refs, never item bodies.
**DoD:** suite green.

### MEM-023 · `brain.py verify-feed` — P1 · 3 pts · §8.4
Fold LinkFormed/LinkFired/LinkPruned per role and diff against `links.json` (keys, fires; weight when events carry it); exit 1 + human-readable divergence report.
**Acceptance:** tests: clean fold (exit 0), injected divergence detected (missing key, fire-count drift), empty feed = trivially green; runs in CI on fixtures.
**DoD:** suite green; retro protocol mentions running it.

### MEM-024 · Opt-in fold mode — P2 · 4 pts · §8.5
`brain.events.authoritative: true` in project.yaml derives `links.json` as a fold-cache (rewrite on command completion) instead of read-modify-write. Default false; flag documented as experimental until OQ-3 resolves.
**Acceptance:** with flag on: concurrent-writer stress shows no lost fires (the race verify-feed catches with flag off); with flag off: zero behavior change (golden files); schema addition validated by config validator.
**DoD:** suite green; validate-config accepts the key; README documents the graduation criteria (OQ-3).

## E3 — Retrieval upgrade (§9) — independent of E2

### MEM-030 · Embeddings capability install — P0 · 5 pts · §9.1 §9.1.1 · resolves OQ-4
`capability.sh install embeddings`: self-contained venv (pinned onnxruntime + tokenizer), pinned ONNX model per OQ-4 benchmark (bge-small-en-v1.5 default vs nomic-embed-text-v1.5 — measure quality on the MEM-034 fixture + latency on M3 Pro, record decision in the OQ table), `manifest.json` (name/version/entrypoint/healthcheck), `embed` entrypoint: stdin text lines → JSON float arrays. Absence/failed healthcheck = recall behaves exactly as today with ≤1 notice line.
**Acceptance:** install idempotent + offline after model download; healthcheck detects broken venv; `embed` round-trip test with pinned expected dims; graceful-absence test (uninstalled → recall golden-identical to today); install location honors OQ-2 default (`~/.claude/capabilities/`, per-repo override flag).
**DoD:** suite green (venv tests may be marked slow/optional in CI); capability pattern documented as the template for future capabilities (fleet spec seed).

### MEM-031 · Embedding index — P0 · 3 pts · §9.2
`brain.py index <role>`: upsert (slug, content-hash) → vector into `brain/index.sqlite3`; incremental after mint/evolve; rebuildable from scratch; gitignored via MEM-010 manifest.
**Acceptance:** tests: fresh build, incremental update on changed note only, hash-stable no-op, rebuild-equals-incremental; index absence never errors recall.
**DoD:** suite green; manifest updated (ignore policy).

### MEM-032 · Hybrid recall seeding — P0 · 3 pts · §9.3
Seed = union of today's glob/keyword hits and top-K embedding neighbors (K=8 flag); ranking/budget/tiers unchanged.
**Acceptance:** fixture where keyword misses a semantically-related note and hybrid finds it; keyword-only path golden-identical when sidecar absent; K flag respected; budget respected (existing tests still green).
**DoD:** suite green.

### MEM-033 · PPR recall (flagged) — P1 · 4 pts · §9.4
`brain.recall.ppr: true` replaces 2-hop spread with stdlib PPR (damping 0.85, personalization = seeds, 1e-6/50-iter convergence); off by default until OQ-3.
**Acceptance:** unit tests vs hand-computed PPR on a toy graph; flag off = golden-identical recall; flag on preserves tier/budget rendering; link fire/bump semantics defined + tested (traversed = edges with meaningful mass, documented threshold).
**DoD:** suite green; validate-config accepts the key.

### MEM-034 · Recall-eval fixture + script — P1 · 3 pts · §9.5
Frozen brain + query→expected-notes pairs from real retro ground truth; `recall-eval` reports hit@K + MRR for keyword vs hybrid vs hybrid+PPR; CI advisory.
**Acceptance:** deterministic scores on fixture; report artifact readable; wired into CI as non-gating; documented as the OQ-3 graduation evidence.
**DoD:** suite green; results recorded in the PR description.

## E4 — Write-path anti-degradation (§10) — blockedBy E3

### MEM-040 · Mint-time neighbor surfacing — P1 · 2 pts · §10.1 §10.5
With sidecar: mint prints top-5 nearest notes (slug, first line, similarity). Retro/brains protocol docs instruct evolve/supersede over duplicate mints.
**Acceptance:** fixture test of surfaced list; absent sidecar = no output change; protocol docs updated (docs[]).
**DoD:** suite green.

### MEM-041 · Near-duplicate guard — P1 · 3 pts · §10.2
Similarity > 0.90 (flag) to an existing note ⇒ require `--supersedes`/`--evolves`/`--force`; refusal message names the neighbor; `--force` recorded in the NoteMinted event.
**Acceptance:** tests: block fires, each escape hatch works, threshold flag, sidecar-absent = guard inert; event payload carries the choice.
**DoD:** suite green.

### MEM-042 · `supersede` command — P0 · 3 pts · §10.3
Frontmatter stamps both notes (`superseded-by`/`superseded-at`/`supersedes`); recall excludes superseded from every tier; links and files remain; emits NoteSuperseded.
**Acceptance:** tests: stamp round-trip via parse/render (KEY_ORDER extended), recall exclusion at all tiers, graduated+superseded interplay, event emitted; directory listing marks superseded.
**DoD:** suite green; brain SKILL.md documents the command.

### MEM-043 · `evolve` command — P0 · 3 pts · §10.4
In-place body update from stdin, strength bump, `evolved-at` stamp, wikilink re-extraction without resetting existing link metadata, NoteEvolved event, incremental index update (MEM-031 hook).
**Acceptance:** tests: body replaced + frontmatter preserved/bumped, new wikilinks added with defaults, existing link fires/weights untouched, event emitted, index refreshed; git-history-as-record documented.
**DoD:** suite green; brain SKILL.md updated.

## E5 — Neural-view on the unified feed (§11) — blockedBy E2

### MEM-050 · Cursor extension to brain-events — P0 · 4 pts · §11.1
`/events?since=` covers `brain-events.jsonl` alongside `.activation.jsonl` per repo/role (typed events tagged by source), same skip-backlog + byte-offset semantics; feedless repos unchanged.
**Acceptance:** server tests: cursor round-trip across both files, backlog skip, mixed repos (with/without feed), malformed feed line skipped without stall; existing /events consumers unaffected (schema additive).
**DoD:** suite green; README /events contract updated.

### MEM-051 · Superseded ghosting — P1 · 3 pts · §11.2
Ghost rendering (reduced opacity, excluded from recall highlight) for notes with `superseded-by` and their links; supersession chain in the inspector.
**Acceptance:** graph payload carries the flag; UI renders ghosted (visual check + DOM/state assertion in the page's test harness if present); chain shown on inspect.
**DoD:** suite green; screenshot in PR.

### MEM-052 · Provenance on click — P1 · 3 pts · §11.3
Note/synapse inspector shows originating events (minted/evolved/superseded/last-fired + frontmatter `source`), read on demand via a `/note-events/<repo>/<role>/<slug>` route (bounded scan).
**Acceptance:** route tests (bounded read, missing feed = empty), inspector renders the timeline; no preloading of feed bodies into /graph.
**DoD:** suite green.

### MEM-053 · Loop-closure animation + activation sunset plan — P2 · 3 pts · §11.4 §11.5
Animate NoteMinted following FeedbackRouted(brain-note) (the visible self-improvement loop); document the `.activation.jsonl` sunset (opt-out flag + ≥2-release window), no writer removal in this task.
**Acceptance:** animation triggers on the event pair in a fixture replay; sunset plan in README + CHANGELOG note; flag exists and defaults to keep-writing.
**DoD:** suite green; demo GIF or recording in PR.
