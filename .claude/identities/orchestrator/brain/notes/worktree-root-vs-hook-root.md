---
tags: [process, worktree, gate, telemetry]
paths: ["plugins/spec-workflow/scripts/gate.sh plugins/spec-workflow/scripts/telemetry.py"]
strength: 1
source: ""
confidence: direct
learned-from: 480
graduated: false
created: 2026-07-28
last-touched: 2026-07-28
---

When a session works in a git worktree but board.sh/hook enforcement runs against the MAIN checkout, every recorded artifact the hooks read (gate-pass, telemetry.jsonl review-round events) must be recorded against the root the HOOK reads, not the session's cwd. Symptoms seen on #480: 'In review' move BLOCKED right after a green gate (pass recorded for the worktree tree, move run from the main checkout), then the QA move BLOCKED because review-round telemetry sat in the worktree's .claude/telemetry.jsonl. Rule: before any status move, ask "which root will the guard hook resolve?" — run the recorded gate from the tree being reviewed, and record telemetry with root = the checkout board.sh runs from; when they differ, record in both rather than diagnosing after a BLOCK.
