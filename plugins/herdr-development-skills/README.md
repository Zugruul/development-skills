# herdr-development-skills

The integration layer between [Herdr](https://herdr.dev) and the other development skills in this marketplace. It checks which plugins and features are actually enabled and configured in the current environment and repository, and wires those into the [`herdr`](../herdr/README.md) plugin: board tasks and build-loop lanes run in Herdr worktree agents that an orchestrator listens to.

All knowledge of the specialized plugins lives here. The `herdr` plugin knows only Herdr; this plugin **requires it** and builds on its skills (`herdr:worktree`, `herdr:agent`, `herdr:prompt`, `herdr:listen`, `herdr:orchestrate`, `herdr:status`) instead of repeating Herdr commands.

## Install

```bash
claude plugin marketplace add Zugruul/development-skills
claude plugin install herdr-development-skills@development-skills   # installs herdr too
```

Install the specialized plugins you want wired in (`spec-workflow`, `peer-review`) the same way. None is required: an integration whose plugin is missing reports `UNAVAILABLE` with the reason, and the rest keep working.

## Skills

| Skill | Purpose | Needs |
|---|---|---|
| `integrations` | Read-only report of which plugins are enabled, how spec-workflow is configured here, and which integrations are `READY`, `PAUSED` or `UNAVAILABLE` | - |
| `task-lane` | One board task in its own Herdr worktree agent, running `implement-task` (or one whole `build-next` iteration for that task) | spec-workflow, configured |
| `build-loop` | The build loop (`/loop` + `build-next`) in a separate Herdr agent while this one orchestrates | spec-workflow, configured |
| `build-lanes` | Several board tasks in parallel, one `build-next` lane per Herdr worktree agent, within `methodology.maxInProgress` | spec-workflow, configured |
| `review-lane` | A second agent next to a lane running `peer-review` on its diff; findings come back unapplied | peer-review |

Every skill also needs Herdr itself (the binary, and the agent running inside a Herdr pane) and the `herdr` plugin.

## How detection works

`scripts/detect.py [--root DIR] [--json]` is read-only and offline.

- **Plugins.** `enabled` when the host's `enabledPlugins` says so (user, project and local settings, later files winning) or the plugin's skills are linked into a project skills directory (`.claude/skills`, `.agents/skills`, `.opencode/skills`). `available` when the plugin is installed or sits next to this one but enablement could not be confirmed (Codex keeps that state where this script cannot read it). `absent` otherwise.
- **spec-workflow in this repository.** Looks for the project config and reads it through spec-workflow's own loader, so defaults and overlays match what the workflow itself sees: main branch, branch pattern, `maxInProgress`, `serialDelivery`, `autoMerge`, `work.type`, `work.checkout`, the `herdr` object, and the checkpoint flag in the primary checkout.
- **Features.** `READY`, `PAUSED` (the build loop's checkpoint flag is set) or `UNAVAILABLE`, each with its reasons.

It reads files and cannot see a session, so the skills treat it as a hint and confirm the needed skills are listed before offering a feature.

## How a lane runs

1. The orchestrator reads the task and works out the lane: branch from `project.branchPattern`, base a freshly fetched main, path `<primary checkout>/.claude/worktrees/<task-id>` (where spec-workflow keeps task lanes).
2. `herdr:worktree` plans it, asks the user, and creates it with explicit `--cwd`, `--branch`, `--base` and `--path`.
3. `herdr:agent` starts the lane agent and sends one prompt: run the spec-workflow skill on the assigned task, in this checkout, which already is the lane.
4. `herdr:listen` follows it. Anything the workflow requires a human for (checkout mode, consent before an autonomous merge, UI decisions) blocks the lane; the orchestrator shows the question to the user and relays the answer. It never answers for them.

With `build-lanes` the orchestrator is the only picker: it assigns one task per lane from the queue, so two lanes cannot start the same task. spec-workflow's own board admission and merge lock still apply inside each lane.

spec-workflow can also open the lanes it creates itself in Herdr (`herdr.enabled` in the project config). That setting is independent of this plugin and is what makes `build-loop`'s lanes visible as workspaces.

## Proposed integrations (not implemented)

| Idea | Why it would help |
|---|---|
| Lane cleanup after merge | Close the Herdr workspace of a lane whose task reached QA or Ready, using spec-workflow's own lane removal |
| Task-state in the roster | Join spec-workflow's local task record (TODOs done and total per task) into the orchestrator's lane roster |
| Remote-compute lanes | Start lane agents on a saved Herdr SSH machine that is also a registered compute target |
| Handoff per lane | Have each lane write a spec-workflow handoff when the orchestrator stops, and collect the paths |

## Tests

```bash
bash plugins/herdr-development-skills/tests/run-tests.sh
```

Hermetic: a private `HOME` and throwaway repositories, no Herdr and no network. The suite reads `plugins/herdr` and `plugins/spec-workflow` (their skills, config loader and fixtures), mirroring the dependency direction. The checks on a configured repository need PyYAML, as spec-workflow's loader does, and are skipped with a note without it.
