---
tags: [bash, testing, tdd]
paths: []
strength: 1
source: "PRV-003 (#169)"
graduated: false
created: 2026-07-15
---

When chaining two already-tested scripts (diff-source + peer-review), the wiring layer itself IS testable production logic, not just glue -- write tests for it (stub the underlying scripts, assert on real invocation args + content, not just call-count) rather than treating orchestration as 'obviously correct' prose. This PRV-003 correctly did this.
