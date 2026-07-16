---
tags: [review, verification, concurrency]
paths: []
strength: 1
source: "task #176 (CDX-004) review"
graduated: false
created: 2026-07-16
---

For a task that mutates global/host state (codex/git/system config), don't accept the dev's claim of isolation at face value -- independently reproduce the roundtrip yourself in a throwaway env, AND capture the real config's mtime+size before and after as positive proof it was untouched.

Why: reviewing #176 (CDX-004), reproducing the codex marketplace roundtrip in an isolated CODEX_HOME (rather than trusting the dev's report) was what let a stray pre-existing global marketplace entry be conclusively ruled out as this task's doing. Separately: a destructive verification step (moving the delivered artifact aside to prove the test goes red) raced against a concurrently-running background gate and produced a spurious RED that had to be re-diagnosed and disproven with a clean re-run.

How to apply: (1) don't just read a dev's isolation claim, reproduce it with your own throwaway env and before/after evidence on the real state. (2) serialize any move-aside/mutate-then-restore verification step against concurrent gate runs -- confirm no background gate is in flight before temporarily perturbing the tree, or you'll manufacture a false failure and waste a round chasing it.
