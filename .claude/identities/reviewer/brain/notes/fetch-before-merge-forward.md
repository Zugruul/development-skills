---
tags: [review, git]
paths: ["**"]
strength: 1
source: "#66 review retro"
graduated: false
created: 2026-07-08
---

`git fetch origin` is a MANDATORY first step before any merge-base/merge-forward/collision check — a stale local origin/main silently produces a false "clean merge-forward" against a remote that has moved. Print/inspect the fetch output so "already up to date" vs "new commits pulled" is visible, then compare.

Related: [[diff-against-merge-base]] [[explicit-cd-every-command]]
