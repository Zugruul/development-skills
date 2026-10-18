---
tags: [cli, json, testing, stderr]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "Issue #538: successful Codex install warning broke JSON parsing"
confidence: direct
graduated: false
created: 2026-10-18
last-touched: 2026-10-18
---

## Boundary
Capture machine-readable stdout separately from diagnostic stderr. Preserve the command exit code before parsing; valid JSON does not prove success.

## Regression
Drive the existing harness with warning-bearing success, malformed stdout, and valid JSON with a failed exit status. Keep the real CLI roundtrip alongside fixtures.

Related: [[pin-exit-code-not-just-output-in-helper-tests]]
