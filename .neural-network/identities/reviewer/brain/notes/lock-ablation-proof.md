---
tags: [review, concurrency, tests]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "PR-close #314 r2"
graduated: false
created: 2026-07-22
---

When a review reproduces a concurrency bug, the fix round must ship a regression test whose discrimination is proven by ABLATION (replace the lock with a nullcontext in a scratch tree — exactly the guarded checks fail). Both dev and reviewer ablated independently on the chat-lock fix; treat lock-ablation as the standard proof for serialization fixes.

Related: [[fixture-must-reach-fixed-path]] [[write-site-classification-sweep]]
