# Backlog — spec CDX (SPEC-CODEX-COMPAT.md)

Task ids: `CDX-<number>`. Ranges: E0 = 001–009, E1 = 010–019, E2 = 020–029, E3 = 030–039, E4 = 040–049, E5 = 050–059. Points ≈ complexity (1–10 rubric, seed-board skill). Every task cites its SPEC-CODEX-COMPAT.md §s; acceptance criteria are the merge bar.

§15 OQ-3's decided defaults (P0/E0, P1/E1-E4, P2/E5) are the *baseline*; a few tasks deviate with an inline reason (CDX-006 AGENTS.md is P1 not P0 — not install-blocking; CDX-030's gate-before-review preflight is P0 even in E3 — it's the single highest-priority safety gap per §9.1/§12; CDX-032 and CDX-043 are P2 — hook-bootstrap-equivalent and version-bump hygiene are lower-urgency than the rest of their epics; CDX-040's CI job is P0 in E4 because nothing else in E4 is verifiable without it). Epic sequencing here follows spec `sw`'s existing pattern in this same `project.yaml` (no `blockedBy` guards between adjacent epics; `next-task` sequencing is relied on, not a schema-level block) rather than `mem`'s guarded epics, since E0-E5 here are strictly linear with no cross-epic reordering need.

## E0 — Codex packaging & plugin-root resolution (§6)

