---
name: ui-options
description: Iterative UI mode — present the human 2–4 concrete UI design options for a task as a local HTML page with a favorite selector and likeable aspect keywords, then collect the choice via issue comment. Use when a task involves UI-affecting decisions and iterative UI mode is on.
---

# UI options page — delegate the UI decision to the human

The human, not the agent, picks UI direction when iterative UI mode is ON. You produce real options, they choose, work on everything else continues meanwhile.

## Mode check (do this first)
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/ui-mode.sh" status    # prints ON, or OFF with the reason
```
`off` / `on` toggle it for this clone (local gitignored flag); `methodology.iterativeUI=false` in project.json is the project-wide kill switch.
OFF → decide the UI yourself following the spec and existing conventions; skip this skill.
If the human says they are going AFK, won't be watching, or sounds annoyed by UI questions — **offer to turn it off** (`ui-mode.sh off`).

## 1. Build the page
1. Design **2–4 genuinely different options** (not one option with color tweaks): different layout/navigation/density/visual language. Each option must be a self-contained inline HTML+CSS mockup of the actual screen/component the task needs.
2. `cp "${CLAUDE_PLUGIN_ROOT}/templates/ui-options.html" docs/ui-options/<task-id>.html` (create the dir), then edit it following the comments in the template: fill `__TASK_ID__`/`__TASK_TITLE__`/`__ISSUE_URL__`, and `__SESSION_ID__` with the value of `echo "$CLAUDE_CODE_SESSION_ID"` (gives the human a `claude --resume` way back into this session; if empty, replace the whole resume sentence with nothing — the issue comment channel always works). Duplicate the OPTION section per option, put each mockup in `.preview`, and give each option **4–8 aspect chips** — short trait keywords a non-designer can react to (e.g. `dense layout`, `sidebar nav`, `rounded cards`, `muted palette`, `inline editing`). Keep the "Iterative UI mode is ON / how to turn it off" hint intact.
3. Commit the page on the task branch.

## 2. Ask the human — decision hub first
The hub is one long-lived local page the human keeps open; cards appear there, answers come back automatically (no copy/paste). `HUB` = `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/ui-hub.py"`.
```bash
$HUB start                       # idempotent; prints RUNNING http://127.0.0.1:4747
$HUB ask <task-id>-r1 "<task-id>: <short question>" docs/ui-options/<task-id>.html
```
The first time in a session, tell the human the hub URL (once — it never changes). If only UI work remains, re-ask with `--blocking` so the card is flagged "agent is waiting on this".
Also post a short issue comment (`board.sh comment N`) pointing at the hub — the issue stays the durable/remote channel, and pasting the selection there works too.

## 3. Keep working, don't block
Continue every part of the task that does not commit to a UI option: domain logic, API, state, tests, plumbing, UI-agnostic scaffolding. Before UI-specific work (and at each iteration start), collect answers from both channels:
```bash
$HUB answers --consume           # JSON lines: {id, title, selection, ...}
bash "${CLAUDE_PLUGIN_ROOT}/scripts/board.sh" show N   # '### UI selection' comment
```

## 4. Apply the selection — iterate until the human commits
- **`Use: Option X (as-is, final)`** → decision made: implement exactly that option. No further rounds.
- **`Element notes:` lines** are element-scoped instructions: `Option X [tag.class > tag "element text"]: <note>` — the bracket is the element's selector path inside that option's mockup, the quote its text. Apply each note to that exact element; never generalize it to the whole design.
- **Favorite and/or liked aspects (no "Use")** → the human is still exploring: build the next round. Synthesize their favorite + liked aspects into one variant, plus 1–2 alternatives that explore what their picks left ambiguous (e.g. they liked both `monospace styling` and a polished shell — one variant leans each way). Do **not** badge any option as "Suggested" in the page — the template shuffles option order and an endorsement biases the pick; state your recommendation (and why) in the issue-comment acknowledgment instead. Include a Round-1-style recap of what they picked. Enqueue as `<task-id>-r<N+1>`; repeat until a `Use:` arrives.
- **Conflicting aspects** → resolve visibly: show the resolution as the suggested variant, note the conflict in its subtitle.
- Acknowledge each round on the issue (`board.sh comment N`: "Round 3 in the hub — B2 suggested").
- **No selection and only UI work remains** → do NOT guess: re-ask `--blocking`, post a reminder comment, report the task blocked-on-human, and stop the iteration (see `build-next` stop conditions).
