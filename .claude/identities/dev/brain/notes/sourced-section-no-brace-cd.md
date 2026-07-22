---
tags: [tests, shell, run-tests, cwd]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: ""
confidence: direct
learned-from: GL-050 #300 gate incident
graduated: false
created: 2026-07-22
last-touched: 2026-07-22
---

section-*.sh test files are SOURCED into run-tests.sh's single process — any `cd` not inside a subshell `( ... )` or `$( ... )` leaks cwd to every later section, and a following `rm -rf` of that dir strands the whole suite in a deleted cwd (39 cascade failures in unrelated server/CLI sections). Running the new section in isolation (--section) is necessary but NOT sufficient — nothing after it in a filtered run exercises the leak. Structural check before any full-suite run on a new/edited section file: grep it for brace-group cd (`{ cd ...` / `^{$`) and convert to subshells; apply the discipline to inline mutation blocks, not just fixture helpers.

Related: [[batch-red-across-surfaces]]
