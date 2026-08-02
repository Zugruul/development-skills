---
tags: [delegation, worktree, concurrency]
paths: ["plugins/spec-workflow/skills/build-next"]
strength: 1
source: "feedback 2026-08-02 item 1, two mispinned dev agents"
confidence: direct
graduated: false
created: 2026-08-01
last-touched: 2026-08-01
---

Subagent working-directory pinning follows the SPAWNING session's cwd, not the brief: every brief that names a worktree must tell the agent to verify pwd against the brief before its first write and re-pin via the worktree-entry tool if they disagree. The orchestrator's own path-guarded tools and tree-fingerprint hooks likewise evaluate ITS pinned tree, not the task's — plan board moves and edits around that. Related: [[worktree-lane-default]], [[dev-idle-recovery-ladder]].
