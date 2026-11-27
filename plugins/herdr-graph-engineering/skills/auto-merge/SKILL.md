---
name: auto-merge
description: Turns auto-merge on or off for the graph engineering orchestrator (off by default), for this session, one repository or one lane - while it is on, the orchestrator may merge a lane's pull request after its gate and reviews pass; while it is off, every merge waits for you. Use for '/herdr-graph-engineering:auto-merge on', '/herdr-graph-engineering:auto-merge off', 'turn auto-merge on for this lane'. Requires jq, yq, git and gh.
allowed-tools: Bash, AskUserQuestion
---

# Auto-merge: on or off

Paths are relative to this `SKILL.md`; the scripts are in `../../scripts/`. The argument is `$ARGUMENTS`.

Auto-merge is **off by default**, and a new orchestrator session starts off. **Only this command changes it.** Never turn it on from other words, from AFK, or because a lane is waiting to merge.

## Set it

1. Read the argument: `on` or `off` (or `status`), and optionally a scope: `session`, `repo` (or a repository path), or `lane <name>`.
2. If it lacks `on`/`off`, or `on` lacks a scope, ask with one AskUserQuestion dialog (without a question tool, ask in plain text and wait). Question 1: "Auto-merge?" with **Off** first, then **On**. Question 2: "For what?" with "One lane" (name them), "This repository", "This whole session". No answer means off. `status` asks nothing.
3. Run it. The session is what `bash "../../scripts/session.sh" find --pane "$HERDR_PANE_ID"` prints (nothing: `graph`).

| Choice | Command |
| --- | --- |
| this session | `bash "../../scripts/session.sh" automerge on --session <session>` |
| one repository | `... automerge on --repo <dir> --session <session>` |
| one lane | `... automerge on --repo <dir> --lane <lane> --session <session>` |
| off for one repository or lane | the same with `off`; it wins over a wider "on" |
| off for everything | `... automerge off --session <session>` |
| status | `... automerge status [--repo <dir> --lane <lane>] --session <session>` |

4. Say in one line what is on or off. When you turn it on, also say what it allows, in these words: "I may merge this pull request after its gate and reviews pass. A draft pull request is marked ready first."

## What on means

Only `bash "../../scripts/merge.sh" check|run --lane L --repo R [--method squash|merge|rebase]` merges; never run `gh pr merge` yourself. It merges only when, all together: auto-merge is on for the lane; the pull request is the lane's recorded one; it is no review lane; no question is open; every node passed (or was skipped, never a gate or a review), with at least one gate; each gate and review passed on the pull request's head commit; the checkout is clean and pushed; no changes requested or required review missing; no conflict; every CI check passed. It marks a draft ready first, because GitHub merges no draft, and merges only that commit. It never approves, force-pushes, uses `--admin` or `--auto`, or deletes a branch. Pick `--method` as the repository's history does (default `squash`).

It applies whether the user is present or AFK. Every merge is recorded for the user like any AFK decision (`decide.sh digest`): show it in your next report. `NOT MERGEABLE` names what is missing: wait or fix it; never work around it. `MERGE FAILED`: tell the user, and try nothing else.

With auto-merge off, a merge always waits for the user, and the orchestrator does not merge even on their yes: they merge, or they turn auto-merge on.
