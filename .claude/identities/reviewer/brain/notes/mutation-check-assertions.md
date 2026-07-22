---
tags: [review, tests, mutation, verification]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "PR-close #302 review"
graduated: false
created: 2026-07-22
---

To prove error-message assertions discriminate, mutate the implementation (swap the specific message for a generic one), re-run the section, confirm the exact dependent checks fail, then restore and git-diff-verify clean. Cheap, decisive, and catches would-pass-on-any-error test sections that reading alone cannot.

Related: [[import-and-probe-python-library]]
