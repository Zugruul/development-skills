# AGENTS.md

This repo is [Zugruul/development-skills](https://github.com/Zugruul/development-skills), a Claude Code and Codex plugin marketplace: `spec-workflow`, `scaffold-project`, `peer-review`, and `remote-compute` ship from `plugins/`. `spec-workflow` — the autonomous build-loop plugin — develops *this very repo*, dogfood-style.

## You may be the loop itself

That dogfooding isn't incidental: this repo is built by the `spec-workflow` plugin it ships, autonomously, one board task at a time, via `/spec-workflow:build-next`. If you were invoked to implement a task here, there is a real chance you *are* an instance of that same loop — a dev/reviewer/orchestrator identity working a spec-driven task off the GitHub Project board. Behave accordingly: strict TDD (a failing test commits before the implementation that turns it green), and don't hand-wave the gate below.

## Where the contract lives

- [`SPEC.md`](SPEC.md) — spec-workflow's own contract (the plugin most of this repo's work targets).
- [`SPEC-CODEX-COMPAT.md`](SPEC-CODEX-COMPAT.md) — the dual-host (Claude Code + Codex) compatibility spec that this file itself exists to satisfy (§6.5).
- [`docs/BACKLOG-CODEX-COMPAT.md`](docs/BACKLOG-CODEX-COMPAT.md) — the task backlog for that compatibility work.
- [`.neural-network/project.yaml`](.neural-network/project.yaml) — machine-readable config: boards, specs, epics, invariants, and the gate command below.

## Validating a change

The single command that proves a change is correct in this repo (`.neural-network/project.yaml`'s `commands.gate`, quoted verbatim):

```
bash plugins/spec-workflow/tests/run-tests.sh && bash plugins/remote-compute/tests/run-tests.sh && shellcheck -x plugins/spec-workflow/scripts/*.sh plugins/spec-workflow/scripts/lib/*.sh plugins/spec-workflow/tests/*.sh plugins/remote-compute/tests/*.sh && claude plugin validate plugins/spec-workflow && claude plugin validate plugins/remote-compute
```

Run it green before considering any task done.

## Schema versioning

Every schema'd file this repo owns (a consumer repo's `.neural-network/project.yaml`, its `specs/<id>.yaml` files, and any future config-family file) carries a `schemaVersion` as a **semver string** — current: `"2.0.0"`. A missing field, or the legacy integers (`1` json era, `2` pre-cutover yaml era), all read as **`1.0.0`** (`config.py schema_semver()` / the `schema-version` CLI verb are the one detection path).

Maintaining it — any schema-breaking change MUST, in the same PR:

1. Bump `SCHEMA_SEMVER` in `plugins/spec-workflow/scripts/config.py` (major bump for breaking changes).
2. Add a `## <old> → <new>` chapter to `plugins/spec-workflow/skills/migrate-version/references/migrations.md` with **idempotent** steps a consumer repo follows to migrate (the `migrate-version` skill applies chapters in order and verifies after each).
3. Update `validate-config.py`'s accepted versions and `schemas/project-config.schema.json`'s `schemaVersion` description, plus any deprecation note text.
4. Never break reading of the previous version silently: old versions stay detectable and the registry says how to leave them.

## Install and usage

See [`README.md`](README.md) for marketplace install/update instructions and the per-plugin skills tables.

## What this marketplace provides

This repository ships four plugins. Each skill's `SKILL.md` is the operational
source of truth; the index below describes when to use it and links directly to
its instructions. Keep these summaries and the README's plugin tables in sync
when skills are added, removed, or renamed.

### spec-workflow

Spec-driven project setup and delivery, configured per consumer repository in
`.neural-network/project.yaml`. The workflow covers specs, GitHub Project
boards, TDD implementation, gates, reviews, identity brains, and project
operations. The repo's `SPEC.md` and `SPEC-ASSISTANT.md` define the detailed
contracts.

