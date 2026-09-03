---
tags: [validation, schema, errors]
paths: ["plugins/spec-workflow/scripts/assistant/**"]
strength: 1
source: "PR-close #338"
confidence: direct
graduated: false
created: 2026-07-27
last-touched: 2026-07-27
---

For any function promising "never a bare stack trace, always this typed error", coverage needs TWO axes: values that violate the schema, AND declarations that are internally inconsistent (a malformed regex pattern, a non-string argv element, a placeholder referencing an optional-and-omitted param). All three round-2 escapes in the invoke path were schema-VALID inputs whose declaration was broken — a five-minute adversarial pass over "what can the declaring author get wrong" up front catches the class.
