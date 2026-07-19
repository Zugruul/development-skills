---
tags: [review, verification]
paths: ["**"]
strength: 1
source: "PR#227 (CDX-014, #184) -- verified sessionHostBreakdown's single-host output reduces exactly to the pre-PR expression by reading both side by side, not just trusting the test"
graduated: false
created: 2026-07-19
---

When a diff claims "existing behavior unchanged in the common case" (e.g. a new optional parenthetical that's empty in the default case), don't just trust a passing test -- read the old and new string-building expressions side by side and reduce the new one algebraically for the default-case input, confirming it collapses to literally the old expression. A test can pass while still being subtly different (e.g. an extra space, a conditional that's technically equivalent but not byte-identical); reading the expressions directly catches what a test's specific fixture might not exercise.

Related: [[verify-tdd-empirically-when-log-is-thin]]
