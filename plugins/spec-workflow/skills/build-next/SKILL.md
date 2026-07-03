---
name: build-next
description: Run ONE build iteration — checkpoint check, pick the next board task (reading human comments), implement it via TDD to a green gate, open a PR, keep the board strictly up to date. Designed to be driven by /loop to work the backlog until done.
allowed-tools: Bash
---

# /build-next — one build iteration

Pre-start check: !`bash "${CLAUDE_PLUGIN_ROOT}/scripts/preflight.sh" --spec`
If the line above says `PREFLIGHT FAIL`, STOP — follow its instruction instead of continuing.

You are an autonomous engineer building `<cfg:project.name>`. Read `.claude/project.json` once at the start — it defines the boards, specs, gate, and rules. The board is the **source of truth**, kept up to date in real time. Exactly **one task per invocation**, strict TDD. `board.sh` = `bash "${CLAUDE_PLUGIN_ROOT}/scripts/board.sh"`.

## Preflight (every iteration)
1. `gh auth status` must show the `project` scope — if missing, STOP and tell the human to run `gh auth refresh -h github.com -s project`.
2. **Checkpoint:** if the file at `paths.checkpointFile` (default `.claude/CHECKPOINT`) exists, do NOT start work — write a `handoff` (using the file's contents as the reason) and end the loop.
3. `git switch <cfg:project.mainBranch> && git pull --ff-only` — start clean.

## Iteration
1. **`next-task` skill** — `board.sh next`, then `board.sh show N` to read the body and **all human comments**; fold comment-driven changes into the issue body (`edit-body`) and acknowledge (`comment`) before starting.
2. **`implement-task` skill** on #N — you create the branch + `board.sh move N "In progress"`, then spawn a dev subagent (`model: cfg:delegation.devModel`) with the full what/how/why brief; it develops TDD to a green gate, pushes, opens the PR.
3. **Verify** — re-run the gate yourself; confirm tests-first, invariants, isolation coverage. Then `board.sh move N "In review"`.
4. **Review** — review agent on the diff; relay findings to a dev agent; re-gate.
5. Report: task, gate result, PR link, board status.

## Advancing beyond In review
*In review* → *QA* after the PR merges; validate on the running stack (`dev-up`) against acceptance criteria → *Ready*; → *Deployed* only when actually published. Never fake these transitions. Bugs found after *Ready*: `board.sh bug "<desc>" <top-prio> <origin#>` — never reopen shipped tasks.

## Stop conditions (write a `handoff`, then stop)
- checkpoint flag present, OR
- `board.sh next` reports empty/only-blocked backlog, OR
- the gate cannot go green after a reasonable attempt (report the blocker), OR
- a human-only blocker (auth, secrets, credentials, decisions) — also post it as a `board.sh comment` on the task.

## Non-negotiables
Board reflects reality at every step · ≤ `methodology.maxInProgress` task(s) In progress · test first, always · gate green before In review · human comments read and answered · small focused PRs.
