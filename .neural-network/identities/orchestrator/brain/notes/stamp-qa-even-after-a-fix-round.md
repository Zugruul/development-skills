---
tags: [board, process, discipline]
paths: ["**"]
strength: 1
source: "PR#180 CDX-010 feedback triage"
graduated: false
created: 2026-07-19
---

When a task's merge required a follow-up fix round (a residual CI failure found after the first merge), still stamp QA as its own board transition before Ready -- even under the pull to close out quickly after a longer-than-usual back-and-forth. The underlying validation (CI green, reviews approved) may be genuinely done, but skipping the intermediate status leaves the board history inconsistent with what a reader would expect to see (a task that needed a fix round jumping straight from In review to Ready, with no visible QA stamp).

Recurrence (CDX-010): after the sed-portability fix confirmed CI green, moved the task directly In review -> Ready, skipping QA. Not a substantive gap (the fix WAS verified against the real CI run, which is exactly what QA-stage validation for a CI-outcome task means) but a bookkeeping slip worth catching before it becomes habit.
