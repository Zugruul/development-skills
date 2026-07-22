---
tags: [subagents, stalls, harness, gate]
paths: ["**"]
strength: 1
source: "PR-close #313 dev interview"
graduated: false
created: 2026-07-22
---

Stall root-cause hypothesis (from the one non-stalling dev): the harness auto-backgrounds commands exceeding ~120s, and the full gate takes 2-5 min — agents may lose the thread waiting on a backgrounded gate rather than refusing to commit. Mitigations to test in briefs: instruct devs to run the gate expecting auto-backgrounding (poll the task result explicitly, conclude from exit status), or split the gate (fast section first, full suite once). Distinguish stalled-before-commit from stalled-on-gate before designing the #364 fix.

Related: [[brief-closed-action-set]] [[unresponsive-agent-take-over]]
