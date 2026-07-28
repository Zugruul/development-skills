---
tags: [tests, node, event-loop]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "PR-close #334"
confidence: direct
graduated: false
created: 2026-07-27
last-touched: 2026-07-27
---

Passing assertions and clean process exit are separate contracts: a harness can print every OK and still hang because an eval'd REAL implementation leaked a live timer (setInterval from an unresolved dispatch) holding Node's event loop open. When a section hangs, extract each harness and run it with a kill-after watchdog; the leak is usually the one case that never resolves its async continuation.
