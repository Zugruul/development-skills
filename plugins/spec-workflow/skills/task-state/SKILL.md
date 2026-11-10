---
name: task-state
description: Keeps the local record of which tasks agents are working on and their TODOs, shared by every agent and worktree of a repo and shown in the herdr tasks panel. Use when picking up, progressing, handing over or finishing a task, or when asked what agents are working on right now. It never reads or writes the board.
allowed-tools: Bash
---

# Task state

This is the live record of work in progress. The herdr tasks panel draws it directly, so what you record here is what the human sees. It makes no network calls. The panel shows only task-state records: it does not read a repo's TODO.md.

`board.sh move` creates the record when a task moves to the working status (In progress) and none exists: the issue title, status, agent `orchestrator`, and one TODO per unchecked `- [ ]` acceptance criterion in the issue body (or "Meet the issue's acceptance criteria" when there are none). It uses the title and body that `board.sh show` saved, so it costs no API call; only when that copy is missing does it make one REST read of the issue. An existing record keeps its TODOs and only gets the new status. A move to In review or QA with no record prints one warning naming the `task-state.sh set` command to run. The move never fails because of task-state. The saved copy is a snapshot from the last `board.sh show`, so run `show` right before moving to In progress (implement-task already does). Copies for issues that never finish stay until cleared; they are small and gitignored. Only unchecked criteria outside code fences count, and when the body has an Acceptance criteria heading, only that section's.

The board stays the source of truth for a task's status. This record adds what the board cannot show: the TODOs and how far along they are.

Resolve `../../scripts/task-state.sh` relative to this `SKILL.md`, and run it from any checkout of the repo. Every worktree shares the same record. State lives under the repo's git common directory, so never edit those files by hand, and never commit them.

## Commands

```bash
task-state.sh set  --id 12 --title "Add parser" --status "In progress" --agent orchestrator \
                   --todo "Write the failing test" --todo "Implement the parser"
task-state.sh todo --id 12 --start 1 --agent dev       # mark in progress; shows [>] and a Now line
task-state.sh todo --id 12 --done 1 --agent dev        # tick by number, or by exact text
task-state.sh todo --id 12 --undo 1 --agent dev        # reopen (also restores a dropped TODO)
task-state.sh todo --id 12 --drop 2 --agent dev        # work left scope: kept, numbered, not counted
task-state.sh todo --id 12 --add "Fix review finding" --before "Gate green" --agent reviewer  # insert in work order
task-state.sh todo --id 12 --move 4 --before 2 --agent dev   # reorder; numbers do not change
task-state.sh show --id 12                             # numbered TODOs (--json for scripts)
task-state.sh list                                     # every tracked task
task-state.sh clear --id 12                            # stop tracking
```

`--id` is the board issue number, or any id made of letters, digits, `-` and `_`.

## What to do, and when

1. **On pickup**, run `set` before implementation starts. Write one `--todo` for each acceptance criterion in the issue, in plain words the human can follow.
2. **On resume**, run `show` first. Then run `set` with the same TODOs if anything is missing. Seeding again keeps all progress and adds only what is new.
3. **As you work**, keep the record true at each of these moments, when it happens:
   - **Start**: mark a TODO `--start` when you begin it, and do not leave it set after you stop. `--done`, `--undo` and `--drop` clear it. Several agents can each have one active; the panel shows them in a `Now:` line under the task.
   - **Order**: the list reads in the order the work happens. Insert new work with `--before`, normally before the gate, review and merge items it must precede, never at the end by default. If you re-gate after a fix, the gate item stays after the fix.
   - **Completion**: tick a TODO when it is really finished, one at a time, not in a batch at the end.
   - **Scope change**: add new work with `--add`. When work leaves scope, `--drop` it. A dropped TODO keeps its number, shows as `[-]`, and is not counted in done or total. Do this when an issue comment or review changes scope, too.
   - **Regression or rework**: when a check fails or a finding sends the work back to an earlier step, reopen every TODO that is no longer true with `--undo`, before starting the fix. A failed review reopens "implementation" and "gate green". Re-tick only after the redo is finished.

   The panel must never claim something a regression has undone.
4. **On finish**, run `clear` when the task is closed or abandoned. `board.sh move` also updates the status. QA keeps the record, so retro, feedback and closure TODOs stay visible after the merge; it is cleared when the task moves to Ready, Deployed or later (the end of the status flow), as a safety net. Do not rely on it for abandoned work.

Write a real TODO for each piece of work, and tick only what is true. A panel that claims progress that did not happen is worse than no panel.

## Several agents and worktrees

- **One task, one record.** All agents on a task share it, from any worktree. Parallel lanes need no setup.
- **Always pass `--agent` with your role** (`orchestrator`, `dev`, `reviewer`). The panel shows who has been on each task.
- **Only touch your own task.** A lane updates its own id. Never clear or edit another lane's task unless the human asks.
- **The orchestrator seeds and clears. Whoever does the work ticks.** Pass every dev and reviewer agent its task id and these rules in the brief, as the required `## TODO UPKEEP (required)` section. Subagents never read brains, but they do use this record.
- **Run `show` before you tick by number** if another agent may have added TODOs. Every TODO has a permanent number stored on it. Inserting or moving a TODO changes the order, not any number, and a dropped TODO stays in the list, so a number you have seen stays valid. `show` lists numbers in display order, so they may appear out of sequence. New TODOs get the highest number plus one.
- **Concurrent writes are safe.** Each command takes a lock and replaces the file atomically. Read and update only through this script.
- **An old update does not prove a task is dead.** The panel shows each task's age. If a task looks stale, check its lane before you clear it.
