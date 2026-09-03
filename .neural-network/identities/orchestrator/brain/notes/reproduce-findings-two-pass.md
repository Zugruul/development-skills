---
tags: [review, orchestration]
paths: []
strength: 1
source: ""
learned-from: loop-feedback 2026-07-07 item 2
graduated: false
created: 2026-07-07
---

Separate spec-compliance review from adversarial code-quality review, and brief reviewers to REPRODUCE findings (run the crash, craft the traversal escape, occupy the port) rather than read-only inspect. In one iteration this caught a permission crash, a lying startup message, routing corruption on duplicate timestamps, and a path-containment escape — all missed by the implementing agent and the suite. Related: [[smoke-test-is-not-review]].
