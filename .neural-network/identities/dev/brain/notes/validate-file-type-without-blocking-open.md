---
tags: [filesystem, security, async, testing]
paths: ["plugins/spec-workflow/scripts/assistant/**"]
strength: 1
source: "Issue #348 review repair: FIFO destination blocked before fstat"
confidence: direct
graduated: false
created: 2026-10-18
last-touched: 2026-10-18
---

## Boundary
Opening an existing output path may block before a regular-file check can run. Use a nonblocking open and inspect the opened descriptor; refuse nonregular files and symlinks before reading.

## Evidence
Place a FIFO at the task destination. Prove bounded refusal, temporary-file cleanup, and subsequent worker availability, not merely the exception type.

Related: [[deterministic-repro-fast]]
