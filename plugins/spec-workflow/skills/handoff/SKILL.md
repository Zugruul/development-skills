---
name: handoff
description: Writes a handoff document — board snapshot, work done this session, running state, how to resume, gaps/blockers. Use at a loop checkpoint, end of a working session, 'write a handoff', or when pausing the build loop.
---

# Handoff

Write to `<cfg:paths.handoffDir>/<YYYY-MM-DD-HHMM>.md` (default `docs/handoffs/`; convert relative dates to absolute). Gather state first:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/board.sh" list | sort
bash "${CLAUDE_PLUGIN_ROOT}/scripts/board.sh" list "In progress"
```

## Contents (all six, in order)
1. **Board snapshot** — counts per status; anything *In progress* (should be ≤ `methodology.maxInProgress`) with its branch/PR.
2. **Done this session** — tasks moved and to which status; PR links; human comments answered.
3. **Running state** — dev stack up or down (see `dev-up`), port-forwards, background jobs.
4. **How to resume** — `git status`, current branch, next `board.sh next` pick.
5. **Gaps / blockers** — anything needing a human (secrets, credentials, decisions), including unanswered issue comments.
6. **Checkpoint reason** — why the loop stopped (flag file contents / backlog empty / blocked / human requested).

Commit the handoff. Resume later with `/loop /spec-workflow:build-next`.
