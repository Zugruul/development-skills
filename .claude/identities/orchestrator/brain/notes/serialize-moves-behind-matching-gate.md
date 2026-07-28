---
tags: [concurrency, gates, board]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: ""
confidence: direct
learned-from: #458-comment,2026-07-28
graduated: false
created: 2026-07-28
last-touched: 2026-07-28
---

The recorded gate pass is ONE shared last-writer-wins marker, and guard-board-move's tree fingerprint follows the SESSION's cwd (git toplevel at hook time), not the command's cd. Running N lanes means any lane's gate.sh clobbers the marker; a board move only passes when (session tree == marker tree). Working sequence: pin the session cwd (EnterWorktree) to the tree you gated, run the gate for THAT tree, and do every pending In-review move immediately after it records — batching all unlocked moves into that window. Never cd into another checkout inside the move command (board-queue's inner preflight then fingerprints the WRONG tree). Cost of learning this live: three redundant ~9-minute suite runs. Fix proposal filed on #458 (per-tree pass records).

Related: [[squash-merge-kills-branch-anchors]]
