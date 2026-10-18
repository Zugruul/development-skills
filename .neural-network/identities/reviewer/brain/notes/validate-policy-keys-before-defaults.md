---
tags: [review, config, validation, defaults]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "development-skills#238 independent review round 1; e0cdf67 RED, 0dffb16 fix"
confidence: direct
graduated: false
created: 2026-10-18
last-touched: 2026-10-18
---

## Rule
Reject unknown keys in a policy mapping before applying defaults for omitted fields.
A misspelled enable key differs from a valid mapping that omits it; checking value
types alone can silently select the disabled default.

## Verification
Exercise the real write boundary with both a misspelled key and a valid omitted-key
control. Assert refusal leaves external state unchanged and retains queued work,
then correct the settings and prove the same operation succeeds.

Related: [[copied-precedent-needs-fresh-verification]] [[reproduce-before-verdict]]
