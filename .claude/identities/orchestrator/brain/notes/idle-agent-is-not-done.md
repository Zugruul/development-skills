---
tags: [subagents, verification, orchestration]
paths: ["**"]
strength: 1
source: "PR-close #301"
graduated: false
created: 2026-07-22
---

An idle notification from a subagent is a claim of availability, not completion — check its worktree (git log origin/main..HEAD + git status) before treating the task as delivered. Twice in one task the work was finished but UNCOMMITTED at idle; a one-line nudge naming the exact missing artifact (commit with identity flags, gate run, report) resumed it in under a minute both times.

Related: [[brief-out-of-scope-failure-line]]
