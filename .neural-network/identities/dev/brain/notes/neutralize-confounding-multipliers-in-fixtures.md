---
tags: [tests, fixtures, ranking, isolation]
paths: ["plugins/spec-workflow/tests"]
strength: 1
source: "Zugruul/development-skills#251"
learned-from: GL-010 retro
source-note: verify-fixture-isolates-intended-path
graduated: false
created: 2026-07-21
last-touched: 2026-07-21
---

A 'useful' outcome dated after the last retro-mark almost always also falls inside GL-003's outcome window, so a decay-reset test granting a useful outcome is confounded with the outcome multiplier. Neutralize the confounder in the fixture (methodology.outcomeMultiplierStep: 0 in its project.yaml) so the assertion isolates the mechanism actually under test.
