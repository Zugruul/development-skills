# spec-workflow

Spec-driven autonomous build workflow for Claude Code: a GitHub Project board is the source of truth, tasks are implemented TDD-first by delegated dev agents, a single gate command decides advancement, and humans steer asynchronously through issue comments and UI-option pages.

Everything project-specific lives in the consumer repo's **`.claude/project.json`** (versioned, `schemaVersion: 1` — [schema](./schemas/project-config.schema.json) with editor `$schema` support): boards + field ids, one or more specs with epics/task ranges/dependency guards, hard invariants, gate/dev commands, `docs[]` sets (where documentation lives + which code paths each covers — one set for a standalone repo, one per package for a monorepo; the reviewer blocks PRs that change covered behavior without updating them), delegation models (incl. `prReviewModel` and per-role commit `identities` — template-resolved per clone), paths, and methodology knobs (`maxInProgress`, `iterativeUI`, `isolationSuite`, and `autoMerge`/`mergeMethod` — autonomous PR review, approval, and merge in place of human approval; protocol in [`skills/build-next/references/auto-review.md`](./skills/build-next/references/auto-review.md)).

## Skills

| Skill | Purpose |
|---|---|
| `craft-spec` | Assisted spec creation: plan-mode interview → numbered-§ draft → backlog → review gate |
| `setup-project` | Bootstrap a repo: board creation, `init-config.sh` auto-fill, validation, hygiene |
| `seed-board` | Issues + board items from the backlog (idempotent) |
| `board` | All board reads/writes via `board.sh` (no hardcoded ids); comments are the human steering channel |
| `next-task` | `PICK` / `RESUME` / `BLOCKED` decision from priority, epic order, guards, and the WIP limit |
| `implement-task` | One task: brief a dev subagent (what/how/why), verify, drive the board |
| `ui-options` | Iterative UI mode: options page with favorite + aspect selection for the human |
| `gate` | The single green-before-advance quality command |
| `auto-merge` | Status/on/off for autonomous PR review+merge (`methodology.autoMerge`); asks with flow previews when called bare |
| `pr-review-model` | Show/set the autonomous PR reviewer's model (`delegation.prReviewModel`); asks with options when called bare |
| `agent-identities` | Show/set per-role commit identities (`{name}`/`{local}+suffix@{domain}` templates, per-clone resolution) |
| `build-next` | One loop iteration — drive with `/loop /spec-workflow:build-next` |
| `checkpoint` / `handoff` | Pause/resume the loop via a local flag; session handoff docs |
| `dev-up` | Bring up the project's dev stack for QA |

## Scripts (`scripts/`)

`board.sh` (next/show/move/prio/est/bug/list/comment/edit-body/fields/config) · `next.py` (picker: priority → epic rank → guards → WIP resume) · `init-config.sh` (auto-fill board ids from a live project) · `seed-board.sh` · `preflight.sh` (load-time config/spec checks injected into spec-requiring skills) · `validate-config.py` · `merge-mode.sh` (auto-merge status/on/off + reviewer model/merge method) · `identity.sh` (per-role commit identity resolution: `{name}`, `{local}+suffix@{domain}`; `--check` runs in preflight).

## Human steering

- **Issue comments** — read before every task; scope changes are folded into the issue body and acknowledged.
- **Iterative UI mode** (default ON) — UI decisions go to the human via `docs/ui-options/<task-id>.html` (favorite selector + likeable aspect keywords + notes; "Copy selection" produces the comment to paste). Disable per-clone with `touch .claude/ITERATIVE_UI_OFF` or permanently with `methodology.iterativeUI: false`.
- **Checkpoint flag** — `touch .claude/CHECKPOINT` pauses the loop at the next safe boundary with a handoff.

## Testing

```bash
bash tests/run-tests.sh        # hermetic: validator fixtures, picker, preflight, init-config (fake gh)
python3 tests/check-evals.py   # eval case structure
claude plugin eval .           # skill evals on real models (early access)
```
