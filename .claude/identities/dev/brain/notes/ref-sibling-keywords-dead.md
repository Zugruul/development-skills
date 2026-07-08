---
tags: [jsonschema, docs]
paths: ["plugins/spec-workflow/schemas/**"]
strength: 1
source: "#80 retro"
graduated: false
created: 2026-07-08
---

Draft-07 JSON Schema ignores sibling keywords next to a bare {"$ref": ...} — a description written at the ref SITE is dead prose that never renders on hover. Put the description on the definition itself, or wrap the ref in allOf when sibling keywords must apply. A schema can LOOK documented in source and not be on hover; only a resolution-aware walk catches it.

Related: [[presence-vs-value-claims]]
