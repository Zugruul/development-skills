---
tags: [streaming, privacy, protocols]
paths: ["plugins/spec-workflow/scripts/assistant/**"]
strength: 1
source: "Task #523 round2 close"
confidence: direct
graduated: false
created: 2026-10-18
last-touched: 2026-10-18
---

## Preserve semantic boundaries

A streaming privacy filter needs provider message and text-block boundaries as well as character deltas. Flattening separate messages can turn a line-anchored private directive into public inline text.

## Verify the full sequence

- Normalize boundaries before any public callback.
- Exercise tool cycles in both initial and follow-up completions.
- Vary message/block topology, populated block starts and chunk splits independently.
- Keep thinking, tool and nested-agent content out of public callbacks.

Related: [[protocol-layer-failure-enumeration]] [[capture-real-output-as-fixtures]]
