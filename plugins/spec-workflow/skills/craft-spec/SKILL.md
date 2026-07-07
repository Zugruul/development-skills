---
name: craft-spec
description: Assisted spec creation — interviews the user (plan mode + structured questions), drafts a numbered-section spec with EARS acceptance criteria, derives an epic/task backlog, review-gates it, and registers it in project.yaml. Use for 'write/create/draft a spec', starting a project that has no spec, or adding a new spec to an existing repo.
---

# Craft a spec with the user

Deliverables: a spec document (e.g. `SPEC.md`), a backlog document (e.g. `docs/BACKLOG.md`) with epics + numbered, story-pointed, acceptance-criteria'd tasks, and (if `.claude/project.yaml` exists) a registered `specs[]` entry. The spec is the contract every future task is built and judged against — invest accordingly.

Read `${CLAUDE_PLUGIN_ROOT}/skills/craft-spec/references/spec-guide.md` **before Phase 2** — it has the document structure, the interview question bank, and the review checklist.

## Phase 0 — orient
- Check what exists: `.claude/project.yaml` (registered specs?), any `SPEC*.md` / `docs/` design docs, and the codebase itself. Adding a spec to an existing project? Read the existing spec's conventions and reuse them.
- If the user gave a written brief, mine it first — never ask what it already answers.

## Phase 1 — discover (plan mode + interview)
1. Enter plan mode (EnterPlanMode) if available: this phase is research + design, no file writes yet.
2. Interview with AskUserQuestion, in rounds of at most 4 questions, using the question bank in the reference. Cover, in order: problem & users → goals and explicit NON-goals → domain concepts & invariants → constraints (stack, compliance, performance, budget) → integrations/compatibility surface → quality attributes & testing expectations → delivery order and milestones.
3. Rules: offer concrete options (the user can always pick Other); state your inferences as defaults to confirm rather than open questions; stop interviewing when new answers stop changing the design — 2–4 rounds is typical.

## Phase 2 — draft
Write the spec following the structure in the reference: numbered sections (`§N`) so tasks can cite them; every functional requirement stated testably; hard invariants in their own section (they become `specs[].invariants`); explicit non-goals; open questions listed with owners, never silently dropped.

## Phase 3 — backlog
Derive from the spec: epics in build order (foundations → features → polish) with dependency guards where order is mandatory; tasks numbered in per-epic ranges (e.g. E0=001–009, E1=010–019, infra=090–099), each with priority, story points, acceptance criteria, and the spec §s it implements. Every requirement in the spec must be covered by at least one task.

## Phase 4 — review (do not skip)
1. Self-review against the checklist in the reference; fix what fails.
2. Present to the user: a compact summary (goals, non-goals, epic sequence, riskiest decisions, open questions) — via plan approval (ExitPlanMode) if in plan mode, else directly. Use AskUserQuestion to resolve each open question and to get explicit sign-off on scope and epic order. Iterate until approved.

## Phase 5 — wire up
- `.claude/project.yaml` exists → add the `specs[]` entry (unique `taskPrefix`, epics with `taskRanges` + `blockedBy`, `invariants` copied from the spec), then validate: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/board.sh" config`. Suggest `seed-board` next.
- No config yet → suggest `setup-project` (the spec paths from this session slot into its Phase 2).
