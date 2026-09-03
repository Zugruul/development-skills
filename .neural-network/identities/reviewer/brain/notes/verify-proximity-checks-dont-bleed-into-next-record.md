---
tags: [review, testing]
paths: ["**"]
strength: 1
source: "PR#233 (CDX-031, #188) round 1 -- a 6-line awk window let invariant N+1's own verdict word satisfy invariant N's check, defeating it for 8 of 9 invariants"
graduated: false
created: 2026-07-19
---

When reviewing a "proximity window" check (e.g. an awk/grep window of N lines after a match, used to associate a value with the nearest preceding label), check whether the window is wide enough to accidentally reach the NEXT record's own matching content -- a repeating-record document (one paragraph per item, consistent spacing) is exactly the shape where this silently defeats the check for every item except the last one. Prove it by deliberately stripping the target value from the record under test and confirming the check actually fails; don't trust that "the check passed on the real data" means it discriminates.

Related: [[trace-dict-merge-for-key-collisions]] [[reproduce-claimed-bug-fix-before-and-after]]
