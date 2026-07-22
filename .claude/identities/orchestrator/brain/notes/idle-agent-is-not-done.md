---
tags: [subagents, verification, orchestration]
paths: ["**"]
strength: 2
source: "PR-close #302 recurrence"
graduated: false
created: 2026-07-22
---

An idle notification from a subagent is a claim of availability, not completion — check its worktree before treating the task as delivered. Recurred on the very next task after minting: agent idled three times with finished-but-uncommitted work and never resumed; escalation path is [[unresponsive-agent-take-over]].
