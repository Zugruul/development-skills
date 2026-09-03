---
tags: [review, python, verification, fixtures]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "PR-close #301 reviewer interview"
graduated: false
created: 2026-07-22
---

For a pure-library Python module, import-and-probe it directly (sys.path.insert + call functions with adversarial inputs) SEPARATELY from running the shipped bash fixtures — a checker section only proves the function does what its own author decided to assert. Example gap this found: every marker fixture built input with literal \n, so no fixture could ever exercise text.splitlines()'s wider definition of a line (\x0b/\x0c/unicode separators); writing to the grammar spec, not Python's line semantics, made that structurally invisible to the suite.

Related: [[reports-are-not-the-code]] [[verify-with-library-own-classes]]
