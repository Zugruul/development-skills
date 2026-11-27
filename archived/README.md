# development-skills: archived plugins

These plugins are **archived**. They stay here so people who rely on them can still install them, from a marketplace of their own, `development-skills-archived`, rooted in this folder. The maintained plugins are in the [root marketplace](../README.md).

What archived means:

- No new features, and no promise of fixes.
- CI only validates their manifests and marketplace files. **Their test suites are not run**, so a change elsewhere can break one without anyone noticing.
- The release tooling still runs for spec-workflow: a version bump on `main` updates its manifest, and the root [`CHANGELOG.md`](../CHANGELOG.md) takes its version headings from it.

| Plugin | What it is |
| --- | --- |
| [`spec-workflow`](plugins/spec-workflow/README.md) | Spec-driven build loop with a GitHub Project board |
| [`remote-compute`](plugins/remote-compute/README.md) | Remote machines over SSH as compute (needs `spec-workflow` for project enablement) |
| [`peer-review`](plugins/peer-review/README.md) | Review of a diff by another vendor's CLI |
| [`scaffold-project`](plugins/scaffold-project/skills/scaffold-project/SKILL.md) | Greenfield minikube workflow scaffold |
| [`herdr-development-skills`](plugins/herdr-development-skills/README.md) | Bridge between Herdr and spec-workflow (needs `herdr` and `herdr-simple-orchestrate` from the root marketplace) |

## Install

Add this folder, not the repository root, as a marketplace. Install from a clone: `plugin marketplace add Zugruul/development-skills` does not reach this folder, because it reads the marketplace at the repository root.

```bash
git clone https://github.com/Zugruul/development-skills.git
```

Claude Code:

```bash
claude plugin marketplace add ./development-skills/archived
claude plugin install spec-workflow@development-skills-archived
```

Codex:

```bash
codex plugin marketplace add ./development-skills/archived
codex plugin add spec-workflow@development-skills-archived
```

For another plugin, substitute its name. Keep the clone: the marketplace points at it. To update, run `git pull` in the clone, then update the plugin in your host. For remote-compute, which also has a standalone controller and target machines, follow the [installed-update guide](docs/remote-compute-updates.md).

`herdr-development-skills` depends on `herdr` and `herdr-simple-orchestrate` from the root marketplace. Add **both** marketplaces; Claude Code then installs the two dependencies with it. Without the root marketplace it installs but fails to load:

```bash
claude plugin marketplace add Zugruul/development-skills
claude plugin marketplace add ./development-skills/archived
claude plugin install herdr-development-skills@development-skills-archived
```

In Codex, add both marketplaces and install the two dependencies yourself with `codex plugin add <name>@development-skills`.

To link the skills into a project's skill directories instead of using a marketplace, run [`install-skills.sh`](install-skills.sh) from this folder: `./development-skills/archived/install-skills.sh claude` (or `opencode`, `codex`, `all`). The root script links only the maintained plugins.

## Moving an existing install

These five plugins used to be listed in the root `development-skills` marketplace. Nothing is uninstalled or switched for you. **Once your copy of that marketplace updates, Claude Code keeps an installed one listed but it fails to load** (`Plugin <name> not found in marketplace development-skills`), so it stops working until you switch. This was seen with a local-folder marketplace; a GitHub-sourced one and what Codex does with an old install were not tested. To switch, in Claude Code:

```bash
claude plugin uninstall spec-workflow@development-skills
claude plugin marketplace add /path/to/development-skills/archived
claude plugin install spec-workflow@development-skills-archived
```

In Codex, use `codex plugin remove spec-workflow@development-skills`, then the two Codex commands above.

Also replace `<plugin>@development-skills` with `<plugin>@development-skills-archived` in the `enabledPlugins` map of every `.claude/settings.json` that names one of the five. A repository's `.neural-network/` files and the state under `~/.remote-compute/` are not tied to the marketplace name.

Two addresses changed with the move:

- The config schema is now at `https://raw.githubusercontent.com/Zugruul/development-skills/main/archived/plugins/spec-workflow/schemas/project-config.schema.json`. Update the `# yaml-language-server` line of an existing `project.yaml` to keep editor completion.
- A `herdr plugin link` or script path into `plugins/<name>` of a clone is now `archived/plugins/<name>`.

