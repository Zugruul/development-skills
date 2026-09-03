---
tags: [python, resources, cleanup]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "PR-close #315 review r2"
graduated: false
created: 2026-07-22
---

Resource-owning objects (servers, temp dirs) must be constructed BEFORE the try whose finally releases them — construction inside the try makes the finally NameError on a failing __init__, masking the real error and leaking siblings. Consistency matters: two functions in one file had it right and two wrong; sweep a file for the pattern once one instance is found.

Related: [[partial-results-honesty]] [[lock-key-canonicalize]]
