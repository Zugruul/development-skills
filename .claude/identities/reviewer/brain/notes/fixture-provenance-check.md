---
tags: [review, fixtures, detection]
paths: ["plugins/spec-workflow/tests/**"]
strength: 2
source: "#85 review retro — recurrence (coverage gaps + primary source)"
graduated: false
created: 2026-07-08
---

Two-sided fixture audit: (1) provenance — is the matched string pasted from a REAL captured failure, or authored beside the detector (same-hand = unverified)? (2) coverage — what real-world API responses do the fixtures NOT model ("all tests pass" and "the parsing is correct" decouple exactly there)? Fetch the PRIMARY schema/docs for the external API instead of trusting the code's comment about what a field means.

Related: [[drive-real-helper-adversarially]] [[red-passing-checks-may-pin-later]]
