---
tags: [tdd, brains, worktrees]
paths: ["**"]
strength: 1
source: "development-skills#239 implementation and independent review"
confidence: direct
graduated: false
created: 2026-10-18
last-touched: 2026-10-18
---

## Keep recall bookkeeping outside implementation history

- Record pre-brief recall metadata in a separate orchestrator checkout and integrate it during closure.
- A structural TDD guard can classify JSON or JSONL memory changes as implementation, even when no source changed.
- Check the red-first preflight early so a bookkeeping commit cannot surprise the review transition after a long gate.

If repairing an unpublished task branch, preserve its original history, change only metadata ordering, prove the final tree is identical, replay the real RED, and rerun both preflights. Never add a vacuous test commit or weaken the guard.

Related: [[canonical-merge-locus]] [[front-load-exact-mechanics-in-design-docs]]
