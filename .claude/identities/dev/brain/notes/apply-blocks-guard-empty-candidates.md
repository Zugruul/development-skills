---
tags: [cli, destructive, propose-only]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "retro 2026-07-21 GL-004 review round"
graduated: false
created: 2026-07-21
---

A propose-only rule must not share a destructive verb's apply block: with zero actionable candidates the block still runs its writes (rewriting or even CREATING the state file) and prints misleading "removed 0" output. Skip the apply block explicitly when the actionable set is empty, with a message naming why, and test the empty-candidates + --apply path — including the file-absent-stays-absent variant.

Related: [[type-validate-jsonl-reads]]
