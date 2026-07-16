---
tags: [process, stalled-agent, infra]
paths: []
strength: 1
source: "CDX-053 (#202) -- two consecutive dev-agent spawns stalled on a mechanical commit+push step"
graduated: false
created: 2026-07-16
---

When a spawned dev subagent goes idle 2-3 times in a row with zero progress on a task you've already confirmed is nearly done (content verified correct, just needs commit+gate+push), don't keep re-nudging the same stuck agent -- spawn a fresh one with the exact current state described (uncommitted diff location, what's already verified). If the FRESH agent also stalls identically, that's a signal of an environment/infra issue rather than agent competence -- at that point, finishing already-authored-and-verified mechanical steps (commit/gate/push) yourself is reasonable and does not violate the worktree->dev-agent->reviewer discipline, since the actual engineering was already done by a real dev agent; only route the result through independent review before merging, same as any other change.
