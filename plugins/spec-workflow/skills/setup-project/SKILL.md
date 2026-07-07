---
name: setup-project
description: Bootstraps a repository for the spec-workflow — creates the GitHub Project board, auto-fills .claude/project.json ids via init-config.sh, validates the config, and sets up local-state gitignores. Use for 'set up this repo', 'adopt the workflow', 'initialize the board', or onboarding a new/existing project.
---

# Set up a repository for the spec-workflow

Goal: after this skill, the repo has a valid `.claude/project.json` (schemaVersion 1), a GitHub Project board wired to it, and is ready for `seed-board` → `/loop /spec-workflow:build-next`.

Work through the phases in order. Do not skip validation.

## Phase 1 — prerequisites (check, fix, or stop)
```bash
gh auth status          # must be logged in AND show the 'project' scope
git rev-parse --show-toplevel   # must be inside a git repo (git init if new)
```
If the `project` scope is missing: `gh auth refresh -h github.com -s project` (interactive — ask the human to run it if it fails).

## Phase 2 — the spec(s)
Each spec is a design document plus a backlog of numbered tasks. One repo can have several specs (e.g. `platform` + `mobile-app`), each with its own task prefix.
- If a spec already exists, note its path. If not, STOP here and run the `craft-spec` skill — it interviews the user and produces the spec + backlog this workflow needs; then resume at Phase 3. The workflow is spec-driven; there is nothing to build without it.
- For each spec, a backlog doc (e.g. `docs/BACKLOG.md`) should list every task: `<PREFIX>-<number>`, title, epic, priority, story points, acceptance criteria, Definition of Done. Number tasks in per-epic ranges (e.g. E0 = 001–009, E1 = 010–019, infra = 090–099) so ranges map cleanly to epics.

## Phase 3 — GitHub Project board
Create one board per `boards[]` entry you plan (usually one). Exact commands: read `${CLAUDE_PLUGIN_ROOT}/skills/setup-project/references/github-project-setup.md` **now** and follow it. It covers: creating the Project, adding the Status options, Priority and Estimate fields.

## Phase 4 — write .claude/project.json
1. Auto-fill the board ids (creates the config from the template if none exists, else updates `boards[0]` in place):
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/init-config.sh" <owner> <owner/repo> <project-number>
   ```
   Review its output: reorder `statusFlow` / priority options if the board returned them in a different order than the intended pipeline/rank.
2. Fill every field. The full schema with descriptions is `${CLAUDE_PLUGIN_ROOT}/schemas/project-config.schema.json`; keep the template's `$schema` line — it gives humans editor autocomplete/validation. Key decisions:
   - `project.branchPattern` — e.g. `<prefix>/<id>-<slug>` → branches like `cp/012-error-model`.
   - `boards[]` — ids from Phase 3. `statusFlow` order **is** the pipeline; priority `options` order **is** the priority order (highest first).
   - `specs[]` — one entry per spec: unique `taskPrefix`, `epics` in build order with `taskRanges`, and `blockedBy` guards for hard dependencies (e.g. nothing from E1 until E0 is fully Deployed).
   - `specs[].invariants` — the project's hard rules, stated imperatively; they are pasted verbatim into every implementation brief, so make them self-contained.
   - `commands.gate` — ONE command running build+lint+format+tests. Create it (e.g. a `gate` script in package.json) if it doesn't exist; the whole workflow hinges on it.
   - **Merge policy** — AskUserQuestion (header "Merging"): does a human approve/merge every PR (default, `methodology.autoMerge: false`) or does the loop review+merge autonomously (`true` — the `auto-merge` skill explains/toggles it later)? If autonomous, also ask `methodology.mergeMethod`: **squash (Recommended)** — linear history; per-role commit attribution is preserved as `Co-authored-by:` trailers in the squash body plus the PR link — vs **merge** — keeps the individual role-attributed commits on main — vs **rebase**. Also mention `docs[]`: declare where documentation lives (one set for a standalone repo, one per package for a monorepo) so the reviewer can enforce doc maintenance.
3. Validate — must print `VALID`:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/board.sh" config
   ```

## Phase 5 — repo hygiene
- Add the local flags + state to `.gitignore`: `printf '.claude/CHECKPOINT\n.claude/ITERATIVE_UI_OFF\n.claude/ui-hub/\n.claude/gate-pass\n' >> .gitignore`
- Create `paths.handoffDir` (default `docs/handoffs/`).
- If the project has a dev stack, set `commands.devUp` and write the doc at `paths.devDoc` (ports, profiles, preconditions).
- Commit `.claude/project.json` + docs.

## Phase 6 — seed and go
1. Run the `seed-board` skill to create one issue + board item per backlog task.
2. Smoke-test: `board.sh next` must print a sensible `=> PICK`, and `board.sh list` the seeded items.
3. Start building: `/spec-workflow:build-next` once, or `/loop /spec-workflow:build-next` for the autonomous loop. Pause anytime with the `checkpoint` skill.

## Adding a spec to an already-configured repo
Append a new `specs[]` entry (unique `taskPrefix`, own epics/ranges/guards), re-run `board.sh config`, extend the backlog doc, and run `seed-board` for the new tasks. Boards can be shared or per-spec (`specs[].board`).
