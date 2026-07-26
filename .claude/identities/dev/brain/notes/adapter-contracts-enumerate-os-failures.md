---
tags: [python, subprocess, errors]
paths: ["plugins/spec-workflow/scripts/assistant/**"]
strength: 1
source: "#408 fix"
graduated: false
created: 2026-07-26
last-touched: 2026-07-26
---

A wrapper documented as 'never lets a raw exception escape' must enumerate OS-level failure modes explicitly: missing binary (FileNotFoundError), EPERM, ENOEXEC — not just nonzero-exit/timeout/parse-failure. adapters.invoke_cli caught TimeoutExpired only; Popen's FileNotFoundError bypassed the whole AdapterError taxonomy and crashed CI for 8+ runs.

Related: [[diff-ambient-binaries-for-env-divergence]]
