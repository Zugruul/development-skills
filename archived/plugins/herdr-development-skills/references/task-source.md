# Task source: work that comes without a task identifier

Shared by `task-lane`, `build-lanes` and `build-loop`. Read it whenever the user asks for a specific piece of work and gives **no task identifier**, or gives a **description instead of one** ("change the health check to 204 and open a draft PR"). Do not guess a task, do not refuse, and do not quietly drop to plain Herdr skills: decide the task source first, then run the lane.

A *piece of work* is one thing the user wants done, which becomes one lane. A request can hold several.

## 1. When there is nothing to decide

Skip the question for a piece when its answer is already known:

- The user gave its identifier (an issue number, a task id, an issue URL): that is option 3, already answered.
- The user already said in this conversation which option they want for it.
- A standing answer covers it. "No tasks for these, just run them" or "file a task for each" applies to every remaining piece of that request; do not ask again inside it. A new request starts fresh.
- Another skill of this plugin already decided it and handed the piece to you with its task source. Ask once per piece of work, never once per skill hop.

A bare `build-loop` or `build-lanes` with no specific work named is not a piece without a task: those pick from the board themselves. This procedure is for work the user described.

## 2. What can work here

Run `python3 "../../scripts/detect.py"` (path relative to the calling `SKILL.md`) and read the `TASK SOURCE` block. Option 1 needs only Herdr. Options 2 and 3 need spec-workflow enabled, the repository configured with a board, and the build loop not paused.

- **All three `possible`**: ask (section 3).
- **Options 2 and 3 `NOT POSSIBLE`**: do not ask a question with dead options. Tell the user in one or two sentences why a task cannot be created or looked up here, using the reasons printed, and that the work will run without a task. Then continue with option 1. The worktree approval that follows is where they can still decline.
- **Option 1 `NOT POSSIBLE`**: Herdr or the `herdr` plugin is missing, so no lane can run at all. Say so and stop.

## 3. The question

Ask through the host's structured-input facility (on Claude Code, the AskUserQuestion tool), one question per piece of work, with exactly these three options in this order:

| # | Option | What it means |
| --- | --- | --- |
| 1 | **Run the workflow without a task** | The same lane (worktree, agent, brief, listen) runs from your description alone. Nothing is read from or written to the board. Steps that need a task are skipped and listed as skipped in the final report. |
| 2 | **Create a task for it** | A board task is created from your description first, after a search for duplicates. You see the new identifier, then the normal task lane runs on it. |
| 3 | **Provide the task identifier** | You give the identifier of an existing task and the normal task lane runs on it. |

- Quote the piece of work in the question so the user sees what they are deciding for.
- Several pieces in one request: one question each, in the same prompt when the host allows it, each labelled with its piece ("Health check to 204", "Retry budget"). The answers may differ.
- Add nothing to the list and remove nothing from it. The host's free-text answer is how the user gives an identifier directly or says something else.

## 4. Acting on the answer

Record the answer per piece in your roster as its **task source**: `none`, `created #N` or `given #N`. Pass it along whenever you hand the piece to another skill.

### Option 1: run without a task

Follow the calling skill's **no-task lane**. Before any worktree is planned, make sure you can brief the agent: with no issue body to fall back on, the brief must come entirely from the user. You need:

1. **Goal**: what must be true when the work is done.
2. **Checkout**: which repository, and the base to branch from.
3. **Scope**: what is in, and what is explicitly out.
4. **Done**: how far to take it (commits only, pushed branch, draft PR, ready PR) and which checks must pass.
5. **Report**: what the agent says back.

If the description does not give one of these and the repository's own instructions do not settle it, ask the user for that one missing piece. Do not invent scope, and do not widen "change X" into "and tidy Y".

### Option 2: create a task for it

Use the spec-workflow `create-inbound` skill with the user's description. It searches the board for duplicates first and decides, with the user where it must, whether to file a new issue or fold the request into an existing one. Do not search or create issues yourself.

- It filed or matched an issue: tell the user the identifier and title, then run the calling skill's normal task lane on it.
- It filed nothing (the user declined, or it stopped): report that and ask how to go on. Do not fall back to option 1 silently.

### Option 3: provide the task identifier

Take the identifier from the user's answer; if the answer does not contain one, ask for it. Read the task with the spec-workflow `board` skill. If it cannot be found, say so and ask again rather than guessing a near match. Then run the calling skill's normal task lane on it.

## 5. What a no-task run skips

Every no-task final report carries this list, each line marked `skipped (no task)`:

- reading the task and its comments from the board;
- board status moves (In progress, In review, QA, Ready);
- issue comments and replies;
- the task-state record of the task's TODOs;
- the gate record tied to a task's move to review (the project's checks still run; their result is reported, not recorded against a task);
- linking the pull request to an issue.

Everything else still applies: the repository's own instructions, its conventions for branches and commits, and its checks. If something in the repository refuses the work because it has no task (for example a hook that blocks a pull request with no linked issue), the lane agent stops and reports it; bring that to the user, who may then choose option 2 or 3 for this piece.
