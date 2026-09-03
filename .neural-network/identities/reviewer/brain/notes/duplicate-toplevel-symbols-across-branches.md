---
tags: [review, integration, javascript]
paths: ["plugins/spec-workflow/templates/**"]
strength: 1
source: "batch-3 blocker"
graduated: false
created: 2026-07-26
last-touched: 2026-07-26
---

When reviewing concurrently-open branches of the same file, grep each branch's NEW top-level identifiers against the sibling diffs: duplicate function/const names merge without textual conflict when far apart, and in browsers the later declaration hoists over the earlier — signature mismatch becomes silent data scrambling, worse than a red test. Found this way: emitVoiceSpan (050x051).

Related: [[trial-merge-and-run-integrated-tree]]
