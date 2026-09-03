---
tags: [review, verification, boundaries]
paths: ["**"]
strength: 1
source: "PR#126 MEM-002 retro"
graduated: false
created: 2026-07-18
---

For any comparison operator gating inclusion/exclusion in a diff (date/version/threshold filters, `<` vs `<=` at a boundary), pick concrete boundary-adjacent values and TRACE THE ACTUAL OPERATOR BY HAND instead of pattern-matching the code to what the docstring/spec says it should do. Reading code and confirming it matches stated intent are different acts -- an off-by-one on which side of the operator an inclusive/exclusive boundary lands reads as correct at a glance in both directions, and a docstring saying "at/after" is not itself evidence the code implements ">=" rather than ">".

Recurrence (MEM-002 review, x2 independent passes): both reviewers hand-traced `month_match.group(1) < since` with concrete months (2026-05/06/07 against --since=2026-06) before trusting the docstring's "at/after" wording -- it happened to be correct, but tracing was the only way to KNOW that rather than assume it.

Related: [[equality-guards-invite-ordering-probes]]
