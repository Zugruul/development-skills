# AGENTS.md: archived plugins

Rules for `archived/`. The repository-wide rules are in the root [`AGENTS.md`](../AGENTS.md); `CLAUDE.md` here only points to this file.

## What archived means

- This folder is its own marketplace, `development-skills-archived`: [`.claude-plugin/marketplace.json`](.claude-plugin/marketplace.json) and [`.agents/plugins/marketplace.json`](.agents/plugins/marketplace.json). Their sources resolve from this folder. Never list one of these plugins in a root marketplace file.
- The plugins are not developed further. Change one only to keep it working (for example when something it references moves), never to add behaviour. When behaviour changes, bump its version in both manifests and in the archive's marketplace entry.
- CI only validates manifests and marketplace files (`claude plugin validate`, [`check-marketplaces.sh`](../.github/scripts/check-marketplaces.sh)). It runs none of their suites. When you change a plugin, run its suite yourself; `.github/workflows/ci.yml` says how to restore them in CI.
- A maintained plugin never depends on an archived one. An archived one may depend on a maintained one, declared as `<name>@development-skills`, with `development-skills` listed in the archive's `allowCrossMarketplaceDependenciesOn`.
- The release workflows still call spec-workflow's scripts: `semver.sh` (version bump on `main`) and `changelog.py` (root `CHANGELOG.md`). Keep both working; `changelog.py` reads spec-workflow's manifest at its old and its new path.

## Layout and history

`plugins/`, `docs/` (user guides of these plugins) and `install-skills.sh` (a link to the root script) mirror the repository root. Specs (`SPEC*.md`), backlogs, design notes, spec deltas, audits and handoffs stayed in the root [`docs/`](../docs/) and the repository root. They predate the move: read a `plugins/<archived name>/` path in them as `archived/plugins/<archived name>/`.

## Test hazard: the spec-workflow suite

Run it only in a throwaway clone whose `origin` is not a real remote. The suite keeps its temp folders under one root that it removes on exit, and one test runs the suite again. If the outer run is ended (a `timeout`, a kill, Ctrl-C) while the nested one is still running, `mktemp -d` fails, a helper turns the empty path into the current directory, and fixture git commands run in the real checkout and can push to its `origin`. This happened. Never wrap the suite in `timeout` and never interrupt it. After a run, check `git status`, `git branch` and `git config --get-regexp 'user|core.bare|remote'`.

## Plugins

| Plugin | Note |
| --- | --- |
| [`spec-workflow`](plugins/spec-workflow/README.md) | Its own rules (the build loop, the board, the gate, schema versioning) are in [`plugins/spec-workflow/AGENTS.md`](plugins/spec-workflow/AGENTS.md). |
| [`remote-compute`](plugins/remote-compute/README.md) | Still needs `spec-workflow` for project enablement and role dispatch (notes below). |
| [`peer-review`](plugins/peer-review/README.md) | Independent review through another vendor's CLI. |
| [`scaffold-project`](plugins/scaffold-project/skills/scaffold-project/SKILL.md) | Greenfield minikube workflow scaffold. |
| [`herdr-development-skills`](plugins/herdr-development-skills/README.md) | The bridge between Herdr and spec-workflow. |

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
  `python3 archived/plugins/remote-compute/scripts/remote-compute.py --help`; on a target,
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

### peer-review

The [peer-review skill](plugins/peer-review/skills/peer-review/SKILL.md) obtains
an independent code review from OpenAI Codex or Anthropic Claude through trusted
local provider scripts and returns source-labeled findings without applying them.
The disclosure covers repository context beyond the diff; the user's CLI
configuration owns authentication and transport. Review flags constrain intended
edits, not network isolation. There is no peer HTTP dispatcher or endpoint
allowlist; SSH-machine registration grants no peer HTTP authority. See
[plugins/peer-review/README.md](plugins/peer-review/README.md) for provider and
script details.

### scaffold-project

The [scaffold-project skill](plugins/scaffold-project/skills/scaffold-project/SKILL.md)
creates a greenfield minikube development workflow: start, stop, dev, build,
port-forward, and bootstrap scripts, with explicit minikube profiles and
`package.json` commands. See the linked skill for its templates and invocation.
