---
tags: [debugging, tdd, environment]
paths: ["plugins/spec-workflow/**"]
strength: 1
source: "PR-close #437"
graduated: false
created: 2026-07-27
last-touched: 2026-07-27
---

Trust a fix only after reproducing the exact failing ENVIRONMENT, not after the suite goes green — the #437 bug stayed invisible to every direct test run because only gate.sh's env exported PYTHONPATH. The red commit mattered precisely because it forced that env into the test itself; also run the literal repro command from the task before committing, it asserts something different than "my new check passes".

Related: [[guard-presence-vs-position]]
