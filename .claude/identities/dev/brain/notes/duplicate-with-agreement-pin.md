---
tags: [tests, refactoring]
paths: ["plugins/spec-workflow/**"]
strength: 1
source: "#73 retro"
graduated: false
created: 2026-07-08
---

Duplicating a formula to keep pinned extraction tests untouched is a legitimate trade ("duplicated code" for "isolated risk") — but write the AGREEMENT check in the same pass, never just a keep-in-sync comment. And perturbation-test your own pins as a matter of course (temporarily break the protected thing, confirm the test fires, revert): it's the only proof a regression test discriminates.

Related: [[batch-red-across-surfaces]] [[enumerate-state-writers]]
