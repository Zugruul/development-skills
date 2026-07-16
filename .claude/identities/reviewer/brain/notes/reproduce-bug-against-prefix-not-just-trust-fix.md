---
tags: [review, verification, bash]
paths: []
strength: 1
source: "task #130 (MEM-011) review"
graduated: false
created: 2026-07-16
---

Verify a bug-fix claim adversarially: reproduce the ORIGINAL bug directly against the pre-fix code (not just confirm the fix's tests pass), so 'this was a real bug' is a demonstrated fact rather than a trusted assertion.

Why: reviewing #130 (MEM-011), the dev claimed local-state.sh's read-loop left $?==1 on success. Reproducing it directly against origin/main's pre-fix version (not just running the fix's own passing tests) confirmed the bug was real and load-bearing -- it would have made gitignore-sync.sh abort with a false error -- rather than a misdiagnosis or an already-latent-but-harmless issue.

How to apply: when a dev's report claims 'X was broken, I fixed it,' don't just confirm the new tests pass -- check out or otherwise exercise the pre-fix state directly and confirm the claimed failure actually reproduces there. Construct your own adversarial fixtures (a stale block with deliberately weird spacing, a track path hit only from within the managed block itself) rather than only re-running the dev's own test suite -- independent fixtures catch what a shared blind spot wouldn't.
