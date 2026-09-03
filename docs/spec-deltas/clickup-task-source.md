---
task: 'clickup-task-source'
spec: sw
sections: ["§3"]
---

## §3 Non-goals (v1) — CLARIFIED

The "Board providers other than `github-project`" non-goal stands unchanged: `boards[].provider` still accepts only `github-project`, and every board verb (`board.sh next/move/prio/...`), the picker, the queues, and the guards remain GitHub-only.

NEW, and deliberately NOT a board provider: `integrations.clickup` (schema: `schemas/project-config.schema.json`) lets `implement-task` take ONE human-picked task from ClickUp — a task SOURCE, not a board. There is no ClickUp `next`/pick/WIP accounting; the human hands the task ref (URL / `clickup:<id>` / `CU-<id>`) explicitly. Reads (task body, checklists, comments) are always allowed; the only ClickUp mutations the workflow may perform are `actions.move` / `actions.comment` / `actions.assign`, each an explicit opt-in defaulting to false (absent map == strictly read-only; disallowed actions are reported as `CLICKUP SKIPPED (safeguard)`, never performed). Transport is the configured MCP server (`integrations.clickup.mcp`) or a personal-token API fallback (`integrations.clickup.apiTokenEnv`); at least one is required while enabled. Full protocol: `skills/implement-task/references/clickup.md`.
