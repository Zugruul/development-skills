---
tags: [json, persistence, review]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "#241 retrospective: independently reproduced workflow boundary"
confidence: direct
graduated: false
created: 2026-10-19
last-touched: 2026-10-19
---

## Check the whole persistence cycle

When adding a strict state reader, verify that every successful official write remains readable by that reader. Exercise another task immediately after the write; shared history can spread one malformed record across otherwise independent tasks.

## Numeric conversion matters

Rejecting literal `NaN` and `Infinity` does not reject `1e400`, which Python converts to infinity. Check parsed floats for finiteness, including nested and extra fields, and serialize the complete payload with `allow_nan=False` before opening the destination. Test that rejection preserves existing bytes and does not create an empty log.

Related: [[reports-are-not-the-code]] [[reproduce-before-verdict]]
