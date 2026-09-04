---
task: 'clickup-task-source'
spec: sw
sections: ["§3"]
---

## §3 Non-goals (v1) — CLARIFIED

The "Board providers other than `github-project`" non-goal stands unchanged: `boards[].provider` still accepts only `github-project`, and every board verb (`board.sh next/move/prio/...`), the picker, the queues, and the guards remain GitHub-only.

NEW, and deliberately NOT a board provider: `integrations.clickup` (schema: `schemas/project-config.schema.json`) lets `implement-task` take ONE human-picked task from ClickUp — a task SOURCE, not a board. There is no ClickUp `next`/pick/WIP accounting; the human hands the task ref (URL / `clickup:<id>` / `CU-<id>`) explicitly. Reads (task body, checklists, comments) are always allowed; the only ClickUp mutations the workflow may perform are `actions.move` / `actions.comment` / `actions.assign`, each tri-state `ask`/`allow`/`disallow` defaulting to `ask` (ask degrades to disallow in non-interactive runs; withheld actions are reported as `CLICKUP SKIPPED (safeguard)`, never performed). Transport is MCP-ONLY: the configured MCP server (`integrations.clickup.mcp`) is required while enabled — no API-token fallback exists. Full protocol: `skills/implement-task/references/clickup.md`.
