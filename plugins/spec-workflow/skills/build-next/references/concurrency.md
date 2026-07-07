# Parallel lanes (`methodology.maxInProgress` > 1)

`maxInProgress` is THE concurrency knob: the board WIP limit AND the number of
parallel implementation **lanes**. `1` (default) = strictly sequential — one task,
one dev agent, at a time. `N>1` lets the orchestrator run up to N tasks at once,
each in its own lane. The picker (`next.py`) already refuses to hand out more than
N in-progress tasks, so the board can never exceed the limit; these rules govern
how the orchestrator runs the lanes safely.

## A lane

One lane = one task, end to end, isolated:
- **Own git worktree** — `git worktree add <abs path> <branch>` off `mainBranch`.
  Never run two lanes in the same working tree. Absolute-path discipline (build-next
  rule 9) is mandatory: every git/gate command for a lane starts with
  `cd <that lane's absolute worktree path> &&` in the SAME call — a bare `git push`
  lands in whatever directory the shell last `cd`-ed to.
- **Own branch** — from `project.branchPattern`, one per task.
- **Own dev agent** — spawned per lane (naming below). One agent = one task; never
  point two agents at one lane or one agent at two tasks.

## Opening a lane — the overlap gate

Before opening a second (or Nth) lane, check the candidate task does NOT overlap any
in-flight lane's file area:
- Different epics, and non-intersecting `covers` globs / expected paths.
- If two ready tasks touch the same package/module/spec section → **do not** parallelize
  them; run them sequentially in one lane. Overlapping lanes race on the same files and
  produce merge conflicts the loop then has to untangle — slower than sequential.
When in doubt, stay sequential. Concurrency is an optimization for independent work,
not a mandate.

## Running lanes

- Each lane follows the normal `implement-task` flow (brief → TDD → gate → In review →
  review). Lanes are independent: a lane **blocked on a human** (auth, a UI decision, an
  ambiguous criterion) parks at *In review*/commented and does **not** block the others —
  keep the rest moving.
- **A merge invalidates the others.** When any lane merges to `mainBranch`, announce it to
  every other live lane (the existing auto-review §4 announce): each other lane must
  `cd <its worktree> && git rebase <mainBranch>` (or pull) before its next push, or its PR
  goes stale. A merged contract change may turn another lane's in-flight task stale — re-check
  its acceptance criteria against the new spec/delta.
- **Checkpoint pauses ALL lanes.** If `paths.checkpointFile` appears, no lane starts new
  work; each finishes to a safe boundary (or parks) and the loop writes one handoff covering
  every lane. The gate/`guard-board-move` hook still applies per lane.
- Clean up a lane's worktree after its PR merges (`git worktree remove <path>`).

## Naming (role-prefix FIRST, always)

Agent names are `<role>-<scope>` — the identity **role** first, then the task/PR it serves.
Never the reverse, never a bare counter.
- **role** = the identity role: `dev`, `reviewer`, `pr-reviewer`, `research`, …
- **scope** = what the agent is FOR: the task id or PR number (`dev-cp012`, `pr-reviewer-pr5`).
- A respawn for the SAME scope appends a letter: `dev-cp012-b`.
- A long-lived agent reused across scopes keeps a stable bare role name: `pr-reviewer`.
- Bare counters (`dev-agent-3`) are **deprecated** — the suffix must say what the agent is
  for, so parallel lanes are distinguishable at a glance.

Examples: `dev-cp012` (dev lane for task CP-012), `pr-reviewer-pr5` (PR reviewer for PR #5),
`dev-cp012-b` (second dev spawn on the same task after a re-brief).
