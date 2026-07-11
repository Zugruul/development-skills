---
tags: [feedback, yaml, bugs]
paths: ["plugins/spec-workflow/scripts/feedback.py"]
strength: 1
source: "session retro 2026-07-10: feed corruption repair"
graduated: false
created: 2026-07-10
---

The feedback feed broke for EVERY consumer because two records carried a bare hash-ref after a space inside plain YAML scalars — YAML treats " #..." as a comment start, truncating the value and making the continuation lines a parse error. Repaired by converting the affected summary/detail fields to literal blocks. Code fix warranted in feedback.py emit: serialize free-text fields (summary, detail, generalized) as quoted or literal-block scalars unconditionally.
