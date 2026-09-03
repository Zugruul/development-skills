---
tags: [review, testing, verification]
paths: ["**"]
strength: 1
source: "PR#127 MEM-003 retro"
graduated: false
created: 2026-07-18
---

For any "X must happen after Y in a document/file" ordering claim in a test, verify the assertion mechanism at TWO levels, neither alone is sufficient: (a) SYNTHETIC minimal input where you control both the pass and fail case, to confirm the mechanism itself is sound in isolation; (b) the REAL artifact, to confirm the mechanism's output matches what you independently observe (e.g. `grep -bo` for byte offsets) about the actual file. Synthetic-only can validate a mechanism that happens not to apply to the real file's structure; real-only can pass by coincidence without proving the check would actually catch a regression. The cheapest version of level (b): temporarily mutate the real file to swap the order, rerun the test, confirm it goes RED, then revert -- tracing the code by eye only tells you the assertion would pass on the CURRENT file, not that it is genuinely order-sensitive.

Recurrence (MEM-003 review, two independent reviewers converged on this): one reviewer swapped the Archive/Triage step order in retrospective/SKILL.md, reran the test section, confirmed the expected FAIL, reverted; a second reviewer separately verified the `${VAR%%pattern*}` byte-offset idiom on synthetic strings AND cross-checked real byte offsets via `grep -bo` against the actual file.

This generalizes [[verify-guard-regex-on-real-artifact]] to non-regex assertion idioms (string-offset comparisons, ordering checks).

Related: [[verify-guard-regex-on-real-artifact]] [[trace-boundary-operators-by-hand]]
