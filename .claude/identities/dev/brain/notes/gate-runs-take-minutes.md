---
tags: [tooling, gate, monitors]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: ""
confidence: direct
learned-from: 481
graduated: false
created: 2026-07-28
last-touched: 2026-07-28
---

This repo's full suite (run-tests.sh, and gate.sh which chains it with shellcheck + plugin validate) takes several minutes, not one or two. When waiting on it: default Monitor/timeout budgets to 10+ minutes, and never infer "almost done" from a section header in the output — section names are not ordered by proximity to the end. Check actual process liveness (pid) instead of reading progress tea leaves. Two idle-looking stalls in one task were exactly this optimistic time-budgeting, not stuck processes.
