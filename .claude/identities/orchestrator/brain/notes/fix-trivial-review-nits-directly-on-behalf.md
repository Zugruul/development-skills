---
tags: [review, merge, efficiency]
paths: ["**"]
strength: 1
source: "PR#232 (MEM-023, #136) -- fixed a one-line docstring inaccuracy myself via identity.sh on-behalf dev instead of re-briefing dev-mem023"
graduated: false
created: 2026-07-19
---

When a reviewer flags a one-line, zero-risk correction (e.g. an inaccurate docstring comment, not a logic bug), the orchestrator can fix it directly on-behalf of the dev identity (identity.sh on-behalf dev --co reviewer) rather than spinning up another dev-agent round trip -- cheaper for the loop and appropriate for genuinely mechanical, low-risk fixes. Reserve the full re-brief round for anything touching actual logic/tests/behavior, where independent implementation judgment matters.

Related: [[check-stray-worktrees-before-branch-ops]]
