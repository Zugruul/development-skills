---
tags: [review, tdd, verification]
paths: []
strength: 1
source: "task #177 (CDX-005) review"
graduated: false
created: 2026-07-16
---

When verifying a TDD red-test claim, don't just read the diff and trust the commit message says it fails for the right reason -- reconstruct the actual pre-fix state (revert one change, or check out the earlier commit) and re-run the specific check to confirm the failure message matches the claimed defect exactly.

Why: reviewing #177 (CDX-005), reconstructing one pre-fix angle-bracket description and re-running the validator produced the exact expected error ("Description cannot contain angle brackets"), confirming the red commit's test discriminates for the right reason rather than merely existing and happening to fail for some coincidental reason.

How to apply: for any review where TDD-first is a claimed criterion, spend the extra few minutes reconstructing the pre-fix state and re-running the new test against it -- a red commit that exists is not the same evidence as a red commit proven to fail for the stated reason.
