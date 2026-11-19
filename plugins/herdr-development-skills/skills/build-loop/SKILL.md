---
name: build-loop
description: Runs the spec-workflow build loop (loop + build-next) in a separate Herdr agent while the current agent orchestrates - listening to it, reporting each iteration and bringing its questions to the user. Use for '/herdr-development-skills:build-loop', 'run the build loop in a herdr agent', 'work the backlog in another pane and tell me when it needs me'. Requires Herdr, the herdr plugin and spec-workflow configured in the repository.
allowed-tools: Bash, AskUserQuestion
---

# The build loop in a Herdr agent

Run `python3 "../../scripts/detect.py"` first (path relative to this `SKILL.md`). Continue only when `build-loop` is `READY`; on `PAUSED` or `UNAVAILABLE` relay the reasons and stop. Then follow the `herdr:orchestrate` skill if you have not taken the orchestrator role yet.

One agent runs the loop; you watch it. Use this when the user wants the backlog worked without tying up this session. For several tasks at once in separate Herdr worktrees, use `build-lanes` instead. Never run both on one repository at the same time: two pickers can start the same task.

## 1. Check nothing else is looping

Run the `herdr:status` skill for this repository. If an agent there is already running the build loop or a lane, say so and ask before adding another.

## 2. Start the loop agent

Use the `herdr:agent` skill.

- **Pane**: a sibling of your pane whose working directory is the **primary checkout** from the detect output (not a task worktree: the loop switches to the main branch and creates its own task lanes).
- **Kind**: the one the user asked for; otherwise ask.
- **Name**: `build-loop`, or `build-loop-<repo>` when that is taken.
- **First prompt**, sent once:
  - a Claude Code agent: `/loop /spec-workflow:build-next`
  - any other kind: `Run the spec-workflow build-next skill. When an iteration ends without one of its stop conditions, start the next iteration. Stop when build-next says to stop.`

No worktree is created by this skill, so there is nothing to approve beyond starting the agent. The loop registers its own lanes; when the repository's project config has `herdr.enabled: true`, spec-workflow opens them in Herdr itself and they appear as workspaces (the detect output shows the setting).

## 3. Listen

Follow the agent with the `herdr:listen` skill, iteration after iteration.

- **Blocked**: the loop asks a human several things by design (which checkout mode, consent before the first autonomous merge, UI decisions). Show each question to the user and relay their answer with `herdr:prompt`. Never answer a consent gate yourself, and never tell the loop that config or an earlier session already authorized something.
- **Each iteration's report**: pass it on in the loop's own three groups (done, in progress, queued), with the task, gate result, PR or merge state and board status. Mark what you verified and what is the loop's claim.
- **Stopped**: the loop ends on its own stop conditions (paused, empty or blocked backlog, a gate that will not go green, a human-only blocker). Report which one, and the exact action it needs from the user.

## 4. Pausing and stopping

To pause, use the spec-workflow `checkpoint` skill: the loop finishes to a safe boundary and writes its handoff. Do not interrupt the agent with keys or close its pane to stop it; that leaves the board and the lane half-updated.
