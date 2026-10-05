---
tags: [python, sys-path, guards, ordering]
paths: ["plugins/spec-workflow/scripts/**/*.py"]
strength: 1
source: "PR-close #437"
graduated: false
created: 2026-07-27
last-touched: 2026-07-27
---

A guard like `if X not in sys.path: insert(0, X)` tests PRESENCE but protects an ORDERING invariant — the two are different questions. Under gate.sh's exported PYTHONPATH the dir was present at the wrong position, the insert was skipped, and the wrong `config` module shadowed the right one (the deterministic 43-fail cluster behind #412). For ordering guards use remove-then-insert so the intended position always wins.

Related: [[reproduce-the-failing-env]]
