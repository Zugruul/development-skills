---
tags: [tests, bash, lifecycle, ports]
paths: ["plugins/spec-workflow/tests/_lib.sh"]
strength: 1
source: "issue-349-review-limit"
confidence: direct
graduated: false
created: 2026-10-11
last-touched: 2026-10-11
---

## Failure Mode
A port selector called through command substitution runs in a child shell. Mutating its used-port list does not reserve an unbound port in the parent; two sibling draws can collide.

## Fix
Pass already selected sibling ports as explicit exclusions. Bound retries and fail without returning an excluded candidate. Preserve the no-argument interface.

## Verification
Use deterministic equal-seed draws and an exhausted one-candidate range. Bound tests with an existing runtime rather than adding a platform-specific executable.

Related: [[deterministic-repro-fast]] [[bash-test-sections-shared-state]]
