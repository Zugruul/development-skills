---
tags: [review, guards, identity, config]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "#240 independent review round 1 and verified round 2 fix"
confidence: direct
graduated: false
created: 2026-10-18
last-touched: 2026-10-18
---

## Follow the identifier used by the write

When a guard classifies a display label but the mutation writes a resolved identifier, test two labels resolving to the same identifier. A permitted-looking alias can select an unguarded branch while changing the protected state.

## Prove the mismatch

- Run the normal configuration validator to establish what callers can supply.
- Use a stateful fake whose mutation follows the identifier, not the requested label.
- Reject locally ambiguous mappings or classify the resolved destination before choosing a bypass; distinguish this from unverifiable external metadata.

Related: [[reports-are-not-the-code]] [[distinguish-missed-vs-uncatchable-findings]]