## Tooling

### Neural View

![](docs/neural-view.png)

Visualization of "brains" that help guide development and knowledge base over each project. With help of RAG in addition to semantic search we are able to probe it for information.

### Live activations — watch the memories fire

![Recall activations lighting up in real time](docs/activations.png)

When an agent recalls a lesson, you see it happen. Every `brain.sh recall` an
orchestrator runs — while briefing a dev agent, reviewing a diff, or answering
a question — emits activation events, and the neural view renders them the
moment they occur:

- **Expanding rings** pulse around the exact notes being accessed, right where
  they sit in their repo's cluster — in the screenshot, a live
  `development-skills` session is seeding three orchestrator memories and the
  ripples radiate out from each one.
- **The activation log** (bottom right) narrates the same events as text:
  timestamp, repo, role, event kind, and the note's slug — so a glowing neuron
  is never anonymous.
- **Spreading activation is visible too**: after the seeded notes light up,
  energy flows along their synapses to related notes (the `hop` events), which
  is literally the recall ranking algorithm drawing itself.
- **Live session markers** (`· 1 LIVE` next to a repo name) show which brains
  currently have an agent thinking against them.

Nothing is replayed or simulated — the page tails each brain's
`.activation.jsonl` feed, so what you're watching is the actual memory traffic
of agents working, as it happens. Leave it on a second monitor and you can
tell at a glance *what the loop is thinking about* without reading a single
transcript.

### Remote compute

Use another computer as compute. Register a machine once, then send work to it
from wherever you are working — typically driving a GPU box from a laptop.

- **Key-based SSH only.** Never a password prompt, never a stored secret.
- **Jobs run detached** and survive your session ending; state lives in files on
  the machine, so status and logs are recoverable afterwards.
- **Tools plug in as data.** Supporting a new tool (image generation, model
  training) means adding a small bundle folder, never changing the software.
- **Validated recipes.** Values are validated and quoted once; workflows are
  pre-authored. Bundles execute trusted code with the SSH account's permissions,
  not inside a sandbox. Privileged setup steps are printed for the human.

A machine is registered once, told which environments and tools it has, and then
given named job recipes you run with different parameters. A terminal dashboard
on the machine shows what is queued, running, and finished.

The controller CLI help is `python3 archived/plugins/remote-compute/scripts/remote-compute.py --help`.
It lists machine, job, and capability commands, including `capabilities list`,
`capabilities install <nickname> <bundle-name-or-directory>`, and
`capabilities installed [<nickname>]`. On a registered compute machine,
`remote-compute help` lists local and controller commands. Bare `caps` (also
`capabilities`) shows bundles on this machine. Install the combined CLI on
WSL/Linux/macOS with `python3 archived/plugins/remote-compute/scripts/remote-compute.py install-cli`.
Existing local commands and legacy controller aliases remain supported.

Capabilities can come directly from GitHub, without changing this marketplace:

```bash
remote-compute capabilities install storm590x https://github.com/OWNER/REPO CAPABILITY --ref main
remote-compute capabilities install storm590x https://github.com/OWNER/REPO --all
remote-compute capabilities sync storm590x  # on another registered client, e.g. a MacBook
remote-compute doctor storm590x
```

The repository must contain `capability.yaml` bundles, not just arbitrary
workflow files. Install only trusted code; installs record the resolved commit.
Target-side admission coordinates clients sharing one SSH account, while stable
UUIDs keep machine identity independent of each client's nickname.

**→ Full guide: [docs/remote-compute.md](docs/remote-compute.md)** — setup,
registering a machine, declaring jobs, running and watching work, sharing a
machine between projects, and adding support for a new tool.

## Compatibility audit

The [incremental compatibility matrix](docs/compatibility-matrix.md) audits the
four shipped remote-compute skills for Claude Code and Codex. It separates
source review and local tests from unverified live execution, names known
gaps, and documents WSL/Linux/macOS execution with a WSL bridge for Windows
Codex hosts. Native PowerShell is unsupported; this is not a marketplace-wide
parity claim or completion of CDX-042.

