---
name: dev-up
description: Brings up the project's local dev stack (commands.devUp in .claude/project.yaml) for QA, validation against acceptance criteria, or debugging the running system. Use for 'run the stack', 'start the dev environment', or QA of a merged task — not needed for unit/integration TDD.
---

# Local dev stack

```bash
jq -r '.commands.devUp // empty' .claude/project.yaml   # then run that command, e.g.: ./dev.sh
```
If empty, this project has no configured dev stack — say so and stop.

Project-specific details (profiles, ports, isolation from other stacks, flags, preconditions) live in the doc at `paths.devDoc` (e.g. `docs/DEV.md`) — **read it before bringing the stack up or debugging it.**

## QA use
After a task merges (*In review* → *QA*), validate the running behavior against the task's acceptance criteria on this stack, then `board.sh move N QA` → on pass → `Ready`. If validation fails on a task already *Ready*, file a bug: `board.sh bug "<desc>" <top-priority> <origin#>`.
