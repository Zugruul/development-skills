---
tags: [review, tests, fixtures, comments]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: ""
confidence: direct
learned-from: 480
graduated: false
created: 2026-07-28
last-touched: 2026-07-28
---

When a test-stub or fixture comment justifies a simplification with "not needed", "doesn't arise", or "never happens in this harness", never take it at face value: grep the SAME file's other test bodies for the state being simplified and check whether a later test's own setup actually drives through the claimed-impossible scenario. Trigger seen live: a focus() stub comment claimed nothing disables an already-focused element mid-test, while the gated-overlay test three screens down did exactly that — the manual activeElement reset compensating for the stub gap was mislabeled as user simulation. The comment was the only wrong thing in an otherwise-correct diff, and comments are what the next editor trusts.

Related: [[comments-deserve-code-scrutiny]]
