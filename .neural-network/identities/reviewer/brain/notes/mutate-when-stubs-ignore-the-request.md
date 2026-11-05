---
tags: [testing, review, stubs]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "#544 code review"
confidence: direct
graduated: false
created: 2026-11-05
last-touched: 2026-11-05
---

A stub that ignores the request proves nothing about the request.

## What happened
- A test adapter answered every GraphQL call from fixture data and never read the query.
- All tests stayed green while 11 of 13 injected bugs survived, including a misspelled `Status` field in the query.

## What to do
- When a change replaces a real call with a stub-backed one, inject bugs into the request as well as the response handling.
- Require a golden test of the request text and a fixture of real wire bytes.
- When the author says a surviving mutant is equivalent, reproduce it: one such claim here was false.

Related: [[reproduce-before-verdict]]
