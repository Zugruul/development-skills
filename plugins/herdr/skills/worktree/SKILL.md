---
name: worktree
description: Starts a Herdr worktree (a git worktree opened as its own Herdr workspace) and, when asked, one or more agents on it, each with an initial prompt. Use for '/herdr:worktree', 'start a herdr worktree for branch X', 'open a worktree and put an agent on it', or when an orchestrator needs an isolated checkout for delegated work. Requires running inside Herdr.
allowed-tools: Bash, AskUserQuestion
---

# Start a Herdr worktree

`ctl` = `python3 "../../scripts/herdr_ctl.py"` (resolve the path relative to this `SKILL.md`). Run `python3 "../../scripts/herdr_ctl.py" check` first; if it prints `HERDR UNAVAILABLE`, say so and stop.

Treat the rest of the request as: the branch, optionally the base ref, the path, and the agents to start (name, kind, initial prompt each).

## 1. Decide branch, base and path

- **Branch**: the one the user named. No branch given: ask.
- **Base**: the ref the user named. For a new branch with no base given, ask; do not pick one. Follow the repository's own base rule when its instructions state one (for example "branch from a freshly fetched `origin/main`"), and fetch that ref first.
- **Path**: follow the target repository's own worktree location rule when it has one (read its `AGENTS.md` / `CLAUDE.md` / contributing notes). With no rule, omit `--path` in the plan below and it proposes Herdr's configured worktree directory.

## 2. Plan (read-only), then ask

```bash
python3 "../../scripts/herdr_ctl.py" worktree-plan --branch <branch> --base <ref> [--path <path>] [--label <text>] [--cwd <any checkout of the repo>]
```

It resolves the repository's primary checkout (Herdr only creates worktrees from there), checks that the branch is not already checked out, that the destination does not exist and that the base resolves, reports whether the primary checkout is dirty, and prints the exact command with `--cwd`, `--branch`, `--base` and `--path` all explicit. It creates nothing.

- `DO NOT CREATE`: fix what it names, or tell the user. If the branch is already checked out, offer `herdr worktree open` on it instead of a second worktree.
- Otherwise **Ask the user** to approve, showing why a worktree helps, the branch, the base (ref and commit), and the exact path. Skip the question only when the user already asked for this worktree in this conversation. Approval for one worktree is not approval for the next.

Never stash, discard, move or commit the user's changes to make this pass. Never add `--trust-repository` yourself; if Herdr refuses the repository, tell the user and stop.

## 3. Create

Run the printed `herdr worktree create ... --no-focus` line unchanged. From the JSON answer take the workspace id (`.result.workspace.workspace_id`). If the answer does not carry it, read it back instead of guessing:

```bash
herdr worktree list --cwd <primary checkout>     # the entry whose .path is the new path -> .open_workspace_id
herdr pane list --workspace <workspace id>       # .result.panes[0].pane_id is the worktree's first pane
```

A failed or timed-out `create` does not prove nothing was made: run `herdr worktree list` before any retry.

## 4. Start agents (only if asked)

Follow the `agent` skill (`../agent/SKILL.md`) once per agent:

- The first agent goes in the worktree's first pane.
- Each further agent gets its own tab in the same workspace, so every agent keeps a usable width: `herdr tab create --workspace <workspace id> --cwd <worktree path> --label <agent name> --no-focus`, then use `.result.root_pane.pane_id`.
- The new pane is usually still starting its shell. Do not `sleep` and hope: the `agent` skill's start helper retries until the pane is ready.

## 5. Report

Report, per worktree: workspace id, branch, base, path; per agent: name, kind, pane, tab and state. Say plainly what was not started and why. Do not remove a worktree, close a workspace or delete a branch unless the user asks.
