---
name: worktree
description: Starts a Herdr worktree (a git worktree opened as its own Herdr workspace) and, when asked, one or more agents on it, each with an initial prompt. Use for '/herdr:worktree', 'start a herdr worktree for branch X', 'open a worktree and put an agent on it', or when another agent needs an isolated checkout for delegated work. Requires running inside Herdr.
allowed-tools: Bash, AskUserQuestion
---

# Start a Herdr worktree

Run `bash "../../scripts/check.sh"` first (paths are relative to this `SKILL.md`). If it prints `HERDR UNAVAILABLE`, say so and stop.

Treat the rest of the request as: the branch, optionally the base ref, the path, and the agents to start (name, kind, initial prompt each).

## 1. Decide branch, base, path and label

- **Branch**: the one the user named. No branch given: ask.
- **Base**: the ref the user named. For a new branch with no base given, ask; do not pick one. Follow the repository's own base rule when its instructions state one (for example "branch from a freshly fetched `origin/main`"), and fetch that ref first.
- **Target repository**: the repository being changed, as `git -C <target> rev-parse --show-toplevel` of its checkout. A standalone clone nested inside another repository (its own `.git`, gitignored there) is its own target, not the enclosing repository.
- **Path**: take a worktree location rule only from that repository's own instructions (its `AGENTS.md` / `CLAUDE.md` / contributing notes at its toplevel). A rule from an enclosing repository, or from your own or the caller's checkout, never applies to a nested standalone clone. With no rule of its own, use Herdr's configured worktree directory: `<worktrees.directory>/<repo>/<branch with / as ->`, `~/.herdr/worktrees` by default. The path must not fall inside another repository's working tree unless the target's own rule puts it there.
- **Label**: the bold title of the workspace's entry in Herdr's sidebar. It is always one hyphen-separated group of letters and digits with no spaces (`fix-health-check`, `ABC-123-add-parser`). Use the label the user or the calling skill gave; otherwise derive it from the branch (`feat/x` becomes `feat-x`).

## 2. Check (read-only), then ask

```bash
herdr worktree list --cwd <any checkout of the repo>     # .result.source.repo_root is the primary checkout
git -C <primary checkout> status --porcelain             # dirty or clean; left untouched either way
git -C <primary checkout> rev-parse --short <base>       # the base resolves to a commit
bash "../../scripts/check-path.sh" --target <target> --path <path>   # PATH OK, or the path is inside another repository
```

- The branch is already checked out (an entry in `.result.worktrees[]` has that `.branch`): do not make a second worktree; offer `herdr worktree open --cwd <primary checkout> --branch <branch> --no-focus` instead.
- The path already exists: say so and stop.
- The base does not resolve: fetch it, or ask.
- `PATH REFUSED`: the path is inside another repository's working tree. Pick the path again by the rules above; add `--target-rule` only when the target's own instructions put it there.

**Ask the user** to approve, showing why a worktree helps, the branch, the base (ref and commit), the exact path and the label. Skip the question only when the user already asked for this worktree in this conversation. Approval for one worktree is not approval for the next.

Never stash, discard, move or commit the user's changes to make this pass. Never add `--trust-repository` yourself; if Herdr refuses the repository, tell the user and stop.

## 3. Create

Always pass every value explicitly:

```bash
herdr worktree create --cwd <primary checkout> --branch <branch> --base <base> --path <path> --label <label> --no-focus
```

Leave out `--base` only when the branch already exists. From the JSON answer take the workspace id (`.result.workspace.workspace_id`). If the answer does not carry it, read it back instead of guessing:

```bash
herdr worktree list --cwd <primary checkout>     # the entry whose .path is the new path -> .open_workspace_id
herdr pane list --workspace <workspace id>       # .result.panes[0].pane_id is the worktree's first pane
```

A failed or timed-out `create` does not prove nothing was made: run `herdr worktree list` before any retry.

## 4. Start agents (only if asked)

Follow the `agent` skill (`../agent/SKILL.md`) once per agent:

- The first agent goes in the worktree's first pane.
- Each further agent gets its own tab in the same workspace, so every agent keeps a usable width: `herdr tab create --workspace <workspace id> --cwd <worktree path> --label <agent name> --no-focus` (a tab is labelled with its agent's name, which already has no spaces), then use `.result.root_pane.pane_id`.
- The new pane is usually still starting its shell. Do not `sleep` and hope: the `agent` skill's start script retries until the pane is ready.

## 5. Report

Report, per worktree: workspace id, branch, base, path; per agent: name, kind, pane, tab and state. Say plainly what was not started and why. Do not remove a worktree, close a workspace or delete a branch unless the user asks.
