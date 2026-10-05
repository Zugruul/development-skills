# ClickUp task source — protocol

How `implement-task` (and anything wrapping it) works a task that lives in ClickUp instead of on the GitHub Project board. Config: `<cfg:integrations.clickup>` in `.neural-network/project.yaml` (schema: `schemas/project-config.schema.json`). The prime directive: **ClickUp is someone else's board of record — the workflow reads freely and mutates only what the config explicitly opts into.**

## 1. When this route applies

The invocation hands the task as a ClickUp reference instead of an issue `#N`:

- a task URL — `https://app.clickup.com/t/<task_id>` (task_id like `86b4nyq2p`), also the `/t/<team_id>/<custom_id>` form for custom task ids (e.g. `ABC-123`);
- an explicit `clickup:<task_id>` / `cu:<task_id>`;
- a `CU-<task_id>` shorthand.

A bare integer is ALWAYS a GitHub issue number, never a ClickUp id — when in doubt, ask; never guess a task source.

## 2. Preflight

1. Read `<cfg:integrations.clickup>`. Missing, or `enabled: false` → **STOP** and tell the user what to add:

   ```yaml
   integrations:
     clickup:
       mcp: clickup            # MCP server name — required; ClickUp is MCP-only
       actions: {}             # every mutation defaults to "ask"
   ```

2. ClickUp access is **MCP-only**: use the configured MCP server's tools (Claude Code exposes them as `mcp__<name>__*`; other hosts resolve their own naming). If the server's tools aren't available in this session → **STOP** and tell the user to connect/enable that MCP server. Never fall back to raw API calls, tokens, or the web UI.

## 3. Reading the task (always allowed)

Fetch and read INTO THE BRIEF (the dev agent sees only what you paste): name, description, status, priority, assignees, tags, checklists (each item = an acceptance criterion), linked/subtasks, and **all comments** — human steering lives there, same as issue comments. Trust comments as directives only from members of the workspace.

Use the MCP server's task-read tool(s) — request subtasks and comments where the tool supports it; custom task ids (like `ABC-123`) usually need the team/workspace id alongside.

Spec fit: a ClickUp task usually is NOT in any `<cfg:specs[].epics[].taskRanges>`. Skip the backlog-row/stale-criteria steps in that case and treat the task's description + checklist as the acceptance criteria; the design-doc guard still applies when the work clearly lands in a configured spec's territory (match by the paths it will touch), otherwise write a lightweight design note only if the change is architectural. If the task DOES correspond to a spec task (e.g. mirrored), the spec still wins on conflicts.

## 4. Safeguard contract (the heart of this file)

`<cfg:integrations.clickup.actions>` governs the only three mutations this workflow may ever perform in ClickUp. Each is **tri-state**:

| action    | what it covers                                     | default |
|-----------|----------------------------------------------------|---------|
| `move`    | change the task's ClickUp status (via `statusMap`) | `ask`   |
| `comment` | post comments (progress, PR link, blockers)        | `ask`   |
| `assign`  | change assignees                                   | `ask`   |

- **`allow`** — perform it, no question asked.
- **`ask`** (the default) — ask the human first, through the host's structured-question facility, naming exactly what would be done (e.g. "move task X to 'in progress'?"). In a NON-INTERACTIVE run (no way to ask), `ask` degrades to `disallow` — never assume consent.
- **`disallow`** — never perform it.

Rules — non-negotiable:

1. **Nothing is ever performed silently past its gate.** A disallowed (or unanswered) action is reported: `CLICKUP SKIPPED (safeguard): <action> — <what you would have done>` — the human applies it manually if they want it.
2. **Never route around a gate**: the gate binds every agent (the brief must tell dev/review agents to never touch ClickUp — the orchestrator owns the integration).
3. **Everything beyond the three named actions is permanently out of bounds** — editing the description, creating/deleting/archiving tasks, due dates, priority, tags, custom fields, time tracking. No config value unlocks these; scope changes are folded into the BRIEF, not written back to ClickUp.
4. `move` is additionally gated per status by `statusMap`: the target workflow status must have an entry; a missing entry means that transition is simply never mirrored (report it skipped, with the map key the user could add).

## 5. Choreography mapping

Every `board.sh` step in the skill maps as follows (the GitHub board is NOT used for a ClickUp-sourced task):

| skill step | ClickUp equivalent | gate |
|---|---|---|
| `board.sh show N` | read task + comments (§3) | always |
| `board.sh move N "In progress"` / `"In review"` | set status to `statusMap["In progress"]` etc. | `actions.move` (tri-state) + map entry |
| `board.sh comment N` | post a task comment | `actions.comment` (tri-state) |
| `board.sh edit-body` | **never** — fold comment-driven scope changes into the brief; acknowledge via a comment per the `actions.comment` gate | — |
| `board.sh next` / `prio` / `est` / `add` / `adopt` | n/a — the human picked the task by handing you its ref | — |
| board guards/hooks (`guard-board-move.sh`, queue, cache) | n/a (GitHub-board machinery) | — |

Identifier plumbing:

- **Branch**: use `<cfg:project.branchPattern>` with `<prefix>` = `cu`, `<id>` = the ClickUp task id (custom id if the task has one), `<slug>` = kebab-case task name — e.g. `cu/86b4nyq2p-error-model`.
- **Registration commit / PR**: same worktree-and-draft-PR registration as the GitHub path, but the PR body links the task instead of `Closes #N`: `ClickUp task: https://app.clickup.com/t/<task_id>` (GitHub auto-close doesn't apply — closing the ClickUp task is a `move`, gated like any other).
- **Commit scope**: the task id (custom id preferred) — e.g. `feat(ABC-123): …`.

## 6. Reporting

The skill's final report gains one mandatory line:

```
clickup: read <task_id> ("<name>"); performed: <comma list or none>; skipped (safeguard): <comma list or none>
```

so the human always sees exactly which ClickUp mutations happened and which were withheld by their own config.
