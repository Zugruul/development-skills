---
tags: [testing, review]
paths: []
strength: 2
source: ""
learned-from: loop-feedback task-34
graduated: false
created: 2026-07-07
---

For a mechanical refactor whose risk is silent loss (test-suite splits, data migrations, config restructures), define the invariant as a comparable artifact — the SET of check-names, row counts, a golden output — and diff pre vs post to prove nothing was dropped. "The suite still passes" is necessary but NOT sufficient when the suite itself is what's being restructured. The run-tests.sh split proved zero loss via `comm -23` of main-vs-split check-names = 0. Related: [[prove-flakiness-fix-on-baseline]], [[reproduce-findings-two-pass]].
