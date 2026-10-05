---
tags: [review, process, calibration]
paths: ["**"]
strength: 1
source: "PR#180 CDX-010 post-merge retro"
graduated: false
created: 2026-07-19
---

When a review pass approves a diff that later turns out to have a real bug, distinguish two different failure categories before drawing a lesson: (a) "the reviewer MISSED something checkable" -- a real gap in the review's rigor, fix by reviewing harder/differently; vs (b) "the reviewer's environment structurally could not have caught this" -- not a rigor gap, the bug lives in a divergence between environments and a single-environment review cannot see it BY CONSTRUCTION, no matter how thorough. Conflating these leads to the wrong fix: telling a reviewer to "be more careful" about a category-(b) bug wastes effort and doesn't prevent recurrence; the actual fix is adding a NEW kind of check (a cross-environment reproduction step) that didn't exist before, not doing the SAME check harder.

Recurrence (CDX-010): a GNU/BSD sed portability bug slipped past two thorough, correct-at-the-time first-round reviews (both approved, both had run the tests, both read every diff hunk) because neither reviewer had access to a GNU sed environment -- category (b), not a rigor failure. The actual fix was adding a specific cross-environment reproduction step to the SECOND review pass (see [[verify-portability-claims-in-target-environment]]), not redoing the first pass more carefully.

Related: [[verify-portability-claims-in-target-environment]]
