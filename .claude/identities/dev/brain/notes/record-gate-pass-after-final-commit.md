---
tags: [gate, tdd, process]
paths: ["plugins/spec-workflow/**"]
strength: 1
source: ""
confidence: direct
learned-from: 479
graduated: false
created: 2026-07-29
last-touched: 2026-07-29
---

Run the recorded gate AFTER the round's final commit, never before: the pass fingerprint binds HEAD plus the uncommitted diff, so committing byte-identical content immediately invalidates a pass recorded pre-commit — the In-review move blocks and the whole multi-minute suite must re-run on an unchanged tree. Sequence is commit first, then gate.sh, then stop.

Related: [[gate-runs-take-minutes]]
