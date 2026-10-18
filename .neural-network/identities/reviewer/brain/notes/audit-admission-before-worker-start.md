---
tags: [review, audit, queue, privacy]
paths: ["plugins/spec-workflow/scripts/assistant/**"]
strength: 1
source: "Issue #348 round 2: saturated task queue omitted the refusal outcome"
confidence: direct
graduated: false
created: 2026-10-18
last-touched: 2026-10-18
---

## Review boundary
Worker audit tests cannot establish evidence for requests rejected before task creation. Drive the real caller with a full task queue and inspect the refusal event.

## Required checks
- Verify capability and operation attribution, turn/command correlation, and sanitized fields.
- Prove no task or remote effect was created.
- Saturate the trace queue separately: pre-worker evidence remains best effort and must not block the conversation.

Related: [[tested-through-which-caller]] [[reproduce-before-verdict]]