| Skill | Purpose |
| --- | --- |
| [agent-identities](plugins/spec-workflow/skills/agent-identities/SKILL.md) | Configure per-role Git author names and emails. |
| [ask-brain](plugins/spec-workflow/skills/ask-brain/SKILL.md) | Ask all identity brains collectively, grounded in their recorded knowledge. |
| [ask-identity](plugins/spec-workflow/skills/ask-identity/SKILL.md) | Ask one role's identity brain without starting a build iteration. |
| [auto-merge](plugins/spec-workflow/skills/auto-merge/SKILL.md) | Inspect or toggle autonomous PR review, approval, and merge. |
| [board](plugins/spec-workflow/skills/board/SKILL.md) | Read or update the configured GitHub Project board and issues. |
| [brain](plugins/spec-workflow/skills/brain/SKILL.md) | Inspect, recall, maintain, and explain per-role zettel brains. |
| [build-next](plugins/spec-workflow/skills/build-next/SKILL.md) | Run one complete autonomous board-to-PR build iteration. |
| [changelog-generate](plugins/spec-workflow/skills/changelog-generate/SKILL.md) | Regenerate a versioned changelog from Git history. |
| [checkpoint](plugins/spec-workflow/skills/checkpoint/SKILL.md) | Pause or resume the build loop at a safe task boundary. |
| [concurrency](plugins/spec-workflow/skills/concurrency/SKILL.md) | Inspect or set the board WIP limit and parallel implementation lanes. |
| [craft-spec](plugins/spec-workflow/skills/craft-spec/SKILL.md) | Interview, draft, and review a spec and derive its task backlog. |
| [create-inbound](plugins/spec-workflow/skills/create-inbound/SKILL.md) | Search for duplicates, then capture an ad-hoc request on the board. |
| [dev-up](plugins/spec-workflow/skills/dev-up/SKILL.md) | Start the project's configured development stack for QA or debugging. |
| [feedback](plugins/spec-workflow/skills/feedback/SKILL.md) | Record structured feedback about the workflow for later triage. |
| [find-task](plugins/spec-workflow/skills/find-task/SKILL.md) | Search existing board issues by title and body similarity. |
| [gate](plugins/spec-workflow/skills/gate/SKILL.md) | Run and record the project's required quality gate. |
| [handoff](plugins/spec-workflow/skills/handoff/SKILL.md) | Write a resumable session handoff with board and runtime state. |
| [implement-task](plugins/spec-workflow/skills/implement-task/SKILL.md) | Orchestrate one board task through delegated TDD, review, and board updates. |
| [knowledge-base-seed](plugins/spec-workflow/skills/knowledge-base-seed/SKILL.md) | Seed or refresh the repository knowledge identity brain from project sources. |
| [migrate-version](plugins/spec-workflow/skills/migrate-version/SKILL.md) | Migrate project config and related data through the versioned migration registry. |
| [neural-view](plugins/spec-workflow/skills/neural-view/SKILL.md) | Start, stop, or inspect the live identity-brain and project visualization. |
| [next-task](plugins/spec-workflow/skills/next-task/SKILL.md) | Select the next eligible board task, honoring priority, dependencies, and comments. |
| [pr-review-model](plugins/spec-workflow/skills/pr-review-model/SKILL.md) | Inspect or set the allowed models for the autonomous reviewer identity. |
| [queue](plugins/spec-workflow/skills/queue/SKILL.md) | Show upcoming build-loop picks and why tasks may be blocked. |
| [refine-task-ui](plugins/spec-workflow/skills/refine-task-ui/SKILL.md) | Turn a selected UI direction into screenshots and actionable issue criteria. |
| [retrospective](plugins/spec-workflow/skills/retrospective/SKILL.md) | Triage workflow feedback and maintain identity-brain notes. |
| [seed-board](plugins/spec-workflow/skills/seed-board/SKILL.md) | Create board issues from a backlog after complexity scoring and splitting. |
| [setup-assistant](plugins/spec-workflow/skills/setup-assistant/SKILL.md) | Scaffold or configure a persistent assistant repo, its persona, and memory. |
| [setup-project](plugins/spec-workflow/skills/setup-project/SKILL.md) | Initialize a repo's project config, GitHub Project board, and local-state ignores. |
| [sync-project-configs](plugins/spec-workflow/skills/sync-project-configs/SKILL.md) | Dry-run or apply versioned config updates across discovered project repos. |
| [ui-mode](plugins/spec-workflow/skills/ui-mode/SKILL.md) | Inspect or toggle human-directed iterative UI decisions. |
| [ui-options](plugins/spec-workflow/skills/ui-options/SKILL.md) | Present UI alternatives in the local decision hub and capture the user's choice. |
| [whisper-sidecar](plugins/spec-workflow/skills/whisper-sidecar/SKILL.md) | Install, run, stop, or health-check the private local whisper.cpp speech sidecar. |

### remote-compute

Remote-compute separates machine registration, project availability, and actual
allocation:

- **Registration is user-level and machine-local.** The registry lives under
  `~/.remote-compute/`; it records owned machines and verified capabilities.
  SSH is key-only, host keys are pinned, and probes report observed facts rather
  than guessed hardware or software.
