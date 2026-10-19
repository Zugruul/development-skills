---
tags: [audit, inventory, runtime]
paths: ["**/local-state.manifest", "**/audits/*"]
strength: 1
source: "Task #274 independent review and runtime audit"
confidence: direct
graduated: false
created: 2026-10-19
last-touched: 2026-10-19
---

## Make a broad audit reviewable
Pair an exact per-file inventory with a smaller table of runtime writer families. The inventory exposes omissions; the family table records resolved defaults, source sites, policy, and exclusions. Neither replaces the other.

## Distinguish evidence
- Follow current write sites separately from legacy readers.
- Explain external state and caller-selected destinations instead of inventing repository ignore rules.
- Verify derived exceptions inside tracked directories without hiding their durable contents.
