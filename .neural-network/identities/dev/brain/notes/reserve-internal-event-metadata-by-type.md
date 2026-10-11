---
tags: [observability, queue, compatibility]
paths: ["plugins/spec-workflow/scripts/assistant/observability.py"]
strength: 1
source: "issue-349-review-limit"
confidence: direct
graduated: false
created: 2026-10-11
last-touched: 2026-10-11
---

## Contract
Ordinary event payloads may already contain fields that look internal. Do not identify commit-ack envelopes by key presence alone.

## Implementation
Use a private typed acknowledgement object and validate it before commit callbacks. Preserve ordinary event behavior for scalar and container values using the same key.

## Verification
Queue legacy events with colliding field names and confirm the writer stays alive and persists subsequent events.

Related: [[audit-new-path-parity-before-writing]]