## Assistant observability (in progress)

The in-repo assistant (`SPEC-ASSISTANT.md`) records every turn as an event in a
per-repo, gitignored `.claude/assistant/traces.sqlite` (append-only, WAL mode).
Retention is pruned automatically by a single background writer thread, oldest
events first, configured per repo via `assistant.observability.traces.sqlite`
in `project.yaml`:

```yaml
assistant:
  observability:
    traces:
      sqlite:
        retainDays: 30   # delete events older than N days; 0 = unlimited
        maxMB: 500        # trim oldest events until the file is under N MB; 0 = unlimited
```

Both knobs default to `30`/`500` when omitted. Retention only ever touches
`traces.sqlite` — it never deletes the embeddings index, `session.jsonl`, or
any other local-state file. Full observability epic tracked in
[`docs/design/ast-E4.md`](../docs/design/ast-E4.md).

Memory access is fully observable too — see
[Live activations](#live-activations--watch-the-memories-fire) under Tooling
for the real-time view of recalls lighting up the network.

## Testing

CI does not run these suites. Run the one you need from the repository root, and read [`AGENTS.md`](AGENTS.md) first: the spec-workflow suite has a known hazard.

```bash
bash archived/plugins/spec-workflow/tests/run-tests.sh
bash archived/plugins/remote-compute/tests/run-tests.sh
bash archived/plugins/peer-review/tests/run-tests.sh
bash archived/plugins/herdr-development-skills/tests/run-tests.sh
claude plugin eval archived/plugins/spec-workflow         # skill evals (early access; needs API credits)
```

### spec-workflow task preflight

Task-start preflight validates the resolved project config and checks the managed
ignore block against the current manifest. A missing/stale block or inspection
failure prints `PREFLIGHT FAIL` with a repair command; skill callers stop on that
line even though the loader exits zero. Repair explicitly with
`bash archived/plugins/spec-workflow/scripts/gitignore-sync.sh /path/to/repo/.gitignore`
(or the corresponding installed plugin script), then rerun preflight. Dry-run
uses the same comparison and cleans its own temporary files, even when TMPDIR
points inside the repo. See the [runtime path audit](../docs/audits/runtime-paths-274.md)
for all-plugin coverage and caller-selected path exclusions.

Before switching branches or pulling, build-next also inspects the actual checkout
with `bash archived/plugins/spec-workflow/scripts/checkout-preflight.sh [--root DIR]`.
The read-only command reports JSON `clean`/`dirty`/`uninspectable` (exit 0/1/2),
including staged, unstaged, untracked, conflicting and submodule changes even when
Git status preferences hide them. Ignored files stay ignored. Pass
`--checkout worktree` only for an already authorized worktree session: dirty work
then routes to a separate clean lane based on fetched remote main (local main
when no remote exists). An explicit main-only session pauses for a decision.
Existing edits, HEAD, index and stashes are preserved; nothing is auto-stashed or
committed. The advisory loader remains zero-exit and surfaces the routing decision.
This is a point-in-time check, not a lock against concurrent writers; a clean
linked worktree is checked independently of a dirty primary checkout. See the
[startup protocol](plugins/spec-workflow/skills/build-next/SKILL.md#dirty-checkout-isolation-285).

## Plugins

### spec-workflow

The assistant's `remote-compute-control` skill provides restricted SSH access to
approved WSL targets, separate from the human remote-compute controller. Install
only its data with `python3 -I /absolute/plugin/scripts/assistant/remote_control.py
install --assistant-root /absolute/assistant-repo`, then provision dedicated keys
and explicitly enable it. Its installed manifest owns the host allowlist. Follow
the [setup, security and testing guide](docs/assistant-remote-control.md); local
checks do not prove live enforcement. Managed commands require committed audit intent,
sanitize persisted data, and retain task recovery IDs independently of trace retention.
The separate `comfyui-render` skill queues pinned API workflows through a dedicated
SSH tunnel, samples native WebSocket progress, and publishes images through the
existing artifact endpoint. See the [render deployment and recovery guide](docs/assistant-comfyui-render.md).

Spec-driven autonomous build workflow. A repo declares its boards, specs, epics, guards, gate command, delegation roster, and conventions in a **versioned YAML config** (`.neural-network/project.yaml`, schemaVersion 2 — schema in `plugins/spec-workflow/schemas/`, wired for editor hover/autocomplete via a `# yaml-language-server` modeline; needs PyYAML); the plugin's skills and scripts read that config through one shared loader, so the same workflow drives any project. A legacy `.neural-network/project.json` (schemaVersion 1) is still read and auto-converted (deprecated).

| Skill | Purpose |
|---|---|
| `craft-spec` | Assisted spec creation: interview → draft → review → backlog |
| `setup-project` | Bootstrap a repo: config, GitHub Project board, validation |
| `setup-assistant` | Scaffold a bare-brain assistant repo (marker, project.yaml assistant section, brain dirs, persona AGENTS.md, gitignores) and edit its settings |
| `remote-compute-control` | Install data-only assistant access to approved WSL targets: audited inventory, status, redacted bounded logs and cancellation through dedicated forced-command SSH keys |
| `comfyui-render` | Queue pinned ComfyUI image workflows over a dedicated SSH tunnel, recover owned requests, and publish audited artifacts |
| `seed-board` | Create issues + board items from a spec's backlog (idempotent) |
| `board` | All board reads/writes (single script, no hardcoded ids) |
| `next-task` | Prioritized + sequenced + guarded pick; reads human comments |
| `queue` | Read-only view of the upcoming build-next picks, priority-first, with blocked reasons |
| `find-task` | Ranked search of existing board issues by title/body similarity (dedup) |
| `create-inbound` | Search-first, dedup-gated capture of ad-hoc ideas/bugs/requests onto the board |
| `implement-task` | One task via TDD, delegated to a dev subagent with a what/how/why brief |
| `refine-task-ui` | Run a task's UI through the `ui-design` plugin, then fold screenshots and acceptance criteria into the issue |
| `gate` | The project's single green-before-advance quality command |
| `build-next` | One full loop iteration — drive with `/loop /spec-workflow:build-next` |
| `brain` | Per-identity zettel memory: private brains, spreading-activation recall, retro mint/prune/graduate |
| `auto-merge` | Toggle autonomous PR review + merge (reviewer agent approves instead of a human) |
| `pr-review-model` | Show/set the model the autonomous PR reviewer runs on |
| `agent-identities` | Per-role commit attribution — each person's clone signs agent commits with their own plus-addressed email |
| `concurrency` | Show/set `methodology.maxInProgress` — sequential (default) vs N parallel implementation lanes |
| `checkpoint` | Pause/resume the loop via a local flag file |
| `handoff` | Session/pause handoff document |
| `dev-up` | Bring up the project's dev stack for QA |
| `neural-view` | Live JARVIS-style visualization of the identity brains — notes as neurons, recalls lighting up in real time |
| `feedback` | Structured per-iteration process feedback about the workflow itself (`methodology.feedback`); triaged into backlog/brain-note/graduate/upstream/ignore at retro time |
| `task-state` | Local record of tasks in progress and their TODOs, shared across agents and worktrees and shown in the herdr tasks panel |
| `neural-network-projects-list` | Read-only inventory of anchored local repos, config toggles, configured boards and validation errors |
| `sync-project-configs` | Discover every anchored repo and bring its `.neural-network/project.yaml` up to the plugin's current config surface via versioned sync rules; dry-run by default |
| `changelog-generate` | Fully regenerates `CHANGELOG.md` from git history, versioned by `plugin.json`'s semver windows and grouped by conventional-commit type; idempotent, kept fresh on every push to `main` by a GitHub Action |

Humans steer the loop by commenting on task issues: `next-task`/`implement-task` read every comment before starting, fold accepted changes into the issue's acceptance criteria, and reply on the issue.

### remote-compute

Register remote machines (SSH, key-only) as user-level compute resources and
dispatch jobs/capability bundles to them. **Requires the spec-workflow
plugin** for project setup and the gitignored project.local.yaml overlay.
`run --role ROLE JOB [--root DIR]` and
`dispatch --role ROLE --workdir W --cmd C [--root DIR]` select enabled,
registered aliases in lexical order with an exact role match. The standalone
controller reads only compute, with local compute replacing the whole base value.
Nickname commands remain unrestricted by project availability and read no project.
Fallback is limited to pre-reservation busy/connectivity failures or explicit
target admission refusals; uncertain reservation or launch stops for inspection.
Full guide:
[docs/remote-compute.md](docs/remote-compute.md).

The ComfyUI bundle also offers explicit, non-executing UI-save import:
`remote-compute run gpubox comfyui:import-workflow --job-id comfy-import-example --param workflow=/path/UI.json --param port=8188`.
It writes a new API artifact for later rendering. Only the documented
`core-txt2img-v1` workflow-v0.4 seven-core-class profile is supported, with fixed
seed control and exact graph/schema agreement; custom nodes, dynamic prompts,
filename substitutions and ambiguous graphs are refused. It does not support
all saved workflows or frontend versions. See the
[exact boundary, offline invocation and native-export fallback](docs/remote-compute.md#explicit-comfyui-ui-save-import).
Behavioral schema options are validated per input; transformed prompt escape
forms and reserved node IDs `nodes`/`links` are refused. Once published, an
artifact remains a success even if temporary-file cleanup emits a warning.

| Skill | Purpose |
|---|---|
| `remote-compute` | Register/probe machines, manage project availability, install bundles, and run or inspect work by explicit nickname or project role. |
| `compute-top` | Terminal dashboard, on the machine or over SSH, for what remote-compute work is running/finished there; opens logs, prunes history |

### peer-review

Get a source-labeled second opinion from OpenAI Codex or Anthropic Claude through
trusted local provider scripts. Review material can include repository context
beyond the diff; the user's CLI configuration owns authentication and transport.
Review flags constrain intended edits, not network isolation. There is no peer HTTP
dispatcher or endpoint allowlist; SSH-machine registration grants no peer HTTP
authority. See [peer-review](plugins/peer-review/README.md) for the disclosure and
provider configuration boundary.

| Skill | Purpose |
|---|---|
| `peer-review` | Pick a trusted provider, disclose external transmission, and report source-labeled findings without applying them. |

### scaffold-project

Scaffolds a new greenfield project's minikube dev-workflow scripts
(start/stop/dev/build/port-forward/bootstrap) into a `scripts/` folder, with
`package.json` wired to run them.

| Skill | Purpose |
|---|---|
| `scaffold-project` | Generate a project's minikube dev-workflow scripts from templates, every profile bound explicitly (`MK_PROFILE`, never minikube's shared default) so scaffolded projects never collide with each other |

```bash
claude plugin install scaffold-project@development-skills-archived
```

### herdr-development-skills

The integration layer between Herdr and the plugins above. It checks which
plugins and features are enabled and configured in the current repository, then
runs board tasks and build-loop lanes in Herdr worktree agents an orchestrator
listens to. **Requires the herdr and herdr-simple-orchestrate plugins**; an integration whose specialized
plugin is missing reports why and the rest keep working. Asked for work that
has no task identifier, the lane skills ask once whether to run it without a
task, create one through spec-workflow's intake, or use an existing one. See
[herdr-development-skills](plugins/herdr-development-skills/README.md).

| Skill | Purpose |
|---|---|
| `integrations` | Read-only report of which integrations are ready, paused or unavailable here, and why |
| `task-lane` | One piece of work in its own Herdr worktree agent: a spec-workflow board task (`implement-task`), or work described in plain words with no task |
| `build-loop` | `/loop /spec-workflow:build-next` in a separate Herdr agent while this one orchestrates |
| `build-lanes` | Several `build-next` lanes in parallel Herdr worktree agents, within `methodology.maxInProgress` |
| `review-lane` | A `peer-review` agent next to an existing lane; findings come back unapplied |

```bash
claude plugin install herdr-development-skills@development-skills-archived
```


Autonomous spec-workflow approval now uses durable three-round admission before
each reviewer invocation, shared across linked worktrees. The read-only approval
check applies to both PR and local delivery; tagged two-pass reviews remain
separate. See [commands, compatibility and recovery](plugins/spec-workflow/README.md#bounded-autonomous-reviewer-rounds).
