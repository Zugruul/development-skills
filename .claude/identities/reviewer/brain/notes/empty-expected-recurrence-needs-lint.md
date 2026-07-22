---
tags: [review, tests, vacuous, lint]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "PR-close #307 (3rd recurrence)"
graduated: false
created: 2026-07-22
---

The empty-expected vacuous check() pattern has now shipped in three consecutive new test sections (zero-noise, leftover-tmp) despite a minted lesson — a knowledge-injection ceiling: briefs cannot reliably prevent a syntactic footgun. The durable fix is mechanical (check() warns/fails on empty expected, or a check_empty helper) — tracked as a backlog item; until it lands, EVERY new-section review must sweep for empty-expected as a standing step.

Related: [[check-empty-expected-vacuous]] [[fixture-must-reach-fixed-path]]
