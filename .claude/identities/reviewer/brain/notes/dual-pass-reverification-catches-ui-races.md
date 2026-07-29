---
tags: [review, process, ui, races]
paths: []
strength: 1
source: "loop-feedback 2026-07-29 (485 close)"
confidence: direct
graduated: false
created: 2026-07-29
last-touched: 2026-07-29
---

On UI state machines (selection mirrors, polling loops, async switch flows), run TWO independent review passes -- one against the spec's acceptance intents, one for code quality/races -- and REQUIRE a re-verification round where the reviewer reads the fix sites in the tree rather than trusting the fixer's mapping. On one feature both passes together surfaced 19 real findings (three high-severity races) after the implementer believed it done, and the re-verification rounds caught residuals the fix batch itself introduced.
