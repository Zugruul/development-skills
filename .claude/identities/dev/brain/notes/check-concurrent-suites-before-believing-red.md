---
tags: [tests, flakes, concurrency]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "#412 incident 2026-07-26"
graduated: false
created: 2026-07-26
last-touched: 2026-07-26
---

Before treating a red full-suite/gate run as real, pgrep for other run-tests.sh/gate.sh processes — worktree isolation does NOT isolate ports or shared /tmp: a '43 failed' cluster reproduced 4x purely from concurrent sibling suites and vanished solo. Mechanical fix tracked as #412 (gate.sh flock); until it lands, check by hand.

Related: [[deterministic-repro-fast]]
