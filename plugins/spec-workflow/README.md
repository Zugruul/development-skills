# spec-workflow

Spec-driven autonomous build workflow for Claude Code: a GitHub Project board is the source of truth, tasks are implemented TDD-first by delegated dev agents, a single gate command decides advancement, and humans steer asynchronously through issue comments and UI-option pages.

Everything project-specific lives in the consumer repo's **`.claude/project.yaml`** (versioned, `schemaVersion: 2`, YAML — [schema](./schemas/project-config.schema.json)): boards + field ids, one or more specs with epics/task ranges/dependency guards, hard invariants, gate/dev commands, `docs[]` sets (where documentation lives + which code paths each covers — one set for a standalone repo, one per package for a monorepo; the reviewer blocks PRs that change covered behavior without updating them), the `delegation.identities` roster (each role's git author templates AND its ALLOWED `models`, resolved per-clone; a role may be an array of per-package identities routed by `covers` globs), paths, and methodology knobs (`maxInProgress`, `iterativeUI`, `isolationSuite`, and `autoMerge`/`mergeMethod` — autonomous PR review, approval, and merge in place of human approval; protocol in [`skills/build-next/references/auto-review.md`](./skills/build-next/references/auto-review.md)).

**Editor support**: `project.yaml`'s first line is a `# yaml-language-server: $schema=…` modeline; the Red Hat YAML extension (`redhat.vscode-yaml`) reads it for hover + autocomplete. `setup-project` also writes a `.vscode/` `yaml.schemas` mapping and an extension recommendation. **Legacy**: a `.claude/project.json` (schemaVersion 1, old `delegation.devModel/reviewModel/prReviewModel` keys) is still read — normalized to the v2 shape with a deprecation warning; `init-config.sh` converts it to `project.yaml`. Requires **PyYAML** (`pip3 install pyyaml`).

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
| `pr-review-model` | Show/set the autonomous PR reviewer's allowed models (`delegation.identities.reviewer.models`); asks with options when called bare |
| `agent-identities` | Show/set per-role identities — name/email templates, allowed `models`, `covers` routing (per-clone resolution) |
| `build-next` | One loop iteration — drive with `/loop /spec-workflow:build-next` |
| `brain` | Inspect/tend the per-identity zettel brains (recall/mint/prune/directory); orchestrator-only |
| `checkpoint` / `handoff` | Pause/resume the loop via a local flag; session handoff docs |
| `dev-up` | Bring up the project's dev stack for QA |

## Scripts (`scripts/`)

`config.py` (the shared loader: finds `.claude/project.yaml`, normalizes legacy json, `get`/`json`/`path` verbs for bash callers) · `board.sh` (next/show/move/prio/est/bug/list/comment/edit-body/fields/config) · `next.py` (picker: priority → epic rank → guards → WIP resume) · `init-config.sh` (auto-fill board ids from a live project; writes `project.yaml`) · `seed-board.sh` · `preflight.sh` (load-time config/spec checks injected into spec-requiring skills) · `validate-config.py` · `merge-mode.sh` (auto-merge status/on/off + reviewer models/merge method) · `identity.sh` (per-role identity + allowed-models resolution, `covers` path routing; `--check` runs in preflight) · `brain.sh`→`brain.py` (per-identity zettel memory: mint/recall/directory/consult/prune/graduate; spreading-activation retrieval, stdlib only).

## Identity brains

Each agent role (dev / reviewer / orchestrator, extensible) owns a **private** brain of atomic zettel notes under `.claude/identities/<role>/brain/` in the consumer repo. Brains give each identity durable memory that evolves **separately** — a hard product requirement. `ROLE.md` (per role) is the stable, human-owned instruction; starter templates ship in [`templates/identities/`](./templates/identities/).

- **Isolation** — only the orchestrator process reads or writes a brain. Subagents never see a brain path; recalled lessons reach them as pasted text in their brief. One role reads another's note only through a deliberate `consult`.
- **Retrieval** — `brain.sh recall <role> --paths ... --keywords ...` runs **spreading activation**: notes seeded by path-glob/tag match, activation flowing along `[[wikilink]]` edges (2 hops), emitted strongest-first within a token budget. Graduated notes stop being injected but still bridge links.
- **Evolution** — at each PR close the orchestrator runs a retro: `mint` notes in its own wording (strength bumps on re-mint), `prune` stale links, `graduate` proven lessons, regenerate `DIRECTORY.md`, commit as the orchestrator identity.
- **Contract** — every recall/consult appends to `<role>/brain/.activation.jsonl` (a frozen JSON-lines format a live viewer consumes). Link metadata (weight/fires/last) lives in `links.json`; notes stay clean markdown.

Full protocol: [`skills/build-next/references/brains.md`](./skills/build-next/references/brains.md).

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
