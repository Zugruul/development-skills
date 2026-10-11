---
tags: [validation, schema, serialization]
paths: ["plugins/remote-compute/**"]
strength: 1
source: "issue526 review round1"
confidence: direct
graduated: false
created: 2026-10-11
last-touched: 2026-10-11
---

## Validate meaning at the use site

- An allowed schema-option name does not prove its semantics are supported everywhere.
- Bind behavioral flags to the exact node/input and expected type/value. A dynamic-prompt flag on a filename widget can change serialization even when the core class and widget count still match.
- Test relocated flags, truthy non-booleans and malformed defaults alongside valid ordinary values.

Related: [[bool-before-int-guard]] [[bind-contract-checks-to-clauses]]
