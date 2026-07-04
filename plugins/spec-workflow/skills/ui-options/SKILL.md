---
name: ui-options
description: Iterative UI mode — present the human 2–4 concrete UI design options for a task as a local HTML page with a favorite selector and likeable aspect keywords, then collect the choice via issue comment. Use when a task involves UI-affecting decisions and iterative UI mode is on.
---

# UI options page — delegate the UI decision to the human

The human, not the agent, picks UI direction when iterative UI mode is ON. You produce real options, they choose, work on everything else continues meanwhile.

## Mode check (do this first)
Iterative UI is ON unless either is true:
```bash
test -f .claude/ITERATIVE_UI_OFF && echo OFF-by-flag
jq -e '.methodology.iterativeUI == false' .claude/project.json >/dev/null 2>&1 && echo OFF-by-config
```
OFF → decide the UI yourself following the spec and existing conventions; skip this skill.
If the human says they are going AFK, won't be watching, or sounds annoyed by UI questions — **offer to turn it off**: `touch .claude/ITERATIVE_UI_OFF` (local, gitignored; `rm` re-enables).

## 1. Build the page
1. Design **2–4 genuinely different options** (not one option with color tweaks): different layout/navigation/density/visual language. Each option must be a self-contained inline HTML+CSS mockup of the actual screen/component the task needs.
2. `cp "${CLAUDE_PLUGIN_ROOT}/templates/ui-options.html" docs/ui-options/<task-id>.html` (create the dir), then edit it following the comments in the template: fill `__TASK_ID__`/`__TASK_TITLE__`/`__ISSUE_URL__`, and `__SESSION_ID__` with the value of `echo "$CLAUDE_CODE_SESSION_ID"` (gives the human a `claude --resume` way back into this session; if empty, replace the whole resume sentence with nothing — the issue comment channel always works). Duplicate the OPTION section per option, put each mockup in `.preview`, and give each option **4–8 aspect chips** — short trait keywords a non-designer can react to (e.g. `dense layout`, `sidebar nav`, `rounded cards`, `muted palette`, `inline editing`). Keep the "Iterative UI mode is ON / how to turn it off" hint intact.
3. Commit the page on the task branch.

## 2. Ask the human
Post on the task issue (this is the channel the loop already reads):
```bash
printf '%s' "UI decision needed — open docs/ui-options/<task-id>.html (task branch) in a browser, pick a favorite and/or the aspects you like, hit Copy selection, and paste the result here as a comment. Building the non-UI parts meanwhile." | bash "${CLAUDE_PLUGIN_ROOT}/scripts/board.sh" comment N
```

## 3. Keep working, don't block
Continue every part of the task that does not commit to a UI option: domain logic, API, state, tests, plumbing, and any UI-agnostic scaffolding. Re-check `board.sh show N` for the `### UI selection` comment before starting UI-specific work.

## 4. Apply the selection
- **Favorite picked** → implement that option; fold in liked aspects from other options and the notes.
- **Only aspects picked** → synthesize a design from the liked aspects; if they conflict, say how you resolved it in a reply comment.
- Acknowledge via `board.sh comment N` ("Applying: option B + A's palette…").
- **No selection and only UI work remains** → do NOT guess: post a reminder comment, report the task blocked-on-human, and stop the iteration (see `build-next` stop conditions).
