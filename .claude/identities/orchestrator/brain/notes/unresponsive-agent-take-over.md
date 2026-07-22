---
tags: [subagents, orchestration, on-behalf]
paths: ["**"]
strength: 1
source: "PR-close #302"
graduated: false
created: 2026-07-22
---

When a subagent ignores two concrete-command nudges, stop waiting: verify its written work yourself (run the full gate, diff the red-to-head test changes for weakened assertions), then record it on-behalf (committer=orchestrator, author=dev, per auto-review rule b) and proceed to review. The brief framing line alone did not prevent the stall — the take-over protocol, not more nudging, is what keeps the loop moving. Cap: two nudges, then act.

Related: [[idle-agent-is-not-done]] [[brief-out-of-scope-failure-line]]
