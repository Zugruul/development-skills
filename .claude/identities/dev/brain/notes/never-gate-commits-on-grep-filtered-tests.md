---
tags: [testing, shell, process]
paths: []
strength: 1
source: "loop-feedback 2026-07-29 (485 close)"
confidence: direct
graduated: false
created: 2026-07-29
last-touched: 2026-07-29
---

Never chain a commit after a grep-filtered test run: 'tests | grep FAIL && commit' commits exactly when failures ARE found, because grep exits 0 on match -- the guard is inverted. Gate on the runner's own exit code, and issue the commit as a separate command only after reading the result. One red commit landed this way and had to be fixed forward within minutes.
