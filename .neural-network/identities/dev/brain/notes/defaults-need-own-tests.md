---
tags: [tests, constants, invariants]
paths: ["plugins/spec-workflow/**"]
strength: 1
source: "PR-close #311 review r2"
graduated: false
created: 2026-07-22
---

Default constants documented as load-bearing invariants (budget sums, headroom, cap keys) need their OWN suite assertions importing the real values — tests that always pass explicit overrides leave defaults entirely unguarded (a 10x default blowout stayed green). Rule: if a docstring calls a constant relationship deliberate, a test must assert that relationship.

Related: [[mutation-check-assertions]] [[fixture-must-reach-fixed-path]]
