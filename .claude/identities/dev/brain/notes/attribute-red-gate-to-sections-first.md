---
tags: [gate, debugging, test-suite]
paths: ["plugins/spec-workflow/tests/run-tests.sh"]
strength: 1
source: "retro AST-020 (dev interview)"
graduated: false
created: 2026-07-22
---

When the gate is red, FIRST attribute every FAIL line to its owning section from one captured log (awk: track the last seen section header, print it per FAIL, sort -u) before rerunning anything. A narrow diff with a red gate is usually an unrelated section — attribution from the existing log saves a full extra suite run compared to eyeballing a truncated tail.
