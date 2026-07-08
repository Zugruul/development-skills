---
tags: [review, python, verification]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 2
source: "#53 review retro — recurrence (bool/float fixtures)"
graduated: false
created: 2026-07-08
---

importlib-load or directly execute the changed code with adversarial inputs BEYOND the shipped tests (bool-as-int, float-equals-int, alternate wordings, oversized lines) — for dynamically-typed edge cases execution is the only real proof; reasoning about isinstance()/coercion semantics from memory gets subtly wrong exactly where it matters.

Related: [[verify-with-library-own-classes]] [[json-escaped-check-weakness]]
