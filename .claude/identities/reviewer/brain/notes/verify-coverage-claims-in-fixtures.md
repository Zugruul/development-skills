---
tags: [review, coverage, tests]
paths: []
strength: 1
source: "Zugruul/development-skills#254"
confidence: direct
learned-from: GL-013 review retro
graduated: false
created: 2026-07-21
last-touched: 2026-07-21
---

Never trust a test file's own comment about what other suites cover — read what the referenced fixtures actually construct. A comment claimed budget-boundary interaction was 'covered by the tier-downgrade suites staying green', but those fixtures never set confidence/outcomes so they could not exercise the new longer headers. Grep the claimed-coverage suites for the relevant setup calls; the tell is in the fixture setup, not the assertions.
