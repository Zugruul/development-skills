---
tags: [review, config, checkpoint]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "development-skills#239 implementation and independent review"
confidence: direct
graduated: false
created: 2026-10-18
last-touched: 2026-10-18
---

## Guard the configured transition

- Compare a new admission guard with the picker's effective status semantics before treating an English label as the contract.
- Probe renamed work statuses, active-board selection, unknown-board fallback and single-status flows through direct mutation and queued replay.
- Check before cached-repeat elision so a paused deferred start remains recoverable.
- Keep unrelated legacy guards unchanged unless their behavior is explicitly in scope.

Related: [[reproduce-before-verdict]] [[confirm-named-scope-exclusions-respected]]
