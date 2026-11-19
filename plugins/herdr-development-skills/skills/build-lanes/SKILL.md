---
name: build-lanes
description: Runs several spec-workflow board tasks in parallel, each as a build-next lane in its own Herdr worktree agent, with the current agent as orchestrator - picks non-overlapping tasks within the project's lane limit, starts one worktree and agent per task, listens to all of them and relays their questions and results. Use for '/herdr-development-skills:build-lanes', 'run three build lanes in herdr', 'work the backlog in parallel worktrees'. Requires Herdr, the herdr plugin and spec-workflow configured in the repository.
allowed-tools: Bash, AskUserQuestion
---

# Parallel build lanes in Herdr worktree agents

Run `python3 "../../scripts/detect.py"` first (path relative to this `SKILL.md`). Continue only when `build-lanes` is `READY`; on `PAUSED` or `UNAVAILABLE` relay the reasons and stop. Then follow the `herdr:orchestrate` skill if you have not taken the orchestrator role yet.

You are the one picker. Each lane agent gets exactly one task that you assigned, so two lanes never start the same task. Do not run this next to `build-loop` on the same repository.

Treat the rest of the request as: how many lanes, optionally specific issue numbers, and the agent kind.

## 1. How many lanes

`maxInProgress` in the detect output is the project's limit: the board's WIP limit and the number of lanes at once. Open at most `maxInProgress` minus the tasks already occupying a slot. With `serialDelivery=true`, tasks In review occupy a slot too.

- The user asks for more than the headroom: say what the limit is, open what fits, and mention that the spec-workflow `concurrency` skill changes it. Do not go over the limit on your own.
- `maxInProgress=1`: one lane at a time. That is the project's choice; run them one after the other.

## 2. Which tasks

Use the spec-workflow `queue` skill for the upcoming picks in order, with what is blocked and why. Take from the top, skipping blocked tasks. Issues the user named come first.

Apply spec-workflow's overlap gate before adding each lane: a task that touches the same package, module or spec section as a lane already running, or shares its epic, does not get a parallel lane. It waits. When in doubt, stay sequential; overlapping lanes cost more in conflicts than they save.

## 3. One approval for the set

Work out every lane first (the `task-lane` skill, section 3: branch, base, path, label). Then ask the user once, listing per lane: issue, task id and title, branch, base, path, agent kind. This approval covers exactly the listed worktrees; a lane added later needs its own.

## 4. Start the lanes

For each approved task, follow the `task-lane` skill with scope `iteration`, one after the other (each start waits for its pane and its agent). Skip its approval question for lanes the user just approved in step 3. If one lane fails to start, report it and carry on with the others.

## 5. Listen to all of them

Follow every lane with the `herdr:listen` skill, all targets at once, and keep a roster in every report: lane agent, issue, branch, state, and what changed since the last report.

- **Blocked lane**: show its question to the user, labelled with the lane and its tab; relay the answer with `herdr:prompt`. One question per lane, never a merged "approve all". A lane blocked on a human does not hold up the others.
- **A lane merged**: main moved. When another lane next settles or asks something, tell it to rebase onto the main branch before its next push. Do not interrupt a lane that is working; with `serialDelivery=true` each lane rebases at its own merge turn, and the lanes' own merge lock keeps merges one at a time.
- **A lane finished**: report its task, gate result, merge or PR state and board status; verify the board status with the `board` skill. Then, if the user asked to keep going and no pause flag appeared, go back to step 1 for the freed slot.
- **Paused meanwhile** (re-run the detect script when unsure): start no new lane. Running lanes stop at a safe boundary by themselves.

## 6. When to stop

Stop when the requested tasks are done, the queue has nothing eligible, the loop is paused, or the user says so. End with the roster: per lane the outcome and anything left for the user, with the exact action each open item needs. Leave worktrees and workspaces in place; spec-workflow removes a lane once its work has landed.
