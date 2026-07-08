---
tags: [review, fixtures, detection]
paths: ["plugins/spec-workflow/tests/**"]
strength: 3
source: "#80 review retro — recurrence (audit the checker itself)"
graduated: true
created: 2026-07-08
---

Three-sided fixture audit: (1) provenance — matched strings pasted from REAL captured failures, never authored beside the detector; (2) coverage — what real inputs do the fixtures NOT model; (3) when the check under review IS a permanent gate: attack the CHECKER with adversarial inputs (empty strings, unvisited constructs) — "0 findings today" says nothing about what a careless future edit slips past forever. Fetch primary schemas/docs over trusting code comments.

Related: [[drive-real-helper-adversarially]] [[red-passing-checks-may-pin-later]]
