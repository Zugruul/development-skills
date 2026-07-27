---
tags: [review, verification, empiricism]
paths: ["plugins/spec-workflow/**"]
strength: 1
source: "PR-close #437 review"
graduated: false
created: 2026-07-27
last-touched: 2026-07-27
---

Never review a fix against its own commit message — reproduce the root cause yourself before the verdict. For #437 one python3 -c (set PYTHONPATH, emulate sys.path[0], print config.__file__) converted "plausible" into "the old code provably died at setup.py:70". The same discipline caught my own confidently-wrong bash-3.2 claim before I filed it. The cheap empirical check is almost always under a minute.

Related: [[grep-for-the-third-site]]
