---
tags: [debugging, flaky, diagnosis]
paths: ["plugins/spec-workflow/**"]
strength: 1
source: "PR-close #437 / #412 investigation"
graduated: false
created: 2026-07-27
last-touched: 2026-07-27
---

When a "flaky" failure has survived multiple fixes, stop chasing hypotheses and run discriminator analysis: list every red and green run and find the single variable that separates them. The 43-fail cluster's discriminator was the INVOKER (every gate.sh run red, every direct run-tests.sh run green) — pointing straight at gate.sh's PYTHONPATH export. Earlier theories (TMPDIR bloat, concurrency) each fit partial evidence and each shipped a fix that changed nothing.

Related: [[cheap-ab-before-10min-runs]]
