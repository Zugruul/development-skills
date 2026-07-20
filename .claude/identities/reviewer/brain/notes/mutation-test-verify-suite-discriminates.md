---
tags: [review, testing]
paths: ["**"]
strength: 1
source: "PR#243 (#235) review -- mutated the classifier to always return 'test', confirmed the specific gated test cases flipped to incorrectly passing, proving the suite genuinely discriminates rather than being tautological"
graduated: false
created: 2026-07-20
---

When verifying a new test suite genuinely discriminates (not just "reverting the fix makes it fail," which only proves the tests are non-trivial, not that the CLASSIFICATION LOGIC inside the fix is doing real work), mutate the classification/decision logic itself in an obviously-wrong way (e.g. force every input into one category) and confirm the specific test cases that logic is supposed to gate flip to incorrectly passing. This catches a test suite that only exercises the happy path or trivially-true assertions, which "revert and confirm red" alone would miss.

Related: [[reproduce-claimed-bug-fix-before-and-after]] [[verify-proximity-checks-dont-bleed-into-next-record]]
