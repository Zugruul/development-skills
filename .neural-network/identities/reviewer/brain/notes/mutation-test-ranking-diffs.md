---
tags: [review, verification, tests, ranking]
paths: ["plugins/spec-workflow/tests"]
strength: 1
source: "Zugruul/development-skills#251"
learned-from: GL-010 review retro
graduated: false
created: 2026-07-21
last-touched: 2026-07-21
---

For any diff adding a numeric/ranking effect, mutation-test it: comment out the core effect (e.g. the multiplier call sites), rerun just that test section, and confirm the expected tests flip to FAIL — tests that do NOT flip reveal coverage gaps. Then restore from backup and verify 'git diff --stat' against base matches the pre-mutation state. Ordering/relative assertions are the easiest to satisfy accidentally; ~10s of mutation beats any plausibility argument.