- **Project availability is local to each consumer repo.** `enable` and
  `disable` manage `compute:` entries in the gitignored
  `.neural-network/project.local.yaml` overlay. This requires spec-workflow,
  which validates and merges that overlay. Availability is non-exclusive:
  multiple projects can enable a machine. A cooperative machine lock, not the
  project entry, serializes work.
- **Capability bundles are installable data.** A bundle has a
  `capability.yaml` manifest and its payload scripts. Run
  `remote-compute capabilities list` to see shipped bundles, then
  `remote-compute capabilities install <nickname> <bundle-name>` to install
  one. A custom bundle can be installed by passing its local directory instead;
  it can live outside this repository. GitHub repositories are supported via
  `capabilities install <nickname> <github-url> <capability-name>` or `--all`,
  optionally with `--ref <branch-tag-or-commit>`; provenance records the resolved
  commit. Install only trusted bundles. Other clients register the same target
  and run `capabilities sync <nickname>` to import its published job catalog,
  without copying or reinstalling payloads. Environments remain client-configured.
  `remote-compute capabilities installed` shows cached installations
  across all registered machines; add a nickname to filter it. `jobs` inspects
  the jobs registered for one machine. Controller command help is available via
  `python3 plugins/remote-compute/scripts/remote-compute.py --help`; on a target,
  `remote-compute help` lists both modes. Bare `caps`/`capabilities` inventories
  the local target; `capabilities list|install|installed|sync|validate` manages
  registered targets. `local` and `controller` prefixes resolve name collisions.
  `install-cli [--prefix DIR]` installs the combined command on WSL/Linux/macOS;
  `install-tools <nickname>` updates target tools. Native PowerShell is not a target.
- **Jobs are constrained recipes.** Named jobs validate parameters before
  safely quoting them into pre-authored commands. Dispatches run detached with
  recoverable status, logs, and outputs. IDs are immutable; automatic IDs have
  unique suffixes. Target-side admission serializes cooperating clients sharing
  an SSH account; `policy <nickname> --max-concurrent-jobs N` sets that limit.
  `job-cancel` checks process identity and reports pending cancellation honestly.
  Recipes are not an OS sandbox, and the sudo-text check is not a privilege boundary.
  Use `exec` or raw `dispatch` only when
  the human has explicitly specified the command; for an outcome request, use a
  matching declared job.
- **Operations are covered too.** `scan` finds a registered machine after its
  DHCP address changes; `ssh` prints connection commands; `compute-top` shows
  reserved, running, and completed work; setup sheets explain host preparation.
  `doctor [nickname] [--json]` checks connectivity, tool versions, catalog drift,
  environments, and stale jobs without changing configuration. Dispatch does not
  silently rerun hardware probes. New targets have stable UUIDs independent of
  client nicknames; legacy registries, stamps, jobs, and command aliases remain readable.

| Skill | Purpose |
| --- | --- |
| [remote-compute](plugins/remote-compute/skills/remote-compute/SKILL.md) | Register/probe machines, manage project availability, install bundles, and run or inspect work. |
| [compute-top](plugins/remote-compute/skills/compute-top/SKILL.md) | Show remote job state, logs, exit codes, and history in a terminal dashboard. |
| [scan](plugins/remote-compute/skills/scan/SKILL.md) | Re-find a registered machine whose address changed while preserving host identity. |
| [ssh](plugins/remote-compute/skills/ssh/SKILL.md) | List registered machines and ready-to-paste SSH and dashboard commands. |

See the [remote-compute user guide](docs/remote-compute.md) for machine setup,
registration, environments, bundle/job authoring, dispatch, locking, and recovery.
The plugin itself is documented in [plugins/remote-compute/README.md](plugins/remote-compute/README.md).

### peer-review

The [peer-review skill](plugins/peer-review/skills/peer-review/SKILL.md) obtains
an independent code review from a different provider (currently Codex or
Claude), reports the cloud disclosure, and returns severity-ranked findings.
Provider selection and dispatch are data-driven; see
[plugins/peer-review/README.md](plugins/peer-review/README.md) for provider and
script details.

### scaffold-project

The [scaffold-project skill](plugins/scaffold-project/skills/scaffold-project/SKILL.md)
creates a greenfield minikube development workflow: start, stop, dev, build,
port-forward, and bootstrap scripts, with explicit minikube profiles and
`package.json` commands. See the linked skill for its templates and invocation.
