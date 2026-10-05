---
tags: [testing, cli]
paths: []
strength: 1
source: "post-merge breakage of brain.sh, PR#4"
graduated: false
created: 2026-07-07
---

Exercise the DEFAULT invocation of every new CLI (no flags) — test fixtures that always pass optional flags leave the most-used path uncovered. brain.sh shipped broken flag-less through two review rounds.
