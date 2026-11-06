---
tags: [guards, verification, review]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "#551 review"
confidence: direct
graduated: false
created: 2026-11-05
last-touched: 2026-11-05
---

A guard fix is only proven when the guard passes on the branch it blocked.

## What happened
- Fixture tests showed the new patterns worked.
- A reviewer pointed out the real commit might also touch `mod.rs`, which the fix would not unblock.
- One read-only run on the real lane settled it: the old guard blocked, the new one exited 0.

## What to do
- Run old and new guards, read-only, on the real branch before merging.
- A reported cause is a pointer until the real commit's file list is checked.

Related: [[check-external-api-semantics-live-early]]
