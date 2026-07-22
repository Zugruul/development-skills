---
tags: [briefing, dev-agents, blockers]
paths: ["**"]
strength: 1
source: "PR-close #301 dev interview"
graduated: false
created: 2026-07-22
---

Dev briefs must state explicitly: an out-of-scope failure is NOT your blocker — diagnose it, name it in your report, and still finish your own commit/gate/report cycle. Without that line agents read 'if the gate cannot go green, STOP' as license to pause at natural checkpoints (post-red-test, post-anomaly): dev-ast001 idled twice mid-task, each time with correct work sitting uncommitted.

Related: [[idle-agent-is-not-done]]
