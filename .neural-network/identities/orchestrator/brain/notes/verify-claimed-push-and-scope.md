---
tags: [orchestration, verification, git]
paths: ["**"]
strength: 1
source: "retro 2026-07-21 serial-delivery close"
graduated: false
created: 2026-07-21
---

A dev report saying "done and pushed" is a claim: check `git log origin/<branch>..HEAD` (unpushed commits) and diff the report's item list against the actual commit --stat (dropped items) before advancing. In one fix round both failure modes occurred at once — a missing doc surface AND an unpushed commit — caught only by direct inspection.

Related: [[gate-runs-outlive-agent-turns]]
