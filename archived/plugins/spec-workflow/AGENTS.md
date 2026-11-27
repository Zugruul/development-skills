# spec-workflow: rules for working on this plugin

`spec-workflow` is **archived**: it is not developed further, and CI does not run its suite (see [`archived/AGENTS.md`](../../AGENTS.md), including the hazard of running that suite). These are the rules that applied to this repository while `spec-workflow` built it, dogfood-style. They still apply to any change made to `archived/plugins/spec-workflow/`, and to repositories that use spec-workflow. The repository-wide rules are in the root [`AGENTS.md`](../../../AGENTS.md).

## You may be the loop itself

That dogfooding isn't incidental: this repo is built by the `spec-workflow` plugin it ships, autonomously, one board task at a time, via `/spec-workflow:build-next`. If you were invoked to implement a task here, there is a real chance you *are* an instance of that same loop — a dev/reviewer/orchestrator identity working a spec-driven task off the GitHub Project board. Behave accordingly: strict TDD (a failing test commits before the implementation that turns it green), and don't hand-wave the gate below.

## Where the contract lives

- [`SPEC.md`](../../../SPEC.md) — spec-workflow's own contract (the plugin most of this repo's work targets).
- [`SPEC-CODEX-COMPAT.md`](../../../SPEC-CODEX-COMPAT.md) — the dual-host (Claude Code + Codex) compatibility spec that this file itself exists to satisfy (§6.5).
- [`docs/BACKLOG-CODEX-COMPAT.md`](../../../docs/BACKLOG-CODEX-COMPAT.md) — the task backlog for that compatibility work.
- [`.neural-network/project.yaml`](../../../.neural-network/project.yaml) — machine-readable config: boards, specs, epics, invariants, and the gate command below.

## Validating a change

The single command that proves a change is correct in this repo (`.neural-network/project.yaml`'s `commands.gate`, quoted verbatim):

```
bash archived/plugins/spec-workflow/tests/run-tests.sh && bash archived/plugins/remote-compute/tests/run-tests.sh && shellcheck -x archived/plugins/spec-workflow/scripts/*.sh archived/plugins/spec-workflow/scripts/lib/*.sh archived/plugins/spec-workflow/tests/*.sh archived/plugins/remote-compute/tests/*.sh && claude plugin validate archived/plugins/spec-workflow && claude plugin validate archived/plugins/remote-compute
```

Run it green before considering any task done.

## Schema versioning

Every schema'd file this repo owns (a consumer repo's `.neural-network/project.yaml`, its `specs/<id>.yaml` files, and any future config-family file) carries a `schemaVersion` as a **semver string** — current: `"2.0.0"`. A missing field, or the legacy integers (`1` json era, `2` pre-cutover yaml era), all read as **`1.0.0`** (`config.py schema_semver()` / the `schema-version` CLI verb are the one detection path).

Maintaining it — any schema-breaking change MUST, in the same PR:

1. Bump `SCHEMA_SEMVER` in `archived/plugins/spec-workflow/scripts/config.py` (major bump for breaking changes).
2. Add a `## <old> → <new>` chapter to `archived/plugins/spec-workflow/skills/migrate-version/references/migrations.md` with **idempotent** steps a consumer repo follows to migrate (the `migrate-version` skill applies chapters in order and verifies after each).
3. Update `validate-config.py`'s accepted versions and `schemas/project-config.schema.json`'s `schemaVersion` description, plus any deprecation note text.
4. Never break reading of the previous version silently: old versions stay detectable and the registry says how to leave them.

## Skills

Spec-driven project setup and delivery, configured per consumer repository in
`.neural-network/project.yaml`. The workflow covers specs, GitHub Project
boards, TDD implementation, gates, reviews, identity brains, and project
operations. The repo's `SPEC.md` and `SPEC-ASSISTANT.md` define the detailed
contracts.

