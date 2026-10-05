---
tags: [review, tdd, process]
paths: []
strength: 1
source: "#410+#408 reviews"
graduated: false
created: 2026-07-26
last-touched: 2026-07-26
---

Red-first is a HISTORY property: a single commit carrying test+fix, even with a convincing stash-cycle repro in the report, is a TDD-order violation — demand the red commit or record the violation plainly. Two independent single-commit violations caught on 2026-07-26 (#410, #408); both devs' tests survived mutation testing, which is why the work stood while the process finding was still recorded.

Related: [[rerun-the-red-empirically]] [[red-commit-worktree-verify]]
