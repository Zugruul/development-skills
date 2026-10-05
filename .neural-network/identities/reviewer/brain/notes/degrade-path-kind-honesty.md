---
tags: [review, error-handling, classifiers]
paths: ["plugins/spec-workflow/scripts/assistant"]
strength: 1
source: "retro AST-020 (reviewer interview)"
graduated: false
created: 2026-07-22
---

When a diff adds a fail-closed classifier with a catch-all degrade path, review WHAT LABEL the degrade path reuses, not just that it degrades cleanly. A crash relabeled as an ordinary benign kind stays honest only until someone branches logic on that kind. Check two things: does the reused kind still tell the truth for the crash case, and does a test assert the DEGRADED entry's own kind/detail rather than only that the operation as a whole survived.
