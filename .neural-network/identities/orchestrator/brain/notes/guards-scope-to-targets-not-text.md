---
tags: [hooks, guards, process]
paths: []
strength: 1
source: "loop-feedback 2026-07-29 (batch 2)"
confidence: direct
graduated: false
created: 2026-07-29
last-touched: 2026-07-29
---

A protective hook that regex-matches command TEXT for guarded paths fires on legitimate maintenance work that merely mentions those paths in strings (heredocs patching the very tooling that manages the guarded area). Scope guards to the actual FILE TARGETS an operation reads/writes, not to any textual mention -- otherwise maintainers route around the guard with string-splitting, which is worse than the narrow gap the guard closes.
