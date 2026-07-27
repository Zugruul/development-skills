---
tags: [review, completeness, sweep]
paths: ["plugins/spec-workflow/**"]
strength: 1
source: "PR-close #437 review"
graduated: false
created: 2026-07-27
last-touched: 2026-07-27
---

When a fix claims to cover "both sites", grep for the third before approving. The #437 sweep for remaining `not in sys.path` guards came back clean (two other files were already converted), but that sweep is the difference between approving a complete fix and leaving a twin bug dormant.

Related: [[reproduce-before-verdict]]
