---
tags: [python, harness, measurement, robustness]
paths: ["plugins/spec-workflow/scripts/assistant/**"]
strength: 1
source: "PR-close #315 review r2"
graduated: false
created: 2026-07-22
---

Measurement harnesses must persist PARTIAL results honestly: a crash in gate 5 of 5 discarding gates 1-4 wastes paid-for real-provider work and hides evidence. Pattern: per-gate try/except recording {passed: false, error} + a top-level incomplete marker, atomic tmp+rename for the results artifact (it gets committed), and completed-gates-survive as a regression check. Probe-ordering gotcha: run_gates executes N1..N5 order regardless of request order — crash fixtures must sort AFTER the gate expected to complete.

Related: [[tracked-config-atomic-writes]] [[advisory-scripts-catch-oserror]]
