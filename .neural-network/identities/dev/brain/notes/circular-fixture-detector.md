---
tags: [tests, fixtures, detection]
paths: ["plugins/spec-workflow/tests/**", "plugins/spec-workflow/scripts/**"]
strength: 1
source: "#77 retro (+#90 live evidence)"
graduated: false
created: 2026-07-08
---

A fixture whose error text was authored alongside the detector proves only that the detector matches itself — zero independent signal. Before trusting any error-text classifier: pull one REAL captured failure string (or ask who has hit it); if unavailable, give the classifier an independent confirmation probe (a stable endpoint) instead of a string match. Also: when changing an error message's shape, grep the whole test tree for assertions on the OLD shape as part of DESIGN, not as a reaction to a red suite.

Related: [[unassumed-full-pipeline-repro]] [[bool-excluded-before-int]]
