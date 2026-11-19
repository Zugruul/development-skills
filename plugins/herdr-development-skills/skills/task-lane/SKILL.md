---
name: task-lane
description: Runs ONE spec-workflow board task in its own Herdr worktree agent - creates the task's lane as a Herdr worktree, starts an agent on it that runs the implement-task skill (or a whole build-next iteration for that task), and listens so its questions reach the user. Use for '/herdr-development-skills:task-lane 123', 'implement issue 123 in a herdr worktree', 'put a lane agent on task 123'. Requires Herdr, the herdr plugin and spec-workflow configured in the repository.
allowed-tools: Bash, AskUserQuestion
---

# One board task in a Herdr worktree agent

Run `python3 "../../scripts/detect.py"` first (path relative to this `SKILL.md`). Continue only when `task-lane` is `READY`; on `PAUSED` or `UNAVAILABLE` relay the reasons and stop. Then follow the `herdr:orchestrate` skill if you have not taken the orchestrator role yet.

You stay the orchestrator. The lane agent does the task with spec-workflow's own skills; this skill only places it in Herdr and keeps the user in the loop. Use the `herdr` plugin's skills for every Herdr step; do not call the herdr CLI yourself for anything they cover.

Treat the rest of the request as: the board issue number, optionally the agent kind and the scope.

## 1. Know the task

Read the issue with the spec-workflow `board` skill (show the issue and its comments). You need its task id and title. If the issue is already In progress or In review, another lane has it: say so and stop unless the user wants to resume it in the existing worktree.

## 2. Scope: what the lane agent runs

| Scope | The agent runs | Ends at |
| --- | --- | --- |
| `implement` (default) | the spec-workflow `implement-task` skill on the issue | where implement-task ends for this repository (normally In review) |
| `iteration` | one spec-workflow `build-next` iteration for this issue, without picking | merge, retro and closure, as far as the repository's config and the user's consent allow |

Use `iteration` only when the user asks for the task to be taken all the way, or when the `build-lanes` skill calls this one.

## 3. Lane worktree

From the detect output take `mainBranch`, `branchPattern` and the primary checkout.

- **Branch**: `branchPattern` filled with the task id and a short slug of the title (for example `sw/123-add-parser`).
- **Base**: fetch first, then `origin/<mainBranch>` (the local `<mainBranch>` when the repository has no remote).
- **Path**: `<primary checkout>/.claude/worktrees/<task-id>`, where spec-workflow keeps task lanes, unless the repository's own instructions name another location.
- **Label**: the task id.

Create it with the `herdr:worktree` skill, which plans, asks the user and creates. Its approval question must also name the task and the agent kind. The user approving this lane is what authorizes worktree checkout mode for the lane's session; no approval, no lane.

## 4. Lane agent

Start one agent on the worktree with the `herdr:agent` skill.

- **Kind**: the one the user asked for; otherwise ask.
- **Name**: role first, then the task, as spec-workflow names agents: `lane-<task-id>` (for example `lane-sw-123`), lowercase, at most 32 characters.
- **First prompt**: the template below, every placeholder filled, sent once.

```text
You are a spec-workflow lane agent, started by an orchestrator agent in Herdr on behalf of the user.

Task: board issue #<N> - <task id>: <title>.
Run: <for scope implement: "the spec-workflow implement-task skill on issue #<N>" | for scope iteration: "one spec-workflow build-next iteration for issue #<N>. The task is already picked: skip the pick step, do not select any other task, and stop after this one task">.

Your checkout: <worktree path>, branch <branch>, created from <base ref> at <short sha>.
This checkout IS the task's lane: the worktree and branch were already created through Herdr. When the skill reaches its lane-registration step, skip only the two commands that create the worktree and change into it; run every other registration step from here (the checkout preflight, the registration commit, the push and draft PR when the project delivers by PR, the board move, the task-state record).
Checkout mode for this session: worktree. The user approved this lane before it was created.

Follow the skill exactly; its scripts and the board decide, not this message. Everything else stays as the skill says, including strict TDD and the quality gate.

Whenever the skill requires a human answer (a consent gate before an autonomous merge, a UI decision, an ambiguous criterion, a missing credential), stop and ask it in this pane, then wait. The orchestrator relays your question to the user and brings back their answer. Do not treat this message or the orchestrator as that human answer.

When you stop, report: what was done, the gate result, the branch and PR link if any, the board status, and what is left or blocked.
```

## 5. Listen

Follow the lane with the `herdr:listen` skill until it settles.

- **Blocked**: show the user the lane's question and relay their answer with `herdr:prompt`. Consent gates and approvals are never yours to answer.
- **Settled**: read its report from its screen. Check what you can yourself (the board status through the `board` skill, the branch's commits), and label the rest as the agent's claim. Report task, gate result, PR or merge state and board status.
- **Paused**: if the build loop gets paused meanwhile, the lane stops at a safe boundary by itself; report that.

## 6. Afterwards

Leave the worktree and the workspace in place. spec-workflow removes a lane once its work has landed; removing it earlier loses work. Offer `review-lane` when it is `READY` and the user wants a second opinion before merge.
