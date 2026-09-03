---
tags: [tdd, design-docs, scope]
paths: ["**"]
strength: 1
source: "PR#180 CDX-010 retro"
graduated: false
created: 2026-07-19
---

When a design doc states both a general acceptance criterion (e.g. "must not require X to function") AND a stricter literal test-spec paraphrase of it (e.g. "string X must be absent"), and a worked example ELSEWHERE in the same doc violates the stricter paraphrase, treat the acceptance criterion as authoritative and the test-spec bullet as a LOSSY COMPRESSION of it that got over-tightened in the writing -- not the other way around. Resolve by making the constraint PRECISE (not by picking whichever reading is easiest to assert), then test the precise version. Flag the call EXPLICITLY in your report rather than silently picking a reading -- that's what lets the resolution get caught/confirmed fast by review instead of relitigated later.

Recurrence (CDX-010): the design doc's own inline-Claude-note worked example necessarily contained the literal string "AskUserQuestion" (by design, for 7 of 9 skills), directly contradicting its own test-spec bullet ("assert this string is absent from all 9 bodies"). Resolved via the acceptance criterion's actual wording ("does not require a tool literally named X to function") into a precise constraint: 0 occurrences for 2 adapter-isolated skills, exactly 1 confined-to-a-labeled-note occurrence for the other 7 -- flagged explicitly in the dev report, confirmed correct by both reviewers independently.

Related: [[respect-named-scope-boundaries]] [[front-load-exact-mechanics-in-design-docs]]
