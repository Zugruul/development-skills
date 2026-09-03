---
tags: [process, concurrency, review]
paths: []
strength: 1
source: "#399/#400 retro"
graduated: false
created: 2026-07-25
---

When the human demands direct implementation mid-lane: (1) STOP the dev agent with TaskStop BEFORE touching the tree — a stand-down message alone is async and the #399 lane kept editing under the orchestrator, producing interleaved mixed-generation state that had to be re-surveyed file-by-file; (2) build on the lane's committed+uncommitted work rather than redoing it; (3) the skipped pre-merge review becomes a POST-merge sweep on main over the whole direct-mode range — verdicts recorded on the issues, BLOCKER/MAJOR as immediate fix commits, MINOR/NIT filed as backlog items; (4) every deviation stated on the issue at merge time. Links: [[prescription-ack-closes-round-cap]], [[live-tweaks-as-brief-amendments]].
