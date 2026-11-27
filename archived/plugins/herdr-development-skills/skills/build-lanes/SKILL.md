---
name: build-lanes
description: Runs several spec-workflow board tasks in parallel, each as a build-next lane in its own Herdr worktree agent, with the current agent as orchestrator - picks non-overlapping tasks within the project's lane limit, starts one worktree and agent per task, listens to all of them and relays their questions and results. Use for '/herdr-development-skills:build-lanes', 'run three build lanes in herdr', 'work the backlog in parallel worktrees'. When the user names work that has no task identifier it asks, per piece, whether to run it without a task, create a task, or use an existing one. Requires Herdr and the herdr plugin; board tasks also need spec-workflow configured in the repository.
allowed-tools: Bash, AskUserQuestion
---

# Parallel build lanes in Herdr worktree agents

Run `python3 "../../scripts/detect.py"` first (path relative to this `SKILL.md`). Continue when `build-lanes` is `READY` or `LIMITED`; on `UNAVAILABLE` relay the reasons and stop. `LIMITED` means only lanes without a task can run here, and nothing is picked from the board; the reasons say why. Then follow the `herdr-simple-orchestrate:orchestrate` skill if you have not taken the orchestrator role yet.

You are the one picker. Each lane agent gets exactly one task that you assigned, so two lanes never start the same task. Do not run this next to `build-loop` on the same repository.

Treat the rest of the request as: how many lanes, optionally specific issue numbers or descriptions of work, and the agent kind.

## 0. Task source for work the user described

Tasks you pick from the board, and issues the user named by identifier, already have their task. For every piece of work the user **described without an identifier**, follow `../../references/task-source.md` first:

- one question per piece, each labelled with its piece, asked together; the answers may differ;
- a standing answer ("no tasks for these, just run them") covers the rest of the request;
- when a task cannot be created or looked up here, say why and run those pieces without a task instead of asking.

Carry each piece's task source (`none`, `created #N`, `given #N`) into the steps below and hand it to `task-lane`, so the user is not asked again.

## 1. How many lanes

Lanes with task source `none` are not board tasks: they do not occupy a `maxInProgress` slot and are not refused by the limit. They still take your attention and can still collide, so the overlap gate in section 2 applies to them, and say how many lanes in total you are about to run.

`maxInProgress` in the detect output is the project's limit: the board's WIP limit and the number of lanes at once. Open at most `maxInProgress` minus the tasks already occupying a slot. With `serialDelivery=true`, tasks In review occupy a slot too.

- The user asks for more than the headroom: say what the limit is, open what fits, and mention that the spec-workflow `concurrency` skill changes it. Do not go over the limit on your own.
- `maxInProgress=1`: one lane at a time. That is the project's choice; run them one after the other.

## 2. Which tasks

Use the spec-workflow `queue` skill for the upcoming picks in order, with what is blocked and why. Take from the top, skipping blocked tasks. Issues the user named come first.

Apply spec-workflow's overlap gate before adding each lane: a task that touches the same package, module or spec section as a lane already running, or shares its epic, does not get a parallel lane. It waits. When in doubt, stay sequential; overlapping lanes cost more in conflicts than they save.

## 3. One approval for the set

Work out every lane first (the `task-lane` skill: section 3 for a task, section 7.2 for work without one). Then ask the user once, listing per lane: its task source and issue or description, branch, base, path, agent kind. This approval covers exactly the listed worktrees; a lane added later needs its own.

## 4. Start the lanes

For each approved lane, follow the `task-lane` skill, one after the other (each start waits for its pane and its agent): scope `iteration` for a task, the no-task lane (its section 7) for task source `none`. Skip its approval question for lanes the user just approved in step 3. If one lane fails to start, report it and carry on with the others.

## 5. Listen to all of them

Follow every lane with the `herdr:listen` skill, all targets at once, and report in the orchestrator report format of the `herdr-simple-orchestrate` plugin every time: one entry per lane, with the lane lines from `../../references/report-lines.md` (`task:`, `gate:`, `board:`) inside it.

- **Blocked lane**: show its question to the user, labelled with the lane and its tab; relay the answer with `herdr:prompt`. One question per lane, never a merged "approve all". A lane blocked on a human does not hold up the others.
- **A lane merged**: main moved. When another lane next settles or asks something, tell it to rebase onto the main branch before its next push. Do not interrupt a lane that is working; with `serialDelivery=true` each lane rebases at its own merge turn, and the lanes' own merge lock keeps merges one at a time.
- **A lane finished**: report its task, gate result, merge or PR state and board status; verify the board status with the `board` skill. For a no-task lane report what changed, its checks and its branch or pull request, and the steps skipped for lack of a task; there is no board status to verify. Then, if the user asked to keep going and no pause flag appeared, go back to step 1 for the freed slot.
- **Paused meanwhile** (re-run the detect script when unsure): start no new lane. Running lanes stop at a safe boundary by themselves.

## 6. When to stop

Stop when the requested tasks are done, the queue has nothing eligible, the loop is paused, or the user says so. End with a last report in that format, then in prose: per lane its task source, the outcome and anything left for the user, with the exact action each open item needs. Leave worktrees and workspaces in place; spec-workflow removes a lane once its work has landed.
