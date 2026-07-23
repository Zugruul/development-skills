---
tags: [tdd, testing, red-first]
paths: ["plugins/spec-workflow/tests"]
strength: 1
source: "retro 373 (dev interview)"
graduated: false
created: 2026-07-22
---

A red test result is only evidence when its FAILURE TEXT matches the predicted failure. A crash with the right exit code but the wrong error message is a fake red — fixing it validates nothing. Run a new regression test standalone and read its actual output before trusting the red; only then implement.

Related: [[capture-dont-transcribe]] [[hermetic-fixture-pins-all-search-paths]]
