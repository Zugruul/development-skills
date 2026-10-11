---
tags: [protocol, classification, testing, review]
paths: ["plugins/remote-compute/scripts/remote-compute.py"]
strength: 1
source: "issue-525-review-round-1"
confidence: direct
graduated: false
created: 2026-10-11
last-touched: 2026-10-11
---

## Follow The Producer's Input Domain
A refusal classifier must recognize the complete text the producer can emit. Free-form holder and reason fields may be empty, contain delimiters, or span lines even when ordinary fixtures use one-line strings.

## Test Both Directions
Run the actual producer with these values and prove valid refusals allow only the intended fallback. Separately inject malformed, contradictory and incomplete envelopes and prove they remain uncertain. Exit status alone is not evidence of retry eligibility.

Related: [[reports-are-not-the-code]] [[copied-precedent-needs-fresh-verification]]
