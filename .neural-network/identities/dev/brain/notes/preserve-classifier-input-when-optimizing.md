---
tags: [security, performance, parsing, compatibility]
paths: ["plugins/spec-workflow/scripts/assistant/remote_audit.py"]
strength: 1
source: "issue-349-r4-differential-verification"
confidence: direct
graduated: false
created: 2026-10-11
last-touched: 2026-10-11
---

## Principle
Optimize token scanning separately from credential classification. A larger matched token must not silently change the key that the original classifier would see.

## Compatibility
Check anchored exact-key rules as well as substring rules. Leading numeric or dash prefixes and an escaped token start can change the first eligible suffix; quoted keys keep their decoded-key semantics.

## Verification
Compare against the complete previous implementation on short inputs, including safe-output parity. Add managed persistence tests that inspect live WAL and checkpointed database bytes. Measure adversarial supported-size inputs with a same-process heartbeat and an owned subprocess deadline.

Related: [[sanitize-structured-credentials-before-storage]] [[batch-red-across-surfaces]]
