---
name: agent
description: Starts a coding agent in an existing Herdr pane and gives it its first prompt, handling the pane still being busy, the wait until the agent is idle, and name rules. Use for '/herdr:agent', 'start a codex agent in that pane', 'put a reviewer agent next to me', or as the agent-starting step of the worktree skill. Requires running inside Herdr.
allowed-tools: Bash, AskUserQuestion
---

# Start an agent in a Herdr pane

**Clients.** If this skill folder is a symlink (an install by the repository's `./install-skills.sh`), take `../../` from the folder it links to (`cd -P <this skill folder> && pwd` prints it).

Run `bash "../../scripts/check.sh"` first (paths are relative to this `SKILL.md`). If it prints `HERDR UNAVAILABLE`, say so and stop.

Starting and prompting are **separate steps**: start, wait until the agent is idle, then prompt. Never fold the prompt into the start.

## 1. Pick the pane

- A pane the caller already has (a new worktree's pane, a pane id the user gave): use it.
- No pane given: make a sibling of your own pane in your current directory, without moving the user's focus. Look at `herdr pane layout --current`; split a wide pane right and a tall pane down:
  `herdr pane split --current --direction right --cwd "$PWD" --no-focus` and read `.result.pane.pane_id`.
- Do not create a workspace, tab or worktree for an agent unless the user asked for that layout.

## 2. Pick the name and kind

- **Name**: must match `[a-z][a-z0-9_-]{0,31}` and be unique among live agents (`herdr agent list | jq -r ".result.agents[].name // empty"`). Say what the agent is for (`reviewer-auth`, `dev-login-fix`), not a counter. The start script refuses an invalid or taken name before anything is started.
- **Kind**: the one the user asked for. None given: ask, offering the kinds `herdr agent start --help` lists; do not assume the user wants the same kind as you.

## 3. Start

```bash
bash "../../scripts/start.sh" --name <name> --kind <kind> --pane <pane id> [--timeout 90] [-- <native agent args>]
```

A pane that was just created is still running its shell startup files, and `herdr agent start` then fails with `agent_pane_busy`. Herdr does not retry; the script does, until Herdr accepts the pane, then waits until the agent is idle.

- `AGENT READY`: go on to the prompt.
- `AGENT BLOCKED AT STARTUP` (exit 3): the agent is up but sits at a dialog (folder trust, login, an update notice). The screen is printed. Show it to the user and ask how to answer; answer with `herdr agent send-keys <name> <key>` only as they say.
- `NAME INVALID` or `NAME TAKEN` (exit 6): pick another name.
- Any other failure: report the herdr error. Do not start a second agent in the same pane to "retry".

## 4. First prompt

Write the prompt for a reader with no context: the goal, where to work, what is in and out of scope, and what to report back. Then send it once, with the `prompt` skill (`../prompt/SKILL.md`).

## 5. Hand over

Report the name, kind, pane, tab and state. To follow the agent's work, use the `listen` skill (`../listen/SKILL.md`). Do not close the pane or stop the agent unless the user asks.
