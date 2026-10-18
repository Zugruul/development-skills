---
tags: [review, ui, lifecycle]
paths: ["plugins/spec-workflow/templates/**"]
strength: 1
source: "Task #523 round2 close"
confidence: direct
graduated: false
created: 2026-10-18
last-touched: 2026-10-18
---

## Enter the state through real code

A fixture that manually constructs a new in-flight turn cannot prove the real assistant switch releases the old dispatch and timer. Invoke the actual transition function, then start the incoming turn before settling the outgoing request.

## Check symmetric exits

- Deliver stale text, success and error after switching; none may alter incoming ownership.
- Rebuild or detach the live row before both success and failure.
- Assert visible errors, queue progress, timer cleanup and scroll retention in the current DOM.

Related: [[reports-are-not-the-code]] [[reproduce-before-verdict]]
