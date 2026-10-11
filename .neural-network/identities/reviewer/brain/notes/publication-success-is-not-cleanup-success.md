---
tags: [atomicity, filesystem, review]
paths: ["plugins/remote-compute/**"]
strength: 1
source: "issue526 review round1"
confidence: direct
graduated: false
created: 2026-10-11
last-touched: 2026-10-11
---

## Publication is the commit point

- Exercise failure after the final artifact becomes visible, not only failed writes before publication.
- Once exclusive publication succeeds, temporary-file cleanup failure must preserve success and the artifact report, with a separate cleanup warning.
- Before publication, preserve the original failure even if cleanup also fails. Never delete an existing or committed artifact to make the result look simpler.

Related: [[reports-are-not-the-code]] [[confirm-named-scope-exclusions-respected]]
