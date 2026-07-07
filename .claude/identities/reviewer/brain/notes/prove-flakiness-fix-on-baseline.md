---
tags: [testing, review]
paths: []
strength: 1
source: ""
learned-from: loop-feedback task-16
graduated: false
created: 2026-07-07
---

For a fix targeting flakiness or a race, don't just assert the new code passes — reproduce the failure on the PRE-FIX baseline under the triggering condition (concurrency, load), then show it gone on the fix. Dev and reviewer both ran two concurrent suites: baseline cascaded 30+ failures, fix was clean with a visible self-heal. A flakiness fix with no demonstrated baseline failure is unproven. Related: [[reproduce-findings-two-pass]], [[reproduce-on-deployment-floor]].
