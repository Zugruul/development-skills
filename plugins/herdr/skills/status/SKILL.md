---
name: status
description: Shows every live Herdr agent with its name, pane, kind, workspace and state, plus the worktrees of the current repository and which are open - read-only. Use for '/herdr:status', 'what agents are running', 'which worktrees are open in herdr', 'is anything blocked'. Requires running inside Herdr.
allowed-tools: Bash
---

# Herdr status

`ctl` = `python3 "../../scripts/herdr_ctl.py"` (resolve the path relative to this `SKILL.md`). Run `python3 "../../scripts/herdr_ctl.py" check` first; if it prints `HERDR UNAVAILABLE`, say so and stop.

This skill only reads. It never prompts, focuses, renames or closes anything.

```bash
python3 "../../scripts/herdr_ctl.py" roster                       # every live agent on this Herdr server
python3 "../../scripts/herdr_ctl.py" roster --repo <primary checkout>   # only agents in that repository's workspaces
herdr worktree list --cwd "$PWD"                                  # this repository's worktrees; .open_workspace_id says which are open
```

Report:

1. **Blocked agents first**, each with its name (or pane id when unnamed), workspace and tab: they wait on a human.
2. Then the rest, grouped by workspace: name, kind, state, directory. Mark yourself (the `*` row).
3. The repository's worktrees: branch, path, and whether a workspace is open for each. A worktree with no `open_workspace_id` exists in git but is not shown in Herdr.

States: `working` is mid-turn; `idle` and `done` are ready for input (`done` is a finished turn nobody has looked at yet); `blocked` waits at an approval or question; `unknown` means Herdr cannot classify the pane, which is not completion.

To see what one agent is doing, use the `listen` skill (`../listen/SKILL.md`). The roster covers this Herdr server only; agents on a saved SSH machine need the same commands with `herdr --machine <label>`.
