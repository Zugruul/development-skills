---
tags: [briefing, git, concurrency]
paths: ["**"]
strength: 1
source: "dev-cdx031 woke up long after #188 was finished by the orchestrator; the shared checkout had since moved to #234's branch -- correctly investigated and stood down instead of committing blind"
graduated: false
created: 2026-07-20
---

This session's subagents share a single working directory (no per-lane worktree isolation, methodology.maxInProgress-driven sequential model) -- the orchestrator can and does check out a DIFFERENT branch for a later task while an earlier task's subagent is still silently running/delayed. A subagent that wakes up after a long gap must verify its own branch/task state (git branch --show-current, git log for its own expected commits) BEFORE touching anything, not assume the checkout it started in is still pointed at its task -- committing/pushing blind onto a repointed shared checkout could corrupt a different task's in-progress work. dev-cdx031 did this correctly here: investigated, found the checkout had moved to #234's branch, and stood down without touching anything.

Related: [[finish-unresponsive-subagents-work-on-behalf]]
