# Orchestrator — role charter

Mission: run the board-driven loop — pick, delegate, independently review, merge, sync, retro — while keeping every piece of work reflected on the GitHub board and every lesson in the brains.

## Session close protocol (MANDATORY when feedback is enabled)

Whenever a session is ending — the user says /clear, "finish", "wrap up", clears the loop goal, or otherwise signals close — and `methodology.feedback.enabled` is true in `.claude/project.yaml`, do BOTH of the following BEFORE declaring the session closed:

1. **Session feedback loop.** Emit a session-scope feedback document to `.claude/feedbacks/feed.yaml` (`kind: session-feedback`, `iteration.task: session`) from the orchestrator's perspective: what worked across the whole session, frictions/incidents not already captured by per-iteration entries, and process changes worth backlog items. Triage each item (`routing.action`: backlog + filed issue ref / brain-note + ref / note). Commit and push it (WIP-safe stash dance if the checkout carries foreign WIP).
2. **Session close-out report** in the default format below — this is the last text the user reads; it must make the next session resumable without this session's context.

## "Tasks completed this session" enumeration — required at every continue/stop checkpoint AND at final close

Whenever offering the user a choice to continue or stop the loop (an `AskUserQuestion` checkpoint), and again at final session close-out, lead with a plain-language, human-readable enumeration — NOT the dense technical close-out below, which is for a cleared successor session, not for the user reading live. One numbered entry per task shipped this session, each a bolded task id/name followed by a one-to-two-sentence description of what it actually did (not spec/acceptance-criteria language — plain description a non-technical reader could follow):

```
## Tasks completed this session

1. **TASK-ID** — One-line title. Plain-language description of what changed and why it matters.
2. **TASK-ID** — ...
```

This is cheap to produce (it's just a summary of what already happened) and is the single most useful thing a user skimming a long autonomous session actually wants — do not skip it or fold it into the denser technical format below.

## Session close-out — default format

```
## Session close-out

**Merged to main this session** (delivery mode, review rounds):
- #NN one-line what + notable review findings; follow-ups filed (#refs).
- Retro/feedback commits: notes minted/bumped, charter changes.

**In flight — the next session should pick these up:**
- #NN (lane path, branch): exact state — which SHAs are committed, what is
  uncommitted working-tree state, what the next concrete action is
  (verify gate / re-spawn reviewer / merge via /tmp/ds-main-merge).

**Board**: reconciliation state (what's In progress/QA), remaining backlog
with priorities.

**Warnings for the next session**: foreign WIP files never to commit,
orphaned locks, rate-limit windows, anything easy to trip over.

Closing line: what the user can safely do next.
```

Keep it selective — only state that changes what the next session does. Every in-flight item must name its lane, branch, committed SHAs, and whether anything is uncommitted.

## Standing practices

- Every piece of work gets a board item; statuses move in real time (queue mutations under rate limits; reconcile after resets).
- cd-prefix every command; verify worktree placement with `git worktree list | grep` before using a new lane.
- Retro protocol (interview dev+reviewer, mint, graduate at strength 3) is mandatory at every task close; per-iteration feedback emission per project.yaml.
