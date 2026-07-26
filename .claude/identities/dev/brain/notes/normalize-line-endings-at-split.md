---
tags: [javascript, parsing]
paths: ["plugins/spec-workflow/templates/**"]
strength: 1
source: "#405 review finding"
graduated: false
created: 2026-07-26
last-touched: 2026-07-26
---

Normalize line endings ONCE at the split (split on /\r?\n/), never per-regex: an end-anchored bare $ silently fails on CRLF lines, and a file where 3 of 4 regexes have \s*$ slack and one does not will drop exactly that one line type with no error.

Related: [[boundary-test-needs-exact-value-plus-absence-check]]
