---
tags: [review, completeness, concurrency]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "PR-close #304 review r1"
graduated: false
created: 2026-07-22
---

When reviewing an ALL-X-covered claim (all write paths locked, all callers migrated), build your own classification table first: grep every candidate site yourself, classify each (covered / exempt-with-reason / NOT covered), and reconcile against the dev's list. Caught 2 genuine lost-update holes (prune --apply, graduate) that the dev's own sweep missed — the dev's list anchors your reading; an independent sweep is the only thing that finds what it omits.

Related: [[mutation-check-assertions]] [[check-empty-expected-vacuous]]