| Skill | Purpose |
| --- | --- |
| [agent-identities](skills/agent-identities/SKILL.md) | Configure per-role Git author names and emails. |
| [ask-brain](skills/ask-brain/SKILL.md) | Ask all identity brains collectively, grounded in their recorded knowledge. |
| [ask-identity](skills/ask-identity/SKILL.md) | Ask one role's identity brain without starting a build iteration. |
| [auto-merge](skills/auto-merge/SKILL.md) | Inspect or toggle autonomous PR review, approval, and merge. |
| [board](skills/board/SKILL.md) | Read or update the configured GitHub Project board and issues. |
| [brain](skills/brain/SKILL.md) | Inspect, recall, maintain, and explain per-role zettel brains. |
| [build-next](skills/build-next/SKILL.md) | Run one complete autonomous board-to-PR build iteration. |
| [changelog-generate](skills/changelog-generate/SKILL.md) | Regenerate a versioned changelog from Git history. |
| [checkpoint](skills/checkpoint/SKILL.md) | Pause or resume the build loop at a safe task boundary. |
| [concurrency](skills/concurrency/SKILL.md) | Inspect or set the board WIP limit and parallel implementation lanes. |
| [craft-spec](skills/craft-spec/SKILL.md) | Interview, draft, and review a spec and derive its task backlog. |
| [create-inbound](skills/create-inbound/SKILL.md) | Search for duplicates, then capture an ad-hoc request on the board. |
| [dev-up](skills/dev-up/SKILL.md) | Start the project's configured development stack for QA or debugging. |
| [feedback](skills/feedback/SKILL.md) | Record structured feedback about the workflow for later triage. |
| [find-task](skills/find-task/SKILL.md) | Search existing board issues by title and body similarity. |
| [gate](skills/gate/SKILL.md) | Run and record the project's required quality gate. |
| [handoff](skills/handoff/SKILL.md) | Write a resumable session handoff with board and runtime state. |
| [implement-task](skills/implement-task/SKILL.md) | Orchestrate one board task through delegated TDD, review, and board updates. |
| [knowledge-base-seed](skills/knowledge-base-seed/SKILL.md) | Seed or refresh the repository knowledge identity brain from project sources. |
| [migrate-version](skills/migrate-version/SKILL.md) | Migrate project config and related data through the versioned migration registry. |
| [neural-network-projects-list](skills/neural-network-projects-list/SKILL.md) | List anchored local repos with config toggles, configured boards and validation errors, without writes or network. |
| [neural-view](skills/neural-view/SKILL.md) | Start, stop, or inspect the live identity-brain and project visualization. |
| [next-task](skills/next-task/SKILL.md) | Select the next eligible board task, honoring priority, dependencies, and comments. |
| [pr-review-model](skills/pr-review-model/SKILL.md) | Inspect or set the allowed models for the autonomous reviewer identity. |
| [queue](skills/queue/SKILL.md) | Show upcoming build-loop picks and why tasks may be blocked. |
| [refine-task-ui](skills/refine-task-ui/SKILL.md) | Turn a UI direction picked through the ui-design plugin into screenshots and actionable issue criteria. |
| [retrospective](skills/retrospective/SKILL.md) | Triage workflow feedback and maintain identity-brain notes. |
| [seed-board](skills/seed-board/SKILL.md) | Create board issues from a backlog after complexity scoring and splitting. |
| [setup-assistant](skills/setup-assistant/SKILL.md) | Scaffold or configure a persistent assistant repo, its persona, and memory. |
| [remote-compute-control](skills/remote-compute-control/SKILL.md) | Use data-only assistant provisioning for audited WSL inventory, status, redacted bounded logs and cancellation through dedicated per-class forced-command SSH keys. |
| [comfyui-render](skills/comfyui-render/SKILL.md) | Queue pinned ComfyUI image workflows over a dedicated SSH tunnel, recover owned requests, and publish audited artifacts. |
| [setup-project](skills/setup-project/SKILL.md) | Initialize a repo's project config, GitHub Project board, and local-state ignores. |
| [sync-project-configs](skills/sync-project-configs/SKILL.md) | Dry-run or apply versioned config updates across discovered project repos. |
| [task-state](skills/task-state/SKILL.md) | Keep the local record of tasks in progress and their TODOs, shared across agents and worktrees. |
| [whisper-sidecar](skills/whisper-sidecar/SKILL.md) | Install, run, stop, or health-check the private local whisper.cpp speech sidecar. |

Mocking UI options and the human's pick live in the standalone `ui-design` plugin (`ui-design:ui-mode`, `ui-design:ui-options`). The build loop calls those skills by name when ui-design is installed and decides UI itself otherwise; the workflow side (`methodology.iterativeUI`, the issue channel, `design-registry.py` and its move-to-review guard, `refine-task-ui`) stays here — see [`skills/build-next/references/ui-design.md`](skills/build-next/references/ui-design.md).
