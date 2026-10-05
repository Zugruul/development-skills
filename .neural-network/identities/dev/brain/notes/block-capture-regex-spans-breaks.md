---
tags: [regex, yaml, sync, robustness]
paths: ["plugins/spec-workflow/scripts/sync-configs.py"]
strength: 1
source: "retro 2026-07-21 #276 review"
graduated: false
created: 2026-07-21
---

A regex that captures an indented YAML block via `(?:[ \t]+\S.*\n?)*` STOPS at the first blank line or column-0 comment inside the block — keys below the break become invisible, and an "insert if absent" rule will insert a DUPLICATE key that yaml.safe_load silently resolves last-wins (committed contradiction, no validator complaint). Block captures must span blank/comment lines up to the next column-0 key, and absence-checks deserve a post-edit duplicate-key count as defense in depth.

Related: [[type-validate-jsonl-reads]] [[apply-blocks-guard-empty-candidates]]
