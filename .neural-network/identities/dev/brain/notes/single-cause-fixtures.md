---
tags: [tests, fixtures]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "#53 retro"
graduated: false
created: 2026-07-08
---

Don't cram a new case into a bundled multi-error fixture — a dict key holds one value, so overwriting to "add" a case silently drops the previous assertion's coverage. Small single-cause fixtures (otherwise-valid config, one bad value) keep every prior assertion intact and make failures trivially attributable.

Related: [[hermetic-tmpdir-per-guard-case]] [[bool-excluded-before-int]]
