---
tags: [review, tests, coverage]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "PR-close #424"
confidence: direct
graduated: false
created: 2026-07-27
last-touched: 2026-07-27
---

When an existing test has an obvious missing twin on the axis a change introduces (argv-varies-invalidates existed; skill_dir-varies didn't), the gap is usually where the bug lives. A diff that adds tests for the NEW behavior but never varies the new axis is the tell to probe exactly there.
