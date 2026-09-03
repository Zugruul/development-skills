---
tags: [testing, tdd, verification]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "MEM-031 fix round, 2026-07-18"
graduated: false
created: 2026-07-18
---

When fixing a review-flagged vacuous/missing test assertion, don't just trust the new assertion is correct — deliberately re-break the underlying code the same way the original bug would have manifested, confirm the new/fixed assertion actually FAILS against that broken version, then restore the real implementation. This is cheap (a few lines, temporary) and is the only way to be sure a 'fixed' test isn't just a different flavor of vacuous.

Related: [[verify-guard-regex-on-real-artifact]]
