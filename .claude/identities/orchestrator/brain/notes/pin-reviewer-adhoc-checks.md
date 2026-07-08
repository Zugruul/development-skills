---
tags: [review, orchestration, tests]
paths: ["plugins/spec-workflow/**"]
strength: 1
source: "#53 retro (both roles)"
graduated: false
created: 2026-07-08
---

A reviewer's ad-hoc adversarial verification vanishes when the review session ends — before merging, send one cheap pinning round: the dev commits the reviewer's hand-probed cases as fixtures/assertions (green immediately, noted as such in the commit message). Uncommitted verification is coverage that expires.

Related: [[pre-diagnose-before-brief]] [[no-change-claims-need-interaction-flags]]
