---
tags: [review, edge-cases, text-generation]
paths: []
strength: 1
source: "#165 review (reviewer-sw165)"
graduated: false
created: 2026-07-15
---

For a string-manipulation bugfix (idempotency, formatting, parsing), verify correctness by tracing every plausible input shape by hand against the actual diff lines (not just re-running the test suite) — fresh input, marker-only input, marker-without-expected-separator, no-marker input. This catches silent data-loss edge cases the test author may not have written a case for.
