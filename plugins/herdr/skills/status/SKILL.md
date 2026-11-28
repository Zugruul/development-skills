---
name: status
description: Read-only status of Herdr - the live agents (workspace, label, kind, state, name) and the repository's worktrees that are open as Herdr workspaces. Use for '/herdr:status', 'what agents are running', 'which worktrees are open in herdr', 'is anything blocked'. Requires running inside Herdr.
allowed-tools: Bash
---

# Herdr status

**Clients.** If this skill folder is a symlink (an install by the repository's `./install-skills.sh`), take `../../` from the folder it links to (`cd -P <this skill folder> && pwd` prints it).

Run `bash "../../scripts/check.sh"` first (paths are relative to this `SKILL.md`). If it prints `HERDR UNAVAILABLE`, say so and stop.

This skill only reads. It never prompts, focuses, renames or closes anything.

## 1. Live agents

```bash
jq -rn --argjson a "$(herdr agent list)" --argjson w "$(herdr workspace list)" --arg me "${HERDR_PANE_ID:-}" '
  ([$w.result.workspaces[]? | {(.workspace_id): .label}] | add // {}) as $label
  | [$a.result.agents[]? | [.workspace_id, ($label[.workspace_id] // .workspace_id), .agent, (.agent_status // "unknown"),
       ([(.name // ""), (if .pane_id == $me then "(this agent)" else "" end)] | map(select(. != "")) | join("  "))]]
  | sort_by([(if .[3] == "blocked" then 0 else 1 end), .[0]]) as $rows
  | ([range(0; 5) as $i | [$rows[][$i] | length] | max // 0]) as $wd
  | "Agents (\($rows | length))",
    ($rows[] | [range(0; 5) as $i | .[$i] + (" " * ($wd[$i] - (.[$i] | length)) // "")] | "  " + join("  ") | sub(" +$"; ""))'
```

## 2. Open worktrees of this repository

```bash
jq -rn --argjson t "$(herdr worktree list --cwd "$PWD")" --argjson w "$(herdr workspace list)" --argjson a "$(herdr agent list)" '
  ([$w.result.workspaces[]? | {(.workspace_id): .label}] | add // {}) as $label
  | ([$a.result.agents[]?.workspace_id]) as $busy
  | [$t.result.worktrees[]?] as $all
  | [$all[] | select(.open_workspace_id) ] | sort_by(.open_workspace_id)
  | map([($label[.open_workspace_id] // .open_workspace_id), (.branch // "(no branch)"),
         (if (.open_workspace_id | IN($busy[])) then "" else "(no agent)" end)]) as $rows
  | ([range(0; 3) as $i | [$rows[][$i] | length] | max // 0]) as $wd
  | "Worktrees (\($rows | length) open of \($all | length))",
    ($rows[] | [range(0; 3) as $i | .[$i] + (" " * ($wd[$i] - (.[$i] | length)) // "")] | "  " + join("  ") | sub(" +$"; ""))'
```

When the current directory is not in a repository Herdr can list, say so instead of the worktree list.

## 3. Print

Paste both outputs unchanged inside one fenced code block (` ```text `). The columns are aligned with spaces, and outside a code block a Markdown renderer collapses them.

- **Agents:** workspace id, workspace label (the title Herdr's sidebar shows), kind, state, then the agent's name when it has one. Blocked agents come first. Your own row ends in `(this agent)`.
- **Worktrees:** the heading counts the worktrees with an open Herdr workspace out of all the repository's worktrees; only the open ones are listed, as workspace label and branch, with `(no agent)` when no live agent runs there.
- No paths and no pane or tab columns. To target an unnamed agent, read its pane id from `herdr agent list`.

If any agent is `blocked`, say so in one line after the block, naming each: they wait on a human.

States: `working` is mid-turn; `idle` and `done` are ready for input (`done` is a finished turn nobody has looked at yet); `blocked` waits at an approval or question; `unknown` means Herdr cannot classify the pane, which is not completion.

To see what one agent is doing, use the `listen` skill (`../listen/SKILL.md`). This covers this Herdr server only; agents on a saved SSH machine need the same commands with `herdr --machine <label>`.
