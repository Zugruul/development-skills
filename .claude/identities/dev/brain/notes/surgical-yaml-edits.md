---
tags: [yaml, config, round-trip]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "PR#3 review round 1"
graduated: false
created: 2026-07-07
---

Read-modify-write of human-authored YAML must preserve comments and formatting byte-for-byte: surgical line-level edits for known keys, never parse+redump. Also: open(f).read() must be fully evaluated BEFORE open(f,'w') truncates.

Related: [[budget-count-join-separators]]
