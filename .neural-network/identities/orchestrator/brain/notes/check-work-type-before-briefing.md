---
tags: [briefing, work-type, process]
paths: []
strength: 1
source: "PRV-001 (#167), caught after PR #172 already opened"
graduated: false
created: 2026-07-15
---

A dev-agent brief written from the default implement-task template opens a GitHub PR unconditionally -- always check project.yaml's work.type BEFORE briefing: under work.type:local no PR should ever be opened (review = git diff, approval = issue comment, merge = local squash). Missed this once (PRV-001 got a real PR under a repo configured for local delivery) -- caught late, not fatal, but should be a brief-time check, not a post-hoc fix.
