---
name: integrations
description: Checks which development-skills plugins and features are actually enabled and configured in the current environment and repository, and reports which Herdr integrations can run - a board task or build-loop lanes in Herdr worktree agents, a build loop in a Herdr agent, a peer review next to a lane. Read-only. Use for '/herdr-development-skills:integrations', 'what can herdr run here', 'is the build loop wired into herdr', or before any other skill of this plugin.
allowed-tools: Bash
---

# Which Herdr integrations can run here

```bash
python3 "../../scripts/detect.py" [--root <checkout>] [--json]
```

Resolve the path relative to this `SKILL.md`. The script is read-only and offline. Relay its output, then explain it in plain words.

## Reading the result

- **herdr** must be `ok`: the agent runs inside a Herdr pane and the binary is on `PATH`. Otherwise nothing here can run; say so and stop.
- **PLUGINS**: `enabled` means the host's settings (or a linked skills directory) say so. `available` means the plugin is installed but the script could not confirm it is enabled for this host. `absent` means it is not there.
- **SPEC-WORKFLOW IN THIS REPOSITORY**: whether the repository has a project config, and the settings the integrations depend on (lane count, delivery mode, pause flag, whether spec-workflow itself opens its lanes in Herdr).
- **FEATURES**: one line per integration skill.

| State | Meaning | Do |
| --- | --- | --- |
| `READY` | Everything it needs is present. | Offer the skill. Read its notes to the user. |
| `LIMITED` | The skill can run, but only for work without a task. | Offer it for described work; say why board tasks are out. |
| `PAUSED` | The build loop is paused by its checkpoint flag. | Start no build work. Say what is paused and that the spec-workflow `checkpoint` skill resumes it. |
| `UNAVAILABLE` | Something is missing. | Give the listed reasons and the one step that fixes each. Do not work around it. |

The script reads files; it cannot see your session. Before offering a `READY` feature, confirm the skills it relies on are really listed in your session (for example `spec-workflow:build-next`, `herdr:worktree`). If they are not, treat the feature as unavailable and say which plugin to enable.

## The integrations

| Feature | Skill | Needs |
| --- | --- | --- |
| `task-lane` | `task-lane` - one piece of work in a Herdr worktree agent | herdr; for a board task also spec-workflow and a configured repository |
| `build-loop` | `build-loop` - the build loop in one Herdr agent | herdr, spec-workflow, a configured repository |
| `build-lanes` | `build-lanes` - several pieces of work in parallel Herdr worktree agents | as `task-lane`; lane count for board tasks from `methodology.maxInProgress` |
| `review-lane` | `review-lane` - an independent review next to a lane | herdr, peer-review |

## Work without a task identifier

The `TASK SOURCE` block says which of the three ways to handle described work are possible here: run it without a task (needs only Herdr), create a task for it, or use an existing task's identifier (both need spec-workflow enabled, a board configured, and the loop not paused). The lane skills use it to decide whether to ask the user or to say why only the first is on offer; the procedure is in `../../references/task-source.md`.

When a specialized plugin is absent, only its features are unavailable; the `herdr` plugin's own skills (`herdr:worktree`, `herdr:listen`, `herdr:status`) and `herdr-simple-orchestrate:orchestrate` keep working without any of them.
