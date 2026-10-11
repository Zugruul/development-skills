---
tags: [security, redaction, json, sqlite]
paths: ["plugins/spec-workflow/scripts/assistant/remote_audit.py"]
strength: 1
source: "issue-349-review-limit"
confidence: direct
graduated: false
created: 2026-10-11
last-touched: 2026-10-11
---

## Boundary
Redact before queueing and SQLite writes, including duplicate task and skill events.

## Representations
Check keys and values, encoded keys, escaped quotes, nested serialized JSON, arrays, and structured values embedded in mixed text. Classify fields by their original names before sanitizing keys. Bound traversal and retain useful nonsecret text.

## Evidence
Inspect raw live WAL and checkpointed database bytes, not only rendered output. A small generated matrix can expose sibling paths missed by individual reproductions.

Related: [[audit-new-path-parity-before-writing]] [[batch-red-across-surfaces]]
