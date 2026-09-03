---
tags: [review, verification, tests, brain.py]
paths: ["plugins/spec-workflow/scripts/brain.py", "plugins/spec-workflow/tests/**"]
strength: 1
source: ""
confidence: direct
learned-from: GL-020 #255 review
graduated: false
created: 2026-07-22
last-touched: 2026-07-22
---

Verify structural claims with executable evidence, not code inspection: (a) "shared formatter/code path" → drive the SAME fixture note through BOTH paths and assert the rendered strings are byte-identical (catches matching-but-drifting reimplementations); (b) "read-only" → sha256 the file before/after the run and assert equality, never trust a mutate=False flag; (c) "hand-computed math" → fixture weights chosen so the expected value derives by hand from the documented constant, asserted as a literal number. And always read the key test bodies line-by-line to rule out tautologies (hash-vs-itself, non-empty checks) before crediting the suite — presence of tests is not evidence.
