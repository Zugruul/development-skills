---
tags: [tdd, config, tests]
paths: ["plugins/spec-workflow/**"]
strength: 2
source: "#66 retro — recurrence (pin-first discipline)"
graduated: false
created: 2026-07-08
---

When a config knob or doc pin must appear in N surfaces, write ALL N test batches in ONE red commit before implementing. Pin discipline: run the red check against the LITERAL string you intend to pin BEFORE writing the fix (soft-wrapped prose and case mismatches only surface when the grep actually runs) — pinned phrases are plain text, one physical line, exact case.

Related: [[single-cause-fixtures]] [[flag-safety-language-removal]]
