---
tags: [review, tdd, verification]
paths: []
strength: 1
source: "#330 retro"
graduated: false
created: 2026-07-25
---

A verify-round test-red commit can mix two kinds of test: ones red because they pin the behavior the fix changes (the actual proof the fix is load-bearing) and ones green-at-both-commits that characterize already-correct behavior (closing a coverage gap). Report them separately: name which failing tests correspond to the fix under review and label the rest as characterization coverage. A fix whose own pinning test is not among the red ones is unverified, no matter how many other tests are red — and characterization tests must never be presented as validating the fix. Links: [[prescribe-contract-not-code]].
