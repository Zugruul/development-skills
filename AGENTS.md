# AGENTS.md

This repo is [Zugruul/development-skills](https://github.com/Zugruul/development-skills), a Claude Code and Codex plugin marketplace. Each plugin lives in `plugins/<name>/`. This file is the canonical instruction file for both hosts; `CLAUDE.md` only points here.

## Active plugins

| Plugin | What it is | Needs |
| --- | --- | --- |
| [`herdr`](plugins/herdr/README.md) | Teaches an agent to use [Herdr](https://herdr.dev): worktrees, agents, prompts, listening, status. Only Herdr, no workflow of its own, no knowledge of other plugins. | `herdr`, `bash`, `jq`, `git` |
| [`herdr-graph-engineering`](plugins/herdr-graph-engineering/README.md) | Graph engineering on `herdr`: one orchestrator chat, each idea a lane running a small graph from a pattern until its definition of done. | `herdr` plugin, `jq`, `yq`, `git` |
| [`remote-compute`](plugins/remote-compute/README.md) | Registers remote machines over SSH and dispatches jobs to them (details below). | still needs `spec-workflow` for project enablement and role dispatch |

## Deprecated plugins

Kept so existing setups keep working. They are not developed further. Change them only to keep them working (for example when something they reference moves), never to add behaviour.

| Plugin | Note |
| --- | --- |
| [`spec-workflow`](plugins/spec-workflow/README.md) | Its own rules (the build loop, the board, the gate, schema versioning) are in [`plugins/spec-workflow/AGENTS.md`](plugins/spec-workflow/AGENTS.md). |
| [`herdr-simple-orchestrate`](plugins/herdr-simple-orchestrate/README.md) | The old orchestrator role and multi-PR code review, moved out of `herdr`. |
| [`herdr-development-skills`](plugins/herdr-development-skills/README.md) | The bridge between Herdr and spec-workflow. |
| [`peer-review`](plugins/peer-review/README.md) | Independent review through another vendor's CLI. |
| [`scaffold-project`](plugins/scaffold-project/README.md) | Greenfield minikube workflow scaffold. |

## Rules for every plugin

- **One plugin, one job.** A plugin carries the scripts it needs and nothing else. It never reaches into another plugin's folder: installed plugins live in versioned folders, so a path into another plugin breaks. It uses another plugin through that plugin's skills, by name (`herdr:worktree`), and declares the dependency in `.claude-plugin/plugin.json` (`"dependencies"`).
- **No Python in active plugins.** Scripts are `bash` (3.2 or later, so the macOS default works; WSL on Windows) with `jq` for JSON. Shared helpers sit in a flat `scripts/src/` folder, one level deep.
- **Only scripts that are really needed.** When the tool's own CLI does a step in one call, the skill calls the CLI directly. A script exists for a wait, a retry or a safety check the CLI cannot do.
- **Tests are hermetic.** Each plugin has `tests/run-tests.sh`, sourcing `section-*.sh` files, with stubs for external binaries. No live session, no network.
- **Two manifests, same version.** `.claude-plugin/plugin.json` and `.codex-plugin/plugin.json`, with the same version, and an entry in both `.claude-plugin/marketplace.json` and `.agents/plugins/marketplace.json`. Bump the version when behaviour changes.
- **Skill descriptions** have no angle brackets (Codex rejects them) and name the triggers a user would type.
- No AI attribution or `Co-Authored-By` lines in commits, pull requests or files.

## Validating a change

Run the checks of every plugin you touched, green, before calling the work done. For the active plugins:

```bash
bash plugins/herdr/tests/run-tests.sh
bash plugins/remote-compute/tests/run-tests.sh
bash plugins/herdr-graph-engineering/tests/run-tests.sh
shellcheck -x plugins/herdr/scripts/*.sh plugins/herdr/scripts/src/*.sh plugins/herdr/tests/*.sh plugins/herdr/tests/fixtures/stub-herdr/herdr
shellcheck -x plugins/herdr-graph-engineering/scripts/*.sh plugins/herdr-graph-engineering/scripts/src/*.sh plugins/herdr-graph-engineering/tests/*.sh plugins/herdr-graph-engineering/tests/fixtures/stub-herdr/herdr
claude plugin validate plugins/herdr && claude plugin validate plugins/herdr-graph-engineering && claude plugin validate plugins/remote-compute
```

A change to a deprecated plugin also runs that plugin's own `tests/run-tests.sh` and `claude plugin validate`; `spec-workflow`'s full gate is in its `AGENTS.md`.

## Adding a plugin

1. `plugins/<name>/` with `.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`, `README.md`, `skills/<skill>/SKILL.md`, `tests/run-tests.sh`, and `scripts/` only if needed.
2. Register it in both marketplace files.
3. Add it to the tables in this file and in the root `README.md`.

## Plugin notes

### remote-compute

Assistant restricted SSH is a separate spec-workflow capability: see the
[provisioning and security guide](docs/assistant-remote-control.md). Its installed
manifest owns `provisioning.hosts`; registration never grants access, and generic
project provisioning overrides only affect check/TTL. The installer binds absolute
engine argv without copying code or enabling the skill. `inspect` and `cancel`
keys have distinct fixed target commands. Managed operations require committed audit
intent before transport; sanitized task descriptors and recovery IDs survive trace
retention. The separate `comfyui-render` task executor uses that audit boundary for
native submit/status/cancel/transfer over its dedicated tunnel grant. See the
[render guide](docs/assistant-comfyui-render.md) for workflow pins, endpoint trust
and conservative cancellation. The human controller below is unchanged.

The [incremental compatibility matrix](docs/compatibility-matrix.md) records
the CDX-050 audit of the four shipped skills below, their Claude/Codex semantics,
source-backed limitations and separately filed gaps. WSL/Linux/macOS are the
execution targets; Windows Codex needs a WSL bridge, and native PowerShell is
unsupported. Local tests and metadata validation do not prove live host/SSH
parity. The rest of the marketplace is outside this audit; CDX-042 remains open.

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
- **Role dispatch is opt-in.** `run --role ROLE JOB [--root DIR]` and
  `dispatch --role ROLE --workdir W --cmd C [--root DIR]` consume only project
  compute, with local compute replacing the whole base value. Root defaults to
  cwd. Enabled, registered aliases with an exact role match are tried lexically;
  candidate job/parameter/environment incompatibility is explained and skipped.
  Failed environment verification excludes a candidate; legacy missing stamps
  remain supported. Nickname commands read no project and need no enablement.
  Fallback is only before reservation for busy/locked/unreachable targets or on
  explicit unambiguous target admission refusal. Any possibly accepted reservation,
  staging failure or launch failure stops with target/job recovery instructions.
  No eligible candidates exits 2, all busy exits 6, exhaustion including unreachable
  exits 1. No new scheduler, hardware probe or automatic catalog sync is involved.
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
| [remote-compute](plugins/remote-compute/skills/remote-compute/SKILL.md) | Register/probe machines, manage project availability, install bundles, and run or inspect work by explicit nickname or project role. |
| [compute-top](plugins/remote-compute/skills/compute-top/SKILL.md) | Show remote job state, logs, exit codes, and history in a terminal dashboard. |
| [scan](plugins/remote-compute/skills/scan/SKILL.md) | Re-find a registered machine whose address changed while preserving host identity. |
| [ssh](plugins/remote-compute/skills/ssh/SKILL.md) | List registered machines and ready-to-paste SSH and dashboard commands. |

ComfyUI authoring-time import is the separate, non-executing
`comfyui:import-workflow` job, invoked with
`remote-compute run gpubox comfyui:import-workflow --job-id comfy-import-example --param workflow=/path/UI.json --param port=8188`.
It creates a new API JSON file only for the documented `core-txt2img-v1`
workflow-v0.4 seven-core-class profile. Fixed seed control, exact graph/schema
agreement and literal values are required; custom/virtual nodes, dynamic prompts,
filename substitution tokens and ambiguous graphs are refused with
`Workflow -> Export (API)` guidance. This is not universal frontend compatibility
and changes no assistant control plane, API rendering or value-only overrides.
The [exact support boundary and offline CLI](docs/remote-compute.md#explicit-comfyui-ui-save-import)
are the operational reference for the bundled helper.
Validation also checks behavioral schema options per input, refuses transformed
prompt escape forms and reserves node IDs `nodes`/`links` for API-runner
compatibility. Exclusive publication commits success: a later temporary-file
cleanup failure reports `ARTIFACT` plus a warning, without removing the artifact.
Failures before publication retain their original error and preserve existing outputs.

See the [remote-compute user guide](docs/remote-compute.md) for machine setup,
registration, environments, bundle/job authoring, dispatch, locking, and recovery.
The plugin itself is documented in [plugins/remote-compute/README.md](plugins/remote-compute/README.md).
For an existing installation, follow the [installed-update guide](docs/remote-compute-updates.md):
verify source/cache/host separately from controller, target tools and catalog
readiness, and back up reviewed custom bundles before any replacement.

### peer-review (deprecated)

The [peer-review skill](plugins/peer-review/skills/peer-review/SKILL.md) obtains
an independent code review from OpenAI Codex or Anthropic Claude through trusted
local provider scripts and returns source-labeled findings without applying them.
The disclosure covers repository context beyond the diff; the user's CLI
configuration owns authentication and transport. Review flags constrain intended
edits, not network isolation. There is no peer HTTP dispatcher or endpoint
allowlist; SSH-machine registration grants no peer HTTP authority. See
[plugins/peer-review/README.md](plugins/peer-review/README.md) for provider and
script details.

### scaffold-project (deprecated)

The [scaffold-project skill](plugins/scaffold-project/skills/scaffold-project/SKILL.md)
creates a greenfield minikube development workflow: start, stop, dev, build,
port-forward, and bootstrap scripts, with explicit minikube profiles and
`package.json` commands. See the linked skill for its templates and invocation.
