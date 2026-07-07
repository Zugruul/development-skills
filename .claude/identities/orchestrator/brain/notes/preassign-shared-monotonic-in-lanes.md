---
tags: [concurrency, orchestration]
paths: []
strength: 1
source: ""
learned-from: loop-feedback 2026-07-07 task-18
graduated: false
created: 2026-07-07
---

When parallel lanes each bump a shared monotonic value (plugin version, migration number), collision is CERTAIN. Pre-assign each lane a distinct value up front (lane N takes base+N), or defer the bump to a single post-merge step — don't pay a guaranteed rebase per concurrent lane. Related: [[frozen-contracts-parallel-prs]], [[decide-oqs-before-brief]].
