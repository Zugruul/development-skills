---
tags: [review, verification, robustness]
paths: ["**"]
strength: 1
source: "PR#126 MEM-002 retro"
graduated: false
created: 2026-07-18
---

When a function takes a filter/threshold parameter, probe the categories of input the spec is SILENT on (malformed values, empty/edge directory or collection contents) even when no test requires it and nothing looks suspicious. Silence in a spec is not a guarantee of good behavior -- it is an unstated risk, and it is exactly where footguns hide, precisely because nobody thought about it enough to write a test for it. The check is cheap (a couple of ad-hoc CLI invocations against the real command) so it is worth doing before every approval, not reserved for cases that look risky.

Recurrence (MEM-002 review): manually ran `archived --since foo` and `archived --since 2026` (malformed, non-YYYY-MM values) against a live repo and confirmed graceful no-crash/empty-output behavior, and manually placed a stray non-.yaml file in the archive dir to confirm the glob filter does not choke on it -- neither was required by any test or spec sentence, both were free, both confirmed the implementation degrades safely rather than crashing.

Related: [[trace-boundary-operators-by-hand]]
