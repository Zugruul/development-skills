---
tags: [queue, identity, snapshot]
paths: ["plugins/spec-workflow/scripts/board-queue.sh", "plugins/spec-workflow/scripts/wip.py"]
strength: 1
source: "#240 regression RED and task-close retro"
confidence: direct
graduated: false
created: 2026-10-18
last-touched: 2026-10-18
---

## Queue deletion needs evidence

An already-target shortcut changes durable recovery state even when it performs no remote mutation. Validate the complete fresh snapshot and one unambiguous target before discarding a queued operation.

## Check both paths

- Test the mutation path and the no-mutation skip separately.
- Feed malformed, incomplete and ambiguous remote states into the real replay command; require the pending operation to survive.
- Changing a local cache alone does not exercise a skip that reads the remote board.

Related: [[boundary-test-needs-exact-value-plus-absence-check]]
