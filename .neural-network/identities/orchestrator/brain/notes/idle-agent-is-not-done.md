---
tags: [subagents, verification, orchestration]
paths: ["**"]
strength: 3
source: "PR-close #303 recurrence"
graduated: false
created: 2026-07-22
---

An idle notification from a subagent is a claim of availability, not completion — check its worktree before treating the task as delivered. Third consecutive task with a commit-boundary stall; this time ONE concrete-command nudge resumed it (fix committed within minutes). The stall pattern is structural (agents treat checkpoints as stopping points); the cheap mitigation is the immediate worktree check + concrete-command nudge, escalating per [[unresponsive-agent-take-over]] only after two ignored.
