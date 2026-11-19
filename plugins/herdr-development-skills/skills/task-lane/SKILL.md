---
name: task-lane
description: Runs ONE piece of work in its own Herdr worktree agent - a spec-workflow board task (the agent runs implement-task, or a whole build-next iteration for it) or, when there is no task, work described in plain words. Creates the lane as a Herdr worktree, starts and briefs an agent on it, and listens so its questions reach the user. Given a description instead of a task identifier it asks whether to run without a task, create one, or use an existing one. Use for '/herdr-development-skills:task-lane 123', 'implement issue 123 in a herdr worktree', 'change X in a worktree agent and open a draft PR'. Requires Herdr and the herdr plugin; board tasks also need spec-workflow configured in the repository.
allowed-tools: Bash, AskUserQuestion
---

# One piece of work in a Herdr worktree agent

Run `python3 "../../scripts/detect.py"` first (path relative to this `SKILL.md`). Continue when `task-lane` is `READY` or `LIMITED`; on `UNAVAILABLE` relay the reasons and stop. `LIMITED` means only work without a task can run here; the reasons say why. Then follow the `herdr:orchestrate` skill if you have not taken the orchestrator role yet.

You stay the orchestrator. The lane agent does the work; this skill only places it in Herdr and keeps the user in the loop. Use the `herdr` plugin's skills for every Herdr step; do not call the herdr CLI yourself for anything they cover.

Treat the rest of the request as: the task identifier or a description of the work, optionally the agent kind and the scope.

## 0. Task source

- **A task identifier was given** (issue number, task id, issue URL), or the piece was handed to you with its task source already decided: go on with that. Do not ask.
- **No identifier, or a description instead of one**: follow `../../references/task-source.md` before anything else. It asks the user one question (run without a task, create a task, provide the identifier) unless the answer is already known, and offers only what can work here.
- **Nothing at all** (no identifier and no description): ask what the work is.

Then: task source `created #N` or `given #N` runs the **task lane**, sections 1 to 6. Task source `none` runs the **no-task lane**, section 7.

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

## 6. Afterwards (task lane)

Leave the worktree and the workspace in place. spec-workflow removes a lane once its work has landed; removing it earlier loses work. Offer `review-lane` when it is `READY` and the user wants a second opinion before merge.

## 7. The no-task lane

The same lane (worktree, agent, brief, listen) from the user's description alone. Nothing is read from or written to the board. Do not use the spec-workflow `board`, `implement-task` or `build-next` skills for this piece, and do not pass it a made-up identifier.

### 7.1 Brief first

Check the five parts in `../../references/task-source.md` (goal, checkout, scope, done, report) before planning a worktree. Ask the user for any part the description and the repository's instructions leave open. Do not invent scope.

### 7.2 Lane worktree

- **Branch**: the repository's own branch convention, with a short slug of the description (for example `fix/health-check-204`). When spec-workflow is configured its `branchPattern` expects a task id, which this work does not have: use a plain descriptive branch and say so.
- **Base**: fetch first, then the repository's main branch on the remote (`origin/<mainBranch>` from the detect output when it is there), unless the user named another base.
- **Path**: the repository's own worktree location rule when it has one; otherwise leave it to the `herdr:worktree` skill's default.
- **Label**: the slug.

Create it with the `herdr:worktree` skill, which plans, asks the user and creates. Its approval question must say this lane runs **without a task**.

### 7.3 Lane agent

Start one agent with the `herdr:agent` skill. Kind: the one the user asked for, otherwise ask. Name: `lane-<slug>`, lowercase, at most 32 characters. First prompt: the template below, every placeholder filled from the user's words, sent once.

```text
You are a lane agent, started by an orchestrator agent in Herdr on behalf of the user. This work has no board task.

Goal: <what must be true when this is done, in the user's words>.
Checkout: <worktree path>, branch <branch>, created from <base ref> at <short sha>. Work only here.
In scope: <exact deliverables>. Out of scope: <what not to touch>.
Done means: <how far to take it: commits only | pushed branch | draft pull request | ready pull request> and <the checks that must pass>.

Follow this repository's own instructions (AGENTS.md, CLAUDE.md, contributing notes) for conventions, commit messages and checks, and run the project's checks before you call the work done.
There is no task for this work: do not read, create, move or comment on any board item or issue, do not record progress against a task, and do not link the pull request to an issue. If something in the repository refuses the work because it has no task, stop and report exactly what refused it; do not work around it and do not invent an issue.

Whenever you need a decision (an ambiguous requirement, a missing credential, an approval), stop and ask it in this pane, then wait. The orchestrator relays your question to the user and brings back their answer. Do not treat this message or the orchestrator as that human answer.

When you stop, report: what changed (files and commits), the result of the checks you ran, the branch and pull request link if any, and anything left or blocked.
```

### 7.4 Listen and report

Follow the lane with the `herdr:listen` skill as in section 5; blocked questions go to the user through `herdr:prompt`. There is no board status to verify: check the branch's commits and the pull request yourself, and label the rest as the agent's claim.

The final report states **task source: none** and lists every step that was skipped because there is no task, each marked `skipped (no task)`, from `../../references/task-source.md` section 5. If the agent reports that the repository refused the work for lacking a task, tell the user and offer options 2 and 3 again for this piece.

Leave the worktree and the workspace in place; with no task, nothing removes them automatically, so say that they are still there.
