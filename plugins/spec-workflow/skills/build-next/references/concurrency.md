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

## The merge dance (`serialDelivery: true` + `maxInProgress: N>1`, #423)

Plain `maxInProgress: N` alone lets N lanes run AND merge independently — fine
when nothing needs main to stay fresh underneath it. Turning `serialDelivery`
on **as well** makes the two knobs one coherent mode instead of cancelling
each other out: N lanes of *implementation* throughput, but merges themselves
serialize strictly ONE at a time — the **synchronization dance**. This keeps
serialDelivery's original promise (every merge lands on a main it actually
saw) without giving up maxInProgress's lane width.

**Slots are COUNT-based, not identified.** A slot is occupied from the moment
a task is PICKed until it is MERGED — both *In progress* and *In review*
count toward `maxInProgress`. There are no slot ids and no side-car state
file: the board itself (current item statuses) is the sole source of truth
for how many slots are occupied. `next.py` computes `occupied = count(In
progress) + count(In review)` and allows a new PICK while `occupied <
maxInProgress`; once occupied reaches the limit, an In-progress lane is
always the actionable next step (`RESUME`), and only when EVERY occupying
task is In review (nothing left to resume) does it print `WAIT: merge-dance`.

**Dance order is FIFO by In-review entry, oldest first** — deterministic,
computed from the merge queue `next.py` always prints when `serialDelivery`
is on and anything is In review (issue numbers, ascending — the most
deterministic ordering field `gh project item-list --format json` actually
offers; it carries no per-item timestamp at all).

### The dance lock

Two orchestrator sessions must never run the dance at once. Before touching
ANY merge under this mode, acquire a lock:
1. `mkdir .claude/merge-dance.lock` (atomic — the FIRST session to succeed
   holds the lock; a second `mkdir` on an existing directory fails, meaning
   "someone else is dancing right now").
2. On success, immediately write an owner file inside it —
   `.claude/merge-dance.lock/owner` — with your session identity and a
   fresh timestamp (`date -u +%FT%TZ`), so a staleness check (next) can tell
   whose lock it is and how old.
3. **Staleness / steal rule:** if `mkdir` fails (lock already held), read the
   owner file's timestamp. If it is **more than 25 minutes old with no
   merge activity since** (no new commit/board move attributable to the
   dance in that window), treat the lock as abandoned — a crashed or
   orphaned session — and steal it: remove the stale lock directory and
   `mkdir` your own. Otherwise, wait/back off and retry; do not force past a
   live lock.
4. Release the lock (`rm -rf .claude/merge-dance.lock`) as the LAST action of
   each completed (or explicitly abandoned) dance step — never leave it held
   across an idle/handoff boundary.

### Running one dance step

While the merge queue is non-empty and you hold the lock:
1. Pick the **OLDEST** In-review task from the queue (issue-number ascending,
   per the FIFO rule above).
2. `cd <its worktree/branch> && git fetch origin && git rebase origin/<mainBranch>`
   — rebase the branch onto the CURRENT main tip. If commits from an earlier,
   already-landed dance step show up as already-applied during the rebase
   (their content squashed into a prior merge commit), that's expected —
   skip/drop them as `git rebase` naturally does when the tree already
   matches; never re-apply a change main already carries.
3. Re-run the recorded gate on the rebased tree (`gate.sh`) — a rebase
   invalidates the previous recorded pass; never merge on a stale recording.
4. Squash-merge with role attribution (`identity.sh on-behalf ...` recipe,
   `auto-review.md` §Commit identities) and apply the semver bump
   (`semver.sh apply-head`) into the same squash commit — same mechanics as
   any other merge, just gated by this lock.
5. Move the board item to *QA*, fold its spec delta, announce the merge to
   every other live lane (existing auto-review §4 announce — a merge
   invalidates the others' merge-bases, though NOT their in-flight work).
6. Release the lock, then re-check the queue: if still non-empty, loop back
   to step 1 (re-acquire the lock — do not hold it idle between steps).

**In-progress lanes are NEVER force-rebased mid-flight by someone else's
dance.** A lane still being implemented rebases onto main at its OWN dance
time — i.e. once IT reaches In review and becomes the oldest queued item —
never earlier, and never as a side effect of another lane's merge. Only the
lane's own dev agent/orchestrator touches its branch while it's In progress.