### CDX-001 · Shared plugin-root resolver (bash + python) — P0 · 5 pts · §5 §6.3 §6.4 §12
Implement `scripts/lib/plugin-root.sh` (sourced by every shell script) and `scripts/lib/plugin_root.py`, both implementing the precedence chain: `SPEC_WORKFLOW_PLUGIN_ROOT` → `CLAUDE_PLUGIN_ROOT` → sentinel-based script-relative discovery (nearest ancestor of the resolver's own physical location containing `.claude-plugin/plugin.json` or `.codex-plugin/plugin.json`) → actionable error.
**Acceptance:** hermetic tests cover: resolution from the source checkout; from a copied/"installed" tree at a different absolute path; from a path containing spaces; an explicit override pointing at a valid plugin root; an explicit override pointing at an invalid/nonexistent directory (fails loudly, does not fall through); no test relies on CWD. bash 3.2-compatible, shellcheck-clean; Python stdlib-only.
**DoD:** suite green, shellcheck clean; resolver not yet wired into other scripts (that's CDX-002).

### CDX-002 · Migrate existing scripts off direct `CLAUDE_PLUGIN_ROOT` — P0 · 5 pts · §6.3 §6.7 §12
Update every script/skill currently interpolating `${CLAUDE_PLUGIN_ROOT}` directly (24 `SKILL.md` files + the scripts they invoke) to source/call the CDX-001 resolver instead. `SKILL.md` prose references to companion files become relative to the skill's own root.
**Acceptance:** zero remaining direct `${CLAUDE_PLUGIN_ROOT}` interpolations outside the resolver itself and its own Claude-fast-path branch; existing hermetic suite still green (no behavior change on the Claude fast path); a targeted test confirms at least one migrated script resolves correctly with `CLAUDE_PLUGIN_ROOT` unset and only the sentinel-based fallback available.
**DoD:** suite green, shellcheck clean.

### CDX-003 · `.codex-plugin/plugin.json` for both plugins — P0 · 3 pts · §6.1
Author valid manifests for `spec-workflow` and `scaffold-project` per `~/.codex/skills/.system/plugin-creator/references/plugin-json-spec.md` (real `name`/`version`/`description`/`author.name` + required `interface` fields; no unsupported fields, no inline `hooks`).
**Acceptance:** `python3 <codex plugin-creator>/scripts/validate_plugin.py <plugin-path>` passes for both; no `[TODO: ...]` placeholders; `.claude-plugin/plugin.json` untouched.
**DoD:** validator run recorded in the PR; suite green.

### CDX-004 · Codex marketplace manifest — P0 · 3 pts · §6.2 §15(OQ-1)
Create `.agents/plugins/marketplace.json` listing both plugins (`source: local`, `./plugins/<name>` paths), each entry with `policy.installation: AVAILABLE`, `policy.authentication: ON_INSTALL`, and `category` (default `Productivity` per OQ-1 unless the user specifies otherwise).
**Acceptance:** manifest matches the schema in the plugin-creator reference; `codex plugin list --marketplace <name> --json` (or documented equivalent) enumerates both plugins after a local marketplace add; `.claude-plugin/marketplace.json` untouched.
**DoD:** suite green; install/list command + output recorded in the PR.

### CDX-005 · Fix the 5 angle-bracket skill descriptions — P0 · 2 pts · §6.6
Rewrite `ask-brain`, `ask-identity`, `create-inbound`, `find-task` (in this worktree) and `changelog-generate` (once its branch merges) descriptions to drop literal `<`/`>` while keeping equivalent triggering precision.
**Acceptance:** `python3 <codex skill-creator>/scripts/quick_validate.py <skill-dir>` passes for all 5; a human diff review confirms no loss of triggering information (what the skill does / when to use it).
**DoD:** all 28 (29 once changelog-generate merges) `SKILL.md` pass the Codex linter; suite green.

### CDX-006 · `AGENTS.md` + `CLAUDE.md` pointer — P1 · 2 pts · §6.5 §15(OQ-2)
Author a canonical root `AGENTS.md`; reduce `CLAUDE.md` to a one-line pointer to it (or generate both from one source, per OQ-2 resolution).
**Acceptance:** `AGENTS.md` exists and covers what a Codex-side agent needs (repo purpose, dogfood note, pointer to SPEC.md/this spec); `CLAUDE.md` either is the one-liner pointer or both files are generated identically from a single source documented in the PR.
**DoD:** suite green; README cross-reference added if needed.

### CDX-007 · E0 exit smoke test — P0 · 3 pts · §14 (E0 exit condition)
End-to-end test: install a plugin via the CDX-004 marketplace into a scratch Codex config, then run a read-only script-backed skill (`find-task`, or `changelog-generate` once merged) from a separate temporary consumer repository (not this repo), asserting it completes and produces correct output.
**Acceptance:** test is hermetic/scriptable (temp dirs, no network beyond what Codex itself needs), documented as the concrete E0 acceptance evidence; failure mode (if Codex's install/list behavior differs from assumed) is reported precisely rather than worked around silently.
**DoD:** suite green; test added to CI-runnable suite or clearly marked as a manual verification script with instructions if CI can't host a real Codex install.

*(CDX-008–009 headroom for discovered E0 work.)*

## E1 — Portable interaction & invocation semantics (§7)

### CDX-010 · Capability-language rewrite: the 9 `AskUserQuestion` skills — P1 · 5 pts · §7.1
Rewrite the 9 skills that name `AskUserQuestion` directly to use capability language in shared prose, isolating any exact Claude tool call into a `references/host-claude.md` adapter per skill (only where the skill's complexity warrants a separate file; simple cases may inline a one-line Claude note).
**Acceptance:** none of the 9 shared `SKILL.md` bodies require a tool literally named `AskUserQuestion` to function; constraints (max question count, recommended option ordering, stop/continue semantics) are preserved in the capability-language rewrite; Claude UX unchanged (still uses `AskUserQuestion` in practice via the adapter).
**DoD:** suite green; skill-by-skill diff reviewed for lost nuance.

### CDX-011 · Plan-mode / no-write phase as capability language — P1 · 3 pts · §7.2
Convert `craft-spec`'s (and any other skill's) Claude-specific `EnterPlanMode`/`ExitPlanMode` framing into an explicit behavioral constraint ("no file writes during discovery/design"), with the Claude tool usage as an adapter note.
**Acceptance:** the constraint is testable/checkable independent of any specific host tool name; `craft-spec`'s existing Claude behavior (entering/exiting plan mode) is unchanged.
**DoD:** suite green.

### CDX-012 · Delegation-spawn capability language — P1 · 5 pts · §7.3
Rewrite subagent-spawning instructions in `implement-task`/`build-next`/others to capability language ("delegate to a fresh implementation agent when the host supports delegation"), isolating exact `Agent`/`subagent_type` parameters into a host adapter.
**Acceptance:** shared prose names no Claude-specific spawn tool/parameter directly; Claude's existing delegation behavior (one-agent-per-task, named `dev-<task-id>`, etc.) is unchanged and covered by the adapter.
**DoD:** suite green; this task feeds directly into E2 (CDX-02x) for the model-selection half of delegation.

### CDX-013 · Argument-semantics audit — P1 · 3 pts · §7.4 §7.5
Audit all skills for `ARGUMENTS:`-style assumptions and `!`-prefixed command-substitution prose; rewrite each as an explicit first workflow step or "treat arguments as the remainder of the request" framing.
**Acceptance:** grep for `ARGUMENTS:` and `!`-prefixed substitution patterns in `SKILL.md` files returns zero unconverted hits (a resolver/reference file explaining the convention is fine; skill-body prose that silently assumes it is not); Claude slash-command behavior unchanged.
**DoD:** suite green.

### CDX-014 · `ui-options`/`neural-view` graceful degradation — P1 · 3 pts · §7.6
Implement: `ui-options` omits (never fabricates) the resume link when `CLAUDE_CODE_SESSION_ID` is unset; `neural-view` renders without live-session data when `~/.claude/jobs` is absent, and labels session counts by host once both are surfaced.
**Acceptance:** red-first tests: unset session id → no resume link, no error; absent `~/.claude/jobs` → neural-view still renders (degraded, not crashed); existing Claude-session behavior unchanged when both are present.
**DoD:** suite green.

*(CDX-015–019 headroom for discovered E1 work.)*

## E2 — Host-aware delegation & model resolution (§8)

### CDX-020 · Additive `models.codex.capability` schema + normalizer — P1 · 5 pts · §8.1 §12 §14
Extend `schemas/project-config.schema.json` to accept an optional `models.codex.capability` (`fast`|`balanced`|`deep-review`|`large-context`) per identity, alongside the existing flat Claude `models` list. Add a normalizer that treats a legacy Claude-only config (no `models.codex`) as valid and produces a safe host-chosen default when a Codex-side model is needed.
**Acceptance:** schema change is additive (existing valid `project.yaml` files, including this repo's own, still validate unmodified); normalizer unit-tested for: legacy-only config, config with `models.codex.capability` set, and a config with an unrecognized capability value (fails clearly, doesn't silently default).
**DoD:** suite green; `docs/BACKLOG.md`-style schema doc/comment updated if the schema file is user-facing.

### CDX-021 · `implement-task`/`build-next` Codex model selection — P1 · 5 pts · §8.2 §8.3
Wire the CDX-020 resolution into the dev/reviewer briefing steps of `implement-task` and `build-next`: under Codex, select via the identity's `models.codex.capability` (or host default if unset); never reference a Claude-only model id in a Codex-run brief.
**Acceptance:** a Codex-path integration test (fixture config + fixture identity) confirms the generated brief contains no Claude model id string when run under a simulated Codex host; `covers`-glob routing, one-agent-per-task, independent dev/reviewer roles, role-prefixed naming, and per-commit attribution are unchanged and covered by regression tests.
**DoD:** suite green.

*(CDX-022–029 headroom for discovered E2 work.)*

## E3 — Build-loop & enforcement parity (§9)

### CDX-030 · Deterministic gate-before-review preflight (hook-independent) — P0 · 5 pts · §9.1 §12 §14
Extract the gate-pass-required-before-*In review* check currently enforced by the Claude `PreToolUse` hook (`guard-board-move.sh`) into an explicit, callable preflight step that any workflow (Claude or Codex) invokes before attempting the board move — not only as an intercepted tool call.
**Acceptance:** red-first regression test: with hook-based interception simulated as absent/bypassed, attempting to move a task to *In review* without a recorded gate pass for the current tree fingerprint is still blocked by the explicit preflight; existing Claude hook-based path is unchanged and still also blocks (defense in depth, not replaced).
**DoD:** suite green; this is the single highest-priority E3 task per §9.1/§12.

### CDX-031 · `build-next`/`implement-task` Codex-path parity walkthrough — P1 · 5 pts · §9.2
Verify and, where needed, adjust protocol text so that under Codex (no `SessionStart`/`PreToolUse` hooks) the workflow still enforces: truthful board-status transitions, human-comment steering read before implementation, red-first TDD, independent two-pass review, orchestrator-mediated brain isolation, mandatory retro/feedback at PR close, checkpoint behavior, concurrency lane/WIP-limit isolation, and bounded auto-merge review rounds.
**Acceptance:** a scenario test (or documented manual walkthrough with fixtures) exercises each invariant under a simulated Codex run and confirms it holds; any invariant that can't be verified as script-enforced is called out explicitly, not assumed.
**DoD:** suite green; any gap found becomes its own follow-up task rather than being silently accepted.

### CDX-032 · `session-start.sh` bootstrap equivalent for Codex — P2 · 3 pts · §9.3
Where `session-start.sh` (Claude `SessionStart` hook) performs bootstrap checks with no Codex lifecycle equivalent, provide those same checks as an explicit first-step preflight skill invocation usable under Codex.
**Acceptance:** the bootstrap checks currently only run by the Claude hook are reachable and testable as a standalone script/step; Claude's existing hook-triggered behavior is unchanged.
**DoD:** suite green.

*(CDX-033–039 headroom for discovered E3 work.)*

## E4 — CI, documentation & compatibility matrix (§10)

### CDX-040 · CI: Codex plugin/skill validation job — P0 · 3 pts · §10.1
Add a CI job running the Codex plugin validator against both `.codex-plugin/plugin.json` manifests and the Codex skill linter against all `SKILL.md` files, alongside the existing Claude `validate-manifests` job.
**Acceptance:** `.github/workflows/ci.yml` gains the new job; a deliberately broken manifest/description in a test branch fails it (verified once, then reverted); existing Claude jobs unchanged.
**DoD:** CI green on a real PR.

### CDX-041 · README updates (root + plugin) — P1 · 3 pts · §10.2
Update `README.md` and `plugins/spec-workflow/README.md` (and `plugins/scaffold-project/`'s if it has one) with: install/update instructions for both hosts (commands actually run and verified), per-host invocation, permissions/authentication needed, per-host model configuration (§8.1), why `.claude/` remains canonical, and a parity/degradation summary.
**Acceptance:** every documented command was actually run against the installed Claude and Codex CLIs during this task and its output matches what's written; no invented flags or unverified behavior.
**DoD:** suite green (docs-only change, but `docs[]` covers[] entries in `project.yaml` are satisfied).

### CDX-042 · Compatibility matrix — P1 · 3 pts · §10.3
Produce a compatibility matrix (table: skill or skill group, Claude support, Codex support, known limitation) covering all skills, seeded from the E0–E3 work already completed.
**Acceptance:** every one of the 28 (soon 29+) skills appears in exactly one row (individually or grouped with a stated rationale); every "degraded" or "not yet ported" entry links to the specific limitation, not a vague note.
**DoD:** matrix committed (e.g. in the root README or a dedicated doc referenced from it).

### CDX-043 · Version bump + release notes — P2 · 2 pts · §10 (release hygiene — no numbered requirement; standard semver practice per §12)
Bump `spec-workflow` and `scaffold-project` plugin versions (both manifests, both marketplaces) per semver for the dual-host release; note the change in whatever changelog mechanism exists (or is landing via the in-flight `changelog-generate` skill).
**Acceptance:** versions bumped consistently across `.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`, and both marketplace entries; no stale version string left in any manifest.
**DoD:** suite green.

*(CDX-044–049 headroom for discovered E4 work.)*

## E5 — Compatibility sweep for new/in-flight work (§11)

### CDX-050 · Sweep compute-registry skill(s) for dual-host compliance — P2 · 3 pts · §11.1
Once the compute-registry work (issue #166) lands a mergeable skill, review it against §7–§9 of this spec (interaction semantics, delegation config, enforcement parity — §10.1's CI already covers the §6.6 lint portion) and record the result as new row(s) in the CDX-042 compatibility matrix.
**Acceptance:** review documented (compliant, or specific named gaps); any gap filed as its own follow-up board task, not fixed silently inline as part of this task.
**DoD:** matrix updated; suite green if any fix was needed and included.

### CDX-051 · Sweep peer-review skill(s) for dual-host compliance — P2 · 3 pts · §11.2
Same review as CDX-050, scoped to the peer-review work (issues #167/#168, backlog at `docs/BACKLOG-PEER-REVIEW.md`).
**Acceptance:** same as CDX-050.
**DoD:** matrix updated; suite green if any fix was needed and included.

### CDX-052 · Standing dual-host compliance checklist — P2 · 2 pts · §11.3
Add a short, linkable checklist (e.g. a `references/` doc or a section in `craft-spec`/`seed-board`) that any future new skill or plugin gets checked against §7–§9 before being considered dual-host complete, so this isn't a one-time sweep.
**Acceptance:** checklist exists, is referenced from at least one skill in the seed/creation path (e.g. `craft-spec` or `seed-board`), and explicitly states that CI (§10.1) already covers the lint-able portion so the checklist only needs to cover judgment-requiring items.
**DoD:** suite green.

*(CDX-053–059 headroom for future new-skill sweeps.)*
