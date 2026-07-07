---
tags: [testing, portability]
paths: []
strength: 1
source: ""
learned-from: loop-feedback 2026-07-07 task-15
graduated: false
created: 2026-07-07
---

Tests validate against the HOST interpreter, not the deployment floor — 3.12+-only python syntax (e.g. same-quote nesting in an f-string expression) passes green when a newer interpreter is first in PATH, then crashes on the stock interpreter every install ships. py_compile only covers standalone .py files, NOT inline python -c snippets in shell scripts. Guard with a static lint for known newer-only constructs across ALL scripts. Third-class portability lesson. Related: [[bash32-empty-array-set-u]], [[loop-state-fingerprint-exclusion]].
