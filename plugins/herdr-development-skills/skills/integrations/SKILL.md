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
| `PAUSED` | The build loop is paused by its checkpoint flag. | Start no build work. Say what is paused and that the spec-workflow `checkpoint` skill resumes it. |
| `UNAVAILABLE` | Something is missing. | Give the listed reasons and the one step that fixes each. Do not work around it. |

The script reads files; it cannot see your session. Before offering a `READY` feature, confirm the skills it relies on are really listed in your session (for example `spec-workflow:build-next`, `herdr:worktree`). If they are not, treat the feature as unavailable and say which plugin to enable.

## The integrations

| Feature | Skill | Needs |
| --- | --- | --- |
| `task-lane` | `task-lane` - one board task in a Herdr worktree agent | herdr, spec-workflow, a configured repository |
| `build-loop` | `build-loop` - the build loop in one Herdr agent | the same |
| `build-lanes` | `build-lanes` - several board tasks in parallel Herdr worktree agents | the same; lane count from `methodology.maxInProgress` |
| `review-lane` | `review-lane` - an independent review next to a lane | herdr, peer-review |

When a specialized plugin is absent, only its features are unavailable; the `herdr` plugin's own skills (`herdr:worktree`, `herdr:listen`, `herdr:orchestrate`) keep working without any of them.
