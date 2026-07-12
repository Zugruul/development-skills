---
tags: [gate, concurrency]
paths: []
strength: 1
source: "retro"
learned-from: PR #153 retro
graduated: false
created: 2026-07-11
---


# Gate/test runs need exclusive use of the working tree

Never run gate.sh or the test suite concurrently with other Bash calls that
touch the repo's fixtures or tmp state — parallel runs race and produce false
REDs. When a gate comes back red during a review, first rule out
self-inflicted concurrency (rerun clean, serially) before treating it as a
finding against the PR.
