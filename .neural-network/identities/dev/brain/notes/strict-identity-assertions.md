---
tags: [tests, tdd, assertions]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "retro 2026-07-21 GL-005/GL-004 review rounds"
graduated: false
created: 2026-07-21
---

Byte-identity claims must be asserted with cmp against snapshot FILES (or exact string equality), never `grep -F` of a multiline expected string — grep treats each line as an alternative pattern, so any shared line makes the check vacuously pass. File-based cmp also catches trailing-newline drift that command-substitution comparison strips. Two review rounds in one session were spent on exactly this.

Related: [[batch-red-across-surfaces]] [[single-cause-fixtures]]
